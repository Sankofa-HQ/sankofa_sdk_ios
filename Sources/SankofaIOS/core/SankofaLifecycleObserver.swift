import Foundation
import UIKit

/// Observes iOS app lifecycle events and triggers flushes / lifecycle events.
///
/// Mirrors `SankofaLifecycleObserver` in the Flutter SDK.
/// Subscribes via `NotificationCenter` — no Objective-C swizzling.
@MainActor
final class SankofaLifecycleObserver {

    private let sessionManager: SankofaSessionManager
    private let flushManager: SankofaFlushManager
    private let captureCoordinator: SankofaCaptureCoordinator
    private let trackLifecycle: Bool
    private let onLifecycleEvent: (String) -> Void

    private var tokens: [NSObjectProtocol] = []

    init(
        sessionManager: SankofaSessionManager,
        flushManager: SankofaFlushManager,
        captureCoordinator: SankofaCaptureCoordinator,
        trackLifecycle: Bool,
        onLifecycleEvent: @escaping (String) -> Void
    ) {
        self.sessionManager = sessionManager
        self.flushManager = flushManager
        self.captureCoordinator = captureCoordinator
        self.trackLifecycle = trackLifecycle
        self.onLifecycleEvent = onLifecycleEvent
    }

    func start() {
        let nc = NotificationCenter.default

        // App entered foreground
        tokens.append(nc.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            
            // 🚀 Check for session rotation (30m rule)
            if self.sessionManager.checkSessionRotation() {
                self.onLifecycleEvent("$session_start")
                
                // If we are recording, restart coordinator with new ID
                if self.captureCoordinator.isStarted == true {
                    self.captureCoordinator.stop()
                    self.captureCoordinator.start(sessionId: self.sessionManager.sessionId)
                }
            }
            
            self.flushManager.start()
            self.captureCoordinator.start() // Resume replay capture
            if self.trackLifecycle { self.onLifecycleEvent("$app_foregrounded") }
        })

        // App about to go to background
        tokens.append(nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            
            // 🚀 Capture background time for rotation
            self.sessionManager.lastBackgroundTime = Date()
            
            self.flushManager.stop()
            self.captureCoordinator.stop() // Pause replay capture (CRITICAL FIX)
            self.flushManager.flush()
            if self.trackLifecycle { self.onLifecycleEvent("$app_backgrounded") }
        })

        // App about to terminate — best-effort synchronous flush.
        tokens.append(nc.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            
            // Mark background time even on termination
            self.sessionManager.lastBackgroundTime = Date()
            
            self.flushManager.flush()
        })
    }

    deinit {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
