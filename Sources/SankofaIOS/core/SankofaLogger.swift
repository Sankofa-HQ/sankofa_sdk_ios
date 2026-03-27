import Foundation

/// Lightweight logging wrapper for the Sankofa SDK.
/// Only emits output when `debug: true` is set in `SankofaConfig`.
final class SankofaLogger {
    private let debug: Bool

    init(debug: Bool) {
        self.debug = debug
    }

    func log(_ message: String) {
        guard debug else { return }
        print("[Sankofa] \(message)")
    }

    func warn(_ message: String) {
        // Warnings always print regardless of debug mode.
        print("[Sankofa ⚠️] \(message)")
    }
}
