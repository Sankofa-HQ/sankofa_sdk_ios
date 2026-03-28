import UIKit
import SwiftUI

/// High-Fidelity rrweb Replay Engine (Phase 28 — The High-Fidelity Compiler).
///
/// This engine acts as a real-time iOS-to-CSS compiler. It recursively traverses
/// the live UIView hierarchy and transforms every view, label, and button into
/// an rrweb-compliant DOM tree with pixel-perfect inline CSS.
final class SankofaWireframeEngine: SankofaCaptureEngine {
    private let sessionId: String
    private let maskAllInputs: Bool
    private var nodeIdCounter = 1

    init(sessionId: String, maskAllInputs: Bool = true) {
        self.sessionId = sessionId
        self.maskAllInputs = maskAllInputs
    }

    // MARK: - SankofaCaptureEngine

    @MainActor
    func captureFrame(completion: @escaping (SankofaFrame?) -> Void) {
        guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) else {
            completion(nil)
            return
        }

        // 1. Build the High-Fidelity DOM Tree
        nodeIdCounter = 1
        let domTree = crawlForRRWeb(view: window, window: window)
        
        // 2. Offload JSON encoding to background thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let jsonData = try JSONEncoder().encode(domTree)
                let frame = SankofaFrame(
                    sessionId: self.sessionId,
                    timestamp: Date(),
                    payload: .wireframe(jsonData)
                )
                completion(frame)
            } catch {
                completion(nil)
            }
        }
    }

    // MARK: - rrweb Crawler (High-Fidelity CSS Bridge)

    @MainActor
    private func crawlForRRWeb(view: UIView, window: UIWindow) -> RRWebNode {
        let currentId = nodeIdCounter
        nodeIdCounter += 1
        
        // Convert local bounds to window-space coordinates
        let frame = view.convert(view.bounds, to: window)
        var children: [RRWebNode] = []
        var css = buildBaseCSS(for: view, frame: frame)
        
        var tagName = "div"
        var textContent: String? = nil
        var attributes: [String: String] = [:]
        
        // 1. Typography & UI Element Mapping
        if let label = view as? UILabel {
            textContent = label.text ?? label.attributedText?.string
            css += typographyCSS(font: label.font, color: label.textColor, alignment: label.textAlignment)
            
        } else if let button = view as? UIButton {
            tagName = "button"
            textContent = button.currentTitle ?? button.titleLabel?.text ?? button.attributedTitle(for: .normal)?.string
            css += typographyCSS(font: button.titleLabel?.font, color: button.titleLabel?.textColor, alignment: .center)
            css += "border: none; outline: none; cursor: pointer; "
            
        } else if let textField = view as? UITextField {
            tagName = "input"
            css += typographyCSS(font: textField.font, color: textField.textColor, alignment: textField.textAlignment)
            css += "padding: 0 12px; outline: none; "
            
            if maskAllInputs || textField.isSecureTextEntry {
                attributes["type"] = "password"
                attributes["value"] = "••••••••"
            } else {
                attributes["value"] = textField.text ?? textField.placeholder ?? ""
            }
            
        } else if let imageView = view as? UIImageView, let image = imageView.image {
            // TINTED SF SYMBOLS & IMAGES -> Base64 Data URI
            tagName = "img"
            let tinted = image.withTintColor(imageView.tintColor ?? .black)
            // Using jpegData with small compression to keep frame payload tiny
            if let data = tinted.jpegData(compressionQuality: 0.1) {
                attributes["src"] = "data:image/jpeg;base64,\(data.base64EncodedString())"
            }
            css += "object-fit: contain; "
            
        } else {
            // SWIFTUI TEXT EXTRACTION (Phase 28 Hack)
            // If it's a generic UIView, use reflection/accessibility to see if it's hiding SwiftUI Text
            if let swiftUIText = extractSwiftUIText(from: view) {
                textContent = swiftUIText
                css += "color: \(view.tintColor?.toHexString() ?? "#000"); font-family: -apple-system, system-ui; font-size: 15px; font-weight: 500; display: flex; align-items: center; "
            }
        }

        // Apply final compiled CSS
        attributes["style"] = css
        
        // 2. Recursive Child Mapping (Ignore hidden to save CPU)
        for subview in view.subviews {
            if !subview.isHidden && subview.alpha > 0.01 {
                children.append(crawlForRRWeb(view: subview, window: window))
            }
        }
        
        // 3. Attach text as RRWeb TextNode (Type 3)
        if let text = textContent, !text.isEmpty {
            let textNodeId = nodeIdCounter
            nodeIdCounter += 1
            let textNode = RRWebNode(id: textNodeId, type: 3, tagName: nil, attributes: nil, childNodes: nil, textContent: text)
            children.append(textNode)
        }
        
        return RRWebNode(id: currentId, type: 2, tagName: tagName, attributes: attributes, childNodes: children.isEmpty ? nil : children, textContent: nil)
    }

    // MARK: - Advanced CSS Compilers

    private func buildBaseCSS(for view: UIView, frame: CGRect) -> String {
        var css = "position: absolute; box-sizing: border-box; "
        css += "left: \(Int(frame.origin.x))px; top: \(Int(frame.origin.y))px; "
        css += "width: \(Int(frame.width))px; height: \(Int(frame.height))px; "
        
        // Shadows (Phase 28)
        if view.layer.shadowOpacity > 0 {
            let dx = view.layer.shadowOffset.width
            let dy = view.layer.shadowOffset.height
            let blur = view.layer.shadowRadius
            let opacity = view.layer.shadowOpacity
            css += "box-shadow: \(Int(dx))px \(Int(dy))px \(Int(blur))px rgba(0,0,0,\(opacity)); "
        }
        
        // Gradients (Phase 28)
        var hasGradient = false
        if let sublayers = view.layer.sublayers {
            for layer in sublayers {
                if let grad = layer as? CAGradientLayer, let colors = grad.colors as? [CGColor] {
                    let colorStrings = colors.map { $0.toHexString() }.joined(separator: ", ")
                    css += "background: linear-gradient(to bottom right, \(colorStrings)); "
                    hasGradient = true
                    break
                }
            }
        }
        
        if !hasGradient, let bgColor = view.backgroundColor?.toHexString(), bgColor != "transparent" {
            css += "background-color: \(bgColor); "
        }
        
        if view.layer.cornerRadius > 0 {
            css += "border-radius: \(Int(view.layer.cornerRadius))px; "
            if view.clipsToBounds { css += "overflow: hidden; " }
        }
        
        if view.layer.borderWidth > 0 {
            css += "border: \(Int(view.layer.borderWidth))px solid \(view.layer.borderColor?.toHexString() ?? "#000"); "
        }
        
        if view.alpha < 1.0 { css += "opacity: \(String(format: "%.2f", view.alpha)); " }
        
        return css
    }

    private func typographyCSS(font: UIFont?, color: UIColor?, alignment: NSTextAlignment) -> String {
        let f = font ?? UIFont.systemFont(ofSize: 14)
        let fontSize = f.pointSize
        let hexColor = color?.toHexString() ?? "#000000"
        
        // Phase 28: Typography Mapping
        let isBold = f.fontDescriptor.symbolicTraits.contains(.traitBold)
        let weight = isBold ? "600" : "400"
        
        var align = "left"
        if alignment == .center { align = "center" }
        else if alignment == .right { align = "right" }
        
        return "color: \(hexColor); font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; font-size: \(Int(fontSize))px; font-weight: \(weight); letter-spacing: -0.3px; text-align: \(align); display: flex; align-items: center; justify-content: \(align == "center" ? "center" : align == "right" ? "flex-end" : "flex-start"); white-space: pre-wrap; "
    }

    private func extractSwiftUIText(from view: UIView) -> String? {
        // Fallback 1: SwiftUI automatically bridges Text() to accessibilityLabel
        if let accLabel = view.accessibilityLabel, !accLabel.isEmpty, view.accessibilityTraits.contains(.staticText) {
            return accLabel
        }
        
        // Fallback 2: The Phase 28 Mirror Hack
        let mirror = Mirror(reflecting: view)
        for child in mirror.children {
            if let label = child.label, label.lowercased().contains("text"), let textValue = child.value as? String {
                return textValue
            }
        }
        return nil
    }
}

