import UIKit

/// High-Fidelity rrweb Replay Engine (Phase 25 — The CSS Bridge).
///
/// This engine acts as a real-time iOS-to-CSS compiler. It recursively traverses 
/// the live UIView hierarchy and transforms every view, label, and button into 
/// an rrweb-compliant HTML node with pixel-perfect inline CSS.
final class SankofaWireframeEngine: SankofaCaptureEngine {

    private let sessionId: String
    private var nodeIdCounter = 1
    private let maskAllInputs: Bool = true // Standard for enterprise recording

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

        nodeIdCounter = 1
        let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
        let frameSize = window.bounds.size
        
        // --- 1. Meta Event (Type 4) ---
        // Tells the player the viewport dimensions so it can scale to "phone size"
        let metaEvent: [String: Any] = [
            "type": 4,
            "timestamp": timestampMs,
            "data": [
                "href": "ios-app://\(Bundle.main.bundleIdentifier ?? "sankofa")",
                "width": Int(frameSize.width),
                "height": Int(frameSize.height)
            ]
        ]

        nodeIdCounter = 4 // Reserve 1=Doc, 2=HTML, 3=Body
        let iosRoot = self.crawlForRRWeb(view: window, window: window)
        
        let rootNode: [String: Any] = [
            "id": 1,
            "type": 0, // Document
            "childNodes": [
                [
                    "id": 2,
                    "type": 2, // Element
                    "tagName": "html",
                    "attributes": ["lang": "en"],
                    "childNodes": [
                        [
                            "id": 3,
                            "type": 2, // Element
                            "tagName": "body",
                            "attributes": ["style": "margin: 0; padding: 0; background: #000; "],
                            "childNodes": [iosRoot]
                        ]
                    ]
                ]
            ]
        ]
        
        // nodeIdCounter is now > 4 from the crawl
        
        let snapshotEvent: [String: Any] = [
            "type": 2,
            "timestamp": timestampMs + 1,
            "data": [
                "node": rootNode,
                "initialOffset": ["left": 0, "top": 0]
            ]
        ]


        // --- 3. Pack Both Events (Meta + Snapshot) ---
        let chunkEvents = [metaEvent, snapshotEvent]
        let unifiedFrame = SankofaFrame(
            sessionId: sessionId,
            timestamp: Date(),
            payload: SankofaFrame.Payload.rrwebEvent(["events": chunkEvents])
        )
        
        completion(unifiedFrame)
    }

    // MARK: - rrweb Crawler (High-Fidelity CSS Bridge)

    @MainActor
    private func crawlForRRWeb(view: UIView, window: UIWindow) -> [String: Any] {
        let currentId = nodeIdCounter
        nodeIdCounter += 1
        
        let frame = view.convert(view.bounds, to: window)
        var children: [[String: Any]] = []
        
        // ... (CSS generation logic unchanged) ...
        var css = "position: absolute; "
        css += "left: \(Int(frame.origin.x))px; top: \(Int(frame.origin.y))px; "
        css += "width: \(Int(frame.width))px; height: \(Int(frame.height))px; "
        css += "box-sizing: border-box; overflow: hidden; "
        
        if let bgColor = view.backgroundColor?.sankofa_toHexString(), bgColor != "transparent" {
            css += "background-color: \(bgColor); "
        }
        
        if view.layer.cornerRadius > 0 {
            css += "border-radius: \(Int(view.layer.cornerRadius))px; "
        }
        
        if view.layer.borderWidth > 0 {
            let borderColor = view.layer.borderColor?.sankofa_toHexString() ?? "#000000"
            css += "border: \(Int(view.layer.borderWidth))px solid \(borderColor); "
        }
        
        if view.alpha < 0.99 {
            css += "opacity: \(String(format: "%.2f", view.alpha)); "
        }

        var tagName = "div"
        var textContent: String? = nil
        var attributes: [String: String] = [:]
        
        // Typography & Component Mapping
        if let label = view as? UILabel {
            tagName = "div" 
            textContent = label.text
            let fontSize = Int(label.font.pointSize)
            let textColor = label.textColor.sankofa_toHexString()
            var align = "left"
            var justify = "flex-start"
            if label.textAlignment == .center { align = "center"; justify = "center" }
            else if label.textAlignment == .right { align = "right"; justify = "flex-end" }
            css += "color: \(textColor); font-family: -apple-system, system-ui, sans-serif; font-size: \(fontSize)px; text-align: \(align); display: flex; align-items: center; justify-content: \(justify); white-space: pre-wrap; "
        } else if let button = view as? UIButton {
            tagName = "button"
            textContent = button.currentTitle
            let fontSize = Int(button.titleLabel?.font.pointSize ?? 16)
            let textColor = button.titleLabel?.textColor?.sankofa_toHexString() ?? "#007AFF"
            css += "color: \(textColor); font-family: -apple-system, system-ui, sans-serif; font-size: \(fontSize)px; border: none; outline: none; background-color: transparent; display: flex; align-items: center; justify-content: center; cursor: pointer; "
        } else if let textField = view as? UITextField {
            tagName = "input"
            let fontSize = Int(textField.font?.pointSize ?? 14)
            let textColor = textField.textColor?.sankofa_toHexString() ?? "#000000"
            css += "color: \(textColor); font-family: -apple-system, system-ui, sans-serif; font-size: \(fontSize)px; padding: 0 8px; border: 1px solid #ccc; outline: none; "
            if textField.isSecureTextEntry || maskAllInputs {
                attributes["type"] = "password"; attributes["value"] = "••••••••"
            } else {
                attributes["value"] = textField.text ?? textField.placeholder ?? ""
            }
        } else if view is UIImageView {
            tagName = "div"
            css += "background-color: #E5E5EA; border: 1px solid #D1D1D6; display: flex; align-items: center; justify-content: center; font-size: 10px; color: #8E8E93; font-family: sans-serif; "
            textContent = "Image Cap"
        }
        
        for subview in view.subviews {
            if !subview.isHidden && subview.alpha > 0.01 {
                children.append(crawlForRRWeb(view: subview, window: window))
            }
        }
        
        if let text = textContent, !text.isEmpty {
            let tNodeId = nodeIdCounter
            nodeIdCounter += 1
            children.append([
                "id": tNodeId,
                "type": 3,
                "textContent": self.sanitize(text)
            ])
        }
        
        attributes["style"] = css
        
        return [
            "id": currentId,
            "type": 2,
            "tagName": tagName,
            "attributes": attributes,
            "childNodes": children // ALWAYS INCLUDE as per rrweb-snapshot requirement
        ]
    }

    // MARK: - Helpers

    private func sanitize(_ text: String) -> String {
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

extension CGColor {
    func sankofa_toHexString() -> String {
        if let components = components, components.count >= 3 {
            let r = Float(components[0])
            let g = Float(components[1])
            let b = Float(components[2])
            return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        }
        return "#000000"
    }
}
