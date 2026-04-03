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
        let absoluteY: CGFloat
        let scrollOffsetY: CGFloat
        let screen: String
        let timestamp: Date
    }

    private(set) var pendingInteractions: [Interaction] = []
    private let queue = DispatchQueue(label: "dev.sankofa.replay.touch")
    private let screenNameProvider: () -> String

    init(screenNameProvider: @escaping () -> String) {
        self.screenNameProvider = screenNameProvider
        super.init(target: nil, action: nil)
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
        record(touches, type: "pointer_down", with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        // Still .possible — we receive all moves without holding any gate.
        record(touches, type: "pointer_move", with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        record(touches, type: "pointer_up", with: event)
        // .failed forces an immediate reset to .possible for the next touch sequence.
        // This is cleaner than .ended for a non-recognizing recognizer because it
        // explicitly signals to the system that we didn't "win" this sequence.
        self.state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        record(touches, type: "pointer_up", with: event)
        self.state = .failed
    }

    // We never prevent other recognizers from firing (we're a passive observer).
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }

    // We CAN be superseded by any recognizer — including system recognizers.
    // Returning false here was wrong: it told iOS "you can't cancel me", which forced
    // the system gate to wait for us even during system gestures. Now we yield properly.
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }

    private func record(_ touches: Set<UITouch>, type: String, with event: UIEvent? = nil) {
        guard let firstTouch = touches.first, let window = self.view as? UIWindow else { return }
        
        var location = firstTouch.location(in: window)
        var interactionType = type
        
        // 🔍 Pinch & Zoom Detection (Midpoint Tracking via All Touches)
        // We use event?.allTouches to see the full state of the screen, not just the subset
        // of touches that moved in this specific frame.
        if let allTouches = event?.touches(for: window), allTouches.count == 2 {
            let touchesArray = Array(allTouches)
            let p1 = touchesArray[0].location(in: window)
            let p2 = touchesArray[1].location(in: window)
            location = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
            interactionType = "pinch"
        }
        
        // 🚀 Infinite Scroll Support: Find active scroll offset
        var scrollOffsetY: CGFloat = 0
        if let scrollView = findActiveScrollView(in: window) {
            scrollOffsetY = scrollView.contentOffset.y
        }
        
        let absoluteY = location.y + scrollOffsetY
        let screen = screenNameProvider()
        
        queue.async {
            self.pendingInteractions.append(Interaction(
                type: interactionType,
                x: location.x,
                y: location.y,
                absoluteY: absoluteY,
                scrollOffsetY: scrollOffsetY,
                screen: screen,
                timestamp: Date()
            ))
        }
    }
    
    private func findActiveScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView, scrollView.isScrollEnabled {
            return scrollView
        }
        for subview in view.subviews {
            if let found = findActiveScrollView(in: subview) {
                return found
            }
        }
        return nil
    }
}
