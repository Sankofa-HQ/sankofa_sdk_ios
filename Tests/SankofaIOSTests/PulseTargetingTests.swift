import XCTest
@testable import SankofaIOS

/// Targeting evaluator parity test suite. Mirrors
/// `sdks/sankofa_sdk_web/packages/pulse/src/__tests__/targeting.test.ts`
/// verbatim — failures here mean the iOS SDK will disagree with the
/// Web SDK and Go server about whether a respondent is eligible for
/// a given survey, which is exactly the divergence the shared DSL
/// is designed to prevent.
final class PulseTargetingTests: XCTestCase {

    private func ctx(
        surveyId: String = "psv_x",
        respondentExternalId: String = "user_42",
        pageUrl: String? = "https://x.com/checkout",
        userProperties: [String: SankofaPulseAnyJSON]? = [:],
        cohorts: [String: Bool]? = [:],
        flagValues: [String: SankofaPulseAnyJSON]? = [:],
        recentEvents: [String: Int]? = [:],
        priorResponseCount: [String: Int]? = [:]
    ) -> SankofaPulseEligibilityContext {
        SankofaPulseEligibilityContext(
            surveyId: surveyId,
            respondentExternalId: respondentExternalId,
            pageUrl: pageUrl,
            recentEvents: recentEvents,
            userProperties: userProperties,
            cohorts: cohorts,
            flagValues: flagValues,
            priorResponseCount: priorResponseCount
        )
    }

    func testEmptyRulesEligible() {
        let d = SankofaPulseTargeting.evaluate(rules: [], context: ctx())
        XCTAssertTrue(d.eligible)
    }

    func testAndOfRulesAllMustMatch() {
        let rules = [
            SankofaPulseTargetingRule(
                kind: SankofaPulseRuleKind.url,
                urlMatch: SankofaPulseMatchOp.contains,
                urlValue: "/checkout"),
            SankofaPulseTargetingRule(
                kind: SankofaPulseRuleKind.userProperty,
                propertyKey: "plan",
                propertyOp: SankofaPulseMatchOp.equals,
                propertyValue: .string("pro")),
        ]
        XCTAssertTrue(SankofaPulseTargeting.evaluate(
            rules: rules,
            context: ctx(userProperties: ["plan": .string("pro")])).eligible)
        XCTAssertFalse(SankofaPulseTargeting.evaluate(
            rules: rules,
            context: ctx(userProperties: ["plan": .string("free")])).eligible)
    }

