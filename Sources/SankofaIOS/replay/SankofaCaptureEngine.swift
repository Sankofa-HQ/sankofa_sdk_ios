import Foundation
import UIKit

/// The protocol that all capture engines must conform to.
/// This enables the `SankofaCaptureCoordinator` to swap engines at runtime
/// without changing any surrounding code — the Strategy Pattern.
protocol SankofaCaptureEngine: AnyObject {
    /// Capture a single frame asynchronously. Returns result via completion.
    func captureFrame(completion: @escaping (SankofaFrame?) -> Void)
}

/// A captured high-fidelity DOM node for rrweb snapshots.
struct RRWebNode: Codable {
    let id: Int
    let type: Int
    let tagName: String?
    let attributes: [String: String]?
    let childNodes: [RRWebNode]?
    let textContent: String?
}

struct RRWebEvent: Codable {
    let type: Int // 2 = FullSnapshot
    let data: RRWebSnapshotData
    let timestamp: Int64
}

struct RRWebSnapshotData: Codable {
    let node: RRWebNode
    let initialOffset: [String: Double]
}

/// A captured frame ready for upload.
struct SankofaFrame {
    enum Payload {
        /// Type 2 (Incremental) / Type 3 (Full Snapshot) / Meta (Type 4)
        case rrwebEvent([String: Any])
        /// High-fidelity wireframe snapshot (Phase 28)
        case wireframe(Data)
    }

    let sessionId: String
    let timestamp: Date
    let payload: Payload
}

