import Foundation

/// Sankofa Remote Config on iOS.
///
/// NOTE: This class is named `SankofaRemoteConfig` rather than
/// `SankofaConfig` because the iOS SDK already uses `SankofaConfig` as
/// the init-options struct passed to `Sankofa.shared.initialize(...)`.
/// Renaming that struct would break the RN native bridge that depends
/// on its Obj-C name. The Web/RN/Flutter SDKs call their equivalent
/// class `SankofaConfig`; iOS is the outlier deliberately.
///
/// Usage:
/// ```swift
/// Sankofa.shared.initialize(apiKey: "sk_live_...")
/// let maxMB: Int = SankofaRemoteConfig.shared.get("max_upload_mb", default: 25)
/// let pricing: [String: Any] = SankofaRemoteConfig.shared.get("pricing", default: ["pro": 9.99])
/// ```
public final class SankofaRemoteConfig: NSObject, SankofaPluggableModule, @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = SankofaRemoteConfig()

    public var canonicalName: SankofaModuleName { .configModule }

    // MARK: - State

    private static let storageKey = "sankofa.config.state"
    private static let staleMaxSeconds: TimeInterval = 7 * 24 * 60 * 60

    private let queue = DispatchQueue(label: "dev.sankofa.config", qos: .utility, attributes: .concurrent)
    private var values: [String: ItemDecision] = [:]
    private var etag: String = ""
    private var savedAt: TimeInterval = 0
    private var defaults: [String: ItemDecision] = [:]
    private var listeners: [String: [UUID: ConfigChangeListener]] = [:]

    private override init() {
        super.init()
        SankofaModuleRegistry.shared.register(self)
        hydrateFromStorage()
    }

    /// Seed bundled defaults — returned on cold cache before the
    /// handshake lands. Call once after `Sankofa.shared.initialize()`.
    @discardableResult
    public func withDefaults(_ defaults: [String: ItemDecision]) -> SankofaRemoteConfig {
        queue.async(flags: .barrier) {
            self.defaults = defaults
        }
        return self
    }

    // MARK: - SankofaPluggableModule

    public func applyHandshake(_ config: [String: Any]) async {
        if let enabled = config["enabled"] as? Bool, !enabled { return }
        var incoming: [String: ItemDecision] = [:]
        if let raw = config["values"] as? [String: [String: Any]] {
            for (key, json) in raw {
                if let d = ItemDecision.fromJSON(json) {
                    incoming[key] = d
                }
            }
        }
        let etag = (config["etag"] as? String) ?? ""
        let (changed, removed) = diffAndApply(incoming: incoming, etag: etag)
        persistToStorage()
        fire(changed: changed, removed: removed)
    }

    // MARK: - Public API (typed reads)

    /// Typed lookup. Returns `defaultValue` on:
    ///   - missing key,
    ///   - present key whose stored type doesn't match `T`,
    ///   - `null` value.
    ///
    /// Supported Ts: `String`, `Int`, `Int64`, `Double`, `Bool`, and
    /// any type the `Any` cast can succeed on for array/object shapes
    /// (`[Any?]`, `[String: Any?]`).
    public func get<T>(_ key: String, default defaultValue: T) -> T {
        let decision = queue.sync { values[key] ?? defaults[key] }
        guard let value = decision?.value else { return defaultValue }
        return typedValue(value, fallback: defaultValue)
    }

    /// Full decision envelope including reason + version + type.
    public func getDecision(_ key: String) -> ItemDecision? {
        queue.sync { values[key] ?? defaults[key] }
    }

    /// Every known key (union of remote + local defaults).
    public func getAllKeys() -> [String] {
        queue.sync { Array(Set(values.keys).union(defaults.keys)) }
    }

    /// Plain `[key: Any]` snapshot — values are unwrapped to their
    /// natural Swift/Foundation types (`Int64` / `Double` / `Bool` /
    /// `String` / `[Any]` / `[String: Any]`). Convenient for
    /// "replace my global settings object on refresh" flows.
    public func getAll() -> [String: Any] {
        queue.sync {
            var out: [String: Any] = [:]
            for (k, d) in defaults { if let v = d.value.rawValue { out[k] = v } }
            for (k, d) in values { if let v = d.value.rawValue { out[k] = v } }
            return out
        }
    }

    @discardableResult
    public func onChange(_ key: String, _ listener: @escaping ConfigChangeListener) -> Cancellation {
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

    public var currentEtag: String { queue.sync { etag } }

    // MARK: - Typed value coercion

    private func typedValue<T>(_ v: ConfigValue, fallback: T) -> T {
        switch v {
        case .null: return fallback
        case .bool(let b): return (b as? T) ?? fallback
        case .int(let i):
            // Let Int64→Int and Int64→Double conversions succeed since
            // JSON doesn't differentiate width.
            if let t = i as? T { return t }
            if T.self == Int.self, let t = Int(exactly: i) as? T { return t }
            if T.self == Double.self { return (Double(i) as? T) ?? fallback }
            return fallback
        case .double(let d):
            if let t = d as? T { return t }
            if T.self == Int.self, let t = Int(d) as? T { return t }
            if T.self == Int64.self, let t = Int64(d) as? T { return t }
            return fallback
        case .string(let s): return (s as? T) ?? fallback
        case .array(let arr):
            let raw = arr.map { $0.rawValue }
            return (raw as? T) ?? fallback
        case .object(let obj):
            var raw: [String: Any] = [:]
            for (k, vv) in obj { if let r = vv.rawValue { raw[k] = r } }
            return (raw as? T) ?? fallback
        }
    }

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

    private func diffAndApply(incoming: [String: ItemDecision], etag: String) -> (changed: Set<String>, removed: Set<String>) {
        queue.sync(flags: .barrier) {
            var changed: Set<String> = []
            var removed: Set<String> = []
            for key in values.keys where incoming[key] == nil {
                removed.insert(key)
            }
            for (key, decision) in incoming where values[key] != decision {
                changed.insert(key)
            }
            values = incoming
            self.etag = etag
            savedAt = Date().timeIntervalSince1970
            return (changed, removed)
        }
    }

    private func fire(changed: Set<String>, removed: Set<String>) {
        let snapshotValues: [String: ItemDecision] = queue.sync { values }
        let snapshotListeners: [String: [UUID: ConfigChangeListener]] = queue.sync { listeners }

        for key in changed {
            guard let bucket = snapshotListeners[key] else { continue }
            let decision = snapshotValues[key]
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
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
            return
        }
        if persisted.savedAt > 0,
           Date().timeIntervalSince1970 - persisted.savedAt > Self.staleMaxSeconds {
            return
        }
        queue.async(flags: .barrier) {
            self.values = persisted.values
            self.etag = persisted.etag
            self.savedAt = persisted.savedAt
        }
    }

    private func persistToStorage() {
        let snapshot: PersistedState = queue.sync {
            PersistedState(values: values, etag: etag, savedAt: savedAt)
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private struct PersistedState: Codable {
        let values: [String: ItemDecision]
        let etag: String
        let savedAt: TimeInterval
    }
}
