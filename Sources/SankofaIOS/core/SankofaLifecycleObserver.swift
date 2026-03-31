import Foundation
import UIKit

/// Observes iOS app lifecycle events and triggers flushes / lifecycle events.
///
/// Mirrors `SankofaLifecycleObserver` in the Flutter SDK.
/// Subscribes via `NotificationCenter` — no Objective-C swizzling.
@MainActor
final class SankofaLifecycleObserver {

    private let flushManager: SankofaFlushManager
    private let captureCoordinator: SankofaCaptureCoordinator
    private let trackLifecycle: Bool
    private let onLifecycleEvent: (String) -> Void

    private var tokens: [NSObjectProtocol] = []

    init(
        flushManager: SankofaFlushManager,
        captureCoordinator: SankofaCaptureCoordinator,
        trackLifecycle: Bool,
        onLifecycleEvent: @escaping (String) -> Void
    ) {
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
            self.flushManager.start()
            self.captureCoordinator.start() // Resume replay capture
            if self.trackLifecycle { self.onLifecycleEvent("$app_opened") }
        })

        // App about to go to background — flush immediately before Apple suspends us.
        tokens.append(nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
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
            self.flushManager.flush()
            if self.trackLifecycle { self.onLifecycleEvent("$app_terminated") }
        })
    }

    deinit {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
