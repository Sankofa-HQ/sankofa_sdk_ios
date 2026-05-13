import Foundation

/// Canonical screen-seen emitter — fire-and-forget POST to
/// `/api/v1/screens/seen`. Mirrors the web / RN implementations:
/// every `Sankofa.shared.screen('Identify')` call hits this so the
/// lexicon + dwell + presence get populated regardless of which
/// Sankofa products the host has enabled.
///
/// Best-effort — failures are silent. The server endpoint is
/// idempotent + TTL-based for presence, so a missed call self-heals
/// on the next call.
final class SankofaScreenSeen {
    static let shared = SankofaScreenSeen()

    private let session: URLSession
    private let queue = DispatchQueue(label: "dev.sankofa.screen-seen", qos: .utility)

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 5
        self.session = URLSession(configuration: cfg)
    }

    func emit(
        endpoint: String,
        apiKey: String,
        screen: String,
        distinctId: String,
        sessionId: String?,
        properties: [String: Any] = [:]
    ) {
        guard !screen.isEmpty, !distinctId.isEmpty else { return }
        let trimmed = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)/api/v1/screens/seen") else { return }

        var body: [String: Any] = [
            "screen": screen,
            "distinct_id": distinctId,
            "ts_ms": Int(Date().timeIntervalSince1970 * 1000),
        ]
        if let sid = sessionId, !sid.isEmpty {
            body["session_id"] = sid
        }
        if !properties.isEmpty {
            body["properties"] = properties
        }
        guard let json = try? JSONSerialization.data(withJSONObject: body, options: []) else { return }

        queue.async { [weak self] in
            guard let self = self else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.httpBody = json
            let task = self.session.dataTask(with: req) { _, _, _ in /* swallow */ }
            task.resume()
        }
    }
}
