import Foundation

/// # Traffic Cop — Module Registry
///
/// The Core SDK routes handshake flags only to modules the developer
/// actually linked into their binary. A dashboard toggle can never
/// activate code that isn't present.
///
/// In Swift, unlinked modules literally can't exist at runtime (the
/// symbol isn't in the binary), so crash prevention is structural.
/// The registry exists to:
///
///  1. Report the `installed_modules` list to the server via the
///     Reverse Handshake so the dashboard can show "SDK Not Detected"
///     lock states instead of toggles that silently do nothing.
///  2. Route server-enabled module flags to the registered handler
///     when the optional module IS linked.
///  3. Emit debug-mode warnings when a dashboard flag references a
///     module the developer didn't include.
///
/// NOTE: The protocol here is `SankofaPluggableModule` — NOT
/// `SankofaModule`, which already exists as the React Native bridge
/// class in `sankofa_sdk_react_native/ios/SankofaModule.swift`. Keeping
/// them distinct avoids a symbol collision when both SDKs are linked
/// into the same React Native host binary.

public enum SankofaModuleName: String {
    case analytics
    case deploy
    case catchModule = "catch"
    case switchModule = "switch"
    case configModule = "config"
}

/// Every pluggable module conforms to this. The Core never imports
/// concrete module types — it only talks through this protocol.
public protocol SankofaPluggableModule: AnyObject {
    var canonicalName: SankofaModuleName { get }
    func applyHandshake(_ config: [String: Any]) async
}

public final class SankofaModuleRegistry {
    public static let shared = SankofaModuleRegistry()

    private var registered: [SankofaModuleName: SankofaPluggableModule] = [:]
    private var coreInitialized: Bool = false
    private let queue = DispatchQueue(label: "dev.sankofa.modules", qos: .utility)

    private init() {}

    /// Called once by `Sankofa.shared.initialize()` to flip core-ready.
    public func markCoreInitialized() {
        queue.sync { coreInitialized = true }
    }

    public var isCoreInitialized: Bool {
        queue.sync { coreInitialized }
    }

    /// Register a module. Called from each module's initializer.
    public func register(_ module: SankofaPluggableModule) {
        let isReady: Bool = queue.sync {
            registered[module.canonicalName] = module
            return coreInitialized
        }

        #if DEBUG
        if !isReady {
            print("[Sankofa] \(module.canonicalName.rawValue) module registered before Sankofa.shared.initialize(). Call initialize() first so the module can read your API key and endpoint.")
        }
        #endif
    }

    public func unregister(_ name: SankofaModuleName) {
        queue.sync { _ = registered.removeValue(forKey: name) }
    }

    public func has(_ name: SankofaModuleName) -> Bool {
        queue.sync { registered[name] != nil }
    }

    /// The list of module names the app binary ships with. Analytics
    /// is always present (it IS the core). Sent to the server in the
    /// Reverse Handshake.
    public func getInstalledModules() -> [String] {
        queue.sync {
            var names: [String] = ["analytics"]
            for name in registered.keys where name != .analytics {
                names.append(name.rawValue)
            }
            return names
        }
    }

    /// The Traffic Cop. Called from the handshake handler when the
    /// server response arrives. Routes each enabled module flag to
    /// its registered handler; warns (debug) or silently no-ops
    /// (release) for flags that reference missing modules.
    ///
    /// Non-async by design — launches module handlers in detached
    /// Tasks so the caller isn't blocked. Module errors are isolated.
    public func routeHandshake(_ modules: [String: Any]?) {
        guard let modules = modules else { return }

        // Deploy
        if let deploy = modules["deploy"] as? [String: Any],
           (deploy["enabled"] as? Bool) == true {
            if let mod = lookup(.deploy) {
                Task.detached {
                    await mod.applyHandshake(deploy)
                }
            } else {
                #if DEBUG
                print("[Sankofa] Server enabled \"deploy\" but Deploy module is not linked. Add the Deploy SDK to enable OTA updates.")
                #endif
            }
        }

        // Catch (ships later)
        if let catchConfig = modules["catch"] as? [String: Any],
           (catchConfig["enabled"] as? Bool) == true {
            if let mod = lookup(.catchModule) {
                Task.detached {
                    await mod.applyHandshake(catchConfig)
                }
            } else {
                #if DEBUG
                print("[Sankofa] Server enabled \"catch\" but SankofaCatch is not linked. Add the Catch SDK to enable crash reporting.")
                #endif
            }
        }

        // Switch — feature flags
        if let switchCfg = modules["switch"] as? [String: Any],
           (switchCfg["enabled"] as? Bool) == true {
            if let mod = lookup(.switchModule) {
                Task.detached {
                    await mod.applyHandshake(switchCfg)
                }
            } else {
                #if DEBUG
                print("[Sankofa] Server enabled \"switch\" but SankofaSwitch is not linked. Construct SankofaSwitch.shared after Sankofa.shared.initialize().")
                #endif
            }
        }

        // Config — remote config (class is SankofaRemoteConfig on iOS
        // because SankofaConfig is already taken by the init-options
        // struct in this SDK — see Sources/SankofaIOS/SankofaConfig.swift).
        if let configCfg = modules["config"] as? [String: Any],
           (configCfg["enabled"] as? Bool) == true {
            if let mod = lookup(.configModule) {
                Task.detached {
                    await mod.applyHandshake(configCfg)
                }
            } else {
                #if DEBUG
                print("[Sankofa] Server enabled \"config\" but SankofaRemoteConfig is not linked. Construct SankofaRemoteConfig.shared after Sankofa.shared.initialize().")
                #endif
            }
        }
    }

    private func lookup(_ name: SankofaModuleName) -> SankofaPluggableModule? {
        queue.sync { registered[name] }
    }
}
