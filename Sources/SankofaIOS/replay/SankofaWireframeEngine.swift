import UIKit

/// Wireframe capture engine.
///
/// Recursively traverses the live `UIView` hierarchy and collects it as a
/// **pre-flattened** array of node dictionaries ready for JSON encoding.
/// No intermediate JSON serialization step — nodes are built directly.
final class SankofaWireframeEngine: SankofaCaptureEngine {

    private let sessionId: String
    private var nodeIdCounter = 1

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    // MARK: - SankofaCaptureEngine

    // KILLER 4 (Concurrency): @MainActor prevents Main Thread Checker crashes
    @MainActor
    func captureFrame(completion: @escaping (SankofaFrame?) -> Void) {
        guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) else {
            completion(nil)
            return
        }

        // 🎯 THE CHEAT CODE: Reset counter for every full snapshot
        nodeIdCounter = 1
        
        // 1. Crawl the view tree into a virtual DOM (rrweb style)
        let rootNode = self.crawlForRRWeb(view: window, window: window)
        
        // 2. Package into an rrweb "Full Snapshot" event (type: 2)
        let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
        let event: [String: Any] = [
            "type": 2, // FullSnapshot
            "timestamp": timestampMs,
            "data": [
                "node": rootNode,
                "initialOffset": ["left": 0, "top": 0]
            ]
        ]

        let frame = SankofaFrame(
            sessionId: sessionId,
            timestamp: Date(),
            payload: .rrwebEvent(event)
        )
        completion(frame)
    }

    // MARK: - rrweb Crawler

    @MainActor
    private func crawlForRRWeb(view: UIView, window: UIWindow) -> [String: Any] {
        let currentId = nodeIdCounter
        nodeIdCounter += 1
        
        let frame = view.convert(view.bounds, to: window)
        var children: [[String: Any]] = []
        
        // 🎨 CSS STYLING: Convert iOS properties to inline CSS for rrweb player
        let bgColor = view.backgroundColor?.sankofa_toHexString() ?? "transparent"
        var style = "position: absolute; left: \(Int(frame.origin.x))px; top: \(Int(frame.origin.y))px; width: \(Int(frame.width))px; height: \(Int(frame.height))px; background-color: \(bgColor);"
        
        if view.alpha < 0.99 {
            style += " opacity: \(view.alpha);"
        }

        var tagName = "div"
        var textContent: String? = nil
        
        // 🧩 TAG MAPPING: iOS UI -> Standard HTML
        if let label = view as? UILabel {
            tagName = "p"
            textContent = label.text
            let textColor = label.textColor.sankofa_toHexString()
            style += " color: \(textColor); font-size: \(Int(label.font.pointSize))px; font-family: sans-serif; overflow: hidden;"
        } else if let button = view as? UIButton {
            tagName = "button"
            textContent = button.currentTitle
            style += " border: none; text-align: center;"
        } else if view is UITextField || view is UITextView {
            tagName = "input"
            textContent = "[masked]"
            style += " border: 1px solid #ccc;"
        }
        
        // 🚜 RECURSION: Crawl subviews (PostHog optimization: skip hidden/transparent)
        for subview in view.subviews {
            if !subview.isHidden && subview.alpha > 0.01 {
                children.append(crawlForRRWeb(view: subview, window: window))
            }
        }
        
        // 📝 TEXT NODES: rrweb expects text as a separate child node (type: 3)
        if let text = textContent, !text.isEmpty {
            let tNodeId = nodeIdCounter
            nodeIdCounter += 1
            children.append([
                "id": tNodeId,
                "type": 3, // TextNode
                "textContent": self.sanitize(text)
            ])
        }
        
        var node: [String: Any] = [
            "id": currentId,
            "type": 2, // ElementNode
            "tagName": tagName,
            "attributes": ["style": style]
        ]
        
        if !children.isEmpty {
            node["childNodes"] = children
        }
        
        return node
    }

    // MARK: - Helpers

    private func sanitize(_ text: String) -> String {
        // Basic sanitisation to prevent JSON breaking
        var result = ""
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
        if self.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return String(format: "#%02X%02X%02X", 
                          Int(r * 255), 
                          Int(g * 255), 
                          Int(b * 255))
        }
        return "#FFFFFF"
    }
}
