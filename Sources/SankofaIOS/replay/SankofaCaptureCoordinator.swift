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

    // MARK: - Init

    init(maskAllInputs: Bool, captureScale: CGFloat = 0.35, uploader: SankofaReplayUploader) {
        self.maskAllInputs = maskAllInputs
        self.captureScale = captureScale
        self.uploader = uploader
        setupKeyboardListeners()
    }

    // MARK: - Lifecycle

    func start(sessionId: String = "", screenNameProvider: @escaping () -> String = { "Unknown" }) {
        guard !isRunning else { return }
        isRunning = true
        self.screenNameProvider = screenNameProvider

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

    // MARK: - Idle Sniper

    private func startIdleCapture() {
        stopIdleCapture()

        // 🎯 SNIPER: Only snaps the screen when the UI thread is resting
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue,
            true,
            0
        ) { [weak self] _, _ in
            guard let self = self else { return }

            self.attachTouchInterceptorIfNeeded()

            let now = CACurrentMediaTime()
            if (now - self.lastCaptureTime) >= (1.0 / self.targetFPS) {
                self.lastCaptureTime = now

                var interactions = self.touchInterceptor?.flush() ?? []
                
                // Add keyboard events collected since last capture
                if !self.keyboardInteractions.isEmpty {
                    interactions.append(contentsOf: self.keyboardInteractions)
                    self.keyboardInteractions.removeAll()
                }
                
                let context = self.deviceInfo.deviceContext()

                self.screenshotEngine.captureFrame { frame in
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
