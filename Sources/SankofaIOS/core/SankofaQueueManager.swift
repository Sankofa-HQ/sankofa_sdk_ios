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

    private let db: DatabaseQueue
    private let logger: SankofaLogger
    private let lock = NSLock()

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

        do {
            db = try DatabaseQueue(path: dbPath)
            try db.write { db in
                try db.create(table: QueuedEvent.databaseTableName, ifNotExists: true) { t in
                    t.autoIncrementedPrimaryKey("id")
                    t.column("type", .text).notNull()
                    t.column("payload", .blob).notNull()
                    t.column("createdAt", .datetime).notNull().defaults(to: Date())
                }
            }
            logger.log("💾 SQLite queue opened at \(dbPath)")
        } catch {
            // Fallback: in-memory database so the SDK never crashes.
            db = try! DatabaseQueue()
            logger.warn("⚠️ Failed to open SQLite queue, using in-memory: \(error)")
        }
    }

    // MARK: - Public

    /// Enqueue an event payload dictionary.
    func enqueue(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event) else {
            logger.warn("❌ Could not serialise event")
            return
        }
        let type = event["type"] as? String ?? "track"
        var record = QueuedEvent(id: nil, type: type, payload: data, createdAt: Date())
        do {
            try db.write { db in try record.insert(db) }
            logger.log("📥 Queued '\(type)' (total: \(count()))")
        } catch {
            logger.warn("❌ Failed to enqueue: \(error)")
        }
    }

    /// Return the number of events currently queued.
    func count() -> Int {
        (try? db.read { try QueuedEvent.fetchCount($0) }) ?? 0
    }

    /// Dequeue the oldest `limit` events, execute `handler`, then delete
    /// successful ones. Failed events remain in the queue for the next flush.
    func flush(limit: Int, handler: ([QueuedEvent]) async -> Set<Int64>) async {
        guard count() > 0 else { return }

        let batch: [QueuedEvent]
        do {
            batch = try db.read { db in
                try QueuedEvent
                    .order(Column("createdAt").asc)
                    .limit(limit)
                    .fetchAll(db)
            }
        } catch {
            logger.warn("❌ Failed to read queue: \(error)")
            return
        }

        let successIds = await handler(batch)

        do {
            try db.write { db in
                for event in batch {
                    guard let id = event.id, successIds.contains(id) else { continue }
                    try event.delete(db)
                }
            }
            logger.log("🗑 Removed \(successIds.count)/\(batch.count) events from queue")
        } catch {
            logger.warn("❌ Failed to delete flushed events: \(error)")
        }
    }
}
