import Foundation

/// Sankofa Switch — feature flags on iOS.
///
/// Usage:
/// ```swift
/// Sankofa.shared.initialize(apiKey: "sk_live_...")
/// _ = SankofaSwitch.shared // constructs & self-registers on first access
///
/// // anywhere, synchronously:
/// if SankofaSwitch.shared.getFlag("new_checkout") {
///     showNewUI()
/// }
/// ```
///
/// The singleton self-registers with the Traffic Cop so the handshake
/// response's `modules.switch` payload flows here automatically. Calls
/// made before the first handshake completes return the supplied
/// defaults, or the last persisted decision from UserDefaults when the
/// cache is fresh (7-day stale-while-revalidate window).
public final class SankofaSwitch: NSObject, SankofaPluggableModule, @unchecked Sendable {

    // MARK: - Singleton

    /// Shared instance. The first access constructs + registers the
    /// instance with the Core; subsequent accesses return the same one.
    /// A singleton is the right choice here because flag state is
    /// inherently global — calls from anywhere in the app should see
    /// the same decisions.
    public static let shared = SankofaSwitch()

    // MARK: - Module protocol

    public var canonicalName: SankofaModuleName { .switchModule }

    // MARK: - State (guarded by `queue`)

    private static let storageKey = "sankofa.switch.state"
    private static let staleMaxSeconds: TimeInterval = 7 * 24 * 60 * 60

    private let queue = DispatchQueue(label: "dev.sankofa.switch", qos: .utility, attributes: .concurrent)
    private var flags: [String: FlagDecision] = [:]
    private var etag: String = ""
    private var savedAt: TimeInterval = 0
    private var defaults: [String: FlagDecision] = [:]
    private var listeners: [String: [UUID: FlagChangeListener]] = [:]

    // MARK: - Init

    private override init() {
        super.init()
        SankofaModuleRegistry.shared.register(self)
        // Hydrate synchronously on first construction so the first
        // `getFlag(...)` call after `shared` access already has cached
        // values available. UserDefaults access is cheap — measured in
        // microseconds — so blocking init briefly is fine.
        hydrateFromStorage()
    }

    /// Seed bundled defaults. Call once after `Sankofa.shared.initialize()`,
    /// before any `getFlag` calls. Supplying defaults for a flag lets
    /// `getFlag` return the right value on a cold cache before the
    /// handshake lands. Returns `self` so it chains.
    @discardableResult
    public func withDefaults(_ defaults: [String: FlagDecision]) -> SankofaSwitch {
        queue.async(flags: .barrier) {
            self.defaults = defaults
        }
        return self
    }

    // MARK: - SankofaPluggableModule

    public func applyHandshake(_ config: [String: Any]) async {
        if let enabled = config["enabled"] as? Bool, !enabled { return }
        var incoming: [String: FlagDecision] = [:]
        if let raw = config["flags"] as? [String: [String: Any]] {
            for (key, json) in raw {
                if let d = FlagDecision.fromJSON(json) {
                    incoming[key] = d
                }
            }
        }
        let etag = (config["etag"] as? String) ?? ""
        let (changed, removed) = diffAndApply(incoming: incoming, etag: etag)
        persistToStorage()
        fire(changed: changed, removed: removed)
    }

    // MARK: - Public API

    /// Returns the boolean value for a flag. Boolean flags return their
    /// evaluated value; variant flags return `true` iff the assigned
    /// variant is non-default.
    public func getFlag(_ key: String, default defaultValue: Bool = false) -> Bool {
        queue.sync {
            if let decision = flags[key] ?? defaults[key] { return decision.value }
            return defaultValue
        }
    }

    /// Returns the assigned variant key for a variant flag, or the
    /// supplied default when the flag is missing.
    public func getVariant(_ key: String, default defaultValue: String = "") -> String {
        queue.sync {
            if let decision = flags[key] ?? defaults[key], !decision.variant.isEmpty {
                return decision.variant
            }
            return defaultValue
        }
    }

