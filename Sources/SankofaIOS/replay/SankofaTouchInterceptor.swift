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

    // ── Move-event rate limiting ──────────────────────────────────────────
    // touchesMoved fires up to 120 times per second on a 120Hz iPad and
    // ~60Hz on iPhone.  Without throttling, a single 5-second swipe used to
    // produce 600+ rows in replay_interactions, inflating "Gestures on
    // Screen" by 100x and triggering false rage-tap clusters.
    //
    // Throttle = max 1 move sample per 50ms (~20 Hz, same as web SDK).
    // Coalesce  = drop moves whose (x,y) is within MOVE_COALESCE_PX of the
    //             last recorded move on the same screen — eliminates jitter
    //             samples while a finger is held still.
    private static let MOVE_THROTTLE_INTERVAL: TimeInterval = 0.05
    private static let MOVE_COALESCE_PX: CGFloat = 4
    private var lastMoveSampleAt: TimeInterval = 0
    private var lastMoveX: CGFloat = -9999
    private var lastMoveY: CGFloat = -9999

    // ── Double-tap recognition ────────────────────────────────────────────
    // When a touchesBegan event lands within DOUBLE_TAP_INTERVAL seconds and
    // DOUBLE_TAP_RADIUS_PX of the previous touchesBegan, we emit an
    // additional "double_tap" Interaction at the same coordinates.  The
    // dashboard reads this as interaction_type = 4 and renders a "2×"
    // marker overlay distinct from regular taps.
    private static let DOUBLE_TAP_INTERVAL: TimeInterval = 0.35
    private static let DOUBLE_TAP_RADIUS_PX: CGFloat = 25
    private var lastTapAt: TimeInterval = 0
    private var lastTapX: CGFloat = -9999
    private var lastTapY: CGFloat = -9999

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

    /// Evaluates the current scroll offset of the key window.
    /// Useful for idle-snapping when no interactions have occurred recently.
    var currentScrollOffsetY: CGFloat {
        guard let window = self.view as? UIWindow else { return 0 }
        if let scrollView = findActiveScrollView(in: window) {
            return scrollView.contentOffset.y
        }
        return 0
    }

    // MARK: - Touch Tracking

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // A new touch sequence resets the move tracker so the first move
        // sample after the down is always recorded.
        lastMoveSampleAt = 0
        lastMoveX = -9999
        lastMoveY = -9999
        record(touches, type: "pointer_down", with: event)

        // ── Double-tap recognition ───────────────────────────────────────
        // Use the FIRST touch's window-relative location for the recognizer
        // (single-finger taps only — multi-touch begins skip this branch).
        guard let firstTouch = touches.first,
              let window = self.view as? UIWindow,
              event.touches(for: window)?.count ?? 1 == 1
        else { return }

        let location = firstTouch.location(in: window)
        let now = CACurrentMediaTime()
        let dt = now - lastTapAt
        let dx = location.x - lastTapX
        let dy = location.y - lastTapY
        let isDouble =
            lastTapAt > 0 &&
            dt < Self.DOUBLE_TAP_INTERVAL &&
            dx * dx + dy * dy <
                Self.DOUBLE_TAP_RADIUS_PX * Self.DOUBLE_TAP_RADIUS_PX

        if isDouble {
            // Emit a synthetic double_tap Interaction at the same coordinates.
            // We bypass record() so the move-coalesce + scroll-resolve logic
            // doesn't double-count work — the cheap path is sufficient since
            // we just resolved the location above.
            var scrollOffsetY: CGFloat = 0
            if let scrollView = findActiveScrollView(in: window) {
                scrollOffsetY = scrollView.contentOffset.y
            }
            let absoluteY = location.y + scrollOffsetY
            let screen = screenNameProvider()
            queue.async {
                self.pendingInteractions.append(Interaction(
                    type: "double_tap",
                    x: location.x,
                    y: location.y,
                    absoluteY: absoluteY,
                    scrollOffsetY: scrollOffsetY,
                    screen: screen,
                    timestamp: Date()
                ))
            }
            // Reset so a third tap doesn't fire another double-tap.
            lastTapAt = 0
            lastTapX = -9999
            lastTapY = -9999
        } else {
            lastTapAt = now
            lastTapX = location.x
            lastTapY = location.y
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        // Throttle to MOVE_THROTTLE_INTERVAL — drop the rest of the frames in
        // the current 50ms window so we don't spam the queue with hundreds of
        // identical samples on a slow drag.
        let now = CACurrentMediaTime()
        if now - lastMoveSampleAt < Self.MOVE_THROTTLE_INTERVAL {
            return
        }
        lastMoveSampleAt = now
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

        // Spatial coalesce — drop pointer_move samples that haven't moved
        // more than MOVE_COALESCE_PX from the previous sample.  Only applies
        // to "pointer_move"; "pointer_down" and "pointer_up" always get through.
        if interactionType == "pointer_move" {
            let dx = location.x - lastMoveX
            let dy = location.y - lastMoveY
            if dx * dx + dy * dy <
                Self.MOVE_COALESCE_PX * Self.MOVE_COALESCE_PX {
                return
            }
            lastMoveX = location.x
            lastMoveY = location.y
        }

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
