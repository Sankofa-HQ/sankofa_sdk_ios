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

    func captureFrame() -> SankofaFrame? {
        guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) else {
            return nil
        }

        let tree = serializeView(window)

        guard let data = try? JSONSerialization.data(withJSONObject: tree) else {
            return nil
        }

        return SankofaFrame(
            sessionId: sessionId,
            timestamp: Date(),
            payload: .wireframe(data)
        )
    }

    // MARK: - View Tree Serialization

    private func serializeView(_ view: UIView) -> [String: Any] {
        var node: [String: Any] = [
            "$type": typeName(of: view),
            "$frame": frameDict(view.frame),
            "$hidden": view.isHidden,
            "$alpha": view.alpha,
        ]

        // Extract text content where safe (not from secure fields)
        if let label = view as? UILabel {
            node["$text"] = label.text ?? ""
        } else if let button = view as? UIButton {
            node["$text"] = button.currentTitle ?? ""
        } else if let textField = view as? UITextField {
            // Never capture text content from text fields
            node["$text"] = "[masked]"
            node["$masked"] = true
        } else if let textView = view as? UITextView {
            node["$text"] = "[masked]"
            node["$masked"] = true
        }

        // Recurse into visible subviews
        let children = view.subviews
            .filter { !$0.isHidden && $0.alpha > 0.01 }
            .map { serializeView($0) }

        if !children.isEmpty {
            node["$children"] = children
        }

        return node
    }

    private func typeName(of view: UIView) -> String {
        switch view {
        case is UILabel:      return "Label"
        case is UIButton:     return "Button"
        case is UITextField:  return "TextField"
        case is UITextView:   return "TextView"
        case is UIImageView:  return "Image"
        case is UIScrollView: return "ScrollView"
        case is UISwitch:     return "Switch"
        case is UISlider:     return "Slider"
        case is UITableView:  return "TableView"
        case is UICollectionView: return "CollectionView"
        default:              return "View"
        }
    }

    private func frameDict(_ rect: CGRect) -> [String: CGFloat] {
        ["x": rect.origin.x, "y": rect.origin.y, "w": rect.size.width, "h": rect.size.height]
    }
}
