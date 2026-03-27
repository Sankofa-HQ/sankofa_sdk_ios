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
        let config = URLSessionConfiguration.background(withIdentifier: "dev.sankofa.sdk.flush")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
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
                    // Force-quit if we exceed Apple's grace period.
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }

                var successIds = Set<Int64>()

                for event in batch {
                    guard let payload = try? JSONSerialization.jsonObject(with: event.payload) as? [String: Any] else {
                        successIds.insert(event.id!) // Remove malformed events
                        continue
                    }

                    let route: String
                    switch event.type {
                    case "alias":  route = "/api/v1/alias"
                    case "people": route = "/api/v1/people"
                    default:       route = "/api/v1/track"
                    }

                    let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
                    guard let url = URL(string: "\(base)\(route)") else { continue }

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

                    do {
                        let body = try JSONSerialization.data(withJSONObject: payload)
                        request.httpBody = body
                        let (_, response) = try await URLSession.shared.data(for: request)
                        if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                            self.logger.log("✅ Sent '\(event.type)'")
                            successIds.insert(event.id!)
                        } else {
                            self.logger.warn("❌ Server rejected '\(event.type)'")
                        }
                    } catch {
                        self.logger.warn("❌ Network error: \(error.localizedDescription)")
                    }
                }

                // Finish the background task.
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid

                return successIds
            }
        }
    }
}
