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
    
    /// The current screen name for stateful tagging (Heatmaps).
    private var currentScreen: String = "Unknown"

    private var logger = SankofaLogger(debug: false)
    private var identity = SankofaIdentity()
    private var sessionManager = SankofaSessionManager()
    private var deviceInfo = SankofaDeviceInfo()
    private var queueManager: SankofaQueueManager?
    private var flushManager: SankofaFlushManager?
    @MainActor private var lifecycleObserver: SankofaLifecycleObserver?
    @MainActor private var captureCoordinator: SankofaCaptureCoordinator?

    // MARK: - Public API

    /// Initialise the SDK. Call this once at app start.
    @objc
    @MainActor
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
        
        fm.onCommandsReceived = { [weak self] commands in
            self?._handleServerCommands(commands)
        }

        let coordinator = SankofaCaptureCoordinator(
            maskAllInputs: config.maskAllInputs,
            captureScale: config.captureScale,
            uploader: SankofaReplayUploader(
                queueManager: qm,
                logger: logger
            )
        )
        coordinator.uploader.setDistinctId(identity.distinctId)
        self.captureCoordinator = coordinator

        let observer = SankofaLifecycleObserver(
            sessionManager: sessionManager,
            flushManager: fm,
            captureCoordinator: coordinator,
            trackLifecycle: config.trackLifecycleEvents,
            onLifecycleEvent: { [weak self] event in
                self?.track(event)
            }
        )
        self.lifecycleObserver = observer

        logger.log("✅ [v2] Sankofa initialized (endpoint: \(config.endpoint))")

        // First Time Open Logic
        let firstOpenKey = "dev.sankofa.first_open_detected"
        if !UserDefaults.standard.bool(forKey: firstOpenKey) {
            UserDefaults.standard.set(true, forKey: firstOpenKey)
            track("$app_open_first_time")
        }

        if config.endpoint.contains("localhost") || config.endpoint.contains("127.0.0.1") {
            #if !targetEnvironment(simulator)
            logger.warn("⚠️ Using 'localhost' on a physical device will fail. Use your machine's local IP (e.g., http://192.168.1.10:8080) instead.")
            #endif
        }

        observer.start()
        fm.start()

        if config.recordSessions {
            coordinator.start(sessionId: sessionManager.sessionId, screenNameProvider: { [weak self] in
                guard let self = self else { return "Unknown" }
                // 🚀 Manual > Auto Hierarchy
                if self.currentScreen != "Unknown" {
                    return self.currentScreen
                }
                return SankofaScreenTracker.findCurrentScreenName() ?? "Unknown"
            })
        }
        
        // Initial session start event
        track("$session_start")

        // ── Unified Handshake (async, non-blocking) ──
        // One call to /api/v1/handshake returns the server-driven
        // config for ALL Sankofa products. If the server says replay
        // is disabled, we stop the capture coordinator. If analytics
        // is disabled, the server silently drops payloads with 202.
        // Falls back gracefully if the endpoint doesn't exist yet.
        Task.detached { [weak self] in
            self?._fetchHandshake(apiKey: apiKey, endpoint: config.endpoint)
        }
    }

    /// Explicitly tag the screen the user is currently viewing.
    /// Used for heatmaps and behavioral context.
    @objc
    public func screen(_ name: String, properties: [String: Any] = [:]) {
        self.currentScreen = name
        var screenProps = properties
        screenProps["$screen_name"] = name
        track("$screen_view", properties: screenProps)
    }

    /// Identify a user by their unique ID. Merges anonymous history into the profile.
    @objc
    @MainActor
    public func identify(userId: String) {
        assertInitialized()
        identity.identify(userId: userId)
        logger.log("👤 [v2] Identified user: \(userId)")
        
        // Update uploader with new identity
        captureCoordinator?.uploader.setDistinctId(userId)

        let payload: [String: Any] = [
            "type": "alias",
            "distinct_id": userId,
            "alias_id": identity.anonymousId,
            "properties": [
                "$session_id": sessionManager.sessionId,
                "$screen_name": currentScreen
            ],
            "default_properties": defaultProperties(),
            "timestamp": Sankofa.iso8601Formatter.string(from: Date()),
            "message_id": UUID().uuidString.lowercased(),
            "lib_version": Sankofa.libVersion
        ]
        queueManager?.enqueue(payload)
    }

    /// Track a custom event with optional properties.
    @objc
    public func track(_ event: String, properties: [String: Any] = [:]) {
        assertInitialized()
        
        var eventProps = properties
        eventProps["$event_name"] = event
        eventProps["$session_id"] = sessionManager.sessionId
        eventProps["$screen_name"] = currentScreen
        
        let payload: [String: Any] = [
            "type": "track",
            "event_name": event,
            "distinct_id": identity.distinctId,
            "properties": eventProps,
            "default_properties": defaultProperties(),
            "timestamp": Sankofa.iso8601Formatter.string(from: Date()),
            "message_id": UUID().uuidString.lowercased(),
            "lib_version": Sankofa.libVersion
        ]

        logger.log("📈 [v2] track → \(event)")
        queueManager?.enqueue(payload)
    }

    /// Set profile attributes for the current user.
    @objc
    public func setPerson(name: String? = nil, email: String? = nil, avatar: String? = nil, properties: [String: Any] = [:]) {
        assertInitialized()

        var personProps = properties
        if let name { personProps["$name"] = name }
        if let email { personProps["$email"] = email }
        if let avatar { personProps["$avatar"] = avatar }
        personProps["$session_id"] = sessionManager.sessionId

        let payload: [String: Any] = [
            "type": "people",
            "distinct_id": identity.distinctId,
            "properties": personProps,
            "default_properties": defaultProperties(),
            "timestamp": Sankofa.iso8601Formatter.string(from: Date()),
            "message_id": UUID().uuidString.lowercased(),
            "lib_version": Sankofa.libVersion
        ]

        logger.log("👤 [v2] setPerson")
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
            "$lib": "sankofa-ios",
            "$lib_version": "1.0.0",
        ]
        deviceInfo.inject(into: &props)
        return props
    }

    private func assertInitialized(file: StaticString = #file, line: UInt = #line) {
        guard isInitialized else {
            #if DEBUG
            preconditionFailure(
                "Sankofa.initialize() must be called before using the SDK.",
                file: file, line: line
            )
            #else
            logger.warn("⚠️ Sankofa: initialize() must be called before using the SDK. Call is being dropped.")
            #endif
            return
        }
    }

    private static let libVersion = "ios-1.0.0"

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    
    private func _handleServerCommands(_ commands: [[String: Any]]) {
        for cmd in commands {
            guard let type = cmd["type"] as? String,
                  let params = cmd["params"] as? [String: Any] else { continue }

            if type == "CAPTURE_PRISTINE", let _ = params["screen"] as? String {
                logger.log("🔥 📸 Server requested pristine capture")
                Task { @MainActor in
                    self.captureCoordinator?.triggerHighFidelityMode(duration: 1.0)
                }
            }
        }
    }

    // MARK: - Unified Handshake

    private func _fetchHandshake(apiKey: String, endpoint: String) {
        let urlString = "\(endpoint)/api/v1/handshake"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                self.logger.warn("⚠️ Handshake failed: \(error.localizedDescription)")
                return
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let modules = json["modules"] as? [String: Any] else {
                self.logger.log("🤝 Handshake unavailable — continuing with local config")
                return
            }

            self.logger.log("🤝 Handshake OK (project: \(json["project_id"] ?? "?"))")

            // Replay: stop capture if server says disabled
            if let replay = modules["replay"] as? [String: Any],
               let enabled = replay["enabled"] as? Bool, !enabled {
                self.logger.log("⏸ Replay disabled by server")
                Task { @MainActor in
                    self.captureCoordinator?.stop()
                }
            }

            // Deploy: log availability for observability
            if let deploy = modules["deploy"] as? [String: Any],
               let hasUpdate = deploy["has_update"] as? Bool, hasUpdate {
                self.logger.log("📦 Deploy update available: \(deploy["label"] ?? "?")")
            }
        }.resume()
    }
}
