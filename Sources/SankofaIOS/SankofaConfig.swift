import Foundation

/// Configuration for the Sankofa iOS SDK.
///
/// Pass a `SankofaConfig` instance to `Sankofa.shared.initialize(apiKey:config:)`
/// to customise the SDK's telemetry and replay behaviour.
@objc(SankofaSankofaConfig)
public final class SankofaConfig: NSObject {

    // MARK: - Core

    /// Base URL for your Sankofa engine, e.g. "https://api.sankofa.dev"
    @objc public var endpoint: String

    /// Enable verbose console logging during development.
    @objc public var debug: Bool

    /// Automatically track `$app_opened`, `$app_backgrounded`, `$app_terminated`.
    @objc public var trackLifecycleEvents: Bool

    // MARK: - Queue & Flush

    /// Number of seconds between automatic event flushes while the app is foregrounded.
    @objc public var flushIntervalSeconds: TimeInterval

    /// Maximum number of events to buffer before triggering an early flush.
    @objc public var batchSize: Int

    // MARK: - Session Replay

    /// Enable session recording (wireframe or screenshot).
    @objc public var recordSessions: Bool

    /// When `true`, all `UITextField` and `UITextView` inputs are automatically
    /// masked in recordings. Individual views can also be masked via
    /// `view.sankofaMask = true`.
    @objc public var maskAllInputs: Bool

    /// Scale factor for screenshot engine to reduce resolution/payload size. Defaults to 0.5.
    @objc public var captureScale: CGFloat

    // MARK: - Catch (error + crash + ANR reporting)
    //
    // Crashlytics + Sentry merged: when `enableCatch` is true,
    // `Sankofa.shared.initialize(...)` installs `NSSetUncaughtExceptionHandler`,
    // the POSIX-signal handler, and the persistent retry queue automatically —
    // host code does NOT need a separate `SankofaCatch.shared.start(...)` call.

    /// Auto-start `SankofaCatch.shared` inside `initialize(...)`.
    /// Defaults to true. Set to false only if you need to defer Catch
    /// boot (e.g. integration tests that spy on the global handler).
    @objc public var enableCatch: Bool

    /// Catch environment tag — "live", "staging", "dev", custom.
    @objc public var catchEnvironment: String

    /// Optional release identifier (e.g. "myapp@1.4.0+42") sent on every Catch event.
    ///
    /// Not `@objc`-exposed because the bare selector `release` collides
    /// with `NSObject.release()` from legacy MRC; ObjC consumers can
    /// use the designated initializer's `release:` parameter instead.
    public var release: String?

    /// Optional app version string sent in the Catch device context.
    public var appVersion: String?

    // MARK: - Init

    @objc
    public init(
        endpoint: String = "https://api.sankofa.dev",
        debug: Bool = false,
        trackLifecycleEvents: Bool = true,
        flushIntervalSeconds: TimeInterval = 30,
        batchSize: Int = 50,
        recordSessions: Bool = true,
        maskAllInputs: Bool = true,
        captureScale: CGFloat = 0.35,
        enableCatch: Bool = true,
        catchEnvironment: String = "live",
        release: String? = nil,
        appVersion: String? = nil
    ) {
        self.endpoint = endpoint
        self.debug = debug
        self.trackLifecycleEvents = trackLifecycleEvents
        self.flushIntervalSeconds = flushIntervalSeconds
        self.batchSize = batchSize
        self.recordSessions = recordSessions
        self.maskAllInputs = maskAllInputs
        self.captureScale = captureScale
        self.enableCatch = enableCatch
        self.catchEnvironment = catchEnvironment
        self.release = release
        self.appVersion = appVersion
        super.init()
    }
}

