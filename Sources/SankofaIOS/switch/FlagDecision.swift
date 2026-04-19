import Foundation

// Wire shape mirroring server/engine/ee/switchmod/evaluator_batch.go.
// Keeping these colocated with the module so a server rename breaks
// the Swift compile — silent drift is the worst failure mode for
// feature-flag contracts.

/// Reason tag returned alongside a flag decision. Stable across server
/// releases — SDKs and dashboards may key off these values. Any new
/// server reason the SDK doesn't recognise falls into `.unknown` so
/// forward-compat doesn't hard-fail.
public enum FlagReason: String, Codable, Sendable {
    case archived
    case halted
    case scheduled
    case noRule = "no_rule"
    case rollout
    case variantAssigned = "variant_assigned"
    case variantUnavailable = "variant_unavailable"
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
    case dependencyUnmet = "dependency_unmet"
    case overrideParseError = "override_parse_error"
    case unknown

    public init(wire: String?) {
        guard let wire = wire, let reason = FlagReason(rawValue: wire) else {
            self = .unknown
            return
        }
        self = reason
    }
}

/// A single flag evaluation result. `value` is the boolean the SDK
/// returns from `getFlag(_:default:)`. For variant flags, `value` is
/// `true` iff the assigned variant is non-default — a convenience so
/// callers who just care about "did this flag fire" don't have to
/// inspect `variant`.
public struct FlagDecision: Codable, Equatable, Sendable {
    public let value: Bool
    public let variant: String
    public let reason: FlagReason
    public let version: Int

    public init(value: Bool, variant: String = "", reason: FlagReason, version: Int) {
        self.value = value
        self.variant = variant
        self.reason = reason
        self.version = version
    }

    /// Decode from the raw handshake dictionary representation.
    /// Returns nil when the shape is obviously wrong so a malformed
    /// single entry doesn't poison the whole flag map.
    public static func fromJSON(_ json: [String: Any]) -> FlagDecision? {
        let value = json["value"] as? Bool ?? false
        let variant = json["variant"] as? String ?? ""
        let reason = FlagReason(wire: json["reason"] as? String)
        let version = json["version"] as? Int ?? 0
        return FlagDecision(value: value, variant: variant, reason: reason, version: version)
    }
}

/// Callback fired when a flag's decision changes after a handshake
/// refresh. `decision` is `nil` when the flag was removed remotely.
public typealias FlagChangeListener = @Sendable (FlagDecision?) -> Void
