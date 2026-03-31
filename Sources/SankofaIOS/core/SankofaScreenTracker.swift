import UIKit

/// Automatic screen detection for iOS.
/// Traverses the view controller hierarchy to find the top-most visible controller.
final class SankofaScreenTracker {
    
    @MainActor
    static func findCurrentScreenName() -> String? {
        guard let window = findKeyWindow() else { return nil }
        guard let rootRect = window.rootViewController else { return nil }
        
        let topVisible = findTopViewController(from: rootRect)
        let name = String(describing: type(of: topVisible))
        
        // Clean up internal names (e.g. from SwiftUI) if necessary.
        if name.contains("UIHostingController") {
            return "SwiftUIContainer"
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
