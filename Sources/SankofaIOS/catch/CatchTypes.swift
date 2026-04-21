import Foundation

// Sankofa Catch wire contract — Swift mirror of the Go struct.
// Every field name + type is frozen at V1 ship. Additions allowed as
// new optional fields only.

public enum CatchWire {
    public static let version: Int = 1
}

public enum CatchLevel: String, Codable, Sendable {
    case fatal, error, warning, info, debug
}

public struct CatchSDKInfo: Codable, Sendable {
    public let name: String
    public let version: String
    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct CatchMechanism: Codable, Sendable {
    public let type: String
    public let handled: Bool
    public let description: String?
    public init(type: String, handled: Bool, description: String? = nil) {
        self.type = type
        self.handled = handled
        self.description = description
    }
}

public struct CatchStackFrame: Codable, Sendable {
    public var filename: String?
    public var function: String?
    public var module: String?
    public var lineno: Int?
    public var colno: Int?
    public var abs_path: String?
    public var in_app: Bool?
    public var platform: String?
    public var instruction_addr: String?
    public var package: String?
    public var symbol: String?
    public var symbol_addr: String?
    public var addr_mode: String?

    public init(
        filename: String? = nil,
        function: String? = nil,
        module: String? = nil,
        lineno: Int? = nil,
        colno: Int? = nil,
        abs_path: String? = nil,
        in_app: Bool? = nil,
        platform: String? = nil,
        instruction_addr: String? = nil,
        package: String? = nil,
        symbol: String? = nil,
        symbol_addr: String? = nil,
        addr_mode: String? = nil
    ) {
        self.filename = filename
        self.function = function
        self.module = module
        self.lineno = lineno
        self.colno = colno
        self.abs_path = abs_path
        self.in_app = in_app
        self.platform = platform
        self.instruction_addr = instruction_addr
        self.package = package
        self.symbol = symbol
        self.symbol_addr = symbol_addr
        self.addr_mode = addr_mode
    }
}

public struct CatchStackTrace: Codable, Sendable {
    public var frames: [CatchStackFrame]
    public init(frames: [CatchStackFrame]) { self.frames = frames }
}

public struct CatchException: Codable, Sendable {
    public var type: String
    public var value: String
    public var module: String?
    public var mechanism: CatchMechanism?
    public var stacktrace: CatchStackTrace?
    public var chained: [CatchException]?
    public init(
        type: String,
        value: String,
        module: String? = nil,
        mechanism: CatchMechanism? = nil,
        stacktrace: CatchStackTrace? = nil,
        chained: [CatchException]? = nil
    ) {
        self.type = type
        self.value = value
        self.module = module
        self.mechanism = mechanism
        self.stacktrace = stacktrace
        self.chained = chained
    }
}

public struct CatchUserContext: Codable, Sendable {
    public var id: String?
    public var email: String?
    public var username: String?
    public var ip_address: String?
    public var segment: String?
    public init(
        id: String? = nil,
        email: String? = nil,
        username: String? = nil,
        ip_address: String? = nil,
        segment: String? = nil
    ) {
        self.id = id
        self.email = email
        self.username = username
        self.ip_address = ip_address
        self.segment = segment
    }
}

public struct CatchDeviceContext: Codable, Sendable {
    public var os: String?
    public var os_version: String?
    public var model: String?
    public var arch: String?
    public var memory_mb: Int64?
    public var locale: String?
    public var country: String?
    public var timezone: String?
    public var app_version: String?
    public var online: Bool?
    public init(
        os: String? = nil,
        os_version: String? = nil,
        model: String? = nil,
        arch: String? = nil,
        memory_mb: Int64? = nil,
        locale: String? = nil,
        country: String? = nil,
        timezone: String? = nil,
        app_version: String? = nil,
        online: Bool? = nil
    ) {
        self.os = os
        self.os_version = os_version
        self.model = model
        self.arch = arch
        self.memory_mb = memory_mb
        self.locale = locale
        self.country = country
        self.timezone = timezone
        self.app_version = app_version
        self.online = online
    }
}

public struct CatchBreadcrumb: Codable, Sendable {
    public let ts_ms: Int64
    public let type: String
    public let category: String?
    public let message: String?
    public let level: CatchLevel?
    // Free-form data; Codable encodes whatever the caller passed
    // as long as the values are JSON-representable.
    public let data: [String: AnyCodable]?

    public init(
        ts_ms: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        type: String,
        category: String? = nil,
        message: String? = nil,
        level: CatchLevel? = nil,
        data: [String: AnyCodable]? = nil
    ) {
        self.ts_ms = ts_ms
        self.type = type
        self.category = category
        self.message = message
        self.level = level
        self.data = data
    }
}

// Debug metadata — consumed by the M5 symbolicator worker to map
// native stack frames under ASLR.
public struct CatchDebugImage: Codable, Sendable {
    public let type: String   // "macho" for iOS / macOS
    public let debug_id: String
    public let code_id: String?
    public let code_file: String?
    public let image_addr: String
    public let image_size: Int64?
    public let image_vmaddr: String?
    public let arch: String?
    public init(
        type: String,
        debug_id: String,
        code_id: String? = nil,
        code_file: String? = nil,
        image_addr: String,
        image_size: Int64? = nil,
        image_vmaddr: String? = nil,
        arch: String? = nil
    ) {
        self.type = type
        self.debug_id = debug_id
        self.code_id = code_id
        self.code_file = code_file
        self.image_addr = image_addr
        self.image_size = image_size
        self.image_vmaddr = image_vmaddr
        self.arch = arch
    }
}

public struct CatchDebugSDKInfo: Codable, Sendable {
    public let sdk_name: String?
    public let version_major: Int?
    public let version_minor: Int?
    public let version_patchlevel: Int?
    public init(
        sdk_name: String? = nil,
        version_major: Int? = nil,
        version_minor: Int? = nil,
        version_patchlevel: Int? = nil
    ) {
        self.sdk_name = sdk_name
        self.version_major = version_major
        self.version_minor = version_minor
        self.version_patchlevel = version_patchlevel
    }
}

public struct CatchDebugMeta: Codable, Sendable {
    public var images: [CatchDebugImage]?
    public var sdk_info: CatchDebugSDKInfo?
    public init(images: [CatchDebugImage]? = nil, sdk_info: CatchDebugSDKInfo? = nil) {
        self.images = images
        self.sdk_info = sdk_info
    }
}

/// The event envelope. Encodes to the frozen wire contract.
public struct CatchEvent: Codable, Sendable {
    public let wire_version: Int
    public let event_id: String
    public let ts_ms: Int64
    public var received_at_ms: Int64?
    public let environment: String

