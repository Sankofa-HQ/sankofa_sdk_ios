import Foundation

/// Manages distinct_id resolution and anonymous ↔ identified user bridging.
///
/// Mirrors `SankofaIdentity` in the Flutter SDK and the identity layer of the Android SDK.
final class SankofaIdentity {

    private let anonKey     = "dev.sankofa.anonymous_id"
    private let distinctKey = "dev.sankofa.distinct_id"
    private let storage     = UserDefaults.standard

    /// The currently active distinct ID. Could be anonymous or resolved.
    var distinctId: String {
        storage.string(forKey: distinctKey) ?? anonymousId
    }

    /// A stable, persistent anonymous ID generated on first launch.
    private(set) lazy var anonymousId: String = {
        if let existing = storage.string(forKey: anonKey) {
            return existing
        }
        let newId = "anon_\(UUID().uuidString)"
        storage.set(newId, forKey: anonKey)
        return newId
    }()

    /// Link anonymous data to a known user ID.
    func identify(userId: String) {
        storage.set(userId, forKey: distinctKey)
    }

    /// Clear identity on logout. Resets distinct_id back to the anonymous ID.
    func reset() {
        storage.removeObject(forKey: distinctKey)
        // Rotate anonymous ID so the new session is fresh.
        let newAnonId = "anon_\(UUID().uuidString)"
        storage.set(newAnonId, forKey: anonKey)
    }
}
