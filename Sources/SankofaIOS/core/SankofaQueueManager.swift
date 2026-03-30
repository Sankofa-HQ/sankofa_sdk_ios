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

        mutating func didInsert(_ inserted: InsertionSuccess) {
            id = inserted.rowID
        }
    }

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
            try database.write { db in
                try db.create(table: QueuedEvent.databaseTableName, ifNotExists: true) { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("type", .text).notNull()
                    t.column("payload", .blob).notNull()
                    t.column("createdAt", .datetime).notNull().defaults(to: Date())
                }
            }
            logger.log("💾 SQLite queue (WAL mode) opened at \(dbPath)")
        } catch {
            // Fallback: Use a temporary in-memory pool if the file system fails.
            database = try! DatabasePool(path: ":memory:")
            logger.warn("⚠️ Failed to open SQLite pool, using in-memory: \(error)")
        }
        self.db = database
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
            
            var record = QueuedEvent(id: nil, type: eventType, payload: data, createdAt: createdAt)
            do {
                try self.db.write { db in try record.insert(db) }
                // 📉 OPTIMIZATION: Removed .count() call from log to save one DB read per insert.
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

        let successIds = await handler(batch)

        do {
            // 🚨 Use `await` here because we are in an `async` context.
            try await db.write { db in
                for event in batch {
                    guard let id = event.id, successIds.contains(id) else { continue }
                    try event.delete(db)
                }
            }
            logger.log("🗑 Removed \(successIds.count)/\(batch.count) events from queue")
            return successIds.count
        } catch {
            logger.warn("❌ Failed to delete flushed events: \(error)")
            return 0
        }
    }
}