    public var distinct_id: String?
    public var anon_id: String?
    public var session_id: String?

    public let level: CatchLevel
    public let type: String

    public var exception: CatchException?
    public var message: String?

    public var tags: [String: String]?
    public var extra: [String: AnyCodable]?
    public var user: CatchUserContext?
    public var device: CatchDeviceContext?
    public var release: String?
    public let platform: String
    public let sdk: CatchSDKInfo

    public var breadcrumbs: [CatchBreadcrumb]?
    public var fingerprint: [String]?

    public var flag_snapshot: [String: String]?
    public var config_snapshot: [String: AnyCodable]?
    public var trace_id: String?
    public var span_id: String?
    public var replay_chunk_index: Int?
    public var debug_meta: CatchDebugMeta?

    public init(
        event_id: String,
        ts_ms: Int64,
        environment: String,
        level: CatchLevel,
        type: String,
        platform: String,
        sdk: CatchSDKInfo,
        exception: CatchException? = nil,
        message: String? = nil,
        distinct_id: String? = nil,
        anon_id: String? = nil,
        session_id: String? = nil,
        tags: [String: String]? = nil,
        extra: [String: AnyCodable]? = nil,
        user: CatchUserContext? = nil,
        device: CatchDeviceContext? = nil,
        release: String? = nil,
        breadcrumbs: [CatchBreadcrumb]? = nil,
        fingerprint: [String]? = nil,
        flag_snapshot: [String: String]? = nil,
        config_snapshot: [String: AnyCodable]? = nil,
        trace_id: String? = nil,
        span_id: String? = nil,
        replay_chunk_index: Int? = nil,
        debug_meta: CatchDebugMeta? = nil
    ) {
        self.wire_version = CatchWire.version
        self.event_id = event_id
        self.ts_ms = ts_ms
        self.environment = environment
        self.level = level
        self.type = type
        self.platform = platform
        self.sdk = sdk
        self.exception = exception
        self.message = message
        self.distinct_id = distinct_id
        self.anon_id = anon_id
        self.session_id = session_id
        self.tags = tags
        self.extra = extra
        self.user = user
        self.device = device
        self.release = release
        self.breadcrumbs = breadcrumbs
        self.fingerprint = fingerprint
        self.flag_snapshot = flag_snapshot
        self.config_snapshot = config_snapshot
        self.trace_id = trace_id
        self.span_id = span_id
        self.replay_chunk_index = replay_chunk_index
        self.debug_meta = debug_meta
    }
}

public struct CatchBatch: Codable, Sendable {
    public let wire_version: Int
    public let events: [CatchEvent]
    public init(events: [CatchEvent]) {
        self.wire_version = CatchWire.version
        self.events = events
    }
}

// Handshake config payload — `modules.catch` on the unified
// handshake response.
public struct CatchHandshakeConfig: Codable, Sendable {
    public let enabled: Bool?
    public let wire_version: Int?
    public let ingest_url: String?
    public let sampling: Sampling?
    public let replay: Replay?
    public let breadcrumbs: Breadcrumbs?
    public let reason: String?

    public struct Sampling: Codable, Sendable {
        public let error_sample_rate: Double?
        public let transaction_sample_rate: Double?
        public let profiles_sample_rate: Double?
    }
    public struct Replay: Codable, Sendable {
        public let on_error_enabled: Bool?
        public let burst_seconds: Int?
    }
    public struct Breadcrumbs: Codable, Sendable {
        public let max_buffer: Int?
    }
}

// AnyCodable — Sankofa's lightweight type-erased wrapper so free-form
// `extra` / `data` / `config_snapshot` bags can round-trip through
// Codable without forcing callers to box their own types.
public struct AnyCodable: Codable, Sendable {
    public let value: Any & Sendable
    public init(_ value: Any & Sendable) { self.value = value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self.value = NSNull() as (Any & Sendable); return }
        if let b = try? c.decode(Bool.self) { self.value = b; return }
        if let i = try? c.decode(Int64.self) { self.value = i; return }
        if let d = try? c.decode(Double.self) { self.value = d; return }
        if let s = try? c.decode(String.self) { self.value = s; return }
        if let a = try? c.decode([AnyCodable].self) {
            self.value = a.map { $0.value }
            return
        }
        if let m = try? c.decode([String: AnyCodable].self) {
            self.value = m.mapValues { $0.value }
            return
        }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "unsupported AnyCodable value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let i as Int64: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let arr as [Any]:
            let wrapped = arr.map { AnyCodable($0 as (Any & Sendable)) }
            try c.encode(wrapped)
        case let dict as [String: Any]:
            let wrapped = dict.mapValues { AnyCodable($0 as (Any & Sendable)) }
            try c.encode(wrapped)
        default:
            try c.encode(String(describing: value))
        }
    }
}
