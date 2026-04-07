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

    /// In-memory cache for the anonymous ID so we stay consistent within a session
    /// without hitting UserDefaults on every read.
    private var _anonymousId: String?

    /// A stable, persistent anonymous ID generated on first launch.
    /// Unlike a lazy var, this always reflects the latest value written by reset().
    var anonymousId: String {
        if let cached = _anonymousId { return cached }
        if let existing = storage.string(forKey: anonKey) {
            _anonymousId = existing
            return existing
        }
        let newId = "anon_\(UUID().uuidString)"
        storage.set(newId, forKey: anonKey)
        _anonymousId = newId
        return newId
    }

    /// Link anonymous data to a known user ID.
    func identify(userId: String) {
        storage.set(userId, forKey: distinctKey)
    }

    /// Clear identity on logout. Resets distinct_id back to a fresh anonymous ID.
    func reset() {
        storage.removeObject(forKey: distinctKey)
        let newAnonId = "anon_\(UUID().uuidString)"
        storage.set(newAnonId, forKey: anonKey)
        _anonymousId = newAnonId   // keep in-memory cache in sync
    }
}
