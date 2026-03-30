import UIKit

/// Wireframe capture engine.
///
/// Recursively traverses the live `UIView` hierarchy and collects it as a
/// **pre-flattened** array of node dictionaries ready for JSON encoding.
/// No intermediate JSON serialization step — nodes are built directly.
final class SankofaWireframeEngine: SankofaCaptureEngine {

    private let sessionId: String
    private var lastTreeSignature: String = ""

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

        // 💨 Idle Detection: Compare signature to avoid flooding identical frames
        let currentSignature = self.generateSignature(for: flatNodes)
        guard currentSignature != lastTreeSignature else {
            // Screen is static; skip this frame to save bandwidth/battery
            completion(nil)
            return
        }
        lastTreeSignature = currentSignature

        // Payload: pass the flat nodes array directly — no JSON roundtrip needed.
        let frame = SankofaFrame(
            sessionId: sessionId,
            timestamp: Date(),
            payload: .wireframeNodes(flatNodes)
        )
        completion(frame)
    }

    private func generateSignature(for nodes: [[String: Any]]) -> String {
        // A simple signature: join the type, x, y, and value of every node.
        // This is much faster than full JSON serialization but catches almost all UI changes.
        return nodes.map { node in
            let t = node["t"] as? String ?? ""
            let x = node["x"] as? Double ?? 0
            let y = node["y"] as? Double ?? 0
            let v = node["v"] as? String ?? ""
            return "\(t)\(Int(x))\(Int(y))\(v)"
        }.joined(separator: "|")
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

        // 🎨 VISUALS: Richer properties for better reconstruction
        if let bgColor = view.backgroundColor {
            node["bg"] = bgColor.sankofa_toHexString()
        }
        
        if view.alpha < 0.99 {
            node["a"] = self.safeDouble(view.alpha)
        }

        if view.layer.cornerRadius > 0 {
            node["cr"] = self.safeDouble(view.layer.cornerRadius)
        }

        if view.layer.borderWidth > 0 {
            node["bw"] = self.safeDouble(view.layer.borderWidth)
            if let borderColor = view.layer.borderColor {
                node["bc"] = UIColor(cgColor: borderColor).sankofa_toHexString()
            }
        }

        // 📝 TEXT & IMAGES: Handle more types, including SwiftUI and Navigation items
        if let label = view as? UILabel {
            node["v"] = self.sanitize(label.text)
            node["fs"] = self.safeDouble(label.font.pointSize)
            node["fc"] = label.textColor.sankofa_toHexString()
        } else if let button = view as? UIButton {
            node["v"] = self.sanitize(button.currentTitle)
            if let label = button.titleLabel {
                node["fs"] = self.safeDouble(label.font.pointSize)
                if let color = button.titleColor(for: .normal) {
                    node["fc"] = color.sankofa_toHexString()
                }
            }
        } else if view is UITextField || view is UITextView {
            node["v"] = "[masked]"
        } else if let imageView = view as? UIImageView {
            // Use accessibility label as a fallback to describe images in wireframes
            if let alt = imageView.accessibilityLabel {
                node["v"] = self.sanitize(alt)
                node["v_type"] = "alt"
            }
        } else if let navBar = view as? UINavigationBar {
            node["v"] = self.sanitize(navBar.topItem?.title)
        } else if let seg = view as? UISegmentedControl {
            let idx = seg.selectedSegmentIndex
            if idx >= 0 {
                node["v"] = self.sanitize(seg.titleForSegment(at: idx))
            }
        } else if String(describing: type(of: view)).contains("UIHostingView") {
            // 🎯 SWIFTUI FIX: Extract text from SwiftUI hosting views by searching sub-labels
            if let swiftUIText = self.findSwiftUIText(in: view) {
                node["v"] = swiftUIText
            }
        }

        output.append(node)

        // Recurse into subviews
        for sub in view.subviews {
            self.collectNodes(from: sub, in: window, into: &output)
        }
    }

    /// Recursively search for a label inside a view (used for SwiftUI text extraction).
    private func findSwiftUIText(in view: UIView) -> String? {
        if let label = view as? UILabel {
            let text = self.sanitize(label.text)
            return text.isEmpty ? nil : text
        }
        for sub in view.subviews {
            if let found = findSwiftUIText(in: sub) {
                return found
            }
        }
        return nil
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
