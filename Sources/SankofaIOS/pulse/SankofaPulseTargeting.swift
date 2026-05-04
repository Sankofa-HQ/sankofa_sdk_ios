import Foundation
import CryptoKit

/// Targeting evaluator — Swift port of
/// `sdks/sankofa_sdk_web/packages/pulse/src/targeting.ts` and
/// `server/engine/ee/pulse/targeting/evaluator.go`.
///
/// Behavioural contract: every (rules, ctx) pair MUST produce the
/// same Decision the Web + Go evaluators produce. The parity test
/// suite at `Tests/SankofaIOSTests/PulseTargetingTests.swift`
/// mirrors the Web tests verbatim. Sampling decisions in particular
/// must agree across server + client — a server-says-in / client-
/// says-out split produces zero exposure rows and breaks A/B
/// reasoning.

public enum SankofaPulseRuleKind {
    public static let url = "url"
    public static let screen = "screen"
    public static let event = "event"
    public static let userProperty = "user_property"
    public static let cohort = "cohort"
    public static let sampling = "sampling"
    public static let frequencyCap = "frequency_cap"
    public static let featureFlag = "feature_flag"
}

public enum SankofaPulseMatchOp {
    public static let equals = "equals"
    public static let notEquals = "not_equals"
    public static let contains = "contains"
    public static let notContains = "not_contains"
    public static let prefix = "prefix"
    public static let regex = "regex"
    public static let inOp = "in"
    public static let notInOp = "not_in"
    public static let exists = "exists"
    public static let notExists = "not_exists"
    public static let gt = "gt"
    public static let lt = "lt"
    public static let gte = "gte"
    public static let lte = "lte"
}

/// One targeting rule. Loosely-typed — relevant fields depend on
/// `kind`; absent fields are simply unused.
public struct SankofaPulseTargetingRule: Codable, Sendable {
    public let kind: String
    // url
    public let urlMatch: String?
    public let urlValue: String?
    // screen — same shape as url, applied to native screen names.
    public let screenMatch: String?
    public let screenName: String?
    // event
    public let eventName: String?
    public let eventMinCount: Int?
    public let eventWindowDays: Int?
    // user_property
    public let propertyKey: String?
    public let propertyOp: String?
    public let propertyValue: SankofaPulseAnyJSON?
    // cohort
    public let cohortId: String?
    // sampling
    public let samplingRate: Double?
    // frequency_cap
    public let frequencyScope: String?
    public let frequencyMax: Int?
    public let frequencyWindowDays: Int?
    // feature_flag
    public let flagKey: String?
    public let flagValue: SankofaPulseAnyJSON?

    public init(
        kind: String,
        urlMatch: String? = nil,
        urlValue: String? = nil,
        screenMatch: String? = nil,
        screenName: String? = nil,
        eventName: String? = nil,
        eventMinCount: Int? = nil,
        eventWindowDays: Int? = nil,
        propertyKey: String? = nil,
        propertyOp: String? = nil,
        propertyValue: SankofaPulseAnyJSON? = nil,
        cohortId: String? = nil,
        samplingRate: Double? = nil,
        frequencyScope: String? = nil,
        frequencyMax: Int? = nil,
        frequencyWindowDays: Int? = nil,
        flagKey: String? = nil,
        flagValue: SankofaPulseAnyJSON? = nil
    ) {
        self.kind = kind
        self.urlMatch = urlMatch
        self.urlValue = urlValue
        self.screenMatch = screenMatch
        self.screenName = screenName
        self.eventName = eventName
        self.eventMinCount = eventMinCount
        self.eventWindowDays = eventWindowDays
        self.propertyKey = propertyKey
        self.propertyOp = propertyOp
        self.propertyValue = propertyValue
        self.cohortId = cohortId
        self.samplingRate = samplingRate
        self.frequencyScope = frequencyScope
        self.frequencyMax = frequencyMax
        self.frequencyWindowDays = frequencyWindowDays
        self.flagKey = flagKey
        self.flagValue = flagValue
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case urlMatch = "url_match"
        case urlValue = "url_value"
        case screenMatch = "screen_match"
        case screenName = "screen_name"
        case eventName = "event_name"
        case eventMinCount = "event_min_count"
        case eventWindowDays = "event_window_days"
        case propertyKey = "property_key"
        case propertyOp = "property_op"
        case propertyValue = "property_value"
        case cohortId = "cohort_id"
        case samplingRate = "sampling_rate"
        case frequencyScope = "frequency_scope"
        case frequencyMax = "frequency_max"
        case frequencyWindowDays = "frequency_window_days"
        case flagKey = "flag_key"
        case flagValue = "flag_value"
    }
}

