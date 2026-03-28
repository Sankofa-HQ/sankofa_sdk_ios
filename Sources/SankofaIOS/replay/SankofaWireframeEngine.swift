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

    func captureFrame(completion: @escaping (SankofaFrame?) -> Void) {
        guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) else {
            completion(nil)
            return
        }

        // 🚨 MAIN THREAD SAFETY: Read the entire view hierarchy synchronously
        // on the main thread, producing a pre-flattened node array.
        var flatNodes: [[String: Any]] = []
        collectNodes(from: window, into: &flatNodes)

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
    private func collectNodes(from view: UIView, into output: inout [[String: Any]]) {
        let f = view.frame
        var node: [String: Any] = [
            "t": self.typeName(of: view),
            "x": self.safeDouble(f.origin.x),
            "y": self.safeDouble(f.origin.y),
            "w": self.safeDouble(f.size.width),
            "h": self.safeDouble(f.size.height)
        ]

        // Capture text content — only from safe view types
        if let label = view as? UILabel {
            node["v"] = self.sanitize(label.text)
        } else if let button = view as? UIButton {
            node["v"] = self.sanitize(button.currentTitle)
        } else if view is UITextField || view is UITextView {
            node["v"] = "[masked]"
        }

        output.append(node)

        // Recurse into visible, non-transparent subviews
        for sub in view.subviews where !sub.isHidden && sub.alpha > 0.01 {
            self.collectNodes(from: sub, into: &output)
        }
    }

    // MARK: - Helpers

    /// Converts CGFloat to Double, clamping NaN and Infinity to 0.
    private func safeDouble(_ value: CGFloat) -> Double {
        let d = Double(value)
        return d.isFinite ? d : 0.0
    }

    /// Removes JSON-breaking characters from text:
    /// - C0 control chars (U+0000–U+001F) except safe whitespace (\t \n \r)
    /// - U+2028 LINE SEPARATOR and U+2029 PARAGRAPH SEPARATOR
    ///   (treated as newlines by JS's JSON.parse, breaking string literals)
    private func sanitize(_ text: String?) -> String {
        guard let text = text, !text.isEmpty else { return "" }
        var result = ""
        result.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x00:          continue  // null byte
            case 0x01...0x08:   continue  // C0 controls
            case 0x0B...0x0C:   continue  // vertical tab, form feed
            case 0x0E...0x1F:   continue  // remaining C0 controls
            case 0x7F:          continue  // DEL
            case 0x80...0x9F:   continue  // C1 controls
            case 0x2028, 0x2029: continue // JS line/paragraph separators
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private func typeName(of view: UIView) -> String {
        switch view {
        case is UILabel:          return "text"
        case is UIButton:         return "button"
        case is UITextField:      return "text" // Map to text for now
        case is UITextView:       return "text" // Map to text for now
        case is UIImageView:      return "media"
        case is UISwitch:         return "button"
        case is UISlider:         return "media"
        case is UITableView:      return "View" // Generic base
        case is UICollectionView: return "View" // Generic base
        default:                  return "View"
        }
    }
}
