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
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
            request.setValue(frame.sessionId, forHTTPHeaderField: "X-Session-Id")
            request.setValue(distinctId, forHTTPHeaderField: "X-Distinct-Id")
            request.setValue(String(currentChunk), forHTTPHeaderField: "X-Chunk-Index")
            request.setValue("screenshot", forHTTPHeaderField: "X-Replay-Mode")
            
            let payloadData: Data
            switch frame.payload {
            case .wireframe(let data):
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                payloadData = data
            case .screenshot(let data):
                request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
                payloadData = data
            }

            // GZIP Compression (Backend compatibility)
            if let compressed = try? (payloadData as NSData).compressed(using: .zlib) as Data {
                request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
                request.httpBody = compressed
            } else {
                request.httpBody = payloadData
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
