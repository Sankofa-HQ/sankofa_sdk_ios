import UIKit

/// Orchestrates the screenshot-only replay system.
///
/// Uses a `CFRunLoopObserver` to snap the screen only when the UI thread is
/// idle (BeforeWaiting), throttled to a configurable FPS. This ensures zero
/// UI jank while still capturing every meaningful frame change.
@MainActor
final class SankofaCaptureCoordinator {

    // MARK: - Config

    private let maskAllInputs: Bool
    private let captureScale: CGFloat
    let uploader: SankofaReplayUploader
    private var sessionId: String = ""
    private var screenNameProvider: () -> String = { "Unknown" }

    // MARK: - Engine

    private lazy var screenshotEngine = SankofaScreenshotEngine(
        sessionId: sessionId,
        maskAllInputs: maskAllInputs,
        captureScale: captureScale
    )

    private let deviceInfo = SankofaDeviceInfo()
    private var touchInterceptor: SankofaTouchInterceptor?
    private var keyboardInteractions: [SankofaTouchInterceptor.Interaction] = []

    // MARK: - Scheduler

    private var runLoopObserver: CFRunLoopObserver?
    private var lastCaptureTime: TimeInterval = 0
    private let targetFPS: Double = 2.0
    private var isRunning = false
    private var tokens: [NSObjectProtocol] = []
    
    /// Accumulated interactions that have not yet been bundled into a frame.
    /// Preserved across throttled runloop cycles so idle-screen taps are never dropped.
    private var pendingCarryoverInteractions: [SankofaTouchInterceptor.Interaction] = []

    // MARK: - Init

    init(maskAllInputs: Bool, captureScale: CGFloat = 0.35, uploader: SankofaReplayUploader) {
        self.maskAllInputs = maskAllInputs
        self.captureScale = captureScale
        self.uploader = uploader
        setupKeyboardListeners()
    }

    // MARK: - Lifecycle

    /// Starts or resumes the capture coordinator.
    ///
    /// - Parameters:
    ///   - sessionId: The session ID to use. If empty, the existing session ID is kept.
    ///   - screenNameProvider: A closure returning the current screen name.
    ///     Pass `nil` (the default) to **preserve** the existing provider — this is the
    ///     correct behaviour for foreground-resume calls from `SankofaLifecycleObserver`
    ///     which should not clobber the provider set during the initial `start`.
    func start(sessionId: String = "", screenNameProvider: (() -> String)? = nil) {
        guard !isRunning else { return }
        isRunning = true

        // Only replace the screenNameProvider if one is explicitly supplied.
        // This prevents foreground-resume calls (which omit the provider) from
        // resetting it to the "Unknown" default and losing screen attribution.
        if let provider = screenNameProvider {
            self.screenNameProvider = provider
        }

        if !sessionId.isEmpty {
            self.sessionId = sessionId
            screenshotEngine = SankofaScreenshotEngine(
                sessionId: self.sessionId,
                maskAllInputs: maskAllInputs,
                captureScale: captureScale
            )
        }

        attachTouchInterceptorIfNeeded()
        startIdleCapture()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopIdleCapture()
    }

    var isStarted: Bool { isRunning }

    /// Forces an immediate high-fidelity capture cycle, typically after a server-side request.
    /// Even if the coordinator is in a throttled state, this ensures a baseline is sent.
    func triggerHighFidelityMode(duration: TimeInterval) {
        // Snap! Force an immediate capture cycle.
        let context = self.deviceInfo.deviceContext()
        let interactions = self.touchInterceptor?.flush() ?? []
        let screen = self.screenNameProvider()

        screenshotEngine.captureFrame { [weak self] frame in
            guard let self = self, let frame = frame else { return }
            self.uploader.upload(frame, screenName: screen, deviceContext: context, interactions: interactions)
        }
    }

    // MARK: - Idle Sniper

