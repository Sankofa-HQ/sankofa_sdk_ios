import Foundation

/// Configuration for the Sankofa iOS SDK.
///
/// Pass a `SankofaConfig` instance to `Sankofa.shared.initialize(apiKey:config:)`
/// to customise the SDK's telemetry and replay behaviour.
///
/// Mirrors `SankofaConfig` on Android and the options struct on Flutter.
public struct SankofaConfig {

    // MARK: - Core

    /// Base URL for your Sankofa engine, e.g. "https://api.sankofa.dev"
    public var endpoint: String

    /// Enable verbose console logging during development.
    public var debug: Bool

    /// Automatically track `$app_opened`, `$app_backgrounded`, `$app_terminated`.
    public var trackLifecycleEvents: Bool

    // MARK: - Queue & Flush

    /// Number of seconds between automatic event flushes while the app is foregrounded.
    public var flushIntervalSeconds: TimeInterval

    /// Maximum number of events to buffer before triggering an early flush.
    public var batchSize: Int

    // MARK: - Session Replay

    /// Enable session recording (wireframe or screenshot).
    public var recordSessions: Bool

    /// When `true`, all `UITextField` and `UITextView` inputs are automatically
    /// masked in recordings. Individual views can also be masked via
    /// `view.sankofaMask = true`.
    public var maskAllInputs: Bool

    /// Replay capture mode. Defaults to `.wireframe` (zero-image, privacy-safe).
    public var captureMode: SankofaCaptureMode

    // MARK: - Init

    public init(
        endpoint: String = "https://api.sankofa.dev",
        debug: Bool = false,
        trackLifecycleEvents: Bool = true,
        flushIntervalSeconds: TimeInterval = 30,
        batchSize: Int = 50,
        recordSessions: Bool = true,
        maskAllInputs: Bool = true,
        captureMode: SankofaCaptureMode = .wireframe
    ) {
        self.endpoint = endpoint
        self.debug = debug
        self.trackLifecycleEvents = trackLifecycleEvents
        self.flushIntervalSeconds = flushIntervalSeconds
        self.batchSize = batchSize
        self.recordSessions = recordSessions
        self.maskAllInputs = maskAllInputs
        self.captureMode = captureMode
    }
}

/// Capture mode for session replay.
public enum SankofaCaptureMode {
    /// Reconstructs the UI as a lightweight JSON view-tree.
    /// Zero-image, privacy-safe, low bandwidth. **Default.**
    case wireframe

    /// Captures pixel-perfect screenshots using Ghost Masking (CoreGraphics
    /// in-memory only — the live screen is never modified).
    case screenshot
}
