import Foundation
import UIKit
import Network

/// Manages periodic and event-driven flushing of the `SankofaQueueManager`.
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

    // KILLER 3 (Battery): NWPathMonitor prevents radio wakeups when offline
    private let networkMonitor = NWPathMonitor()
    private var isConnected = true

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

        networkMonitor.pathUpdateHandler = { [weak self] path in
            self?.isConnected = (path.status == .satisfied)
        }
        networkMonitor.start(queue: DispatchQueue(label: "dev.sankofa.network.monitor"))
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
        // KILLER 3 (Battery Guard)
        guard isConnected else {
            logger.log("📡 Offline. Skipping flush to save battery.")
            return
        }

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

                var uploadTask: URLSessionDataTask?
                var bgTask: UIBackgroundTaskIdentifier = .invalid

                // KILLER 1 (Watchdog Cure): Explicitly cancel network task on expiration
                bgTask = UIApplication.shared.beginBackgroundTask {
                    uploadTask?.cancel()
                    if bgTask != .invalid {
                        UIApplication.shared.endBackgroundTask(bgTask)
                        bgTask = .invalid
                    }
                }

                let successIds = await withCheckedContinuation { continuation in
                    self.performUpload(batch: batch) { task, ids in
                        uploadTask = task
                    } completion: { ids in
                        continuation.resume(returning: ids)
                    }
                }

                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }

                return successIds
            }
        }
    }

    private func performUpload(
        batch: [SankofaQueueManager.QueuedEvent], 
        onStart: @escaping (URLSessionDataTask, Set<Int64>) -> Void,
        completion: @escaping (Set<Int64>) -> Void
    ) {
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        
        // KILLER 2 (Routing): Separate replay chunks from standard events
        let replayEvent = batch.first(where: { $0.type == "replay_chunk" })
        let isReplay = replayEvent != nil
        
        let urlString = isReplay ? "\(base)/api/replay/chunk" : "\(base)/api/v1/batch"
        guard let url = URL(string: urlString) else {
            completion([])
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")

        var body: Data?
        var pendingIds = Set<Int64>()

        if isReplay, let event = replayEvent {
            // Replay chunk is sent individually with metadata headers
            if let id = event.id { pendingIds.insert(id) }
            
            if let payload = try? JSONSerialization.jsonObject(with: event.payload) as? [String: Any] {
                request.setValue(payload["session_id"] as? String, forHTTPHeaderField: "X-Session-Id")
                request.setValue(payload["distinct_id"] as? String, forHTTPHeaderField: "X-Distinct-Id")
                request.setValue(payload["replay_mode"] as? String, forHTTPHeaderField: "X-Replay-Mode")
                if let idx = payload["chunk_index"] as? Int {
                    request.setValue(String(idx), forHTTPHeaderField: "X-Chunk-Index")
                }
                
                // GZIP logic (Phase 2)
                let jsonData = event.payload.sankofa_gzipped() ?? event.payload
                if jsonData.count < event.payload.count {
                    request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
                }
                body = jsonData
            }
        } else {
            // Standard batch upload
            var operations: [[String: Any]] = []
            for event in batch.filter({ $0.type != "replay_chunk" }) {
                guard let payload = try? JSONSerialization.jsonObject(with: event.payload) as? [String: Any],
                      let id = event.id else { continue }
                
                operations.append(["type": event.type, "payload": payload])
                pendingIds.insert(id)
            }
            
            if !operations.isEmpty {
                body = try? JSONSerialization.data(withJSONObject: ["operations": operations])
            }
        }

        guard let uploadData = body else {
            completion([])
            return
        }

        request.httpBody = uploadData
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            var successIds = Set<Int64>()
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                self?.logger.log("✅ Flushed \(isReplay ? "replay chunk" : "\(pendingIds.count) events")")
                successIds = pendingIds
            } else if let error = error {
                self?.logger.warn("❌ Flush network error: \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse {
                self?.logger.warn("❌ Flush rejected (HTTP \(http.statusCode))")
            }
            completion(successIds)
        }
        
        onStart(task, pendingIds)
        task.resume()
    }
}
