import Foundation

/// Uploads captured replay frames to the Sankofa backend.
///
/// Mirrors `SankofaReplayUploader` in the Flutter SDK.
/// Runs compression and upload on a background queue.
final class SankofaReplayUploader {

    private let apiKey: String
    private let endpoint: String
    private let logger: SankofaLogger
    private let uploadQueue = DispatchQueue(label: "dev.sankofa.replay.upload", qos: .background)

    init(apiKey: String, endpoint: String, logger: SankofaLogger) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.logger = logger
    }

    func upload(_ frame: SankofaFrame) {
        uploadQueue.async { [weak self] in
            guard let self else { return }

            let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
            guard let url = URL(string: "\(base)/api/v1/replay") else { return }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(frame.sessionId, forHTTPHeaderField: "x-session-id")
            request.setValue(
                ISO8601DateFormatter().string(from: frame.timestamp),
                forHTTPHeaderField: "x-frame-timestamp"
            )

            switch frame.payload {
            case .wireframe(let data):
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("wireframe", forHTTPHeaderField: "x-replay-type")
                request.httpBody = data
            case .screenshot(let data):
                request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
                request.setValue("screenshot", forHTTPHeaderField: "x-replay-type")
                request.httpBody = data
            }

            URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
                if let error {
                    self?.logger.warn("❌ Replay upload failed: \(error.localizedDescription)")
                } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    self?.logger.warn("❌ Replay upload HTTP \(http.statusCode)")
                } else {
                    self?.logger.log("📹 Frame uploaded (\(frame.sessionId))")
                }
            }.resume()
        }
    }
}