/// Full eligibility context — mirrors server `EligibilityContext`.
public struct SankofaPulseEligibilityContext: Sendable {
    public let surveyId: String
    public let respondentExternalId: String
    public let pageUrl: String?
    /// Native screen / route name. Sourced from the most-recent
    /// Sankofa.shared.screen() call. Empty before the first screen
    /// fires — KindScreen rules will not match until then.
    public let screenName: String?
    public let recentEvents: [String: Int]?
    public let userProperties: [String: SankofaPulseAnyJSON]?
    public let cohorts: [String: Bool]?
    public let flagValues: [String: SankofaPulseAnyJSON]?
    public let priorResponseCount: [String: Int]?

    public init(
        surveyId: String,
        respondentExternalId: String,
        pageUrl: String? = nil,
        screenName: String? = nil,
        recentEvents: [String: Int]? = nil,
        userProperties: [String: SankofaPulseAnyJSON]? = nil,
        cohorts: [String: Bool]? = nil,
        flagValues: [String: SankofaPulseAnyJSON]? = nil,
        priorResponseCount: [String: Int]? = nil
    ) {
        self.surveyId = surveyId
        self.respondentExternalId = respondentExternalId
        self.pageUrl = pageUrl
        self.screenName = screenName
        self.recentEvents = recentEvents
        self.userProperties = userProperties
        self.cohorts = cohorts
        self.flagValues = flagValues
        self.priorResponseCount = priorResponseCount
    }
}

public struct SankofaPulseDecision: Sendable {
    public let eligible: Bool
    public let reason: String?
    public init(eligible: Bool, reason: String? = nil) {
        self.eligible = eligible
        self.reason = reason
    }
}

public enum SankofaPulseTargeting {

    public static func evaluate(
        rules: [SankofaPulseTargetingRule],
        context ctx: SankofaPulseEligibilityContext
    ) -> SankofaPulseDecision {
        for (i, rule) in rules.enumerated() {
            let result = evaluateOne(rule: rule, ctx: ctx)
            if !result.0 {
                return SankofaPulseDecision(
                    eligible: false,
                    reason: "rule[\(i)] \(rule.kind): \(result.1)"
                )
            }
        }
        return SankofaPulseDecision(eligible: true)
    }

    private static func evaluateOne(
        rule: SankofaPulseTargetingRule,
        ctx: SankofaPulseEligibilityContext
    ) -> (Bool, String) {
        switch rule.kind {
        case SankofaPulseRuleKind.url:           return evalUrl(rule, ctx)
        case SankofaPulseRuleKind.screen:        return evalScreen(rule, ctx)
        case SankofaPulseRuleKind.event:         return evalEvent(rule, ctx)
        case SankofaPulseRuleKind.userProperty:  return evalUserProperty(rule, ctx)
        case SankofaPulseRuleKind.cohort:        return evalCohort(rule, ctx)
        case SankofaPulseRuleKind.sampling:      return evalSampling(rule, ctx)
        case SankofaPulseRuleKind.frequencyCap:  return evalFrequencyCap(rule, ctx)
        case SankofaPulseRuleKind.featureFlag:   return evalFeatureFlag(rule, ctx)
        default:                                 return (false, "unknown rule kind")
        }
    }

    // MARK: - URL

    private static func evalUrl(
        _ rule: SankofaPulseTargetingRule,
        _ ctx: SankofaPulseEligibilityContext
    ) -> (Bool, String) {
        let url = ctx.pageUrl ?? ""
        let target = rule.urlValue ?? ""
        switch rule.urlMatch {
        case SankofaPulseMatchOp.equals:
            return url == target ? (true, "") : (false, "url not equal to target")
        case SankofaPulseMatchOp.contains:
            return url.contains(target)
                ? (true, "") : (false, "url does not contain target")
        case SankofaPulseMatchOp.prefix:
            return url.hasPrefix(target)
                ? (true, "") : (false, "url does not start with target")
        case SankofaPulseMatchOp.regex:
            do {
                let re = try NSRegularExpression(pattern: target)
                let range = NSRange(url.startIndex..., in: url)
                return re.firstMatch(in: url, range: range) != nil
                    ? (true, "") : (false, "url does not match regex")
            } catch {
                return (false, "url regex did not compile")
            }
        default:
            return (false, "url_match unknown")
        }
    }

    // MARK: - Screen

