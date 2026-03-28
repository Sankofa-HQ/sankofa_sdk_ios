import UIKit

/// Wireframe capture engine.
///
/// Recursively traverses the live `UIView` hierarchy and serialises it as a
/// lightweight JSON "DOM" — no images, no pixels. This is the default mode.
///
/// Advantages:
///   - Zero bandwidth compared to screenshots.
///   - 100% privacy-safe (no pixel data ever leaves the device).
///   - Works on any iOS 14+ device.
final class SankofaWireframeEngine: SankofaCaptureEngine {

    private let sessionId: String

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    func captureFrame(completion: @escaping (SankofaFrame?) -> Void) {
        guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) else {
            completion(nil)
            return
        }

        // 🚨 MAIN THREAD SAFETY: Reading `view.bounds`, `view.text`, and 
        // `view.subviews` MUST happen on the main thread.
        let tree = serializeView(window)

        // 🚀 Move expensive JSON serialization to a background thread to keep UI smooth.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            guard let data = try? JSONSerialization.data(withJSONObject: tree) else {
                completion(nil)
                return
            }

            let frame = SankofaFrame(
                sessionId: self.sessionId,
                timestamp: Date(),
                payload: .wireframe(data)
            )
            completion(frame)
        }
    }

    // MARK: - View Tree Serialization

    private func serializeView(_ view: UIView) -> [String: Any] {
        let frame = view.frame
        var node: [String: Any] = [
            "t": typeName(of: view),
            "x": safeFloat(frame.origin.x),
            "y": safeFloat(frame.origin.y),
            "w": safeFloat(frame.size.width),
            "h": safeFloat(frame.size.height),
            "hidden": view.isHidden,
            "alpha": safeFloat(view.alpha)
        ]

        // Extract text content where safe (not from secure fields)
        if let label = view as? UILabel {
            node["v"] = sanitizeText(label.text)
        } else if let button = view as? UIButton {
            node["v"] = sanitizeText(button.currentTitle)
        } else if view is UITextField || view is UITextView {
            // Never capture text content from input fields
            node["v"] = "[masked]"
            node["masked"] = true
        }

        // Recurse into visible subviews
        let children = view.subviews
            .filter { !$0.isHidden && $0.alpha > 0.01 }
            .map { serializeView($0) }

        if !children.isEmpty {
            node["c"] = children
        }

        return node
    }

    /// Clamps non-finite CGFloat values to 0 so JSONSerialization never sees NaN/Infinity.
    private func safeFloat(_ value: CGFloat) -> Double {
        let d = Double(value)
        return d.isFinite ? d : 0.0
    }

    /// Removes control characters and null bytes from text that could break JSON parsing.
    private func sanitizeText(_ text: String?) -> String {
        guard let text = text, !text.isEmpty else { return "" }
        // Remove null bytes, control characters (U+0000–U+001F except safe whitespace)
        let cleaned = text.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x00:          return false  // null byte
            case 0x01...0x08:   return false  // control characters
            case 0x0B...0x0C:   return false  // vertical tab, form feed
            case 0x0E...0x1F:   return false  // remaining controls
            default:            return true
            }
        }
        return String(String.UnicodeScalarView(cleaned))
    }

    private func typeName(of view: UIView) -> String {
        switch view {
        case is UILabel:          return "Label"
        case is UIButton:         return "Button"
        case is UITextField:      return "TextField"
        case is UITextView:       return "TextView"
        case is UIImageView:      return "Image"
        case is UIScrollView:     return "ScrollView"
        case is UISwitch:         return "Switch"
        case is UISlider:         return "Slider"
        case is UITableView:      return "TableView"
        case is UICollectionView: return "CollectionView"
        default:                  return "View"
        }
    }
}
