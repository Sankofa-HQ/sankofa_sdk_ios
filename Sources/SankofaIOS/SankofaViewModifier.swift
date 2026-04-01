import SwiftUI

// MARK: - .sankofaScreen() View Modifier

/// Tracks the current screen name for session replay, heatmaps, and event attribution.
///
/// ## Usage
/// ```swift
/// HomeView()
///     .sankofaScreen("Home")
///
/// CheckoutView()
///     .sankofaScreen("Checkout", properties: ["cart_value": 99.0])
/// ```
///
/// The modifier fires `$screen_view` when the view appears and updates the
/// SDK's internal screen state so all subsequent events are attributed to it.
struct SankofaScreenModifier: ViewModifier {
    let name: String
    let properties: [String: Any]

    func body(content: Content) -> some View {
        content
            .onAppear {
                Sankofa.shared.screen(name, properties: properties)
            }
    }
}

public extension View {

    /// Tags this view as a named screen for Sankofa analytics.
    ///
    /// - Parameters:
    ///   - name: The screen name used in heatmaps, session replays, and event context.
    ///   - properties: Optional extra properties sent with the `$screen_view` event.
    func sankofaScreen(_ name: String, properties: [String: Any] = [:]) -> some View {
        modifier(SankofaScreenModifier(name: name, properties: properties))
    }
}
