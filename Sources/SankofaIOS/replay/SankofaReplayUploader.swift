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

    func upload(_ frame: SankofaFrame) {
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
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(frame.sessionId, forHTTPHeaderField: "X-Session-Id")
            request.setValue(distinctId, forHTTPHeaderField: "X-Distinct-Id")
            request.setValue(String(currentChunk), forHTTPHeaderField: "X-Chunk-Index")
            request.setValue(
                ISO8601DateFormatter().string(from: frame.timestamp),
                forHTTPHeaderField: "x-frame-timestamp"
            )

            switch frame.payload {
            case .wireframe(let data):
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("wireframe", forHTTPHeaderField: "X-Replay-Mode")
                request.httpBody = data
            case .screenshot(let data):
                request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
                request.setValue("screenshot", forHTTPHeaderField: "X-Replay-Mode")
                request.httpBody = data
            }

            URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
                if let error {
                    self?.logger.warn("❌ Replay upload failed: \(error.localizedDescription)")
                } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    self?.logger.warn("❌ Replay upload HTTP \(http.statusCode) for chunk \(currentChunk)")
                } else {
                    self?.logger.log("📹 Frame uploaded (\(frame.sessionId)) chunk \(currentChunk)")
                }
                
                // Done! Tell iOS it can suspend.
                UIApplication.shared.endBackgroundTask(bgTask)
            }.resume()
        }
    }
}
