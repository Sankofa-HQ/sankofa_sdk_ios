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
        props["$brand"] = "Apple"
        
        #if targetEnvironment(simulator)
        props["$is_simulator"] = "true"
        #else
        props["$is_simulator"] = "false"
        #endif

        let bounds = UIScreen.main.nativeBounds
        props["$screen_width"] = Int(bounds.width)
        props["$screen_height"] = Int(bounds.height)
        
        // Approximate DPI for iOS (163 is the base for non-retina, scaled accordingly)
        let scale = UIScreen.main.scale
        props["$screen_dpi"] = Int(163 * scale)
        
        props["$locale"] = Locale.current.identifier
        props["$timezone"] = TimeZone.current.identifier
        
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        props["$app_version"] = version
        props["$app_version_string"] = version
        props["$app_build"] = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    }

    func deviceContext() -> [String: Any] {
        let screen = UIScreen.main
        let bounds = screen.bounds // logical points
        let scale = screen.scale
        
        return [
            "screen_width": Int(bounds.width),
            "screen_height": Int(bounds.height),
            "pixel_ratio": Double(scale)
        ]
    }

    private static func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }

        switch identifier {
        case "iPod9,1":                                 return "iPod touch (7th generation)"
        case "iPhone8,1":                               return "iPhone 6s"
        case "iPhone8,2":                               return "iPhone 6s Plus"
        case "iPhone9,1", "iPhone9,3":                  return "iPhone 7"
        case "iPhone9,2", "iPhone9,4":                  return "iPhone 7 Plus"
        case "iPhone8,4":                               return "iPhone SE"
        case "iPhone10,1", "iPhone10,4":                return "iPhone 8"
        case "iPhone10,2", "iPhone10,5":                return "iPhone 8 Plus"
        case "iPhone10,3", "iPhone10,6":                return "iPhone X"
        case "iPhone11,2":                              return "iPhone XS"
        case "iPhone11,4", "iPhone11,6":                return "iPhone XS Max"
        case "iPhone11,8":                              return "iPhone XR"
        case "iPhone12,1":                              return "iPhone 11"
        case "iPhone12,3":                              return "iPhone 11 Pro"
        case "iPhone12,5":                              return "iPhone 11 Pro Max"
        case "iPhone12,8":                              return "iPhone SE (2nd generation)"
        case "iPhone13,1":                              return "iPhone 12 mini"
        case "iPhone13,2":                              return "iPhone 12"
        case "iPhone13,3":                              return "iPhone 12 Pro"
        case "iPhone13,4":                              return "iPhone 12 Pro Max"
        case "iPhone14,4":                              return "iPhone 13 mini"
        case "iPhone14,5":                              return "iPhone 13"
        case "iPhone14,2":                              return "iPhone 13 Pro"
        case "iPhone14,3":                              return "iPhone 13 Pro Max"
        case "iPhone14,6":                              return "iPhone SE (3rd generation)"
        case "iPhone14,7":                              return "iPhone 14"
        case "iPhone14,8":                              return "iPhone 14 Plus"
        case "iPhone15,2":                              return "iPhone 14 Pro"
        case "iPhone15,3":                              return "iPhone 14 Pro Max"
        case "iPhone15,4":                              return "iPhone 15"
        case "iPhone15,5":                              return "iPhone 15 Plus"
        case "iPhone16,1":                              return "iPhone 15 Pro"
        case "iPhone16,2":                              return "iPhone 15 Pro Max"
        case "iPhone17,1":                              return "iPhone 16 Pro"
        case "iPhone17,2":                              return "iPhone 16 Pro Max"
        case "iPhone17,3":                              return "iPhone 16"
        case "iPhone17,4":                              return "iPhone 16 Plus"
        case "arm64", "x86_64":                         return "Simulator"
        default:                                        return identifier
        }
    }
}
