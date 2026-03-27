import UIKit

// MARK: - Constants

/// Layer key used to mark a view for privacy masking.
internal let SankofaMaskKey = "dev.sankofa.mask"

/// Integer tag used as an alternative to the layer key for XML/ObjC compatibility.
internal let SankofaMaskTagValue = 0x5A4B_0001 // "SK" prefix, unique sentinel

// MARK: - UIView Extension

public extension UIView {

    /// Set to `true` to redact this view from Sankofa session recordings.
    ///
    /// ## Usage
    /// ```swift
    /// passwordField.sankofaMask = true
    /// creditCardView.sankofaMask = true
    /// ```
    ///
    /// The Ghost Masking engine will draw a black rectangle over this view's
    /// coordinates in the in-memory screenshot buffer.
    /// **The live screen is never modified.**
    var sankofaMask: Bool {
        get { (layer.value(forKey: SankofaMaskKey) as? Bool) ?? false }
        set { layer.setValue(newValue, forKey: SankofaMaskKey) }
    }
}
