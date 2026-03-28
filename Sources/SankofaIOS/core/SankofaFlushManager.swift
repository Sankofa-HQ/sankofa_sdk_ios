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

                var successIds = Set<Int64>()
                
                // 1. Separate replay chunks from standard events
                let replayEvents = batch.filter { $0.type == "replay_chunk" }
                let standardEvents = batch.filter { $0.type != "replay_chunk" }
                
                // 2. Upload replay chunks one by one (as per server expectation)
                for event in replayEvents {
                    if await self.uploadReplay(event: event) {
                        if let id = event.id { successIds.insert(id) }
                    }
                }
                
                // 3. Upload standard events in a batch
                if !standardEvents.isEmpty {
                    let standardIds = await self.uploadBatch(events: standardEvents)
                    successIds.formUnion(standardIds)
                }

                return successIds
            }
        }
    }

    private func uploadReplay(event: SankofaQueueManager.QueuedEvent) async -> Bool {
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        guard let url = URL(string: "\(base)/api/replay/chunk"),
              let payload = try? JSONSerialization.jsonObject(with: event.payload) as? [String: Any] else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        
        // Metadata headers
        request.setValue(payload["session_id"] as? String, forHTTPHeaderField: "X-Session-Id")
        request.setValue(payload["distinct_id"] as? String, forHTTPHeaderField: "X-Distinct-Id")
        request.setValue(payload["replay_mode"] as? String, forHTTPHeaderField: "X-Replay-Mode")
        if let idx = payload["chunk_index"] as? Int {
            request.setValue(String(idx), forHTTPHeaderField: "X-Chunk-Index")
        }

        // GZIP logic
        let jsonData = event.payload.sankofa_gzipped() ?? event.payload
        if jsonData.count < event.payload.count {
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        }

        request.httpBody = jsonData

        return await withCheckedContinuation { continuation in
            session.dataTask(with: request) { [weak self] data, response, error in
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    self?.logger.log("✅ Flushed replay chunk")
                    continuation.resume(returning: true)
                } else {
                    let http = response as? HTTPURLResponse
                    let status = http?.statusCode ?? 0
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no body"
                    self?.logger.warn("❌ Replay rejected (HTTP \(status)): \(body)")
                    continuation.resume(returning: false)
                }
            }.resume()
        }
    }

    private func uploadBatch(events: [SankofaQueueManager.QueuedEvent]) async -> Set<Int64> {
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        guard let url = URL(string: "\(base)/api/v1/batch") else { return [] }

        var operations: [[String: Any]] = []
        var pendingIds = Set<Int64>()
        
        for event in events {
            guard let payload = try? JSONSerialization.jsonObject(with: event.payload) as? [String: Any],
                  let id = event.id else { continue }
            
            operations.append(["type": event.type, "payload": payload])
            pendingIds.insert(id)
        }

        guard !operations.isEmpty,
              let body = try? JSONSerialization.data(withJSONObject: ["operations": operations]) else {
            return []
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.httpBody = body

        return await withCheckedContinuation { continuation in
            session.dataTask(with: request) { [weak self] data, response, error in
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    self?.logger.log("✅ Flushed \(pendingIds.count) events")
                    continuation.resume(returning: pendingIds)
                } else {
                    let http = response as? HTTPURLResponse
                    let status = http?.statusCode ?? 0
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no body"
                    self?.logger.warn("❌ Batch rejected (HTTP \(status)): \(body)")
                    continuation.resume(returning: [])
                }
            }.resume()
        }
    }
}
