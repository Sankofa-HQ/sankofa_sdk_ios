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
            let status = path.status == .satisfied
            let interface = path.availableInterfaces.map { "\($0.type)" }.joined(separator: ", ")
            
            #if targetEnvironment(simulator)
            //  SIMULATOR FIX: Always report connected in simulator to avoid NWPathMonitor flakiness
            self?.isConnected = true
            #else
            self?.isConnected = status
            #endif
            
            if !status {
                self?.logger.log("📡 Network status changed: \(path.status) (Interfaces: \(interface))")
            }
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
        #if !targetEnvironment(simulator)
        guard isConnected else {
            logger.log("📡 Offline. Skipping flush to save battery.")
            return
        }
        #endif

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

            // 💨 Backlog Fix: Loop until the queue is reasonably clear (max 500 events per cycle)
            // This ensures that even if events arrive faster than the 30s flush interval, 
            // the backlog will eventually be cleared.
            var batchesCleared = 0
            var wasLastBatchFull = true
            
            while wasLastBatchFull && batchesCleared < 10 {
                batchesCleared += 1
                
                let successCount = await queueManager.flush(limit: batchSize) { [weak self] batch async -> Set<Int64> in
                    guard let self else { 
                        wasLastBatchFull = false
                        return [] 
                    }
                    
                    wasLastBatchFull = batch.count >= batchSize
                    
                    var bgTask: UIBackgroundTaskIdentifier = .invalid

                    // KILLER 1 (Watchdog Cure): Background task to keep the upload alive
                    bgTask = await UIApplication.shared.beginBackgroundTask {
                        if bgTask != .invalid {
                            UIApplication.shared.endBackgroundTask(bgTask)
                            bgTask = .invalid
                        }
                    }

                    // 🔀 SPLIT: Partition the batch into replay chunks vs standard events.
                    let replayChunks = batch.filter { $0.type == "replay_chunk" }
                    let standardOps  = batch.filter { $0.type != "replay_chunk" }

                    var allSuccessIds = Set<Int64>()

                    // 💨 🚀 Parallel Pass 1: Upload ALL replay chunks in parallel
                    // Using a TaskGroup to send chunks concurrently speeds up clearing
                    // the backlog and reduces the time the phone's radio stays active.
                    if !replayChunks.isEmpty {
                        let ids = await self.uploadReplayChunksParallel(replayChunks)
                        allSuccessIds.formUnion(ids)
                    }

                    // Pass 2: Upload standard events as a single batch
                    if !standardOps.isEmpty {
                        let ids = await self.uploadStandardBatch(standardOps)
                        allSuccessIds.formUnion(ids)
                    }

                    if bgTask != .invalid {
                        await UIApplication.shared.endBackgroundTask(bgTask)
                        bgTask = .invalid
                    }

                    return allSuccessIds
                }
                
                if successCount == 0 { break } // Safety break if we aren't making progress
            }
        }
    }

    private func uploadReplayChunksParallel(_ chunks: [SankofaQueueManager.QueuedEvent]) async -> Set<Int64> {
        return await withTaskGroup(of: Set<Int64>.self) { group in
            var allIds = Set<Int64>()
            
            // Limit concurrency to 5 to avoid overwhelming the client or server
            let maxConcurrency = 5
            var index = 0
            
            func addNext() {
                if index < chunks.count {
                    let chunk = chunks[index]
                    index += 1
                    group.addTask { await self.uploadReplayChunk(chunk) }
                }
            }
            
            for _ in 0..<min(maxConcurrency, chunks.count) { addNext() }
            
            while let ids = await group.next() {
                allIds.formUnion(ids)
                addNext()
            }
            
            return allIds
        }
    }

    // MARK: - Replay Chunk Upload (individual, to /api/replay/chunk)

    private func uploadReplayChunk(_ event: SankofaQueueManager.QueuedEvent) async -> Set<Int64> {
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        guard let url = URL(string: "\(base)/api/replay/chunk") else { return [] }

        guard let payload = try? JSONSerialization.jsonObject(with: event.payload) as? [String: Any] else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")

        // Set replay-specific headers from the payload metadata
        request.setValue(payload["_session_id"] as? String, forHTTPHeaderField: "X-Session-Id")
        request.setValue(payload["_distinct_id"] as? String, forHTTPHeaderField: "X-Distinct-Id")
        request.setValue(payload["_replay_mode"] as? String, forHTTPHeaderField: "X-Replay-Mode")
        if let idx = payload["_chunk_index"] as? Int {
            request.setValue(String(idx), forHTTPHeaderField: "X-Chunk-Index")
        }

        // GZIP compression
        let rawData = event.payload
        let gzData = rawData.sankofa_gzipped() ?? rawData
        if gzData.count < rawData.count {
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
            request.httpBody = gzData
        } else {
            request.httpBody = rawData
        }

        var pendingIds = Set<Int64>()
        if let id = event.id { pendingIds.insert(id) }

        return await withCheckedContinuation { continuation in
            let task = session.dataTask(with: request) { [weak self] _, response, error in
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    self?.logger.log("✅ Replay chunk uploaded")
                    continuation.resume(returning: pendingIds)
                } else {
                    if let error = error {
                        self?.logger.warn("❌ Replay upload error: \(error.localizedDescription)")
                    } else if let http = response as? HTTPURLResponse {
                        self?.logger.warn("❌ Replay upload rejected (HTTP \(http.statusCode))")
                    }
                    continuation.resume(returning: [])
                }
            }
            task.resume()
        }
    }

    // MARK: - Standard Events Batch Upload (to /api/v1/batch)

    private func uploadStandardBatch(_ events: [SankofaQueueManager.QueuedEvent]) async -> Set<Int64> {
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

        guard !operations.isEmpty else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")

        guard let body = try? JSONSerialization.data(withJSONObject: ["operations": operations]) else { return [] }
        request.httpBody = body

        return await withCheckedContinuation { continuation in
            let task = session.dataTask(with: request) { [weak self] _, response, error in
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    self?.logger.log("✅ Flushed \(pendingIds.count) events")
                    continuation.resume(returning: pendingIds)
                } else {
                    if let error = error {
                        self?.logger.warn("❌ Batch flush error: \(error.localizedDescription)")
                    } else if let http = response as? HTTPURLResponse {
                        self?.logger.warn("❌ Batch flush rejected (HTTP \(http.statusCode))")
                    }
                    continuation.resume(returning: [])
                }
            }
            task.resume()
        }
    }
}
