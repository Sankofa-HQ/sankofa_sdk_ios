import UIKit

/// Automatic screen detection for iOS.
/// Traverses the view controller hierarchy to find the top-most visible controller.
final class SankofaScreenTracker {

    /// View-controller class names that should NEVER be used as automatic
    /// screen tags, because they're framework hosts — there's exactly one
    /// per app and they tell us nothing about which UI the user is
    /// actually viewing.  Screen tagging in these frameworks is the
    /// host language's responsibility:
    ///
    ///   - SwiftUI:       `Sankofa.shared.screen("...")` from `.onAppear`,
    ///                    or the `.sankofaScreen("...")` view modifier.
    ///   - React Native:  `Sankofa.screen("...")` from JS via the bridge.
    ///   - Flutter:       `SankofaNavigatorObserver` (Dart side).
    ///
    /// If we DID auto-tag from these classes, every cold-start frame would
    /// be attributed to "SwiftUIContainer" / "RCTRootViewController" /
    /// "FlutterViewController" — one giant bucket that the dashboard's
    /// per-screen heatmap cannot disambiguate.  Returning nil here lets
    /// the screenNameProvider fall through to "untagged", which the
    /// capture coordinator skips entirely until the host tags a screen
    /// (see `SankofaCaptureCoordinator`'s untagged-screen guard).
    private static let nonTaggableHosts: Set<String> = [
        // SwiftUI
        "UIHostingController",
        // React Native
        "RCTRootViewController",
        "RCTViewController",
        // Flutter
        "FlutterViewController",
        // Generic UIKit base — usually means the app forgot to set rootVC
        "UIViewController",
    ]

    @MainActor
    static func findCurrentScreenName() -> String? {
        guard let window = findKeyWindow() else { return nil }
        guard let rootRect = window.rootViewController else { return nil }

        let topVisible = findTopViewController(from: rootRect)
        let name = String(describing: type(of: topVisible))

        // 🚦 Framework-host skip-list.  Returning nil signals "untagged" so
        // SwiftUI / RN / Flutter screens stay un-attributed until the host
        // calls `Sankofa.shared.screen(...)` explicitly.  Matches the
        // Android NON_TAGGABLE_HOST_ACTIVITIES skip-list.
        //
        // We match prefix-style for `UIHostingController` because Swift's
        // generics inflate the runtime type into something like
        // `UIHostingController<RootView>` — startsWith catches both.
        for prefix in nonTaggableHosts {
            if name == prefix || name.hasPrefix("\(prefix)<") {
                return nil
            }
        }

        return name
    }
    
    @MainActor
    private static func findTopViewController(from root: UIViewController) -> UIViewController {
        if let presented = root.presentedViewController {
            return findTopViewController(from: presented)
        }
        if let navigation = root as? UINavigationController, let top = navigation.topViewController {
            return findTopViewController(from: top)
        }
        if let tab = root as? UITabBarController, let selected = tab.selectedViewController {
            return findTopViewController(from: selected)
        }
        return root
    }
    
    private static func findKeyWindow() -> UIWindow? {
        if #available(iOS 15.0, *) {
            for scene in UIApplication.shared.connectedScenes {
                if let windowScene = scene as? UIWindowScene,
                   scene.activationState == .foregroundActive {
                    if let keyWindow = windowScene.keyWindow { return keyWindow }
                    if let window = windowScene.windows.first(where: { $0.isKeyWindow }) { return window }
                }
            }
        }
        if #available(iOS 13.0, *) {
            for scene in UIApplication.shared.connectedScenes {
                if let windowScene = scene as? UIWindowScene {
                    if let window = windowScene.windows.first(where: { $0.isKeyWindow }) { return window }
                }
            }
        }
        return UIApplication.shared.windows.first(where: { $0.isKeyWindow })
    }
}
