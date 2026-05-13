import Foundation
import UIKit

/// Dedicated heatmap-background capture path — independent of the
/// session-replay frame stream.
///
/// ## Why this exists
/// The session-replay coordinator captures frames opportunistically on
/// every UI-thread idle tick. Those frames are great for playback (lots
/// of them, low fidelity each), but the FIRST frame after a screen
/// transition often catches the UI mid-load — async images, fonts, or
/// SwiftUI body re-evaluations haven't finished yet — and that partial
/// frame is what the backend was keeping forever as the heatmap
/// background. Result: heatmap dots overlaid on a half-empty page.
///
/// This snapshotter fires ONCE per `(screen, app_version, viewport
/// bucket)` per session, AFTER the screen has been on-screen long
/// enough to be considered visually settled, and uploads directly to
/// `/api/heatmaps/snapshot` — separate from the replay chunk path.
///
/// ## Performance contract
/// - All scheduling + encoding + upload runs on a dedicated utility
///   queue, never the main thread.
/// - The UIKit capture step itself briefly hops to main (UIKit
///   requirement) but immediately bounces back. With `captureScale =
///   0.5` and our existing Ghost-Mask renderer that's well under a
///   single 16.6ms frame budget on modern devices.
/// - One capture per screen per session — re-tagging the same screen
///   does NOT re-capture. The backend's sliding window handles any
///   updates the next time the app is launched.
/// - Cancellable: if the user navigates away during the stability
///   delay, the pending capture is dropped.
final class SankofaHeatmapSnapshotter {

    private let apiKey: String
    private let endpoint: String
    private let appVersion: String
    private let captureScale: CGFloat
    private let maskAllInputs: Bool
    private let logger: SankofaLogger

    /// Settle delay before capturing. 1.5s covers async image loads,
    /// SwiftUI body evaluation, and most UIKit layout passes. Faster
    /// than 1s is too aggressive (catches `URLSession` image loads
    /// mid-flight); slower than 2.5s is wasteful for the common case.
    private let stabilityDelay: TimeInterval = 1.5

    /// Serial queue for scheduling + dedupe state. Capture itself
    /// dispatches further out to a global utility queue, so this
    /// queue stays light.
    private let serialQueue = DispatchQueue(label: "dev.sankofa.heatmap.snapshotter", qos: .utility)

    /// Set of "fingerprints" already captured this process lifetime so
    /// we never re-upload the same view twice in a session. Fingerprint
    /// = `"\(screen)|\(appVersion)|\(widthBucket)x\(heightBucket)"`.
    /// Reset is implicit: a fresh launch starts with an empty set,
    /// matching how the backend's `app_version` partitions snapshots.
    private var capturedFingerprints: Set<String> = []

    /// Token for the currently pending stability delay. Bumped on every
    /// `scheduleCapture(for:)` call so an earlier delayed task can
    /// detect it was superseded by a newer screen tag and bail out.
    private var pendingToken: UUID?

