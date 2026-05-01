import XCTest
@testable import SankofaIOS

/// Branching evaluator parity test suite. Mirrors
/// `sdks/sankofa_sdk_web/packages/pulse/src/__tests__/branching.test.ts`
/// verbatim — failures here mean the iOS SDK will disagree with the
/// Web SDK and Go server about which question to show next.
final class PulseBranchingTests: XCTestCase {

    func testEmptyRulesFallThrough() {
        let out = SankofaPulseBranching.resolveNext(
            rules: [], currentQuestionId: "psq_q1", answers: [:])
        XCTAssertEqual(out.nextQuestionId, "")
    }

    func testNoMatchingRuleFallThrough() {
        let rules = [
            SankofaPulseBranchingRule(
                fromQuestionId: "psq_q1",
                condition: SankofaPulseBranchingCondition(
                    kind: SankofaPulseBranchingCondKind.answer,
                    questionId: "psq_q1",
                    op: SankofaPulseBranchingCondOp.equals,
                    value: .string("never")),
                action: SankofaPulseBranchingActionKind.skipTo,
                toQuestionId: "psq_q5"),
        ]
        let out = SankofaPulseBranching.resolveNext(
            rules: rules,
            currentQuestionId: "psq_q1",
            answers: ["psq_q1": .string("always")])
        XCTAssertEqual(out.nextQuestionId, "")
    }

    func testSkipToFiresOnMatch() {
        let rules = [
            SankofaPulseBranchingRule(
                fromQuestionId: "psq_nps",
                condition: SankofaPulseBranchingCondition(
                    kind: SankofaPulseBranchingCondKind.answer,
                    questionId: "psq_nps",
                    op: SankofaPulseBranchingCondOp.lt,
                    value: .int(7)),
                action: SankofaPulseBranchingActionKind.skipTo,
                toQuestionId: "psq_why"),
        ]
        let out = SankofaPulseBranching.resolveNext(
            rules: rules,
            currentQuestionId: "psq_nps",
            answers: ["psq_nps": .int(3)])
        XCTAssertEqual(out.nextQuestionId, "psq_why")
    }

    func testEndSurveyFiresOnMatch() {
        let rules = [
            SankofaPulseBranchingRule(
                fromQuestionId: "psq_consent",
                condition: SankofaPulseBranchingCondition(
                    kind: SankofaPulseBranchingCondKind.answer,
                    questionId: "psq_consent",
                    op: SankofaPulseBranchingCondOp.notAnswered),
                action: SankofaPulseBranchingActionKind.endSurvey),
        ]
        let out = SankofaPulseBranching.resolveNext(
            rules: rules,
            currentQuestionId: "psq_consent",
            answers: [:])
        XCTAssertEqual(out.nextQuestionId, SankofaPulseBranchingEndOfSurvey)
    }

    func testFirstMatchingRuleWins() {
        let rules = [
            SankofaPulseBranchingRule(
                fromQuestionId: "psq_q1",
                condition: SankofaPulseBranchingCondition(
                    kind: SankofaPulseBranchingCondKind.answer,
                    questionId: "psq_q1",
                    op: SankofaPulseBranchingCondOp.answered),
                action: SankofaPulseBranchingActionKind.skipTo,
                toQuestionId: "psq_a"),
            SankofaPulseBranchingRule(
                fromQuestionId: "psq_q1",
                condition: SankofaPulseBranchingCondition(
                    kind: SankofaPulseBranchingCondKind.answer,
                    questionId: "psq_q1",
                    op: SankofaPulseBranchingCondOp.equals,
                    value: .string("x")),
                action: SankofaPulseBranchingActionKind.skipTo,
                toQuestionId: "psq_b"),
        ]
        let out = SankofaPulseBranching.resolveNext(
            rules: rules,
            currentQuestionId: "psq_q1",
            answers: ["psq_q1": .string("x")])
        XCTAssertEqual(out.nextQuestionId, "psq_a")
    }

    func testRulesForOtherFromQuestionsAreIgnored() {
        let rules = [
            SankofaPulseBranchingRule(
                fromQuestionId: "psq_q2",
                condition: SankofaPulseBranchingCondition(
                    kind: SankofaPulseBranchingCondKind.answer,
                    questionId: "psq_q2",
                    op: SankofaPulseBranchingCondOp.answered),
                action: SankofaPulseBranchingActionKind.skipTo,
                toQuestionId: "psq_z"),
        ]
        let out = SankofaPulseBranching.resolveNext(
            rules: rules,
            currentQuestionId: "psq_q1",
            answers: ["psq_q2": .string("x")])
        XCTAssertEqual(out.nextQuestionId, "")
    }

