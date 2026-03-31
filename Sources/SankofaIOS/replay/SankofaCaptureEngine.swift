import Foundation
import UIKit

/// The protocol that all capture engines must conform to.
/// This enables the `SankofaCaptureCoordinator` to swap engines at runtime
/// without changing any surrounding code — the Strategy Pattern.
protocol SankofaCaptureEngine: AnyObject {
    /// Capture a single frame asynchronously. Returns result via completion.
    func captureFrame(completion: @escaping (SankofaFrame?) -> Void)
}

/// A captured frame ready for upload.
struct SankofaFrame {
    enum Payload {
        /// Screenshot engine output: WebP or JPEG image data, privacy-masked in memory.
        case screenshot(Data)
    }

    let sessionId: String
    let timestamp: Date
    let payload: Payload
}
