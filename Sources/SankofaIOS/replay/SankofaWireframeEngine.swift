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
        let traits = window.traitCollection
        
        // 🎨 1. CORE CSS + PREMIUM AESTHETICS
        var css = "position: absolute; "
        css += "left: \(Int(frame.origin.x))px; top: \(Int(frame.origin.y))px; "
        css += "width: \(Int(frame.width))px; height: \(Int(frame.height))px; "
        css += "box-sizing: border-box; overflow: visible; pointer-events: none; "
        css += "z-index: \(depth * 10); " // Increase spacing to prevent clipping
        
        // Background & Gradients
        if let gradientLayer = view.layer as? CAGradientLayer, let colors = gradientLayer.colors as? [CGColor] {
            let hexColors = colors.map { UIColor(cgColor: $0).resolvedColor(with: traits).sankofa_toHexString() }
            css += "background: linear-gradient(180deg, \(hexColors.joined(separator: ", "))); "
        } else if let bgColor = view.backgroundColor?.resolvedColor(with: traits).sankofa_toHexString(), bgColor != "transparent" {
            css += "background-color: \(bgColor); "
        } else if view is UIWindow {
            css += "background-color: \(traits.userInterfaceStyle == .dark ? "#1C1C1E" : "#F2F2F7"); "
        }
        
        // Borders & Radius
        if view.layer.cornerRadius > 0 { css += "border-radius: \(Int(view.layer.cornerRadius))px; " }
        if view.layer.borderWidth > 0 {
            let borderColor = view.layer.borderColor != nil ? UIColor(cgColor: view.layer.borderColor!).resolvedColor(with: traits).sankofa_toHexString() : "#E5E5EA"
            css += "border: \(Int(view.layer.borderWidth))px solid \(borderColor); "
        }
        
        // ✨ PREMIUM: Shadows
        if view.layer.shadowOpacity > 0 {
            let sColor = view.layer.shadowColor != nil ? UIColor(cgColor: view.layer.shadowColor!).resolvedColor(with: traits).sankofa_toHexString() : "#000000"
            let sOpacity = view.layer.shadowOpacity
            css += "box-shadow: \(Int(view.layer.shadowOffset.width))px \(Int(view.layer.shadowOffset.height))px \(Int(view.layer.shadowRadius))px rgba(\(sColor), \(sOpacity)); "
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
            let weight = label.font.fontDescriptor.symbolicTraits.contains(.traitBold) ? "bold" : "normal"
            let textColor = label.textColor.resolvedColor(with: traits).sankofa_toHexString()
            
            let alignMapping: [NSTextAlignment: (String, String)] = [
                .center: ("center", "center"),
                .right: ("right", "flex-end")
            ]
            let (align, justify) = alignMapping[label.textAlignment] ?? ("left", "flex-start")
            css += "color: \(textColor); font-family: -apple-system, system-ui, sans-serif; font-size: \(fontSize)px; font-weight: \(weight); line-height: 1.2; text-align: \(align); display: flex; align-items: center; justify-content: \(justify); white-space: pre-wrap; word-break: break-all; "
        } else if let button = view as? UIButton {
            tagName = "button"
            textContent = button.currentTitle ?? button.titleLabel?.text ?? button.attributedTitle(for: .normal)?.string
            let textColor = button.titleLabel?.textColor?.resolvedColor(with: traits).sankofa_toHexString() ?? "#007AFF"
            let btnBg = button.backgroundColor?.resolvedColor(with: traits).sankofa_toHexString() ?? "transparent"
            css += "color: \(textColor); background-color: \(btnBg); font-family: -apple-system, system-ui, sans-serif; font-weight: 600; border: none; outline: none; display: flex; align-items: center; justify-content: center; position: relative; "
            
            if let img = button.currentImage {
                let tint = button.tintColor?.resolvedColor(with: traits) ?? .black
                let bNodeId = nodeIdCounter
                nodeIdCounter += 1
                children.append([
                    "id": bNodeId,
                    "type": 2,
                    "tagName": "img",
                    "attributes": ["src": "data:image/png;base64,\(img.sankofa_toBase64(tintColor: tint))", "style": "max-height: 80%; max-width: 80%; object-fit: contain; "],
                    "childNodes": []
                ])
            }
        } else if let imgView = view as? UIImageView, let img = imgView.image {
            tagName = "img"
            let tint = imgView.tintColor?.resolvedColor(with: traits) ?? .black
            attributes["src"] = "data:image/png;base64,\(img.sankofa_toBase64(tintColor: tint))"
            css += "object-fit: contain; "
        } else if let textField = view as? UITextField {
            tagName = "input"
            let textColor = textField.textColor?.resolvedColor(with: traits).sankofa_toHexString() ?? "#000000"
            css += "color: \(textColor); padding: 0 12px; border-radius: 8px; border: 1px solid #E5E5EA; background-color: #fff; font-size: 14px; "
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
        
        // 🚜 4. SwiftUI Reflection (The "Do It Well" Hack)
        if textContent == nil {
            textContent = self.extractSwiftUIText(from: view)
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

    /// Uses Reflection to find text inside SwiftUI views
    private func extractSwiftUIText(from view: UIView) -> String? {
        // 1. Check Accessibility first
        if let val = view.accessibilityLabel ?? view.accessibilityValue, !val.isEmpty {
            return val
        }
        
        // 2. Reflection Hack (Mirror)
        let mirror = Mirror(reflecting: view)
        for child in mirror.children {
            if child.label == "text" || child.label == "_text" {
                return "\(child.value)"
            }
        }
        
        // 3. Subview Class Drill (SwiftUI rendering uses specific internal classes)
        let className = String(describing: type(of: view))
        if className.contains("DrawingView") || className.contains("TextView") {
            // Recurse into sublayers or descriptions if needed, 
            // but for now Mirror/Accessibility covers 90%.
        }
        
        return nil
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
    func sankofa_toBase64(tintColor: UIColor? = nil) -> String {
        // PostHog Image Hack: Scale down and TINT for SF Symbols
        let newSize = CGSize(width: size.width * 0.7, height: size.height * 0.7)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let scaledImage = renderer.image { context in
            if let tint = tintColor {
                tint.setFill()
                context.fill(CGRect(origin: .zero, size: newSize))
                self.draw(in: CGRect(origin: .zero, size: newSize), blendMode: .destinationIn, alpha: 1.0)
            } else {
                self.draw(in: CGRect(origin: .zero, size: newSize))
            }
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
