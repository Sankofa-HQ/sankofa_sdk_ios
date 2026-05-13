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

    /// The API key passed to initialize(). Empty string until init has run.
    /// Exposed so sibling modules (Catch, Switch, Config) can authenticate
    /// their own API calls without the host plumbing credentials twice.
    public var apiKeyString: String? { apiKey.isEmpty ? nil : apiKey }

    /// The server endpoint passed to initialize(). Nil until init has run.
    public var endpointString: String? { config.endpoint.isEmpty ? nil : config.endpoint }
    
    /// The current screen name for stateful tagging (Heatmaps).
    private var currentScreen: String = "Unknown"

    // ── SwiftUI / custom-scrollable scroll-offset providers ──────────────
    //
    // UIKit `UIScrollView` (and subclasses: UITableView / UICollectionView)
    // are walked from the key window's view tree by `SankofaTouchInterceptor`.
    // SwiftUI hosts most modern apps and ScrollView is bridged to a UIScrollView
    // on iOS 16+ — but custom scroll containers, `LazyVGrid` inside opaque
    // hosting views, or older iOS versions can return zero offset, which
    // collapses every below-the-fold tap to the first viewport in the
    // heatmap panorama.
    //
    // The host registers a callback returning the active scroll offset in
    // points (typically `{ scrollOffset.y }` from a SwiftUI `GeometryReader`
    // / `ScrollViewReader` / `.onScrollGeometryChange` value).  Multiple
    // registrations are supported — providers iterate in registration
    // order and the first non-zero result wins.  This matches the
    // "first scrollable wins" semantics of the classic-View walker on
    // both iOS and Android.
    //
    // All access is serialised under `scrollProvidersLock` so registration
    // and lookup are safe from any thread (typical use registers from the
    // main thread but the touch interceptor reads from CFRunLoop callbacks
    // and the upload coroutine).
    private var scrollOffsetProviders: [(id: UUID, provider: () -> CGFloat)] = []
    private let scrollProvidersLock = NSLock()

    private var logger = SankofaLogger(debug: false)
    private var identity = SankofaIdentity()
    private var sessionManager = SankofaSessionManager()

    // MARK: - Public identity accessors
    //
    // Exposed for plugin modules (Catch, custom instrumentation) that
    // need to stamp the same session_id / anonymous_id / distinct_id
    // on their own events so cross-product joins work in the dashboard
    // ("this error happened in the same session as this replay").
    //
    // Read-only — the SDK is the single writer; mutation goes through
    // identify() / sessionManager.rotateSession().

    /// The active session identifier. Rotates on app cold start or
    /// after a period of background-inactivity; check
    /// `SankofaSessionManager` for the exact policy.
    public var currentSessionId: String { sessionManager.sessionId }

    /// The active screen / route as the SDK currently knows it.
    /// Resolution: explicit `screen(name)` > auto-detected top view
    /// controller > nil. Cross-product correlation key shared with
    /// Heatmap, Replay, Pulse, Plan, and Catch — Catch reads this on
    /// every error capture so the dashboard can filter and link by
    /// screen without depending on breadcrumbs.
    public var currentScreenName: String? {
        if currentScreen != "Unknown" && !currentScreen.isEmpty {
            return currentScreen
        }
        let auto = SankofaScreenTracker.findCurrentScreenName()
        return (auto?.isEmpty ?? true) ? nil : auto
    }

    /// The device-scoped anonymous identifier. Stable across app
    /// launches until the user uninstalls.
    public var anonymousId: String { identity.anonymousId }

    /// The identified user ID from `identify(distinctId:)`, or the
    /// anonymous ID when no identify call has happened yet.
    public var distinctId: String { identity.distinctId }

    /// Session id of the active replay recording, or nil when
    /// replay is disabled / sampled out / not yet started.
    ///
    /// Sibling modules (Pulse) stamp this on submitted responses
    /// so the dashboard can deep-link from one row to the recorded
    /// session that produced it. Returns nil instead of an empty
    /// string — "no replay" is meaningfully different from "replay
    /// session unknown" and downstream code should be able to tell.
    @MainActor
    public var replaySessionId: String? {
        guard let coordinator = captureCoordinator else { return nil }
        let sid = coordinator.activeSessionId
        return sid.isEmpty ? nil : sid
    }
    private var deviceInfo = SankofaDeviceInfo()
    private var queueManager: SankofaQueueManager?
    private var flushManager: SankofaFlushManager?
    @MainActor private var lifecycleObserver: SankofaLifecycleObserver?
    @MainActor private var captureCoordinator: SankofaCaptureCoordinator?
    private var presenceHeartbeat: SankofaPresenceHeartbeat?

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

        // Traffic Cop: flip core-ready so modules registered AFTER this
        // point don't emit the "registered before initialize()" warning.
        SankofaModuleRegistry.shared.markCoreInitialized()

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

        // ── Catch (Crashlytics + Sentry merged) ──────────────────────
        // Auto-install the NSException + POSIX-signal handlers so host
        // code doesn't need a separate `SankofaCatch.shared.start(...)`
        // call. Skipped when the host opts out via `enableCatch = false`
        // or has already wired Catch by hand (test harnesses, hot reload).
        if config.enableCatch && !SankofaCatch.shared.isStarted {
            _ = SankofaCatch.shared.start(
                environment: config.catchEnvironment,
                release: config.release,
                appVersion: config.appVersion,
                beforeSend: config.beforeSend,
                stallThresholdSeconds: config.catchStallThresholdSeconds
            )
        }

        observer.start()
        fm.start()

        // Live-presence heartbeat — independent of analytics flush so
        // it ticks at its own cadence (15s) while the app is
        // foregrounded. Cheap one-tiny-POST-per-tick; paused on
        // background.
        if let pulse = SankofaPresenceHeartbeat(
            endpoint: config.endpoint,
            apiKey: apiKey,
            payloadProvider: { [weak self] in
                guard let self = self else { return (nil, nil, nil) }
                return (
                    screen: self.currentScreenName,
                    distinctId: self.distinctId,
                    sessionId: self.currentSessionId
                )
            }
        ) {
            self.presenceHeartbeat = pulse
            pulse.start()
        }

        if config.recordSessions {
            coordinator.start(sessionId: sessionManager.sessionId, screenNameProvider: { [weak self] in
                guard let self = self else { return "" }
                // 🚀 Manual > Auto hierarchy.
                //
                // Empty string is the "untagged" sentinel — it tells the
                // capture coordinator to skip both the frame and any
                // pending interactions for this tick.  Better to lose a
                // few cold-start frames than to flood the dashboard with
                // "Unknown" screen rows that no real navigation will
                // ever match.  Mirrors Android's `hasTaggedScreen()` guard.
                if self.currentScreen != "Unknown" {
                    return self.currentScreen
                }
                return SankofaScreenTracker.findCurrentScreenName() ?? ""
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

    /// Register a callback that returns the current scroll offset (in
    /// points) of a SwiftUI or custom scroll container.  Use this from a
    /// SwiftUI view whose state you want included in heatmap accuracy:
    ///
    /// ```swift
    /// struct ProductList: View {
    ///     @State private var scrollOffset: CGFloat = 0
    ///     @State private var sankofaHandle: SankofaScrollContainerHandle?
    ///
    ///     var body: some View {
    ///         ScrollView {
    ///             LazyVStack { … }
    ///                 .background(GeometryReader { geo in
    ///                     Color.clear.preference(
    ///                         key: ScrollOffsetKey.self,
    ///                         value: -geo.frame(in: .named("scroll")).minY
    ///                     )
    ///                 })
    ///         }
    ///         .coordinateSpace(name: "scroll")
    ///         .onPreferenceChange(ScrollOffsetKey.self) { scrollOffset = $0 }
    ///         .onAppear {
    ///             sankofaHandle = Sankofa.shared.tagScrollContainer { scrollOffset }
    ///         }
    ///         .onDisappear {
    ///             sankofaHandle?.remove()
    ///             sankofaHandle = nil
    ///         }
    ///     }
    /// }
    /// ```
    ///
    /// `UIKit` apps using `UIScrollView` / `UITableView` / `UICollectionView`
    /// don't need to call this — the touch interceptor already walks the
    /// view tree for those.  The SwiftUI ScrollView bridge on iOS 16+
    /// also resolves through that walk in most cases — explicit
    /// registration is the escape hatch for hosts where the walk
    /// returns zero (custom scroll containers, opaque hosting views,
    /// pre-iOS 16 SwiftUI).
    ///
    /// Returns a `SankofaScrollContainerHandle`; call `.remove()` when
    /// the scroll container leaves scope.  Idempotent.
    @objc
    @discardableResult
    public func tagScrollContainer(provider: @escaping () -> CGFloat) -> SankofaScrollContainerHandle {
        let id = UUID()
        scrollProvidersLock.lock()
        scrollOffsetProviders.append((id: id, provider: provider))
        scrollProvidersLock.unlock()
        return SankofaScrollContainerHandle { [weak self] in
            guard let self = self else { return }
            self.scrollProvidersLock.lock()
            self.scrollOffsetProviders.removeAll { $0.id == id }
            self.scrollProvidersLock.unlock()
        }
    }

    /// Internal helper consulted by the touch interceptor and the capture
    /// coordinator to resolve the active scroll offset before falling
    /// back to the UIKit `findActiveScrollView` walk.  Defensive
    /// try/catch isn't possible in Swift but a host callback that
    /// crashes will surface clearly during development.
    internal func resolveScrollContainerOffset() -> CGFloat {
        scrollProvidersLock.lock()
        let snapshot = scrollOffsetProviders
        scrollProvidersLock.unlock()
        for entry in snapshot {
            let value = entry.provider()
            if value > 0 { return value }
        }
        return 0
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

    /// Cached modules map + ETag from the last successful handshake.
    /// The ETag is sent as `If-None-Match` on the next refresh so the
    /// server can respond with 304 when nothing has changed; the
    /// cached modules are replayed into the Traffic Cop on that 304
    /// path so modules that constructed between handshakes still pick
    /// up the payload they missed.
    private var cachedHandshakeModules: [String: Any]?
    private var handshakeEtag: String = ""

    private func _fetchHandshake(apiKey: String, endpoint: String) {
        let installed = SankofaModuleRegistry.shared.getInstalledModules().joined(separator: ",")
        let encoded = installed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? installed
        let normalized = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint

        // Device context — the server's evaluator needs these to
        // bucket rollouts deterministically, resolve cohort membership,
        // and honor user allow-lists. Without distinct_id every
        // handshake looks like a new anonymous user so cohort targeting
        // can't match and experiments are non-deterministic.
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "installed", value: installed),
            URLQueryItem(name: "sdk", value: "ios"),
            URLQueryItem(name: "platform", value: "ios")
        ]
        let did = identity.distinctId
        if !did.isEmpty {
            queryItems.append(URLQueryItem(name: "distinct_id", value: did))
        }
        // Identity stitching — only emit anon_id when identify() has
        // actually fired (distinctId diverged from anonymousId).
        // Pre-identify the two ids are equal, so sending both would be
        // redundant noise on the wire.
        let anon = identity.anonymousId
        if !anon.isEmpty && anon != did {
            queryItems.append(URLQueryItem(name: "anon_id", value: anon))
        }
        // OS version from UIDevice — always available on iOS.
        #if canImport(UIKit)
        queryItems.append(URLQueryItem(name: "os_version", value: UIDevice.current.systemVersion))
        #endif
        // App version from the host bundle — CFBundleShortVersionString
        // is the marketing version most apps use (e.g. "1.2.0"), which
        // matches what the server's semver range compares against.
        if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !appVersion.isEmpty {
            queryItems.append(URLQueryItem(name: "app_version", value: appVersion))
        }
        // Locale ID like "en_US" — the server accepts the Apple format.
        let localeID = Locale.current.identifier
        if !localeID.isEmpty {
            queryItems.append(URLQueryItem(name: "locale", value: localeID))
        }

        var components = URLComponents(string: "\(normalized)/api/v1/handshake")
        components?.queryItems = queryItems
        // Fallback to the legacy string concat if URLComponents blows
        // up for some reason — we'd rather ship a partial handshake
        // than fail the whole init.
        let url: URL
        if let built = components?.url {
            url = built
        } else {
            guard let fallback = URL(string: "\(normalized)/api/v1/handshake?installed=\(encoded)&sdk=ios") else { return }
            url = fallback
        }
        _ = encoded // silence unused-warn when the fast path succeeds

        var request = URLRequest(url: url)
        request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        if !handshakeEtag.isEmpty {
            request.addValue(handshakeEtag, forHTTPHeaderField: "If-None-Match")
        }
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                self.logger.warn("⚠️ Handshake failed: \(error.localizedDescription)")
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else { return }

            // 304 — cache still current. Re-route into the Traffic Cop
            // so modules registered between the previous handshake and
            // now pick up the payload they missed.
            if httpResponse.statusCode == 304, let cached = self.cachedHandshakeModules {
                self.logger.log("🤝 Handshake 304 — cached modules still current")
                SankofaModuleRegistry.shared.routeHandshake(cached)
                return
            }

            guard httpResponse.statusCode == 200,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let modules = json["modules"] as? [String: Any] else {
                self.logger.log("🤝 Handshake unavailable — continuing with local config")
                return
            }

            self.logger.log("🤝 Handshake OK (project: \(json["project_id"] ?? "?"), installed: \(installed))")
            self.cachedHandshakeModules = modules
            self.handshakeEtag =
                httpResponse.value(forHTTPHeaderField: "Etag") ??
                httpResponse.value(forHTTPHeaderField: "ETag") ??
                ""

            // Traffic Cop — route enabled flags to registered modules.
            SankofaModuleRegistry.shared.routeHandshake(modules)

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

// MARK: - Catch static helpers (Crashlytics + Sentry merged)
//
// Surface area pinned for parity with the Flutter / RN / Android SDKs.
// Each helper degrades to a no-op when Catch hasn't booted yet (e.g.
// host disabled it via `enableCatch = false`) so call sites never need
// to guard `if catchEnabled { ... }`.
//
// ## Why static
//
// Sentry's iOS SDK exposes `SentrySDK.capture(error:)` rather than
// `SentrySDK.shared.capture(error:)` — the implicit "no instance to
// thread through" makes capture sites read like a single-line log
// statement, which is what Crashlytics + Sentry users already expect.
extension Sankofa {

    /// Capture a handled error. Returns the event ID, or `""` when
    /// Catch is disabled / sampled out / not yet started.
    ///
    /// ```swift
    /// do { try risky() } catch { Sankofa.captureException(error) }
    /// ```
    @discardableResult
    @objc
    public static func captureException(_ error: Error) -> String {
        guard SankofaCatch.shared.isStarted else { return "" }
        return SankofaCatch.shared.captureException(error)
    }

    /// Variant of `captureException` accepting a full `CaptureOptions`
    /// (level / tags / extra / fingerprint / trace ids).
    @discardableResult
    public static func captureException(
        _ error: Error,
        options: SankofaCatch.CaptureOptions
    ) -> String {
        guard SankofaCatch.shared.isStarted else { return "" }
        return SankofaCatch.shared.captureException(error, options: options)
    }

    /// Capture an arbitrary message — non-throwing variant of
    /// `captureException`. Useful for non-fatal "this shouldn't happen"
    /// branches.
    @discardableResult
    @objc
    public static func captureMessage(_ message: String) -> String {
        guard SankofaCatch.shared.isStarted else { return "" }
        return SankofaCatch.shared.captureMessage(message)
    }

    @discardableResult
    public static func captureMessage(
        _ message: String,
        options: SankofaCatch.CaptureOptions
    ) -> String {
        guard SankofaCatch.shared.isStarted else { return "" }
        return SankofaCatch.shared.captureMessage(message, options: options)
    }

    /// Crashlytics-style breadcrumb log. Drops a free-text trail entry
    /// onto the ring buffer that rides on the next captured event.
    /// Doesn't bill — no event is emitted unless something else captures.
    ///
    /// ```swift
    /// Sankofa.log("checkout: applying coupon \(code)")
    /// ```
    @objc
    public static func log(_ message: String) {
        guard SankofaCatch.shared.isStarted else { return }
        SankofaCatch.shared.log(message)
    }

    @objc
    public static func log(_ message: String, category: String) {
        guard SankofaCatch.shared.isStarted else { return }
        SankofaCatch.shared.log(message, category: category)
    }

    /// Set ambient user context that's stamped on every subsequent
    /// capture. Pass `nil` to clear (e.g. on logout). Not `@objc`-exposed
    /// because `CatchUserContext` is a Swift-only struct.
    public static func setUser(_ user: CatchUserContext?) {
        guard SankofaCatch.shared.isStarted else { return }
        SankofaCatch.shared.setUser(user)
    }

    /// Set a single tag.
    @objc
    public static func setTag(_ key: String, _ value: String) {
        guard SankofaCatch.shared.isStarted else { return }
        SankofaCatch.shared.setTag(key, value)
    }

    /// Bulk-set tags — merges into the existing tag map.
    @objc
    public static func setTags(_ tags: [String: String]) {
        guard SankofaCatch.shared.isStarted else { return }
        SankofaCatch.shared.setTags(tags)
    }

    /// Set a single extra (arbitrary key/value) sent on every capture.
    public static func setExtra(_ key: String, _ value: AnyCodable) {
        guard SankofaCatch.shared.isStarted else { return }
        SankofaCatch.shared.setExtra(key, value)
    }

    /// Push a breadcrumb onto the ring buffer. Use `log(_:)` for plain text.
    public static func addBreadcrumb(_ crumb: CatchBreadcrumb) {
        guard SankofaCatch.shared.isStarted else { return }
        SankofaCatch.shared.addBreadcrumb(crumb)
    }

    /// Run `fn` with a temporary scope. Mutations made via the scope
    /// (tags, extras, user, level, fingerprint) overlay onto any
    /// `captureException` / `captureMessage` calls inside `fn`.
    /// Outside `fn` the scope is gone — async captures deferred past
    /// the closure's return will NOT see the scope.
    ///
    /// No-op when Catch isn't initialized; `fn` still runs with a sink
    /// scope so host code that does work alongside captures isn't skipped.
    ///
    /// ```swift
    /// Sankofa.withScope { scope in
    ///     scope.setTag("flow", "checkout")
    ///     scope.setExtra("cart_id", AnyCodable(cart.id))
    ///     Sankofa.captureException(err)
    /// }
    /// ```
    @discardableResult
    public static func withScope<T>(_ fn: (SankofaCatchScope) throws -> T) rethrows -> T {
        guard SankofaCatch.shared.isStarted else {
            // Sink scope so host code still runs.
            return try fn(SankofaCatchScope())
        }
        return try SankofaCatch.shared.withScope(fn)
    }

    /// Force-flush queued Catch events (e.g. before a known process exit).
    @objc
    public static func flushCatch() {
        guard SankofaCatch.shared.isStarted else { return }
        SankofaCatch.shared.flush()
    }
}