    func testNumericComparators() {
        let cases: [(op: String, target: SankofaPulseAnyJSON, answer: SankofaPulseAnyJSON, want: Bool)] = [
            (SankofaPulseBranchingCondOp.lt,  .int(7), .int(3),         true),
            (SankofaPulseBranchingCondOp.lt,  .int(7), .int(7),         false),
            (SankofaPulseBranchingCondOp.lte, .int(7), .int(7),         true),
            (SankofaPulseBranchingCondOp.gt,  .int(7), .int(8),         true),
            (SankofaPulseBranchingCondOp.gte, .int(7), .int(7),         true),
            (SankofaPulseBranchingCondOp.gt,  .int(7), .string("10"),   true),
            (SankofaPulseBranchingCondOp.gt,  .int(7), .string("abc"),  false),
        ]
        for c in cases {
            let ok = SankofaPulseBranching.evaluateCondition(
                SankofaPulseBranchingCondition(
                    kind: SankofaPulseBranchingCondKind.answer,
                    questionId: "q",
                    op: c.op,
                    value: c.target),
                answers: ["q": c.answer])
            XCTAssertEqual(ok, c.want,
                "op=\(c.op) target=\(c.target) answer=\(c.answer)")
        }
    }

    func testContainsArraysAndStrings() {
        let arrCond = SankofaPulseBranchingCondition(
            kind: SankofaPulseBranchingCondKind.answer,
            questionId: "q",
            op: SankofaPulseBranchingCondOp.contains,
            value: .string("key_b"))
        XCTAssertTrue(SankofaPulseBranching.evaluateCondition(
            arrCond,
            answers: ["q": .array([.string("key_a"), .string("key_b"), .string("key_c")])]))
        XCTAssertFalse(SankofaPulseBranching.evaluateCondition(
            arrCond,
            answers: ["q": .array([.string("key_a"), .string("key_c")])]))

        let strCond = SankofaPulseBranchingCondition(
            kind: SankofaPulseBranchingCondKind.answer,
            questionId: "q",
            op: SankofaPulseBranchingCondOp.contains,
            value: .string("slow"))
        XCTAssertTrue(SankofaPulseBranching.evaluateCondition(
            strCond, answers: ["q": .string("the app feels slow")]))
        XCTAssertFalse(SankofaPulseBranching.evaluateCondition(
            strCond, answers: ["q": .string("the app feels fast")]))
    }

    func testInMatchesArrayValues() {
        let cond = SankofaPulseBranchingCondition(
            kind: SankofaPulseBranchingCondKind.answer,
            questionId: "q",
            op: SankofaPulseBranchingCondOp.inOp,
            value: .array([.string("pro"), .string("enterprise")]))
        XCTAssertTrue(SankofaPulseBranching.evaluateCondition(
            cond, answers: ["q": .string("pro")]))
        XCTAssertFalse(SankofaPulseBranching.evaluateCondition(
            cond, answers: ["q": .string("free")]))
    }

    func testAnsweredAndNotAnsweredHandleEmpty() {
        let answered = SankofaPulseBranchingCondition(
            kind: SankofaPulseBranchingCondKind.answer,
            questionId: "q",
            op: SankofaPulseBranchingCondOp.answered)
        let notAnswered = SankofaPulseBranchingCondition(
            kind: SankofaPulseBranchingCondKind.answer,
            questionId: "q",
            op: SankofaPulseBranchingCondOp.notAnswered)
        XCTAssertTrue(SankofaPulseBranching.evaluateCondition(
            answered, answers: ["q": .string("x")]))
        XCTAssertFalse(SankofaPulseBranching.evaluateCondition(
            notAnswered, answers: ["q": .string("x")]))

        XCTAssertFalse(SankofaPulseBranching.evaluateCondition(
            answered, answers: ["q": .string("")]))
        XCTAssertTrue(SankofaPulseBranching.evaluateCondition(
            notAnswered, answers: ["q": .string("")]))

        XCTAssertFalse(SankofaPulseBranching.evaluateCondition(
            answered, answers: ["q": .array([])]))

        XCTAssertFalse(SankofaPulseBranching.evaluateCondition(
            answered, answers: [:]))
        XCTAssertTrue(SankofaPulseBranching.evaluateCondition(
            notAnswered, answers: [:]))
    }

    func testValueNeedingOpsFailClosedWhenAnswerMissing() {
        let cond = SankofaPulseBranchingCondition(
            kind: SankofaPulseBranchingCondKind.answer,
            questionId: "q",
            op: SankofaPulseBranchingCondOp.equals,
            value: .string("x"))
        XCTAssertFalse(SankofaPulseBranching.evaluateCondition(
            cond, answers: [:]))
    }

    func testBooleanAnswersCoerceToNumeric() {
        let cond = SankofaPulseBranchingCondition(
            kind: SankofaPulseBranchingCondKind.answer,
            questionId: "q",
            op: SankofaPulseBranchingCondOp.gt,
            value: .int(0))
        XCTAssertTrue(SankofaPulseBranching.evaluateCondition(
            cond, answers: ["q": .bool(true)]))
        XCTAssertFalse(SankofaPulseBranching.evaluateCondition(
            cond, answers: ["q": .bool(false)]))
    }
}
