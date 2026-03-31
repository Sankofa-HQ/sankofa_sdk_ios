import UIKit

/// Orchestrates the dual-engine replay system using the Strategy Pattern.
///
/// The coordinator runs a `CADisplayLink` throttled to a configurable FPS. On
/// each tick, it delegates to the currently active engine (wireframe or screenshot).
/// Engines can be swapped at runtime in response to API-defined event triggers
/// (Phase 3 — Escalation System).
final class SankofaCaptureCoordinator {

    // MARK: - Config

    private let initialMode: SankofaCaptureMode
    private let maskAllInputs: Bool
    private let captureScale: CGFloat
    let uploader: SankofaReplayUploader
    private var sessionId: String = ""

    private let targetFPS: Double = 2.0  // 2 frames/sec — low enough to avoid battery drain

    // MARK: - Engines

    private lazy var wireframeEngine = SankofaWireframeEngine(sessionId: sessionId)
    private lazy var screenshotEngine = SankofaScreenshotEngine(sessionId: sessionId, maskAllInputs: maskAllInputs, captureScale: captureScale)

    private var currentEngine: SankofaCaptureEngine
    private let deviceInfo = SankofaDeviceInfo()
    private var touchInterceptor: SankofaTouchInterceptor?

    // MARK: - Scheduler

    private var displayLink: CADisplayLink?
    private var lastCaptureTime: TimeInterval = 0
    
    // 🎯 SNIPER: CFRunLoopObserver for idle-state screenshot capture
    private var runLoopObserver: CFRunLoopObserver?
    
    // MARK: - Escalation

    private var escalationConfig: EscalationConfig?
    private var escalationTimer: Timer?

    // MARK: - Init

    init(mode: SankofaCaptureMode, maskAllInputs: Bool, captureScale: CGFloat = 0.5, uploader: SankofaReplayUploader) {
        self.initialMode = mode
        self.maskAllInputs = maskAllInputs
        self.captureScale = captureScale
        self.uploader = uploader
        self.currentEngine = SankofaWireframeEngine(sessionId: "") // Placeholder
    }

    // MARK: - Lifecycle

    func start(sessionId: String = "") {
        // Idempotency: Don't start twice if already running
        guard displayLink == nil else { return }

        if !sessionId.isEmpty {
            self.sessionId = sessionId
            wireframeEngine = SankofaWireframeEngine(sessionId: self.sessionId)
            screenshotEngine = SankofaScreenshotEngine(sessionId: self.sessionId, maskAllInputs: maskAllInputs, captureScale: captureScale)
        }
        
        currentEngine = (initialMode == .wireframe) ? wireframeEngine : screenshotEngine
        
        // Try to attach right away; if the window isn't ready, tick() will retry.
        attachTouchInterceptorIfNeeded()

        let proxy = WeakProxy(self)
        let link = CADisplayLink(target: proxy, selector: #selector(WeakProxy.onTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        
        // If starting in screenshot mode, use the Sniper
        if currentEngine is SankofaScreenshotEngine {
            startIdleCapture()
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        stopIdleCapture()
        escalationTimer?.invalidate()
        escalationTimer = nil
    }
     // MARK: - Capture Tick

    @objc internal func tick() {
        // Retry interceptor attachment every tick until it succeeds
        attachTouchInterceptorIfNeeded()

        // 💨 Throttling Fix: Use CACurrentMediaTime() for precise 2 FPS (even on 120Hz displays)
        let now = CACurrentMediaTime()
        guard now - lastCaptureTime >= (1.0 / targetFPS) else { return }
        lastCaptureTime = now

        // 💨 PERFORMANCE: If we are in screenshot mode, the Sniper (RunLoopObserver) 
        // handles the capture. We don't want the CADisplayLink to fire as well.
        guard !(currentEngine is SankofaScreenshotEngine) else { return }

        let interactions = touchInterceptor?.flush() ?? []
        let context = deviceInfo.deviceContext()

        self.currentEngine.captureFrame { [weak self] frame in
            guard let self = self, let frame = frame else { return }
            self.uploader.upload(frame, deviceContext: context, interactions: interactions)
        }
    }
     // MARK: - Idle Sniper (PostHog Method)

    private func startIdleCapture() {
        stopIdleCapture()
        
        // 🎯 SNIPER: We observe the RunLoop activity "BeforeWaiting".
        // This means the UI thread has just finished drawing all animations, 
        // ripples, and layout passes. Snapping the screen NOW will not lag the UI!
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, _ in
            guard let self = self else { return }
            
            // Retry interceptor attachment in case it wasn't ready at start()
            self.attachTouchInterceptorIfNeeded()
            
            let now = CACurrentMediaTime()
            // Throttle to target FPS (e.g., once every 0.5s for 2 FPS)
            if (now - self.lastCaptureTime) >= (1.0 / self.targetFPS) {
                self.lastCaptureTime = now
                
                let interactions = self.touchInterceptor?.flush() ?? []
                let context = self.deviceInfo.deviceContext()
                
                self.currentEngine.captureFrame { frame in
                    guard let frame = frame else { return }
                    self.uploader.upload(frame, deviceContext: context, interactions: interactions)
                }
            }
        }
        
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.runLoopObserver = observer
    }

    private func stopIdleCapture() {
        if let observer = runLoopObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            runLoopObserver = nil
        }
    }

