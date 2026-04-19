import Foundation

// Wire shape mirroring server/engine/ee/configmod/evaluator_batch.go.

/// Declared type of a config item. Echoed by the server in every
/// decision so the SDK doesn't need to re-parse JSON values.
public enum ConfigType: String, Codable, Sendable {
    case string
    case int
    case float
    case bool
    case json
    case unknown

    public init(wire: String?) {
        guard let wire = wire, let t = ConfigType(rawValue: wire) else {
            self = .unknown
            return
        }
        self = t
    }
}

/// Reason a config item resolved the way it did.
public enum ItemReason: String, Codable, Sendable {
    case archived
    case noRule = "no_rule"
    case ruleMatched = "rule_matched"
    case notInRollout = "not_in_rollout"
    case inExcludedCohort = "in_excluded_cohort"
    case notInTargetCohort = "not_in_target_cohort"
    case cohortLookupFailed = "cohort_lookup_failed"
    case countryBlocked = "country_blocked"
    case countryNotInAllow = "country_not_in_allow"
    case countryUnknown = "country_unknown"
    case appVersionBelowMin = "app_version_below_min"
    case appVersionAboveMax = "app_version_above_max"
    case osVersionBelowMin = "os_version_below_min"
    case osVersionAboveMax = "os_version_above_max"
    case notInUserAllowList = "not_in_user_allow_list"
    case unknown

    public init(wire: String?) {
        guard let wire = wire, let r = ItemReason(rawValue: wire) else {
            self = .unknown
            return
        }
        self = r
    }
}

/// One decision per config item. `value` is a `ConfigValue` — a
/// type-erased wrapper that preserves the exact JSON shape the server
/// emitted (string, number, bool, array, object, null). Callers use
/// `SankofaRemoteConfig.shared.get(_:default:)` to pull a typed value
/// out without casting.
public struct ItemDecision: Codable, Equatable, Sendable {
    public let value: ConfigValue
    public let type: ConfigType
    public let reason: ItemReason
    public let version: Int

    public init(value: ConfigValue, type: ConfigType, reason: ItemReason, version: Int) {
        self.value = value
        self.type = type
        self.reason = reason
        self.version = version
    }

    public static func fromJSON(_ json: [String: Any]) -> ItemDecision? {
        let value = ConfigValue.from(any: json["value"])
        let type = ConfigType(wire: json["type"] as? String)
        let reason = ItemReason(wire: json["reason"] as? String)
        let version = json["version"] as? Int ?? 0
        return ItemDecision(value: value, type: type, reason: reason, version: version)
    }
}

/// Type-erased JSON value. Codable across process restarts so the
/// UserDefaults-persisted cache survives a cold launch.
///
/// Keep the cases minimal and closed — any new JSON type the server
/// adds would require a SDK bump anyway to be usable, so we don't
/// need a `.unknown` escape hatch here.
public enum ConfigValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([ConfigValue])
    case object([String: ConfigValue])

    // MARK: - Dynamic conversion from JSONSerialization output

    public static func from(any: Any?) -> ConfigValue {
        guard let any = any else { return .null }
        if any is NSNull { return .null }
        if let b = any as? Bool { return .bool(b) }
        // NSNumber differentiates Bool vs Int vs Double by the underlying
        // Obj-C type code — the `as? Bool` above already caught the
        // NSNumber-boxed bool; remaining NSNumbers are numeric.
        if let n = any as? NSNumber {
            let isDouble = String(cString: n.objCType) == "d" || String(cString: n.objCType) == "f"
            return isDouble ? .double(n.doubleValue) : .int(n.int64Value)
        }
        if let s = any as? String { return .string(s) }
        if let arr = any as? [Any?] { return .array(arr.map { ConfigValue.from(any: $0) }) }
        if let dict = any as? [String: Any?] {
            var out: [String: ConfigValue] = [:]
            for (k, v) in dict { out[k] = .from(any: v) }
            return .object(out)
        }
        return .null
    }

    // MARK: - Typed getters

    /// The Swift-native representation of this value. Matches the
    /// shape the server emitted — callers almost never need this
    /// directly; prefer `SankofaRemoteConfig.shared.get(_:default:)`.
    public var rawValue: Any? {
        switch self {
        case .null: return nil
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { $0.rawValue }
        case .object(let o):
            var out: [String: Any?] = [:]
            for (k, v) in o { out[k] = v.rawValue }
            return out
        }
    }

    // MARK: - Codable

    // Encode/decode as untagged JSON so UserDefaults data is the same
    // shape the server emits (enables cross-tool debugging).

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([ConfigValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: ConfigValue].self) { self = .object(o); return }
        throw DecodingError.typeMismatch(
            ConfigValue.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "unrecognised JSON type in config cache")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// Callback fired when an item's decision changes. `nil` decision
/// means the item was removed remotely.
public typealias ConfigChangeListener = @Sendable (ItemDecision?) -> Void
