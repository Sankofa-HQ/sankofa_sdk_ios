import Foundation
import UIKit

/// The Sankofa iOS SDK public entry point.
///
/// ## Quick Start
/// ```swift
/// // In your AppDelegate or @main struct:
/// Sankofa.shared.initialize(
///     apiKey: "YOUR_PROJECT_API_KEY",
///     config: SankofaConfig(recordSessions: true)
/// )
///
/// // Track an event:
/// Sankofa.shared.track("button_tapped", properties: ["screen": "home"])
///
/// // Identify a logged-in user:
/// Sankofa.shared.identify(userId: "user_99")
/// ```
public final class Sankofa {

    // MARK: - Singleton

    public static let shared = Sankofa()
    private init() {}

    // MARK: - Internal State

    private var config: SankofaConfig = SankofaConfig()
    private var apiKey: String = ""
    private var isInitialized = false

    private lazy var logger = SankofaLogger(debug: config.debug)
    private lazy var identity = SankofaIdentity()
    private lazy var sessionManager = SankofaSessionManager()
    private lazy var deviceInfo = SankofaDeviceInfo()
    private lazy var queueManager: SankofaQueueManager = {
        SankofaQueueManager(logger: logger)
    }()
    private lazy var flushManager: SankofaFlushManager = {
        SankofaFlushManager(
            apiKey: apiKey,
            endpoint: config.endpoint,
            queueManager: queueManager,
            batchSize: config.batchSize,
            flushInterval: config.flushIntervalSeconds,
            logger: logger
        )
    }()
    private lazy var lifecycleObserver = SankofaLifecycleObserver(
        flushManager: flushManager,
        trackLifecycle: config.trackLifecycleEvents,
        onLifecycleEvent: { [weak self] event in
            self?.track(event)
        }
    )
    private lazy var captureCoordinator: SankofaCaptureCoordinator = {
        SankofaCaptureCoordinator(
            mode: config.captureMode,
            maskAllInputs: config.maskAllInputs,
            uploader: SankofaReplayUploader(
                apiKey: apiKey,
                endpoint: config.endpoint,
                logger: logger
            )
        )
    }()

    // MARK: - Public API

    /// Initialise the SDK. Call this once at app start.
    public func initialize(apiKey: String, config: SankofaConfig = SankofaConfig()) {
        guard !isInitialized else {
            logger.warn("Sankofa already initialized; ignoring duplicate call.")
            return
        }
        self.apiKey = apiKey
        self.config = config
        self.isInitialized = true

        logger.log("✅ Sankofa initialized (endpoint: \(config.endpoint))")

        lifecycleObserver.start()

        if config.recordSessions {
            captureCoordinator.start()
        }
    }

    /// Identify a user by their unique ID. Merges anonymous history into the profile.
    public func identify(userId: String) {
        assertInitialized()
        identity.identify(userId: userId)
        logger.log("👤 Identified user: \(userId)")

        let payload: [String: Any] = [
            "type": "alias",
            "distinct_id": userId,
            "alias_id": identity.anonymousId,
            "session_id": sessionManager.sessionId,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        queueManager.enqueue(payload)
    }

    /// Track a custom event with optional properties.
    public func track(_ event: String, properties: [String: Any] = [:]) {
        assertInitialized()
        
        let payload: [String: Any] = [
            "type": "track",
            "event_name": event,
            "distinct_id": identity.distinctId,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "properties": properties,
            "default_properties": defaultProperties()
        ]

        logger.log("📈 track → \(event)")
        queueManager.enqueue(payload)

        // Let the coordinator check escalation triggers.
        captureCoordinator.onEvent(event)
    }

    /// Set profile attributes for the current user.
    public func setPerson(name: String? = nil, email: String? = nil, properties: [String: Any] = [:]) {
        assertInitialized()
        
        var personProps = properties
        if let name { personProps["$name"] = name }
        if let email { personProps["$email"] = email }
        
        let payload: [String: Any] = [
            "type": "people",
            "distinct_id": identity.distinctId,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "properties": personProps,
            "default_properties": defaultProperties()
        ]

        logger.log("👤 setPerson")
        queueManager.enqueue(payload)
    }

    /// Reset identity. Call on logout to start a fresh anonymous session.
    public func reset() {
        assertInitialized()
        identity.reset()
        sessionManager.rotateSession()
        logger.log("🔄 Identity reset; new session: \(sessionManager.sessionId)")
    }

    /// Immediately flush all queued events to the backend.
    public func flush() {
        flushManager.flush()
    }

    // MARK: - Helpers

    private func defaultProperties() -> [String: Any] {
        var props: [String: Any] = [
            "session_id": sessionManager.sessionId,
            "$lib": "sankofa-ios",
            "$lib_version": "1.0.0",
        ]
        deviceInfo.inject(into: &props)
        return props
    }

    private func assertInitialized(file: StaticString = #file, line: UInt = #line) {
        if !isInitialized {
            logger.warn("⚠️ Sankofa.initialize() not called before \(file):\(line)")
        }
    }
}
