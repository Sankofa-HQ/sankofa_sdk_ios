import UIKit

extension UIColor {
    /// Converts UIColor to a hex string (e.g., #FFFFFF).
    func toHexString() -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        self.getRed(&r, green: &g, blue: &b, alpha: &a)
        
        return String(format: "#%02X%02X%02X",
                      Int(r * 255),
                      Int(g * 255),
                      Int(b * 255))
    }
}

extension CGColor {
    /// Converts CGColor to a hex string (e.g., #FFFFFF).
    func toHexString() -> String {
        return UIColor(cgColor: self).toHexString()
    }
}
