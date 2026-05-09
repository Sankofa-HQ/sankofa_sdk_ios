import Foundation

/// Handle returned by `Sankofa.shared.tagScrollContainer { ... }` —
/// used by the host to unregister the scroll-offset provider when the
/// scrollable leaves scope (typically a SwiftUI `.onDisappear` or a
/// `UIViewController.deinit`).
///
/// Removing the handle multiple times is safe (idempotent).
@objc
public final class SankofaScrollContainerHandle: NSObject {
    private let onRemove: () -> Void
    private var removed = false
    private let lock = NSLock()

    internal init(onRemove: @escaping () -> Void) {
        self.onRemove = onRemove
    }

    /// Stop forwarding scroll offsets to the heatmap pipeline.
    ///
    /// Typically called from a SwiftUI `.onDisappear` block or a
    /// `UIViewController.deinit`.  Idempotent.
    @objc
    public func remove() {
        lock.lock()
        let shouldRemove = !removed
        removed = true
        lock.unlock()
        if shouldRemove {
            onRemove()
        }
    }
}
