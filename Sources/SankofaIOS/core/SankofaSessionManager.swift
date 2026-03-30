import Foundation

/// Generates and manages session IDs.
/// A new session is created on every `reset()` call (user logout) and
/// on cold app launch.
final class SankofaSessionManager {

    private(set) var sessionId: String

    init() {
        self.sessionId = SankofaSessionManager.generateSessionId()
    }

    /// Rotate the session ID (e.g. after `Sankofa.shared.reset()`).
    func rotateSession() {
        sessionId = SankofaSessionManager.generateSessionId()
    }

    private static func generateSessionId() -> String {
        "s_\(UUID().uuidString)"
    }
}
