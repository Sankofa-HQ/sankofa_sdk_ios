import Foundation
import UIKit

/// Uploads captured replay frames to the Sankofa backend.
///
/// Mirrors `SankofaReplayUploader` in the Flutter SDK.
/// Runs compression and upload on a background queue.
final class SankofaReplayUploader {

    private let apiKey: String
    private let endpoint: String
    private let logger: SankofaLogger
    private let uploadQueue = DispatchQueue(label: "dev.sankofa.replay.upload", qos: .background)
    
    private var chunkIndex: Int = 0
    private var distinctId: String = "anonymous"

    init(apiKey: String, endpoint: String, logger: SankofaLogger) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.logger = logger
    }
    
    func setDistinctId(_ id: String) {
        self.distinctId = id
    }

    func upload(_ frame: SankofaFrame, deviceContext: [String: Any]? = nil, interactions: [SankofaTouchInterceptor.Interaction] = []) {
        // 🚨 BACKGROUND PROTECTION: Protect the replay upload context.
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }

        uploadQueue.async { [weak self] in
            guard let self else { 
                UIApplication.shared.endBackgroundTask(bgTask)
                return 
            }

            let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
            // EE Ingestion uses /api/replay/chunk
            guard let url = URL(string: "\(base)/api/replay/chunk") else { 
                UIApplication.shared.endBackgroundTask(bgTask)
                return 
            }

            let currentChunk = self.chunkIndex
            self.chunkIndex += 1

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
            request.setValue(frame.sessionId, forHTTPHeaderField: "X-Session-Id")
            request.setValue(distinctId, forHTTPHeaderField: "X-Distinct-Id")
            request.setValue(String(currentChunk), forHTTPHeaderField: "X-Chunk-Index")
            
            // 🚀 INTERACTION PROCESSING: Find the latest interaction for frame-level metadata.
            let latestInteraction = interactions.last
            
            // 📦 DYNAMIC PAYLOAD: Wrap in the dashboard-expected JSON schema.
            var envelope: [String: Any] = [:]
            let replayMode: String
            
            switch frame.payload {
            case .wireframe(let data):
                replayMode = "wireframe"
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                envelope = [
                    "mode": "wireframe",
                    "events": [[
                        "type": latestInteraction?.type ?? "ui_snapshot",
                        "time_offset_ms": 0,
                        "nodes": [json]
                    ]]
                ]
                
                // Add interaction coords at top level for Wireframe playback
                if let interact = latestInteraction {
                    envelope["x"] = interact.x
                    envelope["y"] = interact.y
                    envelope["eventType"] = interact.type
                }
                
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
                        "x": i.x,
                        "y": i.y,
                        "timestamp": Int64(i.timestamp.timeIntervalSince1970 * 1000)
                    ]
                }
            }

            request.setValue(replayMode, forHTTPHeaderField: "X-Replay-Mode")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            guard let jsonData = try? JSONSerialization.data(withJSONObject: envelope) else {
                UIApplication.shared.endBackgroundTask(bgTask)
                return
            }

            // GZIP Compression (RFC 1952 standard)
            if let gzipped = jsonData.sankofa_gzipped() {
                request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
                request.httpBody = gzipped
            } else {
                request.httpBody = jsonData
            }

            URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
                if let error {
                    self?.logger.warn("❌ [v2] Replay upload failed: \(error.localizedDescription)")
                } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    self?.logger.warn("❌ [v2] Replay upload HTTP \(http.statusCode) (Chunk \(currentChunk))")
                } else {
                    self?.logger.log("📹 [v2] Frame uploaded (\(frame.sessionId)) chunk \(currentChunk)")
                }
                
                UIApplication.shared.endBackgroundTask(bgTask)
            }.resume()
        }
    }
}
