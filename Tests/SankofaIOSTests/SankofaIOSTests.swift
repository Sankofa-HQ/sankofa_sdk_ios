import XCTest
@testable import SankofaIOS

final class SankofaIdentityTests: XCTestCase {

    func testAnonymousIdIsStable() {
        let identity = SankofaIdentity()
        let id1 = identity.anonymousId
        let id2 = identity.anonymousId
        XCTAssertEqual(id1, id2, "Anonymous ID must be stable across reads")
        XCTAssertTrue(id1.hasPrefix("anon_"), "Anonymous ID should have 'anon_' prefix")
    }

    func testIdentifyOverridesDistinctId() {
        let identity = SankofaIdentity()
        identity.identify(userId: "user_42")
        XCTAssertEqual(identity.distinctId, "user_42")
    }

    func testResetClearsIdentity() {
        let identity = SankofaIdentity()
        identity.identify(userId: "user_42")
        XCTAssertEqual(identity.distinctId, "user_42")
        identity.reset()
        XCTAssertNotEqual(identity.distinctId, "user_42", "After reset, distinct_id should revert to anonymous")
        XCTAssertTrue(identity.distinctId.hasPrefix("anon_"))
    }
}

final class SankofaSessionManagerTests: XCTestCase {

    func testSessionIdHasPrefix() {
        let manager = SankofaSessionManager()
        XCTAssertTrue(manager.sessionId.hasPrefix("session_"))
    }

    func testRotateGeneratesNewId() {
        let manager = SankofaSessionManager()
        let id1 = manager.sessionId
        manager.rotateSession()
        let id2 = manager.sessionId
        XCTAssertNotEqual(id1, id2, "rotateSession() must produce a new session ID")
    }
}

final class SankofaConfigTests: XCTestCase {

    func testDefaultValues() {
        let config = SankofaConfig()
        XCTAssertEqual(config.endpoint, "https://api.sankofa.dev")
        XCTAssertFalse(config.debug)
        XCTAssertTrue(config.trackLifecycleEvents)
        XCTAssertEqual(config.flushIntervalSeconds, 30)
        XCTAssertEqual(config.batchSize, 50)
        XCTAssertTrue(config.recordSessions)
        XCTAssertTrue(config.maskAllInputs)
        XCTAssertEqual(config.captureMode, .wireframe)
    }

    func testCustomValues() {
        let config = SankofaConfig(
            endpoint: "https://local:8080",
            debug: true,
            batchSize: 100,
            captureMode: .screenshot
        )
        XCTAssertEqual(config.endpoint, "https://local:8080")
        XCTAssertTrue(config.debug)
        XCTAssertEqual(config.batchSize, 100)
        XCTAssertEqual(config.captureMode, .screenshot)
    }
}
