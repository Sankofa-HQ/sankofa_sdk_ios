import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Sankofa Catch — error tracking on iOS.
///
/// Usage:
/// ```swift
/// Sankofa.shared.initialize(apiKey: "sk_live_...")
/// _ = SankofaCatch.shared.start(environment: "live")
///
/// // anywhere:
/// do { try risky() } catch {
///     SankofaCatch.shared.captureException(error)
/// }
/// ```
///
/// M1 surface (what's wired now):
///   - `captureException`, `captureMessage`, `addBreadcrumb`,
///     `setUser`, `setTags`, `flush`.
///   - `NSSetUncaughtExceptionHandler` for ObjC-style throws.
///   - Auto-populated `debug_meta` from dyld every event (the
///     ASLR-safe symbolication hook).
///   - Persistent offline queue via UserDefaults, batch POST to
///     `/api/catch/events`.
///
/// Later milestones add Mach-signal handlers for native SIGSEGV/
/// SIGABRT/SIGBUS, MetricKit ANR + hang detection, and the replay-on-
/// error hook.
public final class SankofaCatch: NSObject, SankofaPluggableModule, @unchecked Sendable {

    public static let shared = SankofaCatch()

    public var canonicalName: SankofaModuleName { .catchModule }

    // MARK: - State (guarded by `queue`)

    private static let storageKey = "sankofa.catch.queue"
    private static let maxQueueBytes = 512 * 1024
    private static let flushInterval: TimeInterval = 5.0
    private static let batchSize = 20

    private let queue = DispatchQueue(label: "dev.sankofa.catch", qos: .utility, attributes: .concurrent)
    private var buffer: [CatchEvent] = []
    private var environment: String = "live"
    private var releaseName: String?
    private var appVersion: String?
    private var enabled: Bool = true
    private var errorSampleRate: Double = 1.0
    private var breadcrumbs = BreadcrumbRing(capacity: 100)

    private var user: CatchUserContext?
    private var tags: [String: String] = [:]
    private var extra: [String: AnyCodable] = [:]

    private var flushTimer: DispatchSourceTimer?
    private var flagSnapshot: (() -> [String: String]?)?
    private var configSnapshot: (() -> [String: AnyCodable]?)?

    private var previousNSExceptionHandler: NSUncaughtExceptionHandler?
    private var handlerInstalled: Bool = false

    // MARK: - Init

    private override init() {
        super.init()
        SankofaModuleRegistry.shared.register(self)
    }

    /// Kick off Catch. Safe to call from anywhere after
    /// `Sankofa.shared.initialize(...)`. Idempotent — subsequent calls
    /// just update the mutable options.
    @discardableResult
    public func start(
        environment: String = "live",
        release: String? = nil,
        appVersion: String? = nil,
        captureUnhandled: Bool = true,
        readFlagSnapshot: (() -> [String: String]?)? = nil,
        readConfigSnapshot: (() -> [String: AnyCodable]?)? = nil
    ) -> SankofaCatch {
        queue.async(flags: .barrier) {
            self.environment = environment
            self.releaseName = release
            self.appVersion = appVersion
            self.flagSnapshot = readFlagSnapshot
            self.configSnapshot = readConfigSnapshot
            self.hydrateFromStorage()
            self.startFlushTimer()
            if captureUnhandled {
                self.installGlobalHandler()
                // Native-signal handler — writes an async-signal-safe
                // dump file on SIGSEGV/SIGABRT/SIGBUS/etc, which we
                // drain on the next launch. Process that was just
                // killed can't report inline; this is the only way
                // to see native crashes.
                CatchSignalHandler.install()
                self.drainPendingNativeCrashes()
            }
        }
        return self
    }

