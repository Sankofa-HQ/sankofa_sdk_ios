import Foundation
import GRDB

/// Offline-first, thread-safe event queue backed by SQLite via GRDB.
///
/// Mirrors `EventQueueManager` in the Android SDK (Room) and
/// `SankofaQueueManager` in the Flutter SDK (SharedPreferences).
/// GRDB is preferred over CoreData for its simpler threading model.
final class SankofaQueueManager {

    // MARK: - Types

    struct QueuedEvent: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "events"

        var id: Int64?
        var type: String
        var payload: Data      // JSONEncoder'd [String: Any]
        var createdAt: Date
        /// Failed-upload counter. Bumped each time an event is retained for
        /// retry (5xx/network); the event is dropped once it crosses
        /// `maxAttempts` so a permanently-failing event can't wedge the queue.
        var attempts: Int = 0

        mutating func didInsert(_ inserted: InsertionSuccess) {
            id = inserted.rowID
        }
    }

    /// Hard cap on queued rows. Beyond this, the oldest events are evicted on
    /// insert (replay chunks first) so a long offline stretch — or a wedged
    /// upload — can't grow the SQLite file without bound.
    static let maxQueuedEvents = 10_000
    /// Drop an event after this many failed upload attempts.
    static let maxAttempts = 8

    // MARK: - State

    private let db: DatabasePool
    private let logger: SankofaLogger
    private let lock = NSLock()
    
    // 💨 PERFORMANCE FIX: Serial queue for DB writes to avoid priority inversion.
    // We use .utility QoS to ensure it doesn't starve the Main Thread but stays
    // ahead of .background tasks.
    private let writeQueue = DispatchQueue(label: "dev.sankofa.database.write", qos: .utility)

    // MARK: - Init

    init(logger: SankofaLogger) {
        self.logger = logger

        let dbPath: String = {
            let dir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!
                .appendingPathComponent("SankofaIOS", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("queue.sqlite").path
        }()

        var database: DatabasePool
        do {
            // 🚨 CONCURRENCY FIX: Use DatabasePool instead of DatabaseQueue.
            // DatabasePool automatically enables WAL (Write-Ahead Logging) mode,
            // allowing the FlushManager to read batches while the Replay engines
            // are writing frames simultaneously.
            database = try DatabasePool(path: dbPath)
            try Self.setupSchema(database)
            logger.log("💾 SQLite queue (WAL mode) opened at \(dbPath)")
        } catch {
            // Fallback: Use a temporary in-memory pool if the file system
            // fails. The schema MUST be created here too — previously it
            // wasn't, so the fallback DB had no table and silently dropped
            // every event.
            let memory = try! DatabasePool(path: ":memory:")
            try? Self.setupSchema(memory)
            database = memory
            logger.warn("⚠️ Failed to open SQLite pool, using in-memory: \(error)")
        }
        self.db = database
    }

    /// Create the events table and apply lightweight migrations. Shared by
    /// the on-disk and in-memory paths so both always have a valid schema.
    private static func setupSchema(_ database: DatabasePool) throws {
        try database.write { db in
            try db.create(table: QueuedEvent.databaseTableName, ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("type", .text).notNull()
                t.column("payload", .blob).notNull()
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
                t.column("attempts", .integer).notNull().defaults(to: 0)
            }
            // Migration: add `attempts` to DBs created before this column existed.
            let hasAttempts = try db.columns(in: QueuedEvent.databaseTableName)
                .contains { $0.name == "attempts" }
            if !hasAttempts {
                try db.alter(table: QueuedEvent.databaseTableName) { t in
                    t.add(column: "attempts", .integer).notNull().defaults(to: 0)
                }
            }
        }
    }

    // MARK: - Public

    /// Enqueue an event payload dictionary.
    func enqueue(_ event: [String: Any], type: String? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: event) else {
            logger.warn("❌ Could not serialise event")
            return
        }
        
        let eventType = type ?? (event["type"] as? String ?? "track")
        let createdAt = Date()
        
        // 💨 ASYNC WRITE: Offload to serial queue to prevent priority inversion.
        // This ensures tracking from the Main Thread doesn't wait on background replays.
        writeQueue.async { [weak self] in
            guard let self else { return }
            
            var record = QueuedEvent(id: nil, type: eventType, payload: data, createdAt: createdAt, attempts: 0)
            do {
                try self.db.write { db in
                    try record.insert(db)
                    // Enforce the queue cap to bound disk usage. Evict oldest,
                    // replay chunks first (large + reconstructable), then
                    // anything else — and log the eviction (never silent).
                    let total = try QueuedEvent.fetchCount(db)
                    if total > Self.maxQueuedEvents {
                        let overflow = total - Self.maxQueuedEvents
                        let dropped = try self.evictOldest(db, count: overflow)
                        if dropped > 0 {
                            self.logger.warn("⚠️ Queue cap (\(Self.maxQueuedEvents)) reached — evicted \(dropped) oldest event(s)")
                        }
                    }
                }
                self.logger.log("📥 Queued '\(eventType)'")
            } catch {
                self.logger.warn("❌ Failed to enqueue '\(eventType)': \(error)")
            }
        }
    }

    /// Return the number of events currently queued.
    func count() -> Int {
        (try? db.read { try QueuedEvent.fetchCount($0) }) ?? 0
    }

    /// Delete the `count` oldest rows, preferring replay chunks (large,
    /// reconstructable) over track/identify/people events. Returns how many
    /// were actually deleted. Caller is inside a write transaction.
    @discardableResult
    private func evictOldest(_ db: Database, count: Int) throws -> Int {
        guard count > 0 else { return 0 }
        let table = QueuedEvent.databaseTableName
        var deleted = 0
        // 1. Oldest replay chunks first.
        try db.execute(
            sql: "DELETE FROM \(table) WHERE id IN " +
                 "(SELECT id FROM \(table) WHERE type = 'replay_chunk' ORDER BY createdAt ASC LIMIT ?)",
            arguments: [count])
        deleted += db.changesCount
        // 2. If still over, drop oldest of anything.
        let remaining = count - deleted
        if remaining > 0 {
            try db.execute(
                sql: "DELETE FROM \(table) WHERE id IN " +
                     "(SELECT id FROM \(table) ORDER BY createdAt ASC LIMIT ?)",
                arguments: [remaining])
            deleted += db.changesCount
        }
        return deleted
    }

    /// Dequeue the oldest `limit` events, execute `handler`, then delete
    /// successful ones. Failed events remain in the queue for the next flush.
    /// Returns the number of events successfully deleted.
    @discardableResult
    func flush(limit: Int, handler: ([QueuedEvent]) async -> Set<Int64>) async -> Int {
        guard count() > 0 else { return 0 }

        let batch: [QueuedEvent]
        do {
            // 🚨 Use `await` here because we are in an `async` context.
            batch = try await db.read { db in
                try QueuedEvent
                    .order(Column("createdAt").asc)
                    .limit(limit)
                    .fetchAll(db)
            }
        } catch {
            logger.warn("❌ Failed to read queue: \(error)")
            return 0
        }

        // `handler` returns the ids to REMOVE — events that were either
        // accepted by the server OR permanently rejected (4xx poison). Events
        // not in the set are genuine transient failures (5xx/network): bump
        // their attempt counter and drop them once they cross maxAttempts so
        // a permanently-failing event can't block all newer events forever.
        let removeIds = await handler(batch)

        do {
            var droppedPoison = 0
            try await db.write { db in
                for event in batch {
                    guard let id = event.id else { continue }
                    if removeIds.contains(id) {
                        try event.delete(db)
                    } else if event.attempts + 1 >= Self.maxAttempts {
                        try event.delete(db)
                        droppedPoison += 1
                    } else {
                        try db.execute(
                            sql: "UPDATE \(QueuedEvent.databaseTableName) SET attempts = ? WHERE id = ?",
                            arguments: [event.attempts + 1, id])
                    }
                }
            }
            if droppedPoison > 0 {
                logger.warn("⚠️ Dropped \(droppedPoison) event(s) after \(Self.maxAttempts) failed attempts")
            }
            logger.log("🗑 Removed \(removeIds.count)/\(batch.count) events from queue")
            return removeIds.count
        } catch {
            logger.warn("❌ Failed to delete flushed events: \(error)")
            return 0
        }
    }
}
