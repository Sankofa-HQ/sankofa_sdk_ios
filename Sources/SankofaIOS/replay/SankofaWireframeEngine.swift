import UIKit
import SwiftUI

final class SankofaWireframeEngine: SankofaCaptureEngine {
    private let sessionId: String
    private let maskAllInputs: Bool
    private var nodeIdCounter = 1

    init(sessionId: String, maskAllInputs: Bool) {
        self.sessionId = sessionId
        self.maskAllInputs = maskAllInputs
    }

    @MainActor
    func captureFrame(completion: @escaping (SankofaFrame?) -> Void) {
        guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) else {
            completion(nil)
            return
        }

        nodeIdCounter = 5 // Reserve 1-4 for HTML root
        let windowNode = crawlForRRWeb(view: window, window: window, depth: 0)
        
        let documentNode = RRWebNode(
            id: 1, type: 0, tagName: nil, attributes: nil,
            childNodes: [
                RRWebNode(
                    id: 2, type: 2, tagName: "html", attributes: [:],
                    childNodes: [
                        RRWebNode(id: 3, type: 2, tagName: "head", attributes: [:], childNodes: [], textContent: nil),
                        RRWebNode(
                            id: 4, type: 2, tagName: "body", 
                            attributes: ["style": "margin: 0; padding: 0; width: \(window.bounds.width)px; height: \(window.bounds.height)px; background-color: \(window.backgroundColor?.resolvedCSS(with: window.traitCollection) ?? "#000000"); overflow: hidden; "],
                            childNodes: [windowNode], textContent: nil
                        )
                    ], textContent: nil
                )
            ], textContent: nil
        )
        
        let rrwebEvent = RRWebEvent(
            type: 2,
            data: RRWebSnapshotData(node: documentNode, initialOffset: ["left": 0, "top": 0]),
            timestamp: Int64(Date().timeIntervalSince1970 * 1000)
        )
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            if let jsonData = try? JSONEncoder().encode(rrwebEvent) {
                let frame = SankofaFrame(sessionId: self.sessionId, timestamp: Date(), payload: .wireframe(jsonData))
                completion(frame)
            } else {
                completion(nil)
            }
        }
    }

    @MainActor
    private func crawlForRRWeb(view: UIView, window: UIWindow, depth: Int) -> RRWebNode {
        let currentId = nodeIdCounter
        nodeIdCounter += 1
        
        // BUGFIX 1: Use local frame instead of converted absolute coordinates to prevent children flying off-screen.
        let frame = view.frame
        var children: [RRWebNode] = []
        var attributes: [String: String] = [:]
        
        var tagName = "div"
        var textContent: String? = nil
        var css = buildBaseCSS(for: view, frame: frame, traits: window.traitCollection, depth: depth)
        
        // 1. EXTRACT DATA: Text, Images, Inputs
        if let label = view as? UILabel {
            textContent = label.text
            css += typographyCSS(font: label.font, color: label.textColor, alignment: label.textAlignment, traits: window.traitCollection)
            
        } else if let button = view as? UIButton {
            tagName = "button"
            textContent = button.titleLabel?.text
            css += typographyCSS(font: button.titleLabel?.font, color: button.titleLabel?.textColor, alignment: .center, traits: window.traitCollection)
            css += "border: none; outline: none; cursor: pointer; "
            
        } else if let textField = view as? UITextField {
            tagName = "input"
            css += typographyCSS(font: textField.font, color: textField.textColor, alignment: textField.textAlignment, traits: window.traitCollection)
            css += "padding: 0 12px; outline: none; box-sizing: border-box; "
            
            // MASKING CONFIG: Only mask inputs if secure or if config demands it
            if maskAllInputs || textField.isSecureTextEntry {
                attributes["type"] = "password"
                attributes["value"] = "••••••••"
            } else {
                attributes["value"] = textField.text ?? textField.placeholder ?? ""
            }
            
        } else if let textView = view as? UITextView {
            tagName = "textarea"
            css += typographyCSS(font: textView.font, color: textView.textColor, alignment: textView.textAlignment, traits: window.traitCollection)
            css += "padding: 8px; outline: none; box-sizing: border-box; resize: none; "
            
            if maskAllInputs || textView.isSecureTextEntry {
                textContent = "••••••••"
            } else {
                textContent = textView.text
            }
            
        } else if let imageView = view as? UIImageView, let image = imageView.image {
            tagName = "img"
            css += "object-fit: contain; "
            
            var drawImage = image
            if image.renderingMode == .alwaysTemplate, let tint = imageView.tintColor {
                drawImage = image.withTintColor(tint)
            }
            // BUGFIX 2: Use PNG instead of JPEG to preserve alpha channel transparency for icons
            if let base64 = fastEncodeImageToPNG(drawImage) {
                attributes["src"] = "data:image/png;base64,\(base64)"
            }
            
        } else {
            // FAST SWIFTUI TEXT EXTRACTION: Replaces slow Mirror with instant Accessibility
            if view.isAccessibilityElement, view.accessibilityTraits.contains(.staticText), let text = view.accessibilityLabel {
                textContent = text
                css += typographyCSS(font: nil, color: view.tintColor, alignment: .left, traits: window.traitCollection)
            }
        }

        attributes["style"] = css
        
        // 2. RECURSE CHILDREN (Skip hidden to save CPU)
        for subview in view.subviews {
            if !subview.isHidden && subview.alpha > 0.05 {
                children.append(crawlForRRWeb(view: subview, window: window, depth: depth + 1))
            }
        }
        
        // 3. ATTACH TEXT NODE (RRWeb strictly requires text as a child type: 3)
        if let text = textContent, !text.isEmpty, tagName != "input" {
            let textNode = RRWebNode(id: nodeIdCounter, type: 3, tagName: nil, attributes: nil, childNodes: nil, textContent: text)
            nodeIdCounter += 1
            children.append(textNode)
        }
        
        // BUGFIX 3: Unconditionally pass `children` array so JSONEncoder serializes it into strict `[]` instead of omitting it (`nil`).
        return RRWebNode(id: currentId, type: 2, tagName: tagName, attributes: attributes, childNodes: children, textContent: nil)
    }

    // MARK: - CSS & Optimization Helpers

    private func buildBaseCSS(for view: UIView, frame: CGRect, traits: UITraitCollection, depth: Int) -> String {
        var css = "position: absolute; box-sizing: border-box; pointer-events: none; "
        css += "left: \(frame.origin.x)px; top: \(frame.origin.y)px; "
        css += "width: \(frame.width)px; height: \(frame.height)px; "
        css += "z-index: \(depth * 10); "
        
        if let bgColor = view.backgroundColor, bgColor != .clear {
            css += "background-color: \(bgColor.resolvedCSS(with: traits)); "
        }
        
        if view.layer.cornerRadius > 0 {
            css += "border-radius: \(view.layer.cornerRadius)px; "
        }
        if view.layer.borderWidth > 0 {
            let borderColor = UIColor(cgColor: view.layer.borderColor ?? UIColor.clear.cgColor)
            css += "border: \(view.layer.borderWidth)px solid \(borderColor.resolvedCSS(with: traits)); "
        }
        if view.alpha < 1.0 { css += "opacity: \(view.alpha); " }
        if view.clipsToBounds { css += "overflow: hidden; " }
        
        return css
    }

    private func typographyCSS(font: UIFont?, color: UIColor?, alignment: NSTextAlignment, traits: UITraitCollection) -> String {
        let f = font ?? UIFont.systemFont(ofSize: 15)
        let fontSize = f.pointSize
        let cssColor = (color ?? UIColor.label).resolvedCSS(with: traits)
        let isBold = f.fontDescriptor.symbolicTraits.contains(.traitBold)
        let weight = isBold ? "600" : "400"
        
        var align = "left"
        if alignment == .center { align = "center" }
        else if alignment == .right { align = "right" }
        
        return "color: \(cssColor); font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-size: \(fontSize)px; font-weight: \(weight); text-align: \(align); display: flex; align-items: center; justify-content: \(align == "center" ? "center" : align == "right" ? "flex-end" : "flex-start"); white-space: pre-wrap; word-break: break-word; "
    }

    // Prevents UI Lag by forcing images down to a tiny, web-friendly thumbnail
    private func fastEncodeImageToPNG(_ image: UIImage) -> String? {
        let maxDim: CGFloat = 64.0 // Super fast constraint
        let size = image.size
        guard size.width > 0 && size.height > 0 else { return nil }
        
        let scale = min(maxDim / size.width, maxDim / size.height, 1.0)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        
        return resized.pngData()?.base64EncodedString()
    }
}
