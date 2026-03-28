import UIKit

/// Wireframe capture engine.
///
/// Recursively traverses the live `UIView` hierarchy and collects it as a
/// **pre-flattened** array of node dictionaries ready for JSON encoding.
/// No intermediate JSON serialization step — nodes are built directly.
final class SankofaWireframeEngine: SankofaCaptureEngine {

    private let sessionId: String

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    // KILLER 4 (Concurrency): @MainActor prevents Main Thread Checker crashes
    @MainActor
    func captureFrame(completion: @escaping (SankofaFrame?) -> Void) {
        guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) else {
            completion(nil)
            return
        }

        // 🚨 MAIN THREAD SAFETY: Read the entire view hierarchy synchronously
        // on the main thread, producing a pre-flattened node array.
        var flatNodes: [[String: Any]] = []
        self.collectNodes(from: window, in: window, into: &flatNodes)

        // Payload: pass the flat nodes array directly — no JSON roundtrip needed.
        let frame = SankofaFrame(
            sessionId: sessionId,
            timestamp: Date(),
            payload: .wireframeNodes(flatNodes)
        )
        completion(frame)
    }

    // MARK: - Flat Node Collection

    /// Recursively collects view nodes into a pre-allocated flat array (DFS order).
    private func collectNodes(from view: UIView, in window: UIWindow, into output: inout [[String: Any]]) {
        // 💨 PERFORMANCE & FIDELITY: Skip hidden/fully-transparent views (PostHog optimization)
        guard !view.isHidden && view.alpha > 0.01 else { return }

        let f = view.convert(view.bounds, to: window)
        
        var node: [String: Any] = [
            "t": self.typeName(of: view),
            "x": self.safeDouble(f.origin.x),
            "y": self.safeDouble(f.origin.y),
            "w": self.safeDouble(f.size.width),
            "h": self.safeDouble(f.size.height)
        ]

        // 🎨 VISUALS: Extract background color as hex for web reconstruction
        if let bgColor = view.backgroundColor {
            node["bg"] = bgColor.sankofa_toHexString()
        }
        
        if view.alpha < 0.99 {
            node["a"] = self.safeDouble(view.alpha)
        }

        // 📝 TEXT: Only from safe, non-sensitive view types
        if let label = view as? UILabel {
            node["v"] = self.sanitize(label.text)
        } else if let button = view as? UIButton {
            node["v"] = self.sanitize(button.currentTitle)
        } else if view is UITextField || view is UITextView {
            node["v"] = "[masked]"
        }

        output.append(node)

        // Recurse into subviews
        for sub in view.subviews {
            self.collectNodes(from: sub, in: window, into: &output)
        }
    }

    // MARK: - Helpers

    private func typeName(of view: UIView) -> String {
        switch view {
        case is UILabel:          return "text"
        case is UIButton:         return "button"
        case is UITextField:      return "input"
        case is UITextView:       return "input"
        case is UIImageView:      return "media"
        case is UISwitch:         return "toggle"
        case is UISlider:         return "slider"
        case is UITableView:      return "list"
        case is UICollectionView: return "grid"
        default:                  return "view"
        }
    }

    private func safeDouble(_ value: CGFloat) -> Double {
        let d = Double(value)
        return d.isFinite ? d : 0.0
    }

    private func sanitize(_ text: String?) -> String {
        guard let text = text, !text.isEmpty else { return "" }
        var result = ""
        result.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x00, 0x01...0x08, 0x0B...0x0C, 0x0E...0x1F, 0x7F, 0x80...0x9F, 0x2028, 0x2029:
                continue
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

// MARK: - Visual Helpers

extension UIColor {
    func sankofa_toHexString() -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        self.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", 
                      Int(r * 255), 
                      Int(g * 255), 
                      Int(b * 255))
    }
}
