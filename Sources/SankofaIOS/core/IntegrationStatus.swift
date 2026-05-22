import Foundation

/// # Module integration self-audit (iOS SDK)
///
/// Mirrors the `ModuleIntegrationStatus` type used by the Flutter +
/// RN + Web + Android SDKs. Reported to the server via
/// `POST /api/v1/handshake/integrations` so the dashboard's SDK
/// Health page can flag silently-broken host integrations.
///
/// Wire shape kept in lockstep with:
///   - sdks/sankofa_sdk_react_native/src/core/integration.ts
///   - sdks/sankofa_sdk_flutter/lib/src/core/module_registry.dart
///   - sdks/sankofa_sdk_web/packages/browser/src/integration.ts
///   - sdks/sankofa_sdk_android/.../core/IntegrationStatus.kt
///   - server/engine/ee/deploy/integration_health.go
public enum ModuleIntegrationLevel: String {
    case full
    case partial
    case broken
}

public struct ModuleIntegrationStatus {
    public let module: String
    public let level: ModuleIntegrationLevel
    public let missing: [String]
    public let warnings: [String]

    /// Derive the level from missing-count, matching RN + Flutter rule.
    static func deriveLevel(missing: [String]) -> ModuleIntegrationLevel {
        if missing.isEmpty { return .full }
        if missing.count >= 2 { return .broken }
        return .partial
    }
}

/// Audits the host iOS app's Sankofa SDK integration. Runs once after
/// the first successful handshake; result is reported via
/// `IntegrationReporter`.
enum IntegrationAudit {

    static func audit(
        handshakeOk: Bool,
        appVersionFromHost: Bool
    ) -> ModuleIntegrationStatus {
        var missing: [String] = []
        var warnings: [String] = []

        // Hard breakage: server unreachable / API key invalid.
        if !handshakeOk {
            missing.append(
                "Handshake to /api/v1/handshake did not succeed. Check the endpoint URL and that the API key is valid."
            )
        }

        // App Transport Security — if the host points at a plain-HTTP
        // endpoint without an NSAppTransportSecurity exception, iOS
        // will silently fail all requests. We can't introspect ATS
        // settings programmatically (Apple withdrew that API), but we
        // can warn loudly when the configured endpoint is HTTP.
        // Endpoint introspection happens at the caller (the audit
        // entry point feeds us a flag), so the reporter wraps this.

        // App version warning. Without an explicit `appVersion` set on
        // SankofaConfig, the SDK falls back to CFBundleShortVersionString
        // from the host's Info.plist. That's usually right but may not
        // match what the host wants for cohort targeting.
        if !appVersionFromHost {
            warnings.append(
                "SankofaConfig.appVersion not set — falling back to CFBundleShortVersionString. " +
                "Set it explicitly if your release versioning differs from the bundle's."
            )
        }

        // Simulator warning. Production analytics in a simulator is a
        // common foot-gun: events flow but they pollute live data.
        #if targetEnvironment(simulator)
        warnings.append(
            "Running on the iOS simulator. Events from this install will land in your live project unless filtered downstream."
        )
        #endif

        // Debug-build warning, mirrored on Android.
        #if DEBUG
        warnings.append(
            "App is compiled with DEBUG configuration. Events from this install will land in your live project unless filtered downstream."
        )
        #endif

        return ModuleIntegrationStatus(
            module: "analytics",
            level: ModuleIntegrationStatus.deriveLevel(missing: missing),
            missing: missing,
            warnings: warnings
        )
    }
}