    func testUrlMatchOperations() {
        let cases: [(match: String, value: String, url: String, want: Bool)] = [
            (SankofaPulseMatchOp.equals, "https://x.com/", "https://x.com/", true),
            (SankofaPulseMatchOp.equals, "https://x.com/", "https://x.com/checkout", false),
            (SankofaPulseMatchOp.contains, "/checkout", "https://x.com/app/checkout/v2", true),
            (SankofaPulseMatchOp.contains, "/checkout", "https://x.com/app/cart", false),
            (SankofaPulseMatchOp.prefix, "https://x.com/", "https://x.com/checkout", true),
            (SankofaPulseMatchOp.prefix, "https://x.com/", "https://other.com/x", false),
            (SankofaPulseMatchOp.regex, #"\.com/(\w+)/checkout"#, "https://x.com/app/checkout", true),
            (SankofaPulseMatchOp.regex, #"\.com/(\w+)/checkout"#, "https://x.com/checkout", false),
        ]
        for c in cases {
            let rule = SankofaPulseTargetingRule(
                kind: SankofaPulseRuleKind.url,
                urlMatch: c.match,
                urlValue: c.value)
            let d = SankofaPulseTargeting.evaluate(
                rules: [rule], context: ctx(pageUrl: c.url))
            XCTAssertEqual(d.eligible, c.want,
                "url \(c.match) \(c.value) \(c.url)")
        }
    }

    func testEventRespectsMinCount() {
        let cases: [(count: Int, want: Bool)] = [
            (0, false), (1, false), (2, false), (3, true), (10, true),
        ]
        for c in cases {
            let rule = SankofaPulseTargetingRule(
                kind: SankofaPulseRuleKind.event,
                eventName: "purchased",
                eventMinCount: 3)
            let d = SankofaPulseTargeting.evaluate(
                rules: [rule],
                context: ctx(recentEvents: ["purchased": c.count]))
            XCTAssertEqual(d.eligible, c.want, "count=\(c.count)")
        }
    }

    func testEventDefaultMinCountIs1() {
        let rule = SankofaPulseTargetingRule(
            kind: SankofaPulseRuleKind.event, eventName: "signup")
        XCTAssertTrue(SankofaPulseTargeting.evaluate(
            rules: [rule], context: ctx(recentEvents: ["signup": 1])).eligible)
        XCTAssertFalse(SankofaPulseTargeting.evaluate(
            rules: [rule], context: ctx(recentEvents: ["signup": 0])).eligible)
    }

    func testUserPropertyEqualsNumericIn() {
        func equalsRule(_ v: SankofaPulseAnyJSON) -> SankofaPulseTargetingRule {
            SankofaPulseTargetingRule(
                kind: SankofaPulseRuleKind.userProperty,
                propertyKey: "k",
                propertyOp: SankofaPulseMatchOp.equals,
                propertyValue: v)
        }
        XCTAssertTrue(SankofaPulseTargeting.evaluate(
            rules: [equalsRule(.string("pro"))],
            context: ctx(userProperties: ["k": .string("pro")])).eligible)
        XCTAssertFalse(SankofaPulseTargeting.evaluate(
            rules: [equalsRule(.string("pro"))],
            context: ctx(userProperties: ["k": .string("free")])).eligible)

        let numericCases: [(op: String, target: SankofaPulseAnyJSON, actual: SankofaPulseAnyJSON, want: Bool)] = [
            (SankofaPulseMatchOp.gt,  .int(5),  .int(10),  true),
            (SankofaPulseMatchOp.gt,  .int(5),  .int(5),   false),
            (SankofaPulseMatchOp.gte, .int(5),  .int(5),   true),
            (SankofaPulseMatchOp.lt,  .int(100),.int(99),  true),
            (SankofaPulseMatchOp.lte, .int(100),.int(100), true),
            (SankofaPulseMatchOp.gt,  .int(5),  .string("10"),  true),
            (SankofaPulseMatchOp.gt,  .int(5),  .string("abc"), false),
        ]
        for c in numericCases {
            let rule = SankofaPulseTargetingRule(
                kind: SankofaPulseRuleKind.userProperty,
                propertyKey: "k",
                propertyOp: c.op,
                propertyValue: c.target)
            let d = SankofaPulseTargeting.evaluate(
                rules: [rule], context: ctx(userProperties: ["k": c.actual]))
            XCTAssertEqual(d.eligible, c.want,
                "op=\(c.op) target=\(c.target) actual=\(c.actual)")
        }

        let inRule = SankofaPulseTargetingRule(
            kind: SankofaPulseRuleKind.userProperty,
            propertyKey: "plan",
            propertyOp: SankofaPulseMatchOp.inOp,
            propertyValue: .array([.string("pro"), .string("enterprise")]))
        let inCases: [(String, Bool)] = [
            ("pro", true), ("enterprise", true), ("free", false), ("trial", false),
        ]
        for (v, want) in inCases {
            XCTAssertEqual(
                SankofaPulseTargeting.evaluate(
                    rules: [inRule],
                    context: ctx(userProperties: ["plan": .string(v)])).eligible,
                want, "in: \(v)")
        }
    }

    func testUserPropertyExistsAndNotExists() {
        let exists = SankofaPulseTargetingRule(
            kind: SankofaPulseRuleKind.userProperty,
            propertyKey: "k", propertyOp: SankofaPulseMatchOp.exists)
        let notExists = SankofaPulseTargetingRule(
            kind: SankofaPulseRuleKind.userProperty,
            propertyKey: "k", propertyOp: SankofaPulseMatchOp.notExists)
        let present = ctx(userProperties: ["k": .string("v")])
        let absent = ctx(userProperties: ["other": .string("v")])
        XCTAssertTrue(SankofaPulseTargeting.evaluate(
            rules: [exists], context: present).eligible)
        XCTAssertFalse(SankofaPulseTargeting.evaluate(
            rules: [exists], context: absent).eligible)
        XCTAssertFalse(SankofaPulseTargeting.evaluate(
            rules: [notExists], context: present).eligible)
        XCTAssertTrue(SankofaPulseTargeting.evaluate(
            rules: [notExists], context: absent).eligible)
    }

    func testSamplingIsDeterministicForSameUser() {
        let rule = SankofaPulseTargetingRule(
            kind: SankofaPulseRuleKind.sampling, samplingRate: 0.5)
        let c = ctx()
        let first = SankofaPulseTargeting.evaluate(rules: [rule], context: c).eligible
        for i in 0..<100 {
            XCTAssertEqual(
                SankofaPulseTargeting.evaluate(rules: [rule], context: c).eligible,
                first, "sampling drifted on iteration \(i)")
        }
    }

    func testSamplingDistributesNearTargetRate() {
        let rule = SankofaPulseTargetingRule(
            kind: SankofaPulseRuleKind.sampling, samplingRate: 0.5)
        var admitted = 0
        let n = 5000
        for i in 0..<n {
            let c = ctx(respondentExternalId: "user_\(i)")
            if SankofaPulseTargeting.evaluate(rules: [rule], context: c).eligible {
                admitted += 1
            }
        }
        let rate = Double(admitted) / Double(n)
        XCTAssertTrue(rate >= 0.45 && rate <= 0.55,
            "rate=\(rate) drifted outside ±5%")
    }

    func testSamplingRate0NeverAdmits() {
        let rule = SankofaPulseTargetingRule(
            kind: SankofaPulseRuleKind.sampling, samplingRate: 0)
        for i in 0..<100 {
            XCTAssertFalse(SankofaPulseTargeting.evaluate(
                rules: [rule],
                context: ctx(respondentExternalId: "u\(i)")).eligible)
        }
    }

    func testSamplingRate1AlwaysAdmits() {
        let rule = SankofaPulseTargetingRule(
            kind: SankofaPulseRuleKind.sampling, samplingRate: 1)
        for i in 0..<100 {
            XCTAssertTrue(SankofaPulseTargeting.evaluate(
                rules: [rule],
                context: ctx(respondentExternalId: "u\(i)")).eligible)
        }
    }

    func testSamplingAnonymousFailsClosed() {
        let rule = SankofaPulseTargetingRule(
            kind: SankofaPulseRuleKind.sampling, samplingRate: 0.5)
        XCTAssertFalse(SankofaPulseTargeting.evaluate(
            rules: [rule], context: ctx(respondentExternalId: "")).eligible)
    }

    func testFrequencyCapEnforcesPriorCount() {
        let rule = SankofaPulseTargetingRule(
            kind: SankofaPulseRuleKind.frequencyCap,
            frequencyScope: "per_user",
            frequencyMax: 2,
            frequencyWindowDays: 30)
        let cases: [(count: Int, want: Bool)] = [
            (0, true), (1, true), (2, false),
        ]
        for c in cases {
            let d = SankofaPulseTargeting.evaluate(
                rules: [rule],
                context: ctx(priorResponseCount: ["psv_x": c.count]))
            XCTAssertEqual(d.eligible, c.want, "prior=\(c.count)")
        }
    }

    func testFeatureFlagMatchesWhenValueEqual() {
        let rule = SankofaPulseTargetingRule(
            kind: SankofaPulseRuleKind.featureFlag,
            flagKey: "show_survey",
            flagValue: .bool(true))
        XCTAssertTrue(SankofaPulseTargeting.evaluate(
            rules: [rule],
            context: ctx(flagValues: ["show_survey": .bool(true)])).eligible)
        XCTAssertFalse(SankofaPulseTargeting.evaluate(
            rules: [rule],
            context: ctx(flagValues: ["show_survey": .bool(false)])).eligible)
        XCTAssertFalse(SankofaPulseTargeting.evaluate(
            rules: [rule], context: ctx(flagValues: [:])).eligible)
    }

    func testStableHashInRange() {
        for i in 0..<100 {
            let score = SankofaPulseTargeting.stableHash("survey:\(i)")
            XCTAssertTrue(score >= 0 && score < 1, "score=\(score) out of range")
        }
    }

    func testStableHashIsDeterministic() {
        let a = SankofaPulseTargeting.stableHash("psv_x:user_42")
        let b = SankofaPulseTargeting.stableHash("psv_x:user_42")
        XCTAssertEqual(a, b, accuracy: 1e-12)
        let c = SankofaPulseTargeting.stableHash("psv_x:user_43")
        XCTAssertNotEqual(a, c, accuracy: 1e-12)
    }
}