    private static func evalScreen(
        _ rule: SankofaPulseTargetingRule,
        _ ctx: SankofaPulseEligibilityContext
    ) -> (Bool, String) {
        let screen = ctx.screenName ?? ""
        let target = rule.screenName ?? ""
        if screen.isEmpty {
            return (false, "screen unknown")
        }
        switch rule.screenMatch {
        case SankofaPulseMatchOp.equals:
            return screen == target
                ? (true, "") : (false, "screen not equal to target")
        case SankofaPulseMatchOp.contains:
            return screen.contains(target)
                ? (true, "") : (false, "screen does not contain target")
        case SankofaPulseMatchOp.prefix:
            return screen.hasPrefix(target)
                ? (true, "") : (false, "screen does not start with target")
        case SankofaPulseMatchOp.regex:
            do {
                let re = try NSRegularExpression(pattern: target)
                let range = NSRange(screen.startIndex..., in: screen)
                return re.firstMatch(in: screen, range: range) != nil
                    ? (true, "") : (false, "screen does not match regex")
            } catch {
                return (false, "screen regex did not compile")
            }
        default:
            return (false, "screen_match unknown")
        }
    }

    // MARK: - Event

    private static func evalEvent(
        _ rule: SankofaPulseTargetingRule,
        _ ctx: SankofaPulseEligibilityContext
    ) -> (Bool, String) {
        let min = (rule.eventMinCount.map { $0 >= 1 ? $0 : 1 }) ?? 1
        let events = ctx.recentEvents ?? [:]
        let count = events[rule.eventName ?? ""] ?? 0
        if count >= min { return (true, "") }
        return (false,
            "event \"\(rule.eventName ?? "")\" seen \(count) times, need \(min)")
    }

    // MARK: - User property

    private static func evalUserProperty(
        _ rule: SankofaPulseTargetingRule,
        _ ctx: SankofaPulseEligibilityContext
    ) -> (Bool, String) {
        let key = rule.propertyKey ?? ""
        let props = ctx.userProperties ?? [:]
        let present = props[key] != nil
        let v = props[key]

        switch rule.propertyOp {
        case SankofaPulseMatchOp.exists:
            return present ? (true, "") : (false, "property absent")
        case SankofaPulseMatchOp.notExists:
            return !present ? (true, "") : (false, "property present")
        default: break
        }

        if !present { return (false, "property absent") }
        let target = rule.propertyValue
        switch rule.propertyOp {
        case SankofaPulseMatchOp.equals:
            return jsonEqual(v, target)
                ? (true, "") : (false, "property not equal")
        case SankofaPulseMatchOp.notEquals:
            return !jsonEqual(v, target)
                ? (true, "") : (false, "property equal")
        case SankofaPulseMatchOp.contains:
            return strContains(v, target)
                ? (true, "") : (false, "property does not contain target")
        case SankofaPulseMatchOp.notContains:
            return !strContains(v, target)
                ? (true, "") : (false, "property contains target")
        case SankofaPulseMatchOp.inOp:
            return jsonInArray(v, target)
                ? (true, "") : (false, "property not in target list")
        case SankofaPulseMatchOp.notInOp:
            return !jsonInArray(v, target)
                ? (true, "") : (false, "property in target list")
        case SankofaPulseMatchOp.gt,
             SankofaPulseMatchOp.lt,
             SankofaPulseMatchOp.gte,
             SankofaPulseMatchOp.lte:
            return compareNumbers(v, target, rule.propertyOp ?? "")
        default:
            return (false, "property_op unknown")
        }
    }

    // MARK: - Cohort

    private static func evalCohort(
        _ rule: SankofaPulseTargetingRule,
        _ ctx: SankofaPulseEligibilityContext
    ) -> (Bool, String) {
        let id = rule.cohortId ?? ""
        let cohorts = ctx.cohorts ?? [:]
        if cohorts[id] == true { return (true, "") }
        return (false, "respondent not in cohort \"\(id)\"")
    }

    // MARK: - Sampling

    private static func evalSampling(
        _ rule: SankofaPulseTargetingRule,
        _ ctx: SankofaPulseEligibilityContext
    ) -> (Bool, String) {
        let rate = rule.samplingRate ?? 0
        if rate <= 0 { return (false, "sampling rate is 0") }
        if rate >= 1 { return (true, "") }
        if ctx.respondentExternalId.isEmpty {
            return (false, "no external_id; cannot sample deterministically")
        }
        let score = stableHash("\(ctx.surveyId):\(ctx.respondentExternalId)")
        return score < rate
            ? (true, "")
            : (false,
                "sampling miss (score=\(String(format: "%.3f", score)), " +
                "rate=\(String(format: "%.3f", rate)))")
    }

    /// Synchronous SHA-256 over a UTF-8 string, returning the top
    /// 64 bits as a value in [0, 1). Same construction the Go +
    /// Web sides use — top 4 bytes form `hi`, next 4 form `lo`,
    /// then `hi / 2^32 + lo / 2^64`. Critical for cross-language
    /// parity: the same input MUST produce the same score in every
    /// SDK.
    public static func stableHash(_ input: String) -> Double {
        let digest = SHA256.hash(data: Data(input.utf8))
        let bytes = Array(digest)
        let hi = (UInt64(bytes[0]) << 24)
            | (UInt64(bytes[1]) << 16)
            | (UInt64(bytes[2]) << 8)
            | UInt64(bytes[3])
        let lo = (UInt64(bytes[4]) << 24)
            | (UInt64(bytes[5]) << 16)
            | (UInt64(bytes[6]) << 8)
            | UInt64(bytes[7])
        return Double(hi) / 4294967296.0 + Double(lo) / 18446744073709552000.0
    }

