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

    func upload(_ frame: SankofaFrame, screenName: String = "Unknown", deviceContext: [String: Any]? = nil, interactions: [SankofaTouchInterceptor.Interaction] = []) {
        uploadQueue.async { [weak self] in
            guard let self else { return }

            let currentChunk = self.chunkIndex
            self.chunkIndex += 1

            // 🚀 INTERACTION PROCESSING: Find the latest interaction for frame-level metadata.
            let latestInteraction = interactions.last
            
            // 📦 DYNAMIC PAYLOAD: Wrap in the dashboard-expected JSON schema.
            var envelope: [String: Any]
            let replayMode = "screenshot"
            
            // 🔥 App version for heatmap version partitioning
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

            switch frame.payload {
            case .screenshot(let data):
                envelope = [
                    "mode": "screenshot",
                    "$app_version": appVersion,
                    "frames": [[
                        "timestamp": Int64(frame.timestamp.timeIntervalSince1970 * 1000),
                        "image_base64": data.base64EncodedString(),
                        "screen": screenName
                    ]]
                ]
            }

            // Standard mobile metadata
            if let deviceContext {
                envelope["device_context"] = deviceContext
            }
            
            // Interaction list for ripples
            if !interactions.isEmpty {
                var events = envelope["events"] as? [[String: Any]] ?? []
                
                let interactionEvents: [[String: Any]] = interactions.map { i in
                    let type: Int
                    switch i.type {
                    case "pointer_down": type = 1    // 1 = MouseDown (rrweb MouseInteraction)
                    case "pointer_up":   type = 0    // 0 = MouseUp   (rrweb MouseInteraction)
                    case "pointer_move": type = 6    // 6 = TouchMove (rrweb MouseInteraction)
                    default: type = 1
                    }
                    
                    // Send RAW CGFloat coordinates (UIKit points).
                    // The session replay player already normalizes by dividing by screen dims.
                    // The server worker normalizes before inserting into replay_interactions.
                    // safeDouble() guards against NaN/Infinity from UIKit edge cases.
                    return [
                        "type": 3,
                        "data": [
                            "source": 2, // MouseInteraction
                            "type": type,
                            "id": 1,
                            "x": self.safeDouble(i.x),
                            "y": self.safeDouble(i.y)
                        ],
                        "timestamp": Int64(i.timestamp.timeIntervalSince1970 * 1000)
                    ]
                }
                
                events.append(contentsOf: interactionEvents)
                envelope["events"] = events
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
