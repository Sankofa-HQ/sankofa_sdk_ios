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
            "x": frame.origin.x,
            "y": frame.origin.y,
            "w": frame.size.width,
            "h": frame.size.height,
            "hidden": view.isHidden,
            "alpha": view.alpha
        ]

        // Extract text content where safe (not from secure fields)
        if let label = view as? UILabel {
            node["v"] = label.text ?? ""
        } else if let button = view as? UIButton {
            node["v"] = button.currentTitle ?? ""
        } else if let textField = view as? UITextField {
            // Never capture text content from text fields
            node["v"] = "[masked]"
            node["masked"] = true
        } else if let textView = view as? UITextView {
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
}