    // MARK: - Frequency cap

    private static func evalFrequencyCap(
        _ rule: SankofaPulseTargetingRule,
        _ ctx: SankofaPulseEligibilityContext
    ) -> (Bool, String) {
        let max = (rule.frequencyMax.map { $0 >= 1 ? $0 : 1 }) ?? 1
        let prior = ctx.priorResponseCount?[ctx.surveyId] ?? 0
        if prior < max { return (true, "") }
        return (false,
            "respondent has \(prior) prior responses (cap=\(max), " +
            "window=\(rule.frequencyWindowDays.map(String.init) ?? "nil")d)")
    }

    // MARK: - Feature flag

    private static func evalFeatureFlag(
        _ rule: SankofaPulseTargetingRule,
        _ ctx: SankofaPulseEligibilityContext
    ) -> (Bool, String) {
        let key = rule.flagKey ?? ""
        let flags = ctx.flagValues ?? [:]
        guard let have = flags[key] else {
            return (false, "flag \"\(key)\" not in context")
        }
        if jsonEqual(have, rule.flagValue) { return (true, "") }
        return (false, "flag \"\(key)\" value mismatch")
    }

    // MARK: - Helpers

    private static func jsonEqual(_ a: SankofaPulseAnyJSON?, _ b: SankofaPulseAnyJSON?) -> Bool {
        switch (a, b) {
        case (.none, .none): return true
        case (.none, _), (_, .none): return false
        default: break
        }
        guard let a = a, let b = b else { return false }
        // Numbers compare by .doubleValue so 5 == 5.0 across the wire.
        if let an = numericValue(a), let bn = numericValue(b) {
            return an == bn
        }
        return a == b
    }

    private static func strContains(_ v: SankofaPulseAnyJSON?, _ target: SankofaPulseAnyJSON?) -> Bool {
        let haystack: String
        switch v {
        case .some(.string(let s)): haystack = s
        case .none: haystack = ""
        default: haystack = anyJsonToString(v)
        }
        let needle: String
        switch target {
        case .some(.string(let s)): needle = s
        case .none: needle = ""
        default: needle = anyJsonToString(target)
        }
        return haystack.contains(needle)
    }

    private static func jsonInArray(_ v: SankofaPulseAnyJSON?, _ target: SankofaPulseAnyJSON?) -> Bool {
        guard case .array(let arr) = target else { return false }
        return arr.contains { jsonEqual(v, $0) }
    }

    private static func compareNumbers(
        _ v: SankofaPulseAnyJSON?,
        _ target: SankofaPulseAnyJSON?,
        _ op: String
    ) -> (Bool, String) {
        guard let left = numericValue(v) else {
            return (false, "property is not numeric")
        }
        guard let right = numericValue(target) else {
            return (false, "target is not numeric")
        }
        switch op {
        case SankofaPulseMatchOp.gt:
            return left > right ? (true, "") : (false, "\(left) \(op) \(right) fails")
        case SankofaPulseMatchOp.lt:
            return left < right ? (true, "") : (false, "\(left) \(op) \(right) fails")
        case SankofaPulseMatchOp.gte:
            return left >= right ? (true, "") : (false, "\(left) \(op) \(right) fails")
        case SankofaPulseMatchOp.lte:
            return left <= right ? (true, "") : (false, "\(left) \(op) \(right) fails")
        default:
            return (false, "op \(op) not numeric")
        }
    }

    private static func numericValue(_ v: SankofaPulseAnyJSON?) -> Double? {
        switch v {
        case .some(.int(let i)): return Double(i)
        case .some(.double(let d)): return d.isFinite ? d : nil
        case .some(.bool(let b)): return b ? 1.0 : 0.0
        case .some(.string(let s)):
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return nil }
            return Double(t)
        default: return nil
        }
    }

    private static func anyJsonToString(_ v: SankofaPulseAnyJSON?) -> String {
        guard let v = v else { return "" }
        switch v {
        case .string(let s): return s
        case .int(let i):    return String(i)
        case .double(let d): return String(d)
        case .bool(let b):   return String(b)
        case .null:          return ""
        case .array, .object:
            // Best-effort: re-encode + decode so callers see a JSON
            // string form for `contains` matches against arrays/objects.
            if let data = try? JSONEncoder().encode(v),
               let s = String(data: data, encoding: .utf8) { return s }
            return ""
        }
    }
}