    /// Full decision envelope — value + variant + reason + version.
    public func getDecision(_ key: String) -> FlagDecision? {
        queue.sync { flags[key] ?? defaults[key] }
    }

    /// Every currently known flag key (union of cached + defaults).
    public func getAllKeys() -> [String] {
        queue.sync { Array(Set(flags.keys).union(defaults.keys)) }
    }

    /// Subscribe to changes for one flag. Returns a token that you
    /// must keep alive; when the token's `cancel()` is called (or
    /// it's deallocated), the listener is removed.
    @discardableResult
    public func onChange(_ key: String, _ listener: @escaping FlagChangeListener) -> Cancellation {
        let id = UUID()
        queue.async(flags: .barrier) {
            var bucket = self.listeners[key] ?? [:]
            bucket[id] = listener
            self.listeners[key] = bucket
        }
        return Cancellation { [weak self] in
            self?.removeListener(key: key, id: id)
        }
    }

    /// Composite etag from the last successful handshake. The core
    /// sends this as `If-None-Match` on the next refresh.
    public var currentEtag: String { queue.sync { etag } }

    // MARK: - Internals

    private func removeListener(key: String, id: UUID) {
        queue.async(flags: .barrier) {
            guard var bucket = self.listeners[key] else { return }
            bucket.removeValue(forKey: id)
            if bucket.isEmpty {
                self.listeners.removeValue(forKey: key)
            } else {
                self.listeners[key] = bucket
            }
        }
    }

    private func diffAndApply(incoming: [String: FlagDecision], etag: String) -> (changed: Set<String>, removed: Set<String>) {
        queue.sync(flags: .barrier) {
            var changed: Set<String> = []
            var removed: Set<String> = []
            for key in flags.keys where incoming[key] == nil {
                removed.insert(key)
            }
            for (key, decision) in incoming where flags[key] != decision {
                changed.insert(key)
            }
            flags = incoming
            self.etag = etag
            savedAt = Date().timeIntervalSince1970
            return (changed, removed)
        }
    }

    private func fire(changed: Set<String>, removed: Set<String>) {
        let snapshotFlags: [String: FlagDecision] = queue.sync { flags }
        let snapshotListeners: [String: [UUID: FlagChangeListener]] = queue.sync { listeners }

        for key in changed {
            guard let bucket = snapshotListeners[key] else { continue }
            let decision = snapshotFlags[key]
            for (_, listener) in bucket {
                listener(decision)
            }
        }
        for key in removed {
            guard let bucket = snapshotListeners[key] else { continue }
            for (_, listener) in bucket {
                listener(nil)
            }
        }
    }

    // MARK: - Storage

    private func hydrateFromStorage() {
        guard let raw = UserDefaults.standard.data(forKey: Self.storageKey) else { return }
        guard let persisted = try? JSONDecoder().decode(PersistedState.self, from: raw) else {
            // Corrupt JSON — clear so the next persist writes clean.
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
            return
        }
        if persisted.savedAt > 0,
           Date().timeIntervalSince1970 - persisted.savedAt > Self.staleMaxSeconds {
            return
        }
        queue.async(flags: .barrier) {
            self.flags = persisted.flags
            self.etag = persisted.etag
            self.savedAt = persisted.savedAt
        }
    }

    private func persistToStorage() {
        let snapshot: PersistedState = queue.sync {
            PersistedState(flags: flags, etag: etag, savedAt: savedAt)
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private struct PersistedState: Codable {
        let flags: [String: FlagDecision]
        let etag: String
        let savedAt: TimeInterval
    }
}

/// Token returned by `onChange` subscriptions. Callers hold it to keep
/// the listener alive; calling `cancel()` (or letting it deallocate)
/// removes the listener.
public final class Cancellation {
    private var action: (() -> Void)?

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    public func cancel() {
        action?()
        action = nil
    }

    deinit { cancel() }
}
