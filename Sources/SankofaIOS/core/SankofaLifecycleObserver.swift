import Foundation
import UIKit

/// Observes iOS app lifecycle events and triggers flushes / lifecycle events.
///
/// Mirrors `SankofaLifecycleObserver` in the Flutter SDK.
/// Subscribes via `NotificationCenter` — no Objective-C swizzling.
final class SankofaLifecycleObserver {

    private let flushManager: SankofaFlushManager
    private let trackLifecycle: Bool
    private let onLifecycleEvent: (String) -> Void

    private var tokens: [NSObjectProtocol] = []

    init(
        flushManager: SankofaFlushManager,
        trackLifecycle: Bool,
        onLifecycleEvent: @escaping (String) -> Void
    ) {
        self.flushManager = flushManager
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
