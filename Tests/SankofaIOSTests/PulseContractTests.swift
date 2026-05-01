import XCTest
@testable import SankofaIOS

/// Cross-SDK contract test. Reads the canonical golden submit body
/// from `sdks/_contract_tests/goldens/pulse_submit_basic.json` and
/// asserts that the iOS SDK serialises the same fixture inputs into
/// a structurally identical JSON payload.
///
/// If this test fails, the iOS wire shape has drifted away from the
/// server contract that Web + RN already speak. Fix the SDK, not
/// the golden — the golden mirrors what the server's `ingestPayload`
/// struct accepts in `server/engine/ee/pulse/handlers_ingest.go`.
final class PulseContractTests: XCTestCase {

    func testPulseSubmitBasicMatchesGolden() throws {
        let golden = try readGolden("pulse_submit_basic.json")

        let payload = SankofaPulseSubmitPayload(
            surveyId: "psv_test_001",
            respondent: SankofaPulseRespondent(
                userId: "usr_42",
                externalId: "ext_42",
                email: "alice@example.com"
            ),
            context: SankofaPulseContext(
                sessionId: "sess_abc",
                anonymousId: "anon_xyz",
                platform: "contract-test",
                osVersion: "test-os",
                appVersion: "1.0.0",
                locale: "en-US"
            ),
            submittedAt: nil,
            answers: [
                "q1": .string("hello"),
                "q2": .int(9),
                "q3": .array([.string("red"), .string("green")]),
            ]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)
        let produced = try JSONSerialization.jsonObject(with: data)

        try assertStructurallyEqual(golden, produced, path: "$")
    }

    // MARK: - Helpers

    private func readGolden(_ name: String) throws -> Any {
        guard let url = resolveGolden(name) else {
            XCTFail("golden file \(name) not found")
            throw NSError(domain: "PulseContractTests", code: 1)
        }
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Walks up from this file's source dir to find
    /// `sdks/_contract_tests/goldens/<name>`. Falls back to
    /// `SANKOFA_CONTRACT_GOLDENS` for CI runs that exec outside the
    /// workspace.
    private func resolveGolden(_ name: String) -> URL? {
        if let override = ProcessInfo.processInfo
            .environment["SANKOFA_CONTRACT_GOLDENS"], !override.isEmpty {
            let url = URL(fileURLWithPath: override).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir
                .appendingPathComponent("sdks")
                .appendingPathComponent("_contract_tests")
                .appendingPathComponent("goldens")
                .appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    /// Structural equality: same keys, same values, same nesting.
    /// Numbers compare via `.doubleValue` so `9` and `9.0` aren't a
    /// false positive across language serialisers.
    private func assertStructurallyEqual(_ expected: Any, _ actual: Any, path: String) throws {
        if let expectedDict = expected as? [String: Any] {
            guard let actualDict = actual as? [String: Any] else {
                XCTFail("\(path): expected dict, got \(type(of: actual))")
                return
            }
            XCTAssertEqual(
                Set(expectedDict.keys), Set(actualDict.keys),
                "\(path): key set mismatch"
            )
            for (k, v) in expectedDict {
                guard let actualV = actualDict[k] else {
                    XCTFail("\(path).\(k): missing")
                    continue
                }
                try assertStructurallyEqual(v, actualV, path: "\(path).\(k)")
            }
            return
        }
        if let expectedArr = expected as? [Any] {
            guard let actualArr = actual as? [Any] else {
                XCTFail("\(path): expected array, got \(type(of: actual))")
                return
            }
            XCTAssertEqual(expectedArr.count, actualArr.count, "\(path): list length")
            for i in 0..<expectedArr.count {
                try assertStructurallyEqual(
                    expectedArr[i], actualArr[i], path: "\(path)[\(i)]")
            }
            return
        }
        if let expectedNum = expected as? NSNumber, let actualNum = actual as? NSNumber {
            // Use doubleValue compare so 9 vs 9.0 isn't a false positive.
            XCTAssertEqual(
                expectedNum.doubleValue, actualNum.doubleValue, accuracy: 1e-9,
                "\(path)"
            )
            return
        }
        if let expectedStr = expected as? String, let actualStr = actual as? String {
            XCTAssertEqual(expectedStr, actualStr, "\(path)")
            return
        }
        if expected is NSNull && actual is NSNull { return }
        XCTFail("\(path): \(expected) != \(actual) (\(type(of: expected)) vs \(type(of: actual)))")
    }
}