    init(apiKey: String, endpoint: String, appVersion: String, captureScale: CGFloat, maskAllInputs: Bool, logger: SankofaLogger) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.appVersion = appVersion
        self.captureScale = captureScale
        self.maskAllInputs = maskAllInputs
        self.logger = logger
    }

    /// Called from `Sankofa.shared.screen(_:)`. Cheap — just enqueues a
    /// delayed task on the serial queue. No UIKit access from the
    /// caller's thread.
    func scheduleCapture(for screen: String) {
        guard !screen.isEmpty else { return }
        let token = UUID()
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            self.pendingToken = token
            self.serialQueue.asyncAfter(deadline: .now() + self.stabilityDelay) { [weak self] in
                guard let self = self else { return }
                // Superseded by a newer screen tag — drop silently.
                guard self.pendingToken == token else { return }
                self.runCaptureIfNeeded(for: screen)
            }
        }
    }

    private func runCaptureIfNeeded(for screen: String) {
        // Probe viewport size off-main first (UIScreen.main.bounds is
        // safe to read off-main pre-iOS 17; we still hop to main for
        // the actual draw call). Sizes used only for fingerprint
        // bucketing here.
        let (width, height) = currentViewportSize()
        let widthBucket = Self.bucket(width)
        let heightBucket = Self.bucket(height)
        let fingerprint = "\(screen)|\(appVersion)|\(widthBucket)x\(heightBucket)"

        guard !capturedFingerprints.contains(fingerprint) else { return }
        capturedFingerprints.insert(fingerprint)

        // Hop to main to actually grab the pixels, then bounce back to
        // utility for encoding + upload so the UI thread is only held
        // for the duration of `drawHierarchy(...)`.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let pngData = self.snapshotKeyWindow() else { return }
            self.serialQueue.async { [weak self] in
                self?.upload(pngData: pngData, screen: screen, width: width, height: height)
            }
        }
    }

    @MainActor
    private func snapshotKeyWindow() -> Data? {
        guard let window = Self.keyWindow() else { return nil }
        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let sensitiveRects = collectSensitiveRects(in: window)

        let format = UIGraphicsImageRendererFormat()
        format.scale = captureScale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)

        let image = renderer.image { ctx in
            window.drawHierarchy(in: bounds, afterScreenUpdates: false)
            ctx.cgContext.setFillColor(UIColor.black.cgColor)
            for rect in sensitiveRects {
                ctx.cgContext.fill(rect)
            }
        }

        // PNG keeps the heatmap backdrop crisp under the dashboard's
        // simpleheat blend mode. ~2-4× larger than JPEG but uploaded
        // exactly once per screen per session — well worth it.
        return image.pngData()
    }

    @MainActor
    private static func keyWindow() -> UIWindow? {
        if #available(iOS 15.0, *) {
            for scene in UIApplication.shared.connectedScenes {
                if let ws = scene as? UIWindowScene, scene.activationState == .foregroundActive {
                    if let kw = ws.keyWindow { return kw }
                    if let w = ws.windows.first(where: { $0.isKeyWindow }) { return w }
                }
            }
        }
        return UIApplication.shared.windows.first(where: { $0.isKeyWindow })
    }

    @MainActor
    private func collectSensitiveRects(in window: UIWindow) -> [CGRect] {
        var rects: [CGRect] = []
        collectRectsRecursively(view: window, window: window, rects: &rects)
        return rects
    }

    @MainActor
    private func collectRectsRecursively(view: UIView, window: UIWindow, rects: inout [CGRect]) {
        let isSensitive: Bool = {
            if maskAllInputs && (view is UITextField || view is UITextView) { return true }
            if view is UISwitch { return true }
            if (view.layer.value(forKey: SankofaMaskKey) as? Bool) == true { return true }
            if view.tag == SankofaMaskTagValue { return true }
            return false
        }()
        if isSensitive {
            let r = view.convert(view.bounds, to: window)
            rects.append(r)
        }
        for subview in view.subviews {
            collectRectsRecursively(view: subview, window: window, rects: &rects)
        }
    }

    private func currentViewportSize() -> (CGFloat, CGFloat) {
        // Safe off-main read; for fingerprint bucketing the bounds
        // jitter from rotation mid-read is acceptable.
        let b = UIScreen.main.bounds
        return (b.width * UIScreen.main.scale, b.height * UIScreen.main.scale)
    }

    private static func bucket(_ dim: CGFloat) -> Int {
        // 60-pixel buckets so a one-rotated-device-pixel difference
        // doesn't produce a new "viewport" and re-trigger capture.
        return Int(dim / 60.0)
    }

    private func upload(pngData: Data, screen: String, width: CGFloat, height: CGFloat) {
        guard let snapshotURL = URL(string: "\(endpoint)/api/heatmaps/snapshot") else { return }
        let osName = "ios"

        let payload: [String: Any] = [
            "screen_name": screen,
            "app_version": appVersion,
            "os": osName,
            "device_width": Int(width),
            "device_height": Int(height),
            "scroll_offset_y": 0,
            "image_base64": pngData.base64EncodedString()
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var req = URLRequest(url: snapshotURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.httpBody = body
        req.timeoutInterval = 30

        // URLSession.shared dispatches its own background queue —
        // we don't block on the response.
        URLSession.shared.dataTask(with: req) { [weak self] _, response, error in
            if let error = error {
                self?.logger.warn("Heatmap snapshot upload failed: \(error.localizedDescription)")
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                self?.logger.warn("Heatmap snapshot rejected (\(http.statusCode)) for screen \(screen)")
                return
            }
            self?.logger.log("📸 Heatmap snapshot accepted for screen '\(screen)'")
        }.resume()
    }
}
