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
@objc(SankofaSankofa)
public final class Sankofa: NSObject {

    // MARK: - Singleton

    @objc
    public static let shared = Sankofa()
    
    private override init() {
        super.init()
    }

    // MARK: - Internal State

    private var config: SankofaConfig = SankofaConfig()
    private var apiKey: String = ""
    private var isInitialized = false

    private var logger = SankofaLogger(debug: false)
    private var identity = SankofaIdentity()
    private var sessionManager = SankofaSessionManager()
    private var deviceInfo = SankofaDeviceInfo()
    private var queueManager: SankofaQueueManager?
    private var flushManager: SankofaFlushManager?
    private var lifecycleObserver: SankofaLifecycleObserver?
    private var captureCoordinator: SankofaCaptureCoordinator?

    // MARK: - Public API

    /// Initialise the SDK. Call this once at app start.
    @objc
    public func initialize(apiKey: String, config: SankofaConfig = SankofaConfig()) {
        guard !isInitialized else {
            logger.warn("Sankofa already initialized; ignoring duplicate call.")
            return
        }
        self.apiKey = apiKey
        self.config = config
        self.isInitialized = true

        self.logger = SankofaLogger(debug: config.debug)
        let qm = SankofaQueueManager(logger: logger)
        self.queueManager = qm

        let fm = SankofaFlushManager(
            apiKey: apiKey,
            endpoint: config.endpoint,
            queueManager: qm,
            batchSize: config.batchSize,
            flushInterval: config.flushIntervalSeconds,
            logger: logger
        )
        self.flushManager = fm

        let observer = SankofaLifecycleObserver(
            flushManager: fm,
            trackLifecycle: config.trackLifecycleEvents,
            onLifecycleEvent: { [weak self] event in
                self?.track(event)
            }
        )
        self.lifecycleObserver = observer

        let coordinator = SankofaCaptureCoordinator(
            mode: config.captureMode,
            maskAllInputs: config.maskAllInputs,
            uploader: SankofaReplayUploader(
                apiKey: apiKey,
                endpoint: config.endpoint,
                logger: logger
            )
        )
        coordinator.uploader.setDistinctId(identity.distinctId)
        self.captureCoordinator = coordinator

        logger.log("✅ Sankofa initialized (endpoint: \(config.endpoint))")

        observer.start()

        if config.recordSessions {
            coordinator.start()
        }
    }

    /// Identify a user by their unique ID. Merges anonymous history into the profile.
    @objc
    public func identify(userId: String) {
        assertInitialized()
        identity.identify(userId: userId)
        logger.log("👤 Identified user: \(userId)")
        
        // Update uploader with new identity
        captureCoordinator?.uploader.setDistinctId(userId)

        let payload: [String: Any] = [
            "type": "alias",
            "distinct_id": userId,
            "alias_id": identity.anonymousId,
            "session_id": sessionManager.sessionId,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        queueManager?.enqueue(payload)
    }

    /// Track a custom event with optional properties.
    @objc
    public func track(_ event: String, properties: [String: Any] = [:]) {
        assertInitialized()
        
        var eventProps = properties
        eventProps["$event_name"] = event // Promote to property for dashboard display
        
        let payload: [String: Any] = [
            "type": "track",
            "event_name": event,
            "distinct_id": identity.distinctId,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "properties": eventProps,
            "default_properties": defaultProperties()
        ]

        logger.log("📈 track → \(event)")
        queueManager?.enqueue(payload)

        // Let the coordinator check escalation triggers.
        captureCoordinator?.onEvent(event)
    }

    /// Set profile attributes for the current user.
    @objc
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
        queueManager?.enqueue(payload)
    }

    /// Reset identity. Call on logout to start a fresh anonymous session.
    @objc
    public func reset() {
        assertInitialized()
        identity.reset()
        sessionManager.rotateSession()
        logger.log("🔄 Identity reset; new session: \(sessionManager.sessionId)")
    }

    /// Immediately flush all queued events to the backend.
    @objc
    public func flush() {
        flushManager?.flush()
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
