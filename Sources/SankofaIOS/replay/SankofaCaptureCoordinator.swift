import UIKit

/// Orchestrates the single-engine rrweb replay system.
///
/// The coordinator runs a `CADisplayLink` throttled to a configurable FPS. On
/// each tick, it delegates to the replay engine to capture an rrweb snapshot.
@MainActor
final class SankofaCaptureCoordinator {

    // MARK: - Config

    private let maskAllInputs: Bool
    let uploader: SankofaReplayUploader
    private var sessionId: String = ""

    private let targetFPS: Double = 2.0  // 2 frames/sec

    // MARK: - Engines

    private lazy var replayEngine = SankofaWireframeEngine(sessionId: sessionId, maskAllInputs: maskAllInputs)

    private let deviceInfo = SankofaDeviceInfo()
    private var touchInterceptor: SankofaTouchInterceptor?

    // MARK: - Scheduler (Phase 28 Idle Sniper)

    private var runLoopObserver: CFRunLoopObserver?
    private var lastCaptureTime: TimeInterval = 0
    private let targetInterval: TimeInterval = 0.5 // 2 FPS

    // MARK: - Init

    init(maskAllInputs: Bool, uploader: SankofaReplayUploader) {
        self.maskAllInputs = maskAllInputs
        self.uploader = uploader
    }

    // MARK: - Lifecycle

    func start(sessionId: String = "") {
        self.sessionId = sessionId.isEmpty ? "session_\(UUID().uuidString)" : sessionId
        replayEngine = SankofaWireframeEngine(sessionId: self.sessionId, maskAllInputs: maskAllInputs)
        
        if let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) {
            let interceptor = SankofaTouchInterceptor(target: nil, action: nil)
            window.addGestureRecognizer(interceptor)
            self.touchInterceptor = interceptor
        }

        // The Phase 28 Idle Sniper: Ensures zero UI blocking by only triggering 
        // when the run loop is about to sleep (i.e., finished all UI work).
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue,
            true,
            0
        ) { [weak self] _, _ in
            guard let self = self else { return }
            
            let now = CACurrentMediaTime()
            if (now - self.lastCaptureTime) >= self.targetInterval {
                self.lastCaptureTime = now
                
                // Safe to run the heavy CSS crawler!
                let interactions = self.touchInterceptor?.flush() ?? []
                let context = self.deviceInfo.deviceContext()
                
                self.replayEngine.captureFrame { [weak self] frame in
                    guard let self = self, let frame = frame else { return }
                    self.uploader.upload(frame, deviceContext: context, interactions: interactions)
                }
            }
        }
        
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.runLoopObserver = observer
    }

    func stop() {
        if let observer = runLoopObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            runLoopObserver = nil
        }
    }
}

