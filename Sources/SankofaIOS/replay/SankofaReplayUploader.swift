import Foundation
import UIKit

/// Uploads captured replay frames to the Sankofa backend.
///
/// Mirrors `SankofaReplayUploader` in the Flutter SDK.
/// Runs compression and upload on a background queue.
final class SankofaReplayUploader {

    private let queueManager: SankofaQueueManager
    private let logger: SankofaLogger
    private let uploadQueue = DispatchQueue(label: "dev.sankofa.replay.upload", qos: .utility)
    
    private var chunkIndex: Int = 0
    private var distinctId: String = "anonymous"

    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(queueManager: SankofaQueueManager, logger: SankofaLogger) {
        self.queueManager = queueManager
        self.logger = logger
    }
    
    func setDistinctId(_ id: String) {
        self.distinctId = id
    }

    func upload(_ frame: SankofaFrame, deviceContext: [String: Any]? = nil, interactions: [SankofaTouchInterceptor.Interaction] = []) {
        uploadQueue.async { [weak self] in
            guard let self else { return }

            let currentChunk = self.chunkIndex
            self.chunkIndex += 1
            
            // 📦 DYNAMIC PAYLOAD: Wrap in the dashboard-expected JSON schema.
            // 🎯 THE CHEAT CODE: Extract the rrweb event from the payload.
            guard case .rrwebEvent(let event) = frame.payload else { return }
            
            let dateStr = self.isoFormatter.string(from: frame.timestamp)
            
            var envelope: [String: Any] = [
                "mode": "rrweb",
                "session_id": frame.sessionId,
                "distinct_id": self.distinctId,
                "chunk_index": currentChunk,
                "replay_mode": "rrweb",
                "started_at": dateStr,
                "ended_at": dateStr, // Single frame, so start == end
                "event_count": 1,
                "events": [event]
            ]

            // Standard mobile metadata
            if let deviceContext {
                envelope["device_context"] = deviceContext
            }
            
            // Interaction list for ripples
            if !interactions.isEmpty {
                envelope["interactions"] = interactions.map { i in
                    let type: Int
                    switch i.type {
                    case "pointer_down": type = 2
                    case "pointer_up": type = 1
                    default: type = 0 // pointer_move
                    }
                    
                    return [
                        "type": type,
                        "x": self.safeDouble(i.x),
                        "y": self.safeDouble(i.y),
                        "timestamp": Int64(i.timestamp.timeIntervalSince1970 * 1000)
                    ]
                }
            }

            // KILLER 2 (OOM Cleanup): Immediately encode and flush to SQLite, DO NOT hold in memory.
            // We tag it as 'replay_chunk' so the FlushManager knows where to send it.
            self.queueManager.enqueue(envelope, type: "replay_chunk")
            self.logger.log("📹 [v2] Frame queued (\(frame.sessionId)) chunk \(currentChunk)")
        }
    }

    private func safeDouble(_ value: CGFloat) -> Double {
        let d = Double(value)
        return d.isFinite ? d : 0.0
    }
}
