import Foundation
import UIKit

/// Manages periodic and event-driven flushing of the `SankofaQueueManager`.
///
/// Mirrors `SyncWorker` (Android) and the flush loop in `SankofaQueueManager` (Flutter).
/// Uses a background `URLSession` that can survive short app suspensions.
final class SankofaFlushManager {

    private let apiKey: String
    private let endpoint: String
    private let queueManager: SankofaQueueManager
    private let batchSize: Int
    private let flushInterval: TimeInterval
    private let logger: SankofaLogger

    private var timer: Timer?
    private var isFlushing = false
    private let lock = NSLock()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    init(
        apiKey: String,
        endpoint: String,
        queueManager: SankofaQueueManager,
        batchSize: Int,
        flushInterval: TimeInterval,
        logger: SankofaLogger
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.queueManager = queueManager
        self.batchSize = batchSize
        self.flushInterval = flushInterval
        self.logger = logger
    }

    // MARK: - Lifecycle

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: flushInterval, repeats: true) { [weak self] _ in
            self?.flush()
        }
        RunLoop.main.add(timer!, forMode: .common)
        logger.log("⏱ Flush timer started (\(Int(flushInterval))s interval)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Flush

    func flush() {
        lock.lock()
        guard !isFlushing else { lock.unlock(); return }
        isFlushing = true
        lock.unlock()

        Task {
            defer {
                lock.lock()
                isFlushing = false
                lock.unlock()
            }

            await queueManager.flush(limit: batchSize) { [weak self] batch async -> Set<Int64> in
                guard let self else { return [] }

                // 🚨 BACKGROUND PROTECTION: Tell iOS to give us extra time to
                // finish the upload before suspending the app ($ app minimized).
                var bgTask: UIBackgroundTaskIdentifier = .invalid
                bgTask = UIApplication.shared.beginBackgroundTask {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }

                var successIds = Set<Int64>()
                var operations: [[String: Any]] = []
                
                for event in batch {
                    guard let payload = try? JSONSerialization.jsonObject(with: event.payload) as? [String: Any] else {
                        successIds.insert(event.id!) // Remove malformed events
                        continue
                    }
                    
                    // The backend expects: { "type": "...", "payload": { ... } }
                    operations.append([
                        "type": event.type,
                        "payload": payload
                    ])
                }

                if operations.isEmpty {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    return []
                }

                let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
                guard let url = URL(string: "\(base)/api/v1/batch") else {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    return []
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

                do {
                    let batchPayload = ["operations": operations]
                    let body = try JSONSerialization.data(withJSONObject: batchPayload)
                    request.httpBody = body
                    
                    // 🚨 USE CONFIGURED SESSION: Use the background-session configured in the class.
                    let (data, response) = try await session.data(for: request)
                    if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                        self.logger.log("✅ Flushed batch of \(operations.count) events")
                        batch.forEach { if let id = $0.id { successIds.insert(id) } }
                    } else {
                        let bodyStr = String(data: data, encoding: .utf8) ?? "no body"
                        self.logger.warn("❌ Server rejected batch: \(bodyStr)")
                    }
                } catch {
                    self.logger.warn("❌ Batch network error: \(error.localizedDescription)")
                }

                // Finish the background task.
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid

                return successIds
            }
        }
    }
}
