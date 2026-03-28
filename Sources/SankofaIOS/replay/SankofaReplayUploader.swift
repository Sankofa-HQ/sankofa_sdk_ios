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
            let chunkEvents: [[String: Any]]
            let dateStr = self.isoFormatter.string(from: frame.timestamp)
            let timestampMs = Int64(frame.timestamp.timeIntervalSince1970 * 1000)

            switch frame.payload {
            case .rrwebEvent(let event):
                // 🎯 SUPPORT MULTI-EVENT PAYLOADS: If the engine sent a batch of events, unpack them.
                if let nestedEvents = event["events"] as? [[String: Any]] {
                    chunkEvents = nestedEvents
                } else {
                    chunkEvents = [event]
                }
                
            case .wireframe(let data):
                // Phase 28: High-Fidelity Wireframe (Pre-Packaged)
                guard let snapshotEvent = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.logger.warn("❌ Failed to decode wireframe data")
                    return
                }
                
                // Meta Event (Type 4) is still required so the player knows the viewport bounds
                let metaEvent: [String: Any] = [
                    "type": 4,
                    "timestamp": timestampMs,
                    "data": [
                        "href": "ios-app://\(Bundle.main.bundleIdentifier ?? "sankofa")",
                        "width": Int(UIScreen.main.bounds.width),
                        "height": Int(UIScreen.main.bounds.height)
                    ]
                ]
                
                chunkEvents = [metaEvent, snapshotEvent]

            }

            var envelope: [String: Any] = [
                "mode": "rrweb",
                "session_id": frame.sessionId,
                "distinct_id": self.distinctId,
                "chunk_index": currentChunk,
                "replay_mode": "rrweb",
                "started_at": dateStr,
                "ended_at": dateStr,
                "event_count": chunkEvents.count,
                "events": chunkEvents
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
