import UIKit

/// Screenshot engine using Ghost Masking — CoreGraphics in-memory rendering.
///
/// ## Key Design Constraint
/// The live `UIView` hierarchy is **never modified**. No views are added,
/// removed, or resized at any point. Black masks are drawn directly onto an
/// in-memory `UIGraphicsImageRenderer` context — the user's screen remains
/// smooth and unchanged at all times.
///
/// This directly solves the "black flash" problem seen in Flutter SDKs that
/// inject `Container` overlays into the widget tree before screenshotting.
final class SankofaScreenshotEngine: SankofaCaptureEngine {

    private let sessionId: String
    private let maskAllInputs: Bool

    init(sessionId: String, maskAllInputs: Bool) {
        self.sessionId = sessionId
        self.maskAllInputs = maskAllInputs
    }

    // MARK: - SankofaCaptureEngine

    func captureFrame() -> SankofaFrame? {
        guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) else {
            return nil
        }

        // Collect sensitive rects BEFORE entering the renderer context.
        // `view.convert` must run on the main thread.
        let sensitiveRects = collectSensitiveRects(in: window)

        // ─── In-Memory Canvas ────────────────────────────────────────────────
        // UIGraphicsImageRenderer creates a detached CoreGraphics context.
        // The physical display is never touched.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0 // Keep at 1× to control file size.

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)

        let maskedImage = renderer.image { ctx in
            // Step A: Draw the current window into our invisible canvas.
            // `afterScreenUpdates: false` uses the currently committed frame —
            // fastest, and avoids any pending layout pass.
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)

            // Step B: Paint solid black over every sensitive coordinate.
            // This happens on the canvas — not on screen.
            ctx.cgContext.setFillColor(UIColor.black.cgColor)
            for rect in sensitiveRects {
                ctx.cgContext.fill(rect)
            }
        }
        // ─────────────────────────────────────────────────────────────────────

        // Compress off the main thread to prevent any UI stutter.
        let capturedImage = maskedImage // Capture for background queue
        var jpegData: Data? = nil
        let compressionGroup = DispatchGroup()
        compressionGroup.enter()
        DispatchQueue.global(qos: .background).async {
            jpegData = capturedImage.jpegData(compressionQuality: 0.3)
            compressionGroup.leave()
        }
        compressionGroup.wait()

        guard let data = jpegData else { return nil }

        return SankofaFrame(
            sessionId: sessionId,
            timestamp: Date(),
            payload: .screenshot(data)
        )
    }

    // MARK: - Sensitive Rect Collection

    /// Recursively walks the view tree and collects the global `CGRect` for
    /// every sensitive view (`UITextField`, `UITextView`, `UISwitch`, and any
    /// view tagged with `sankofaMask = true`).
    ///
    /// Coordinates are converted from local view space to window space so they
    /// align precisely with the rendered `window.drawHierarchy` output.
    private func collectSensitiveRects(in window: UIWindow) -> [CGRect] {
        var rects: [CGRect] = []
        collectRectsRecursively(view: window, window: window, rects: &rects)
        return rects
    }

    private func collectRectsRecursively(view: UIView, window: UIWindow, rects: inout [CGRect]) {
        let isSensitive: Bool = {
            if maskAllInputs && (view is UITextField || view is UITextView) { return true }
            if view is UISwitch { return true }
            // Respect manual mask tagging (UIView extension or tag)
            if (view.layer.value(forKey: SankofaMaskKey) as? Bool) == true { return true }
            if (view.tag == SankofaMaskTagValue) { return true }
            return false
        }()

        if isSensitive {
            let globalRect = view.convert(view.bounds, to: window)
            rects.append(globalRect)
            // No need to recurse into masked views.
            return
        }

        for subview in view.subviews {
            collectRectsRecursively(view: subview, window: window, rects: &rects)
        }
    }
}
