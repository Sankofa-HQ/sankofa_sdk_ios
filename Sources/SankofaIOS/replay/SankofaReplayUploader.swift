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

            // 🚀 INTERACTION PROCESSING: Find the latest interaction for frame-level metadata.
            let latestInteraction = interactions.last
            
            // 📦 DYNAMIC PAYLOAD: Wrap in the dashboard-expected JSON schema.
            var envelope: [String: Any] = [:]
            let replayMode: String
            
            switch frame.payload {
            case .wireframeNodes(let nodes):
                replayMode = "wireframe"
                
                // Build the wireframe event exactly as the dashboard expects.
                var wireframeEvent: [String: Any] = [
                    "type": "ui_snapshot",
                    "time_offset_ms": 0,
                    "nodes": nodes
                ]
                
                // If there's an active interaction, embed its coords inside the event
                if let interact = latestInteraction {
                    wireframeEvent["x"] = interact.x
                    wireframeEvent["y"] = interact.y
                }

                let chunkStartMs = Int64(frame.timestamp.timeIntervalSince1970 * 1000)
                envelope = [
                    "mode": "wireframe",
                    "chunk_start_timestamp": chunkStartMs,
                    "events": [wireframeEvent]
                ]

            case .screenshot(let data):
                replayMode = "screenshot"
                envelope = [
                    "mode": "screenshot",
                    "frames": [[
                        "timestamp": Int64(frame.timestamp.timeIntervalSince1970 * 1000),
                        "image_base64": data.base64EncodedString()
                    ]]
                ]
            }

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
            var finalPayload = envelope
            finalPayload["_distinct_id"] = self.distinctId
            finalPayload["_session_id"] = frame.sessionId
            finalPayload["_chunk_index"] = currentChunk
            finalPayload["_replay_mode"] = replayMode

            self.queueManager.enqueue(finalPayload, type: "replay_chunk")
            self.logger.log("📹 [v2] Frame queued (\(frame.sessionId)) chunk \(currentChunk)")
        }
    }

    private func safeDouble(_ value: CGFloat) -> Double {
        let d = Double(value)
        return d.isFinite ? d : 0.0
    }
}