    /// Read crash dumps left by previous signal-crash runs and push
    /// them into the buffer so the next flush ships them. Called
    /// once per process at start().
    ///
    /// Symbols are NOT resolved here — the dump only has raw
    /// instruction addresses. Server-side symbolication uses the
    /// per-image `debug_meta` we capture alongside (LC_UUID + text
    /// vmaddr), which is enough to resolve frames deterministically
    /// even across ASLR slides.
    private func drainPendingNativeCrashes() {
        let dumps = CatchSignalHandler.drainPendingDumps()
        guard !dumps.isEmpty else { return }

        for dump in dumps {
            let sigName = Self.signalName(dump.signal)
            let frames = dump.backtrace.map { addr -> CatchStackFrame in
                CatchStackFrame(
                    filename: nil,
                    function: nil,
                    lineno: nil,
                    colno: nil,
                    in_app: nil,
                    instruction_addr: String(format: "0x%016llx", addr),
                    package: nil,
                    addr_mode: nil
                )
            }
            let exc = CatchException(
                type: "NativeCrash",
                value: "\(sigName) (\(dump.signal))",
                module: nil,
                mechanism: CatchMechanism(type: "signalhandler", handled: false),
                stacktrace: CatchStackTrace(frames: frames),
                chained: nil
            )
            let sankofaSDK = Sankofa.shared
            let event = CatchEvent(
                event_id: randomID(),
                ts_ms: dump.timestampSeconds * 1000,
                environment: environment,
                level: .fatal,
                type: "unhandled_exception",
                platform: "ios",
                sdk: CatchSDKInfo(name: "sankofa.ios", version: "ios-0.1.0"),
                exception: exc,
                message: nil,
                distinct_id: sankofaSDK.distinctId,
                anon_id: sankofaSDK.anonymousId,
                session_id: sankofaSDK.currentSessionId,
                tags: tags.isEmpty ? nil : tags,
                user: user,
                device: buildDeviceContext(),
                release: releaseName,
                breadcrumbs: nil,
                flag_snapshot: nil,
                config_snapshot: nil,
                debug_meta: CatchDebugMetaCapture.capture()
            )
            buffer.append(event)
        }
        persistToStorage()
    }

