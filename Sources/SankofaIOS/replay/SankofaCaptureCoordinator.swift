import UIKit

/// Orchestrates the single-engine rrweb replay system.
///
/// The coordinator runs a `CADisplayLink` throttled to a configurable FPS. On
/// each tick, it delegates to the replay engine to capture an rrweb snapshot.
final class SankofaCaptureCoordinator {

    // MARK: - Config

    private let maskAllInputs: Bool
    let uploader: SankofaReplayUploader
    private var sessionId: String = ""

    private let targetFPS: Double = 2.0  // 2 frames/sec

    // MARK: - Engines

    private lazy var replayEngine = SankofaWireframeEngine(sessionId: sessionId)

    private let deviceInfo = SankofaDeviceInfo()
    private var touchInterceptor: SankofaTouchInterceptor?

    // MARK: - Scheduler

    private var displayLink: CADisplayLink?
    private var frameCounter: Int = 0
    private var skipFrames: Int = 0

    // MARK: - Init

    init(maskAllInputs: Bool, uploader: SankofaReplayUploader) {
        self.maskAllInputs = maskAllInputs
        self.uploader = uploader
    }

    // MARK: - Lifecycle

    func start(sessionId: String = "") {
        self.sessionId = sessionId.isEmpty ? "session_\(UUID().uuidString)" : sessionId
        replayEngine = SankofaWireframeEngine(sessionId: self.sessionId)
        
        skipFrames = max(0, Int(60.0 / targetFPS) - 1)
        
        if let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) {
            let interceptor = SankofaTouchInterceptor(target: nil, action: nil)
            window.addGestureRecognizer(interceptor)
            self.touchInterceptor = interceptor
        }

        let proxy = WeakProxy(self)
        let link = CADisplayLink(target: proxy, selector: #selector(WeakProxy.onTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - Capture Tick

    @objc internal func tick() {
        frameCounter += 1
        guard frameCounter > skipFrames else { return }
        frameCounter = 0

        let interactions = touchInterceptor?.flush() ?? []
        let context = deviceInfo.deviceContext()

        replayEngine.captureFrame { [weak self] frame in
            guard let self = self, let frame = frame else { return }
            self.uploader.upload(frame, deviceContext: context, interactions: interactions)
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
