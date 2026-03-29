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

}

extension CGColor {
    /// Converts CGColor to a hex string (e.g., #FFFFFF).
    func toHexString() -> String {
        return UIColor(cgColor: self).toHexString()
    }
}
