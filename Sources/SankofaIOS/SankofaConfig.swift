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

    /// Replay capture mode. Defaults to `.wireframe` (zero-image, privacy-safe).
    @objc public var captureMode: SankofaCaptureMode

    /// Events that trigger a temporary switch to high-fidelity (screenshot) mode.
    /// E.g. ["Checkout Started", "Purchase Completed"]
    @objc public var highFidelityTriggers: [String]

    /// Duration (in seconds) to stay in screenshot mode after a trigger event.
    @objc public var highFidelityDuration: TimeInterval

    /// Scale factor for screenshot engine to reduce resolution/payload size. Defaults to 0.5.
    @objc public var captureScale: CGFloat

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
        captureScale: CGFloat = 0.5,
        // captureMode: SankofaCaptureMode = .screenshot,
        // highFidelityTriggers: [String] = [],
        // highFidelityDuration: TimeInterval = 30
    ) {
        self.endpoint = endpoint
        self.debug = debug
        self.trackLifecycleEvents = trackLifecycleEvents
        self.flushIntervalSeconds = flushIntervalSeconds
        self.batchSize = batchSize
        self.recordSessions = recordSessions
        self.maskAllInputs = maskAllInputs
        self.captureScale = captureScale
        self.captureMode = .screenshot
        self.highFidelityTriggers = []
        self.highFidelityDuration = 30
        super.init()
    }
}

/// Capture mode for session replay.
@objc(SankofaSankofaCaptureMode)
public enum SankofaCaptureMode: Int {
    /// Reconstructs the UI as a lightweight JSON view-tree.
    /// Zero-image, privacy-safe, low bandwidth. **Default.**
    case wireframe = 0

    /// Captures pixel-perfect screenshots using Ghost Masking (CoreGraphics
    /// in-memory only — the live screen is never modified).
    case screenshot = 1
}
