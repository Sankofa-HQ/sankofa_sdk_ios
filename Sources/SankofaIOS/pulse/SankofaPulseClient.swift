import Foundation

/// Network client for the Pulse SDK. Six endpoints today:
///
///   - GET    /api/pulse/handshake          → lightweight survey list
///   - GET    /api/pulse/surveys/:survey_id → full bundle
///   - POST   /api/pulse/responses          → final submit
///   - POST   /api/pulse/partial            → save in-progress state
///   - GET    /api/pulse/partial            → load in-progress state
///   - DELETE /api/pulse/partial            → clear in-progress state
///
/// All authenticated via `x-api-key` (the project API key the host
/// passed to `Sankofa.shared.initialize`). Network failures bubble
/// out to the queue manager which retries with backoff.
@available(iOS 13.0, macOS 10.15, *)
public final class SankofaPulseClient {

    public enum ClientError: Error, LocalizedError {
        case notInitialized
        case malformedURL
        case http(status: Int, body: String?)
        case decode(Error)

        public var errorDescription: String? {
            switch self {
            case .notInitialized: return "Sankofa SDK not initialized"
            case .malformedURL: return "Pulse endpoint URL malformed"
            case .http(let s, let b): return "HTTP \(s)\(b.map { ": \($0)" } ?? "")"
            case .decode(let e): return "decode failed: \(e.localizedDescription)"
            }
        }
    }

    private let endpoint: String
    private let apiKey: String
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(endpoint: String, apiKey: String, session: URLSession = .shared) {
        self.endpoint = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiKey = apiKey
        self.session = session
        let dec = JSONDecoder()
        // Server timestamps are RFC3339 — let the per-field types
        // own their own date handling rather than forcing a global
        // strategy here.
        self.decoder = dec
        self.encoder = JSONEncoder()
    }

    public func handshake() async throws -> SankofaPulseHandshakeResponse {
        let req = try buildRequest(path: "/api/pulse/handshake?installed=pulse",
                                   method: "GET")
        return try await perform(req, decode: SankofaPulseHandshakeResponse.self)
    }

    /// Load the full survey bundle (survey row + targeting rules)
    /// for one survey. The SDK calls this right before presenting so
    /// it can run the targeting evaluator locally and skip the show
    /// if the respondent isn't eligible.
    public func loadSurveyBundle(_ surveyId: String)
    async throws -> SankofaPulseSurveyBundle {
        let req = try buildRequest(
            path: "/api/pulse/surveys/\(surveyId)", method: "GET")
        return try await perform(req, decode: SankofaPulseSurveyBundle.self)
    }

    public func submit(_ payload: SankofaPulseSubmitPayload)
    async throws -> SankofaPulseSubmitResponse {
        var req = try buildRequest(path: "/api/pulse/responses", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(payload)
        return try await perform(req, decode: SankofaPulseSubmitResponse.self)
    }

    /// Upsert the in-progress partial for (survey_id, external_id).
    public func savePartial(_ payload: SankofaPulsePartialUpsert)
    async throws -> SankofaPulsePartialAck {
        var req = try buildRequest(path: "/api/pulse/partial", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(payload)
        return try await perform(req, decode: SankofaPulsePartialAck.self)
    }

    /// Load the partial for (survey_id, external_id). Returns nil
    /// on 404 — distinguishes a clean miss from a network failure,
    /// which still throws.
    public func loadPartial(surveyId: String, externalId: String)
    async throws -> SankofaPulsePartial? {
        guard !endpoint.isEmpty else { throw ClientError.notInitialized }
        var components = URLComponents(string: endpoint + "/api/pulse/partial")
        components?.queryItems = [
            URLQueryItem(name: "survey_id", value: surveyId),
            URLQueryItem(name: "external_id", value: externalId),
        ]
        guard let url = components?.url else { throw ClientError.malformedURL }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.http(status: 0, body: nil)
        }
        if http.statusCode == 404 { return nil }
        if !(200..<300).contains(http.statusCode) {
            throw ClientError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8))
        }
        do {
            return try decoder.decode(SankofaPulsePartial.self, from: data)
        } catch {
            throw ClientError.decode(error)
        }
    }

    /// Idempotent clear of the partial for (survey_id, external_id).
    /// The server also auto-cleans on successful submit, so the SDK
    /// only calls this on explicit dismiss / "start over".
    public func deletePartial(surveyId: String, externalId: String) async throws {
        guard !endpoint.isEmpty else { throw ClientError.notInitialized }
        var components = URLComponents(string: endpoint + "/api/pulse/partial")
        components?.queryItems = [
            URLQueryItem(name: "survey_id", value: surveyId),
            URLQueryItem(name: "external_id", value: externalId),
        ]
        guard let url = components?.url else { throw ClientError.malformedURL }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.http(status: 0, body: nil)
        }
        if http.statusCode == 404 { return }
        if !(200..<300).contains(http.statusCode) {
            throw ClientError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8))
        }
    }

    // MARK: - Internals

    private func buildRequest(path: String, method: String) throws -> URLRequest {
        guard !endpoint.isEmpty else { throw ClientError.notInitialized }
        guard let url = URL(string: endpoint + path) else {
            throw ClientError.malformedURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    private func perform<T: Decodable>(
        _ request: URLRequest, decode type: T.Type
    ) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.http(status: 0, body: nil)
        }
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8)
            throw ClientError.http(status: http.statusCode, body: body)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ClientError.decode(error)
        }
    }
}
