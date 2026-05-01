import Foundation

/// Branching evaluator — Swift port of
/// `sdks/sankofa_sdk_web/packages/pulse/src/branching.ts` and
/// `server/engine/ee/pulse/branching/evaluator.go`.
///
/// Behavioural contract: every (rules, currentQuestionId, answers)
/// triple MUST produce the same Outcome the Web + Go evaluators
/// produce. Tests in
/// `Tests/SankofaIOSTests/PulseBranchingTests.swift` mirror the
/// Web suite verbatim.
///
/// Composition: first matching rule attached to currentQuestionId
/// wins. When no rule matches, returns nextQuestionId="" so the
/// SDK falls through to the natural next question (by order_index).
/// When the matching rule has action="end_survey", returns the
/// [SankofaPulseBranchingEndOfSurvey] sentinel.

/// Sentinel: when [SankofaPulseOutcome.nextQuestionId] equals this
/// string, the survey should end immediately.
public let SankofaPulseBranchingEndOfSurvey = "__end__"

public enum SankofaPulseBranchingActionKind {
    public static let skipTo = "skip_to"
    public static let endSurvey = "end_survey"
}

public enum SankofaPulseBranchingCondKind {
    public static let answer = "answer"
}

public enum SankofaPulseBranchingCondOp {
    public static let equals = "equals"
    public static let notEquals = "not_equals"
    public static let gt = "gt"
    public static let lt = "lt"
    public static let gte = "gte"
    public static let lte = "lte"
    public static let contains = "contains"
    public static let notContains = "not_contains"
    public static let inOp = "in"
    public static let notInOp = "not_in"
    public static let answered = "answered"
    public static let notAnswered = "not_answered"
}

public struct SankofaPulseBranchingCondition: Codable, Sendable {
    public let kind: String
    public let questionId: String
    public let op: String
    public let value: SankofaPulseAnyJSON?

    public init(kind: String, questionId: String, op: String,
                value: SankofaPulseAnyJSON? = nil) {
        self.kind = kind
        self.questionId = questionId
        self.op = op
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case questionId = "question_id"
        case op
        case value
    }
}

public struct SankofaPulseBranchingRule: Codable, Sendable {
    public let fromQuestionId: String
    public let condition: SankofaPulseBranchingCondition
    public let action: String
    public let toQuestionId: String?

    public init(
        fromQuestionId: String,
        condition: SankofaPulseBranchingCondition,
        action: String,
        toQuestionId: String? = nil
    ) {
        self.fromQuestionId = fromQuestionId
        self.condition = condition
        self.action = action
        self.toQuestionId = toQuestionId
    }

    enum CodingKeys: String, CodingKey {
        case fromQuestionId = "from_question_id"
        case condition
        case action
        case toQuestionId = "to_question_id"
    }
}

public struct SankofaPulseOutcome: Sendable {
    public let nextQuestionId: String
    public let reason: String?
    public init(nextQuestionId: String, reason: String? = nil) {
        self.nextQuestionId = nextQuestionId
        self.reason = reason
    }
}

public enum SankofaPulseBranching {

    public static func resolveNext(
        rules: [SankofaPulseBranchingRule],
        currentQuestionId: String,
        answers: [String: SankofaPulseAnyJSON]
    ) -> SankofaPulseOutcome {
        for (i, rule) in rules.enumerated() {
            if rule.fromQuestionId != currentQuestionId { continue }
            if !evaluateCondition(rule.condition, answers: answers) { continue }
            switch rule.action {
            case SankofaPulseBranchingActionKind.skipTo:
                return SankofaPulseOutcome(
                    nextQuestionId: rule.toQuestionId ?? "",
                    reason: "rule[\(i)] skip_to \(rule.toQuestionId ?? "")")
            case SankofaPulseBranchingActionKind.endSurvey:
                return SankofaPulseOutcome(
                    nextQuestionId: SankofaPulseBranchingEndOfSurvey,
                    reason: "rule[\(i)] end_survey")
            default:
                continue
            }
        }
        return SankofaPulseOutcome(
            nextQuestionId: "",
            reason: "fall through (no rule matched)")
    }

