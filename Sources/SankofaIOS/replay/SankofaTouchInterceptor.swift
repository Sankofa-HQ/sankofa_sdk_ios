import UIKit
import UIKit.UIGestureRecognizerSubclass

/// A non-intrusive touch interceptor that captures interactions for session replay.
///
/// By using a `UIGestureRecognizer` attached to the key window with `cancelsTouchesInView = false`,
/// we can observe all touch events without swizzling or interfering with the app's UI.
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
        self.cancelsTouchesInView = false
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
        super.touchesBegan(touches, with: event)
        record(touches, type: "pointer_down")
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        // Optionally throttle move events if needed
        record(touches, type: "pointer_move")
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        record(touches, type: "pointer_up")
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        record(touches, type: "pointer_up")
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
