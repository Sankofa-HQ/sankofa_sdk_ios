import UIKit

/// Orchestrates the dual-engine replay system using the Strategy Pattern.
///
/// The coordinator runs a `CADisplayLink` throttled to a configurable FPS. On
/// each tick, it delegates to the currently active engine (wireframe or screenshot).
/// Engines can be swapped at runtime in response to API-defined event triggers
/// (Phase 3 — Escalation System).
final class SankofaCaptureCoordinator {

    // MARK: - Config

    private let maskAllInputs: Bool
    let uploader: SankofaReplayUploader
    private var sessionId: String = ""

    private let targetFPS: Double = 2.0  // 2 frames/sec — low enough to avoid battery drain

    // MARK: - Engines

    private lazy var wireframeEngine = SankofaWireframeEngine(sessionId: sessionId)
    private lazy var screenshotEngine = SankofaScreenshotEngine(sessionId: sessionId, maskAllInputs: maskAllInputs)

    private var currentEngine: SankofaCaptureEngine
    private let deviceInfo = SankofaDeviceInfo()
    private var touchInterceptor: SankofaTouchInterceptor?

    // MARK: - Scheduler

    private var displayLink: CADisplayLink?
    private var frameCounter: Int = 0
    private var skipFrames: Int = 0 // Derived from FPS: skip (60/targetFPS - 1) frames

    // MARK: - Escalation

    private var escalationConfig: EscalationConfig?
    private var escalationTimer: Timer?

    struct EscalationConfig {
        var triggers: Set<String>
        var highFidelityDuration: TimeInterval
    }

    // MARK: - Init

    init(mode: SankofaCaptureMode, maskAllInputs: Bool, uploader: SankofaReplayUploader) {
        self.maskAllInputs = maskAllInputs
        self.uploader = uploader
        // Default engine based on config
        self.currentEngine = mode == .wireframe
            ? SankofaWireframeEngine(sessionId: "")   // Replaced in start()
            : SankofaScreenshotEngine(sessionId: "", maskAllInputs: maskAllInputs)
    }

    // MARK: - Lifecycle

    func start(sessionId: String = "") {
        self.sessionId = sessionId.isEmpty ? "session_\(UUID().uuidString)" : sessionId
        wireframeEngine = SankofaWireframeEngine(sessionId: self.sessionId)
        screenshotEngine = SankofaScreenshotEngine(sessionId: self.sessionId, maskAllInputs: maskAllInputs)
        currentEngine = wireframeEngine

        skipFrames = max(0, Int(60.0 / targetFPS) - 1)
        
        // Attach touch interceptor to the key window
        if let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) {
            let interceptor = SankofaTouchInterceptor(target: nil, action: nil)
            window.addGestureRecognizer(interceptor)
            self.touchInterceptor = interceptor
        }

        // 🚨 Retain Cycle Fix: CADisplayLink strongly retains its target. 
        // We use a WeakProxy to ensure the Coordinator can be deinitialized.
        let proxy = WeakProxy(self)
        let link = CADisplayLink(target: proxy, selector: #selector(WeakProxy.onTick))
        link.add(to: .main, forMode: .common)
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: 30)
        } else {
            link.preferredFramesPerSecond = Int(targetFPS)
        }
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        escalationTimer?.invalidate()
        escalationTimer = nil
    }

    // MARK: - Capture Tick

    @objc internal func tick() {
        frameCounter += 1
        guard frameCounter > skipFrames else { return }
        frameCounter = 0

        // Flush interactions collected since last tick
        let interactions = touchInterceptor?.flush() ?? []
        let context = deviceInfo.deviceContext()

        // The engine grabs the image instantly on the main thread, 
        // and calls the completion handler when the background compression is done.
        currentEngine.captureFrame { [weak self] frame in
            guard let self = self, let frame = frame else { return }
            self.uploader.upload(frame, deviceContext: context, interactions: interactions)
        }
    }
    // MARK: - Escalation (Phase 3)

    /// Configure the trigger map from remote config.
    func configure(escalation: EscalationConfig) {
        self.escalationConfig = escalation
    }

    /// Called on every `Sankofa.shared.track(event)`.
    /// Checks if the event is in the trigger list and escalates if so.
    func onEvent(_ event: String) {
        guard let config = escalationConfig,
              config.triggers.contains(event),
              !(currentEngine is SankofaScreenshotEngine) else { return }

        // Swap to screenshot engine
        currentEngine = screenshotEngine

        // Schedule automatic rollback
        escalationTimer?.invalidate()
        escalationTimer = Timer.scheduledTimer(
            withTimeInterval: config.highFidelityDuration,
            repeats: false
        ) { [weak self] _ in
            self?.currentEngine = self?.wireframeEngine ?? self!.currentEngine
        }
    }
}

// MARK: - WeakProxy

/// Breaks the CADisplayLink retain cycle by holding a weak reference to the target.
final class WeakProxy {
    private weak var target: SankofaCaptureCoordinator?

    init(_ target: SankofaCaptureCoordinator) {
        self.target = target
    }

    @objc func onTick() {
        target?.tick()
    }
}

