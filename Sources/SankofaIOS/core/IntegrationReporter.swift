import Foundation

/// Fire-and-forget POST of the integration audit result to
/// `POST /api/v1/handshake/integrations`. Mirrors the RN + Flutter +
/// Web + Android reporters byte-for-byte on the wire — the server
/// treats every payload the same way.
///
/// Errors are swallowed. The next launch re-runs the audit and tries
/// again.
enum IntegrationReporter {

    private static let sdkName = "ios"
    private static let sdkVersion = "1.0.0"

    /// - parameter baseEndpoint: absolute base URL, e.g. https://api.sankofa.dev
    /// - parameter appVersion: host's marketing version (or "" if unknown)
    static func report(
        baseEndpoint: String,
        apiKey: String,
        appVersion: String,
        statuses: [ModuleIntegrationStatus],
        debug: Bool,
        log: @escaping (String) -> Void
    ) {
        guard !apiKey.isEmpty,
              !baseEndpoint.isEmpty,
              !statuses.isEmpty else { return }

        let trimmed = baseEndpoint.hasSuffix("/")
            ? String(baseEndpoint.dropLast())
            : baseEndpoint
        guard let url = URL(string: "\(trimmed)/api/v1/handshake/integrations") else { return }

        let payload: [String: Any] = [
            "sdk": sdkName,
            "sdk_version": sdkVersion,
            "platform": "ios",
            "app_version": appVersion,
            "integrations": statuses.map { s -> [String: Any] in
                return [
                    "module": s.module,
                    "level": s.level.rawValue,
                    "missing": s.missing,
                    "warnings": s.warnings,
                ]
            },
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                if debug { log("[Sankofa] Integration report failed: \(error.localizedDescription)") }
                return
            }
            guard let http = response as? HTTPURLResponse else { return }
            if !(200..<300).contains(http.statusCode) {
                if debug { log("[Sankofa] Integration report rejected (\(http.statusCode))") }
                return
            }
            if debug { log("[Sankofa] Integration report OK") }
        }.resume()
    }
}