    public static func evaluateCondition(
        _ cond: SankofaPulseBranchingCondition,
        answers: [String: SankofaPulseAnyJSON]
    ) -> Bool {
        switch cond.kind {
        case SankofaPulseBranchingCondKind.answer:
            return evalAnswerCondition(cond, answers: answers)
        default:
            return false
        }
    }

    private static func evalAnswerCondition(
        _ cond: SankofaPulseBranchingCondition,
        answers: [String: SankofaPulseAnyJSON]
    ) -> Bool {
        let present = answers[cond.questionId] != nil
        let v = answers[cond.questionId]
        switch cond.op {
        case SankofaPulseBranchingCondOp.answered:
            return present && !isEmptyAnswer(v)
        case SankofaPulseBranchingCondOp.notAnswered:
            return !present || isEmptyAnswer(v)
        default: break
        }
        if !present || isEmptyAnswer(v) { return false }
        switch cond.op {
        case SankofaPulseBranchingCondOp.equals:
            return jsonEqual(v, cond.value)
        case SankofaPulseBranchingCondOp.notEquals:
            return !jsonEqual(v, cond.value)
        case SankofaPulseBranchingCondOp.contains:
            return jsonContains(v, cond.value)
        case SankofaPulseBranchingCondOp.notContains:
            return !jsonContains(v, cond.value)
        case SankofaPulseBranchingCondOp.inOp:
            return jsonInArray(v, cond.value)
        case SankofaPulseBranchingCondOp.notInOp:
            return !jsonInArray(v, cond.value)
        case SankofaPulseBranchingCondOp.gt,
             SankofaPulseBranchingCondOp.lt,
             SankofaPulseBranchingCondOp.gte,
             SankofaPulseBranchingCondOp.lte:
            return compareNumeric(v, cond.value, cond.op)
        default:
            return false
        }
    }

    // MARK: - Helpers

    private static func isEmptyAnswer(_ v: SankofaPulseAnyJSON?) -> Bool {
        switch v {
        case .none, .some(.null): return true
        case .some(.string(let s)): return s.trimmingCharacters(in: .whitespaces).isEmpty
        case .some(.array(let a)): return a.isEmpty
        default: return false
        }
    }

    private static func jsonEqual(_ a: SankofaPulseAnyJSON?, _ b: SankofaPulseAnyJSON?) -> Bool {
        switch (a, b) {
        case (.none, .none): return true
        case (.none, _), (_, .none): return false
        default: break
        }
        guard let a = a, let b = b else { return false }
        if let an = numericValue(a), let bn = numericValue(b) {
            return an == bn
        }
        return a == b
    }

    private static func jsonContains(_ v: SankofaPulseAnyJSON?, _ target: SankofaPulseAnyJSON?) -> Bool {
        // Array containment (multi-select).
        if case .array(let arr) = v {
            return arr.contains { jsonEqual($0, target) }
        }
        // String containment.
        if case .string(let s) = v, case .string(let t) = target {
            return s.contains(t)
        }
        return false
    }

    private static func jsonInArray(_ v: SankofaPulseAnyJSON?, _ target: SankofaPulseAnyJSON?) -> Bool {
        guard case .array(let arr) = target else { return false }
        return arr.contains { jsonEqual(v, $0) }
    }

    private static func compareNumeric(
        _ v: SankofaPulseAnyJSON?,
        _ target: SankofaPulseAnyJSON?,
        _ op: String
    ) -> Bool {
        guard let left = numericValue(v) else { return false }
        guard let right = numericValue(target) else { return false }
        switch op {
        case SankofaPulseBranchingCondOp.gt: return left > right
        case SankofaPulseBranchingCondOp.lt: return left < right
        case SankofaPulseBranchingCondOp.gte: return left >= right
        case SankofaPulseBranchingCondOp.lte: return left <= right
        default: return false
        }
    }

    /// Same numeric coercion shape as the Go side: numbers, strings
    /// that parse as numbers, and booleans (true → 1, false → 0).
    /// The boolean coercion is defensive — a boolean question wired
    /// to a numeric op shouldn't crash the evaluator.
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
}
