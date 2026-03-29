import UIKit

extension UIColor {
    /// Converts UIColor to a hex string (e.g., #FFFFFF).
    func toHexString() -> String {
        // Resolve dynamic iOS colors (like .label) for the current trait collection
        let resolved = self.resolvedColor(with: UITraitCollection.current)
        
        // CIColor safely converts any colorspace (like white/grayscale) to RGB components
        let ciColor = CIColor(color: resolved)
        
        return String(format: "#%02X%02X%02X",
                      Int(ciColor.red * 255),
                      Int(ciColor.green * 255),
                      Int(ciColor.blue * 255))
    }

    /// Resolves an iOS dynamic color (like .label) against a trait collection and converts it directly to a web CSS rgba() string.
    func resolvedCSS(with traitCollection: UITraitCollection) -> String {
        let resolved = self.resolvedColor(with: traitCollection)
        let ciColor = CIColor(color: resolved)
        
        let a = ciColor.alpha
        if a == 0 { return "transparent" }
        
        // Using RGBA guarantees perfect translation across web browsers
        return String(format: "rgba(%d, %d, %d, %.2f)", 
                      Int(ciColor.red * 255), 
                      Int(ciColor.green * 255), 
                      Int(ciColor.blue * 255), 
                      a)
    }
}

extension CGColor {
    /// Converts CGColor to a hex string (e.g., #FFFFFF).
    func toHexString() -> String {
        return UIColor(cgColor: self).toHexString()
    }
}