    /// Map signal number → readable name for the exception `value`.
    /// Covers every signal we register in CatchSignalHandler.install().
    private static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGSEGV: return "SIGSEGV"
        case SIGABRT: return "SIGABRT"
        case SIGBUS:  return "SIGBUS"
        case SIGILL:  return "SIGILL"
        case SIGFPE:  return "SIGFPE"
        case SIGTRAP: return "SIGTRAP"
        case SIGSYS:  return "SIGSYS"
        default:      return "SIG\(sig)"
        }
    }

    // MARK: - SankofaPluggableModule

    public func applyHandshake(_ config: [String: Any]) async {
        let cfg = CatchHandshakeConfig(
            enabled: config["enabled"] as? Bool,
            wire_version: config["wire_version"] as? Int,
            ingest_url: config["ingest_url"] as? String,
            sampling: parseSampling(config["sampling"] as? [String: Any]),
            replay: parseReplay(config["replay"] as? [String: Any]),
            breadcrumbs: parseBreadcrumbs(config["breadcrumbs"] as? [String: Any]),
            reason: config["reason"] as? String
        )
        queue.async(flags: .barrier) {
            if cfg.enabled == false {
                self.enabled = false
                return
            }
            self.enabled = true
            if let rate = cfg.sampling?.error_sample_rate {
                self.errorSampleRate = max(0, min(1, rate))
            }
            if let cap = cfg.breadcrumbs?.max_buffer {
                self.breadcrumbs.setCapacity(cap)
            }
        }
    }

    // MARK: - Public API

    @discardableResult
    public func captureException(_ error: Error, options: CaptureOptions = .init()) -> String {
        return capture(
            errorOrMessage: .error(error),
            type: "unhandled_exception",
            options: options,
            mechanism: CatchMechanism(type: "manual", handled: true)
        )
    }

    @discardableResult
    public func captureMessage(_ message: String, options: CaptureOptions = .init()) -> String {
        return capture(
            errorOrMessage: .message(message),
            type: "console_error",
            options: options,
            mechanism: nil
        )
    }

    public func addBreadcrumb(_ crumb: CatchBreadcrumb) {
        queue.async(flags: .barrier) { self.breadcrumbs.push(crumb) }
    }

    public func setUser(_ user: CatchUserContext?) {
        queue.async(flags: .barrier) { self.user = user }
    }

    public func setTags(_ tags: [String: String]) {
        queue.async(flags: .barrier) { self.tags.merge(tags) { _, new in new } }
    }

    public func setExtra(_ key: String, _ value: AnyCodable) {
        queue.async(flags: .barrier) { self.extra[key] = value }
    }

    public func flush() {
        flushInternal(keepalive: false)
    }

    /// Captured shape for public API. Lets callers pass either a
    /// level / tags / user / fingerprint / trace without reaching
    /// for @unchecked-Sendable or Any.
    public struct CaptureOptions: Sendable {
        public var level: CatchLevel?
        public var tags: [String: String]?
        public var extra: [String: AnyCodable]?
        public var user: CatchUserContext?
        public var fingerprint: [String]?
        public var trace_id: String?
        public var span_id: String?
        public init(
            level: CatchLevel? = nil,
            tags: [String: String]? = nil,
            extra: [String: AnyCodable]? = nil,
            user: CatchUserContext? = nil,
            fingerprint: [String]? = nil,
            trace_id: String? = nil,
            span_id: String? = nil
        ) {
            self.level = level
            self.tags = tags
            self.extra = extra
            self.user = user
            self.fingerprint = fingerprint
            self.trace_id = trace_id
            self.span_id = span_id
        }
    }

    // MARK: - Capture path

    private enum CaptureKind { case error(Error); case message(String) }

    private func capture(
        errorOrMessage: CaptureKind,
        type: String,
        options: CaptureOptions,
        mechanism: CatchMechanism?
    ) -> String {
        guard enabled else { return "" }
        if !shouldSample() { return "" }

        let level = options.level ?? (type == "console_error" ? .warning : .error)
        let (exception, messageValue) = composeExceptionOrMessage(errorOrMessage, mechanism: mechanism)
        let eventID = randomID()

        // Identity correlation. Pulled from the core SDK so a Catch
        // event lines up with the user's Analytics session + replay
        // chunk in the dashboard. Failing to read (SDK not initialised)
        // is fine — server tolerates missing ids.
        let sankofaSDK = Sankofa.shared
        let event = CatchEvent(
            event_id: eventID,
            ts_ms: Int64(Date().timeIntervalSince1970 * 1000),
            environment: environment,
            level: level,
            type: type,
            platform: "ios",
            sdk: CatchSDKInfo(name: "sankofa.ios", version: "ios-0.1.0"),
            exception: exception,
            message: messageValue,
            distinct_id: sankofaSDK.distinctId,
            anon_id: sankofaSDK.anonymousId,
            session_id: sankofaSDK.currentSessionId,
            tags: mergedTags(options),
            extra: mergedExtra(options),
            user: options.user ?? user,
            device: buildDeviceContext(),
            release: releaseName,
            breadcrumbs: breadcrumbs.snapshot(),
            fingerprint: options.fingerprint,
            flag_snapshot: flagSnapshot?(),
            config_snapshot: configSnapshot?(),
            trace_id: options.trace_id,
            span_id: options.span_id,
            replay_chunk_index: nil,
            debug_meta: CatchDebugMetaCapture.capture()
        )

        queue.async(flags: .barrier) {
            self.buffer.append(event)
            self.persistToStorage()
            if self.buffer.count >= SankofaCatch.batchSize {
                self.flushInternal(keepalive: false)
            }
        }
        return eventID
    }

    private func composeExceptionOrMessage(
        _ k: CaptureKind,
        mechanism: CatchMechanism?
    ) -> (CatchException?, String?) {
        switch k {
        case .message(let msg):
            return (nil, msg)
        case .error(let err):
            let nsErr = err as NSError
            let type = String(describing: Swift.type(of: err))
            let value = nsErr.localizedDescription
            let stack = CatchStackBuilder.buildFromSymbols(Thread.callStackSymbols)
            return (
                CatchException(
                    type: type,
                    value: value,
                    module: nsErr.domain,
                    mechanism: mechanism ?? CatchMechanism(type: "manual", handled: true),
                    stacktrace: stack,
                    chained: nil
                ),
                nil
            )
        }
    }

    private func mergedTags(_ options: CaptureOptions) -> [String: String]? {
        var merged = tags
        if let t = options.tags {
            for (k, v) in t { merged[k] = v }
        }
        return merged.isEmpty ? nil : merged
    }

    private func mergedExtra(_ options: CaptureOptions) -> [String: AnyCodable]? {
        var merged = extra
        if let e = options.extra {
            for (k, v) in e { merged[k] = v }
        }
        return merged.isEmpty ? nil : merged
    }

    private func shouldSample() -> Bool {
        if errorSampleRate >= 1 { return true }
        if errorSampleRate <= 0 { return false }
        return Double.random(in: 0..<1) < errorSampleRate
    }

    private func buildDeviceContext() -> CatchDeviceContext {
        #if canImport(UIKit)
        let device = UIDevice.current
        return CatchDeviceContext(
            os: device.systemName,
            os_version: device.systemVersion,
            model: device.model,
            arch: archString(),
            locale: Locale.current.identifier,
            timezone: TimeZone.current.identifier,
            app_version: appVersion
        )
        #else
        return CatchDeviceContext(
            os: "macOS",
            os_version: ProcessInfo.processInfo.operatingSystemVersionString,
            arch: archString(),
            locale: Locale.current.identifier,
            timezone: TimeZone.current.identifier,
            app_version: appVersion
        )
        #endif
    }

    private func archString() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #elseif arch(i386)
        return "i386"
        #else
        return "unknown"
        #endif
    }

    // MARK: - Transport

    private func startFlushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + SankofaCatch.flushInterval,
                       repeating: SankofaCatch.flushInterval)
        timer.setEventHandler { [weak self] in self?.flushInternal(keepalive: false) }
        timer.resume()
        self.flushTimer = timer
    }

    private func flushInternal(keepalive: Bool) {
        queue.async(flags: .barrier) {
            guard !self.buffer.isEmpty else { return }
            let batch = CatchBatch(events: self.buffer)
            let pending = self.buffer
            self.buffer.removeAll()
            self.persistToStorage()

            guard let endpoint = Sankofa.shared.endpointString,
                  let apiKey = Sankofa.shared.apiKeyString,
                  let url = URL(string: "\(endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/api/catch/events") else {
                // Config unavailable — restore buffer so the next tick
                // tries again.
                self.buffer.insert(contentsOf: pending, at: 0)
                self.persistToStorage()
                return
            }

            let body: Data
            do {
                let encoder = JSONEncoder()
                body = try encoder.encode(batch)
            } catch {
                // Unserialisable event — drop so we don't loop forever.
                return
            }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.httpBody = body

            URLSession.shared.dataTask(with: req) { [weak self] _, response, error in
                guard let self = self else { return }
                if error != nil || (response as? HTTPURLResponse)?.statusCode ?? 500 >= 500 {
                    // Requeue for next flush.
                    self.queue.async(flags: .barrier) {
                        self.buffer.insert(contentsOf: pending, at: 0)
                        self.persistToStorage()
                    }
                }
            }.resume()
        }
    }

    // MARK: - Persistence

    private func hydrateFromStorage() {
        guard let data = UserDefaults.standard.data(forKey: SankofaCatch.storageKey) else { return }
        do {
            let decoded = try JSONDecoder().decode([CatchEvent].self, from: data)
            self.buffer.append(contentsOf: decoded)
        } catch {
            UserDefaults.standard.removeObject(forKey: SankofaCatch.storageKey)
        }
    }

    private func persistToStorage() {
        do {
            var data = try JSONEncoder().encode(buffer)
            while data.count > SankofaCatch.maxQueueBytes, buffer.count > 1 {
                buffer.removeFirst()
                data = try JSONEncoder().encode(buffer)
            }
            UserDefaults.standard.set(data, forKey: SankofaCatch.storageKey)
        } catch {
            // Storage unavailable — continue.
        }
    }

    // MARK: - Global handler

    private func installGlobalHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        previousNSExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            // Process the ObjC exception BEFORE the previous handler
            // (likely the runtime's own crash reporter) so our event
            // lands even if the previous handler terminates the app.
            let stack = CatchStackBuilder.buildFromSymbols(exception.callStackSymbols)
            let event = CatchException(
                type: exception.name.rawValue,
                value: exception.reason ?? "",
                module: nil,
                mechanism: CatchMechanism(type: "ns_exception", handled: false),
                stacktrace: stack,
                chained: nil
            )
            SankofaCatch.shared.captureInternal(exception: event, type: "unhandled_exception")
            // Best-effort synchronous flush so the event lands before
            // the process tears down.
            SankofaCatch.shared.flushInternal(keepalive: true)
            // Chain to previous handler.
            SankofaCatch.shared.previousNSExceptionHandler?(exception)
        }
    }

    private func captureInternal(exception: CatchException, type: String) {
        let sankofaSDK = Sankofa.shared
        let event = CatchEvent(
            event_id: randomID(),
            ts_ms: Int64(Date().timeIntervalSince1970 * 1000),
            environment: environment,
            level: .fatal,
            type: type,
            platform: "ios",
            sdk: CatchSDKInfo(name: "sankofa.ios", version: "ios-0.1.0"),
            exception: exception,
            message: nil,
            distinct_id: sankofaSDK.distinctId,
            anon_id: sankofaSDK.anonymousId,
            session_id: sankofaSDK.currentSessionId,
            tags: tags.isEmpty ? nil : tags,
            user: user,
            device: buildDeviceContext(),
            release: releaseName,
            breadcrumbs: breadcrumbs.snapshot(),
            flag_snapshot: flagSnapshot?(),
            config_snapshot: configSnapshot?(),
            debug_meta: CatchDebugMetaCapture.capture()
        )
        queue.sync(flags: .barrier) {
            self.buffer.append(event)
            self.persistToStorage()
        }
    }
}

