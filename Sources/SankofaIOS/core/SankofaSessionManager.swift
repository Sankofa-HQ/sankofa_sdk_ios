import Foundation

/// Generates and manages session IDs.
/// A new session is created on every `reset()` call (user logout) and
/// on cold app launch.
final class SankofaSessionManager {

    private static let LAST_BACKGROUND_KEY = "dev.sankofa.last_background_time"
    private(set) var sessionId: String
    
    // The timestamp when the app was last moved to the background.
    var lastBackgroundTime: Date? {
        get { UserDefaults.standard.object(forKey: Self.LAST_BACKGROUND_KEY) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.LAST_BACKGROUND_KEY) }
    }

    init() {
        self.sessionId = SankofaSessionManager.generateSessionId()
    }

    /// Rotate the session ID (e.g. after `Sankofa.shared.reset()`).
    func rotateSession() {
        sessionId = SankofaSessionManager.generateSessionId()
    }
    
    /// Checks if the session should be rotated based on inactivity.
    /// Returns true if the session was rotated.
    func checkSessionRotation(timeoutInterval: TimeInterval = 1800) -> Bool {
        guard let lastBackground = lastBackgroundTime else {
            // No previous background time (first launch or already active)
            return false
        }
        
        let elapsed = Date().timeIntervalSince(lastBackground)
        if elapsed > timeoutInterval {
            rotateSession()
            lastBackgroundTime = nil
            return true
        }
        
        return false
    }

    private static func generateSessionId() -> String {
        "s_\(UUID().uuidString)"
    }
}
