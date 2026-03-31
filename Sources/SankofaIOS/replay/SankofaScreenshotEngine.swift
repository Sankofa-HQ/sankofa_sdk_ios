import UIKit
import ImageIO
import UniformTypeIdentifiers

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
    private let captureScale: CGFloat
    
    // 🚀 Anti-Flood: Cache the last frame to prevent uploading identical static screens
    private var lastImageData: Data?
    private let lock = NSLock()

    init(sessionId: String, maskAllInputs: Bool, captureScale: CGFloat = 0.35) {
        self.sessionId = sessionId
        self.maskAllInputs = maskAllInputs
        self.captureScale = captureScale
    }

    // MARK: - SankofaCaptureEngine

    @MainActor
    func captureFrame(completion: @escaping (SankofaFrame?) -> Void) {
        guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) else {
            completion(nil)
            return
        }

        let sensitiveRects = collectSensitiveRects(in: window)

        let format = UIGraphicsImageRendererFormat()
        format.scale = captureScale
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)

        let maskedImage = renderer.image { ctx in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            ctx.cgContext.setFillColor(UIColor.black.cgColor)
            for rect in sensitiveRects {
                ctx.cgContext.fill(rect)
            }
        }

        // 🚀 Compress on background thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // 🚀 FAST WEBP ENCODING via Apple's ImageIO
            var finalData: Data? = nil
            
            if let cgImage = maskedImage.cgImage {
                let mutableData = NSMutableData()
                if let destination = CGImageDestinationCreateWithData(mutableData, UTType.webP.identifier as CFString, 1, nil) {
                    let options: [CFString: Any] = [
                        kCGImageDestinationLossyCompressionQuality: 0.3
                    ]
                    CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
                    if CGImageDestinationFinalize(destination) {
                        finalData = mutableData as Data
                    }
                }
            }
            
            // Fallback to JPEG if WebP encoding fails on older hardware
            if finalData == nil {
                finalData = maskedImage.jpegData(compressionQuality: 0.3)
            }
            
            guard let data = finalData else {
                completion(nil)
                return
            }
            
            // 🚀 ANTI-FLOOD CHECK: Drop identical frames
            self.lock.lock()
            if data == self.lastImageData {
                self.lock.unlock()
                completion(nil)
                return
            }
            self.lastImageData = data
            self.lock.unlock()

            let frame = SankofaFrame(
                sessionId: self.sessionId,
                timestamp: Date(),
                payload: .screenshot(data)
            )
            completion(frame)
        }
    }

    // MARK: - Sensitive Rect Collection

    private func collectSensitiveRects(in window: UIWindow) -> [CGRect] {
        var rects: [CGRect] = []
        collectRectsRecursively(view: window, window: window, rects: &rects)
        return rects
    }

    private func collectRectsRecursively(view: UIView, window: UIWindow, rects: inout [CGRect]) {
        let isSensitive: Bool = {
            if maskAllInputs && (view is UITextField || view is UITextView) { return true }
            if view is UISwitch { return true }
            if (view.layer.value(forKey: SankofaMaskKey) as? Bool) == true { return true }
            if (view.tag == SankofaMaskTagValue) { return true }
            return false
        }()

        if isSensitive {
            rects.append(view.convert(view.bounds, to: window))
            return
        }
        for subview in view.subviews {
            collectRectsRecursively(view: subview, window: window, rects: &rects)
        }
    }
}