// MARK: - Breadcrumb ring buffer

private final class BreadcrumbRing {
    private var capacity: Int
    private var items: [CatchBreadcrumb] = []
    init(capacity: Int) { self.capacity = max(10, capacity) }
    func setCapacity(_ n: Int) {
        self.capacity = max(10, n)
        while items.count > capacity { items.removeFirst() }
    }
    func push(_ b: CatchBreadcrumb) {
        items.append(b)
        if items.count > capacity { items.removeFirst() }
    }
    func snapshot() -> [CatchBreadcrumb] { items }
}

private func randomID() -> String {
    return UUID().uuidString
}

private func parseSampling(_ dict: [String: Any]?) -> CatchHandshakeConfig.Sampling? {
    guard let d = dict else { return nil }
    return CatchHandshakeConfig.Sampling(
        error_sample_rate: d["error_sample_rate"] as? Double,
        transaction_sample_rate: d["transaction_sample_rate"] as? Double,
        profiles_sample_rate: d["profiles_sample_rate"] as? Double
    )
}

private func parseReplay(_ dict: [String: Any]?) -> CatchHandshakeConfig.Replay? {
    guard let d = dict else { return nil }
    return CatchHandshakeConfig.Replay(
        on_error_enabled: d["on_error_enabled"] as? Bool,
        burst_seconds: d["burst_seconds"] as? Int
    )
}

private func parseBreadcrumbs(_ dict: [String: Any]?) -> CatchHandshakeConfig.Breadcrumbs? {
    guard let d = dict else { return nil }
    return CatchHandshakeConfig.Breadcrumbs(max_buffer: d["max_buffer"] as? Int)
}
