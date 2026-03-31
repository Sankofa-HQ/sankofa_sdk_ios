import UIKit
import UIKit.UIGestureRecognizerSubclass

/// A non-intrusive touch interceptor that captures interactions for session replay.
///
/// By using a `UIGestureRecognizer` attached to the key window with `cancelsTouchesInView = false`,
/// we can observe all touch events without swizzling or interfering with the app's UI.
///
/// ## Critical Implementation Notes
/// 1. We MUST transition `.state` through `.began → .changed → .ended` so the
///    system doesn't cancel our recognizer when other gesture recognizers fire.
/// 2. `cancelsTouchesInView`, `delaysTouchesBegan`, and `delaysTouchesEnded` are
///    all set to `false` so the app's own gesture system is completely unaffected.
final class SankofaTouchInterceptor: UIGestureRecognizer {

    struct Interaction {
        let type: String // "pointer_down", "pointer_up", "pointer_move"
        let x: CGFloat
        let y: CGFloat
        let timestamp: Date
    }

    private(set) var pendingInteractions: [Interaction] = []
    private let queue = DispatchQueue(label: "dev.sankofa.replay.touch")

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        // CRITICAL: All three must be false so we don't interfere with the host app
        self.cancelsTouchesInView = false
        self.delaysTouchesBegan = false
        self.delaysTouchesEnded = false
    }

    func flush() -> [Interaction] {
        return queue.sync {
            let current = pendingInteractions
            pendingInteractions.removeAll()
            return current
        }
    }

    // MARK: - Touch Tracking

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // CRITICAL: Transition to .began so the system doesn't cancel us
        self.state = .began
        record(touches, type: "pointer_down")
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        self.state = .changed
        record(touches, type: "pointer_move")
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        self.state = .ended
        record(touches, type: "pointer_up")
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        self.state = .cancelled
        record(touches, type: "pointer_up")
    }

    // Allow simultaneous recognition with ALL other gesture recognizers
    // so we never block the app's own gestures.
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }

    override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }

    private func record(_ touches: Set<UITouch>, type: String) {
        guard let touch = touches.first, let view = self.view else { return }
        let location = touch.location(in: view)
        
        queue.async {
            self.pendingInteractions.append(Interaction(
                type: type,
                x: location.x,
                y: location.y,
                timestamp: Date()
            ))
        }
    }
}