    // MARK: - Touch Interceptor Attachment

    /// Attaches the touch interceptor to the key window.
    /// Safe to call repeatedly — it's a no-op once attached.
    /// Uses modern UIWindowScene API with legacy fallback.
    private func attachTouchInterceptorIfNeeded() {
        guard touchInterceptor == nil else { return }
        
        guard let window = Self.findKeyWindow() else { return }
        
        let interceptor = SankofaTouchInterceptor(target: nil, action: nil)
        window.addGestureRecognizer(interceptor)
        self.touchInterceptor = interceptor
    }

    /// Modern key-window discovery that works on iOS 13+ with scenes.
    private static func findKeyWindow() -> UIWindow? {
        // Modern: UIWindowScene-based lookup (iOS 15+)
        if #available(iOS 15.0, *) {
            for scene in UIApplication.shared.connectedScenes {
                if let windowScene = scene as? UIWindowScene,
                   scene.activationState == .foregroundActive {
                    if let keyWindow = windowScene.keyWindow {
                        return keyWindow
                    }
                    // Fallback: first visible window in the scene
                    if let window = windowScene.windows.first(where: { $0.isKeyWindow }) {
                        return window
                    }
                }
            }
        }
        
        // iOS 13-14 fallback
        if #available(iOS 13.0, *) {
            for scene in UIApplication.shared.connectedScenes {
                if let windowScene = scene as? UIWindowScene {
                    if let window = windowScene.windows.first(where: { $0.isKeyWindow }) {
                        return window
                    }
                }
            }
        }
        
        // Legacy fallback
        return UIApplication.shared.windows.first(where: { $0.isKeyWindow })
    }

    // MARK: - Escalation (Phase 3)

    func configure(escalation: EscalationConfig) {
        self.escalationConfig = escalation
    }

    func onEvent(_ event: String) {
        guard let config = escalationConfig,
              config.triggers.contains(event),
              !(currentEngine is SankofaScreenshotEngine) else { return }

        // Swap to high-fidelity engine
        currentEngine = screenshotEngine
        startIdleCapture()

        escalationTimer?.invalidate()
        escalationTimer = Timer.scheduledTimer(withTimeInterval: config.highFidelityDuration, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.stopIdleCapture()
            self.currentEngine = self.wireframeEngine
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

/// Configuration for temporary high-fidelity (screenshot) mode triggered by events.
struct EscalationConfig {
    var triggers: Set<String>
    var highFidelityDuration: TimeInterval
}