    private func startIdleCapture() {
        stopIdleCapture()

        // 🎯 SNIPER: Only snaps the screen when the UI thread is resting.
        // CRITICAL FIX: Interactions are ACCUMULATED across throttle-skipped cycles.
        // This ensures that taps on a static/idle screen are NEVER dropped — they
        // are carried forward and bundled into the very next frame that gets uploaded.
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue,
            true,
            0
        ) { [weak self] _, _ in
            guard let self = self else { return }

            self.attachTouchInterceptorIfNeeded()

            // Always drain the touch buffer into the carryover bucket, even if we
            // are going to skip this frame due to rate-limiting. This is the key fix:
            // interactions are NEVER thrown away between frame captures.
            let freshTouches = self.touchInterceptor?.flush() ?? []
            self.pendingCarryoverInteractions.append(contentsOf: freshTouches)

            // Accumulate keyboard events
            if !self.keyboardInteractions.isEmpty {
                self.pendingCarryoverInteractions.append(contentsOf: self.keyboardInteractions)
                self.keyboardInteractions.removeAll()
            }

            let now = CACurrentMediaTime()
            let frameInterval = 1.0 / self.targetFPS
            let timeSinceLast = now - self.lastCaptureTime

            // Rate-limit: skip capture if too soon.
            // EXCEPTION: if we have accumulated interactions and the screen is static,
            // force a capture after 2× the normal interval to flush them out.
            let hasCarriedInteractions = !self.pendingCarryoverInteractions.isEmpty
            let forceCaptureDueToInteractions = hasCarriedInteractions && timeSinceLast >= frameInterval * 1.5

            guard timeSinceLast >= frameInterval || forceCaptureDueToInteractions else { return }
            self.lastCaptureTime = now

            // Snapshot and clear the carryover bucket atomically
            let interactions = self.pendingCarryoverInteractions
            self.pendingCarryoverInteractions = []

            let context = self.deviceInfo.deviceContext()
            let screen = self.screenNameProvider()

            self.screenshotEngine.captureFrame { frame in
                guard let frame = frame else { return }
                self.uploader.upload(frame, screenName: screen, deviceContext: context, interactions: interactions)
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
    private func attachTouchInterceptorIfNeeded() {
        guard touchInterceptor == nil else { return }
        guard let window = Self.findKeyWindow() else { return }

        let interceptor = SankofaTouchInterceptor(screenNameProvider: screenNameProvider)
        window.addGestureRecognizer(interceptor)
        self.touchInterceptor = interceptor
    }
    
    // MARK: - Keyboard Listeners
    
    private func setupKeyboardListeners() {
        let nc = NotificationCenter.default
        
        nc.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
            self?.recordKeyboardEvent(type: "keyboard_show")
        }
        
        nc.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            self?.recordKeyboardEvent(type: "keyboard_hide")
        }
    }
    
    private func recordKeyboardEvent(type: String) {
        let interaction = SankofaTouchInterceptor.Interaction(
            type: type,
            x: 0,
            y: 0,
            absoluteY: 0,
            scrollOffsetY: 0,
            screen: screenNameProvider(),
            timestamp: Date()
        )
        keyboardInteractions.append(interaction)
    }

    /// Modern key-window discovery that works on iOS 13+ with scenes.
    private static func findKeyWindow() -> UIWindow? {
        if #available(iOS 15.0, *) {
            for scene in UIApplication.shared.connectedScenes {
                if let windowScene = scene as? UIWindowScene,
                   scene.activationState == .foregroundActive {
                    if let keyWindow = windowScene.keyWindow { return keyWindow }
                    if let window = windowScene.windows.first(where: { $0.isKeyWindow }) { return window }
                }
            }
        }
        if #available(iOS 13.0, *) {
            for scene in UIApplication.shared.connectedScenes {
                if let windowScene = scene as? UIWindowScene {
                    if let window = windowScene.windows.first(where: { $0.isKeyWindow }) { return window }
                }
            }
        }
        return UIApplication.shared.windows.first(where: { $0.isKeyWindow })
    }
}
