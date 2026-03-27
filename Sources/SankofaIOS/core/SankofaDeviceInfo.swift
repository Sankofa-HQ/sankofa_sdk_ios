import Foundation
import UIKit

/// Collects device and OS metadata to enrich every event.
///
/// Mirrors `SankofaDeviceInfo` in the Flutter SDK.
final class SankofaDeviceInfo {

    private let device = UIDevice.current

    func inject(into props: inout [String: Any]) {
        props["$os"] = "iOS"
        props["$os_version"] = device.systemVersion
        props["$device_model"] = Self.deviceModel()
        props["$device_manufacturer"] = "Apple"
        
        #if targetEnvironment(simulator)
        props["$is_simulator"] = "true"
        #else
        props["$is_simulator"] = "false"
        #endif

        let bounds = UIScreen.main.nativeBounds
        props["$screen_width"] = Int(bounds.width)
        props["$screen_height"] = Int(bounds.height)
        
        props["$locale"] = Locale.current.identifier
        props["$timezone"] = TimeZone.current.identifier
        
        props["$app_version"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        props["$app_build"] = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    }

    private static func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "unknown"
            }
        }
    }
}
