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
    private func crawlForRRWeb(view: UIView, window: UIWindow, depth: Int = 0) -> [String: Any] {
        let currentId = nodeIdCounter
        nodeIdCounter += 1
        
        let frame = view.frame
        var children: [[String: Any]] = []
        let traits = window.traitCollection // 🚨 Critical for Dynamic Colors
        
        // 🎨 1. CORE CSS
        var css = "position: absolute; "
        css += "left: \(Int(frame.origin.x))px; top: \(Int(frame.origin.y))px; "
        css += "width: \(Int(frame.width))px; height: \(Int(frame.height))px; "
        css += "box-sizing: border-box; overflow: hidden; pointer-events: none; "
        css += "z-index: \(depth); "
        
        // Background Resolution
        if let bgColor = view.backgroundColor?.resolvedColor(with: traits).sankofa_toHexString(), bgColor != "transparent" {
            css += "background-color: \(bgColor); "
        } else if view is UIWindow {
            let winBg = traits.userInterfaceStyle == .dark ? "#1C1C1E" : "#FFFFFF"
            css += "background-color: \(winBg); "
        }
        
        if view.layer.cornerRadius > 0 { css += "border-radius: \(Int(view.layer.cornerRadius))px; " }
        if view.layer.borderWidth > 0 {
            let borderColor = view.layer.borderColor != nil ? UIColor(cgColor: view.layer.borderColor!).resolvedColor(with: traits).sankofa_toHexString() : "#E5E5EA"
            css += "border: \(Int(view.layer.borderWidth))px solid \(borderColor); "
        }
        if view.alpha < 0.99 { css += "opacity: \(String(format: "%.2f", view.alpha)); " }

        var tagName = "div"
        var textContent: String? = nil
        var attributes: [String: String] = [:]
        
        // 🎨 2. COMPONENT MAPPING
        if let label = view as? UILabel {
            tagName = "div" 
            textContent = label.text ?? label.attributedText?.string
            let fontSize = max(8, Int(label.font.pointSize))
            let textColor = label.textColor.resolvedColor(with: traits).sankofa_toHexString()
            
            let alignMapping: [NSTextAlignment: (String, String)] = [
                .center: ("center", "center"),
                .right: ("right", "flex-end")
            ]
            let (align, justify) = alignMapping[label.textAlignment] ?? ("left", "flex-start")
            css += "color: \(textColor); font-family: -apple-system, system-ui, sans-serif; font-size: \(fontSize)px; line-height: 1.2; text-align: \(align); display: flex; align-items: center; justify-content: \(justify); white-space: pre-wrap; word-break: break-all; "
        } else if let button = view as? UIButton {
            tagName = "button"
            textContent = button.currentTitle ?? button.titleLabel?.text ?? button.attributedTitle(for: .normal)?.string
            let fontSize = Int(button.titleLabel?.font.pointSize ?? 16)
            let textColor = button.titleLabel?.textColor?.resolvedColor(with: traits).sankofa_toHexString() ?? "#007AFF"
            let btnBg = button.backgroundColor?.resolvedColor(with: traits).sankofa_toHexString() ?? "transparent"
            css += "color: \(textColor); background-color: \(btnBg); font-family: -apple-system, system-ui, sans-serif; font-size: \(fontSize)px; border: none; outline: none; display: flex; align-items: center; justify-content: center; position: relative; "
            if let img = button.currentImage {
                let bNodeId = nodeIdCounter
                nodeIdCounter += 1
                children.append([
                    "id": bNodeId,
                    "type": 2,
                    "tagName": "img",
                    "attributes": ["src": "data:image/png;base64,\(img.sankofa_toBase64())", "style": "max-height: 70%; max-width: 70%; "],
                    "childNodes": []
                ])
            }
        } else if let imgView = view as? UIImageView, let img = imgView.image {
            tagName = "img"
            attributes["src"] = "data:image/png;base64,\(img.sankofa_toBase64())"
            css += "object-fit: contain; "
        } else if let textField = view as? UITextField {
            tagName = "input"
            let textColor = textField.textColor?.resolvedColor(with: traits).sankofa_toHexString() ?? "#000000"
            css += "color: \(textColor); padding: 0 8px; border: 1px solid #ccc; background-color: #fff; "
            if textField.isSecureTextEntry || maskAllInputs {
                attributes["type"] = "password"; attributes["value"] = "••••••••"
            } else {
                attributes["value"] = textField.text ?? textField.placeholder ?? ""
            }
        }

        // 🚜 3. RECURSION
        for subview in view.subviews {
            if !subview.isHidden && subview.alpha > 0.01 {
                children.append(crawlForRRWeb(view: subview, window: window, depth: depth + 1))
            }
        }
        
        // 🚜 4. SwiftUI/Internal Text Detection (PostHog Hack)
        if textContent == nil {
            let className = String(describing: type(of: view))
            if className.contains("DrawingView") || className.contains("TextView") {
                if let val = view.accessibilityLabel ?? view.accessibilityValue {
                    textContent = val
                }
            }
        }

        // 📝 5. TEXT NODES
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
            "childNodes": children
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

extension UIImage {
    func sankofa_toBase64() -> String {
        let newSize = CGSize(width: size.width * 0.5, height: size.height * 0.5)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let scaledImage = renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return scaledImage.pngData()?.base64EncodedString() ?? ""
    }
}

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
