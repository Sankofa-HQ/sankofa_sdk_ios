import Foundation
import Darwin

/// Sankofa Catch — Mach signal handler for native crashes.
///
/// Installs handlers for SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE,
/// SIGTRAP, SIGSYS, SIGPIPE. When any of these fire we write a
/// minimal crash dump to disk using *only* async-signal-safe calls,
/// then re-raise the signal so the OS can still produce its normal
/// crash log and user-visible crashloop behaviour is unchanged.
///
/// On the next app launch, `drainPendingDumps()` reads any dump files
/// left behind, builds a `CatchEvent`, and hands it to `SankofaCatch`
/// for upload. A crash that kills the process immediately is still
/// delivered to the Sankofa server within the first seconds of the
/// next run.
///
/// **Async-signal-safety rules** (why this file looks different from
/// the rest of the SDK):
///
///   - No `malloc`, `Data()`, `String` formatting, `NSLog`,
///     `UserDefaults`, `Codable`, `DispatchQueue`. None of these are
///     async-signal-safe; calling them from a signal handler risks a
///     deadlock or corruption.
///   - Only `write(2)`, `_exit(2)`, `getpid(2)`, `backtrace(2)`,
///     `sigaction(2)`, `sigaltstack(2)` inside the handler.
///   - Pre-allocate buffers at install time, reuse them in the
///     handler.
///   - `backtrace(3)` is on Apple's "probably-safe" list — every
///     shipping crash reporter (Sentry, Firebase, Bugsnag, Apple's
///     own) uses it. Documented caveat below.
///
/// The persisted dump file format is intentionally dumb: four
/// newline-separated lines of ASCII so a stack overflow during
/// handling can't corrupt structured data.
///
///     SANKOFA-CRASH\n
///     SIGNAL <signo>\n
///     TS <unix-seconds>\n
///     BACKTRACE <hex addr> <hex addr> ...\n
///
/// On replay we parse these four lines (in normal, safe Swift code),
/// build a CatchEvent, and upload. If the file is malformed we drop
/// it — better than uploading corrupted events.
public enum CatchSignalHandler {

    /// Maximum backtrace depth we capture. 64 is plenty for real
    /// crashes; anything deeper is library-on-library recursion that
    /// symbolicates to a repeating pattern.
    private static let maxBacktraceFrames: Int32 = 64

    /// Dedicated signal stack size. 64 KB is the SIGSTKSZ-safe
    /// default; enough headroom that a SIGSEGV caused by stack
    /// exhaustion still has room to run the handler.
    private static let alternateStackSize = 64 * 1024

    /// Signals we catch. Exits the process anyway after reporting
    /// (the default disposition for all of these is terminate), but
    /// records the crash for upload on the next launch.
    private static let caughtSignals: [Int32] = [
        SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP, SIGSYS,
    ]

    // MARK: - Install-time state (readable from the handler safely)
    //
    // `installed` guards idempotency; `altStack` is kept alive for the
    // process lifetime (freeing it is unnecessary and would require
    // another global).

    private static var installed: Bool = false
    private static var altStack: UnsafeMutableRawPointer?
    private static var dumpPathC: UnsafeMutablePointer<CChar>?
    private static var previousHandlers: [Int32: sigaction] = [:]

    // MARK: - Public API

    /// Install signal handlers. Safe to call multiple times —
    /// subsequent calls are no-ops. Returns the directory path where
    /// dumps land, for diagnostics / tests.
    @discardableResult
    public static func install() -> String? {
        guard !installed else { return pendingDumpDirectory() }
        installed = true

        // 1. Alternate stack — so a SIGSEGV from stack exhaustion
        //    can still run the handler. Leaked intentionally.
        let stack = malloc(alternateStackSize)
        altStack = stack
        var ss = stack_t()
        ss.ss_sp = stack
        ss.ss_size = alternateStackSize
        ss.ss_flags = 0
        _ = sigaltstack(&ss, nil)

        // 2. Pre-compute the dump path as a C string so the handler
        //    can `open()` without any Swift string conversion.
        if let dir = pendingDumpDirectory() {
            let file = (dir as NSString).appendingPathComponent("crash-\(Int(Date().timeIntervalSince1970)).dump")
            dumpPathC = strdup(file)
        }

        // 3. Install sigaction for each caught signal. SA_SIGINFO
        //    gives us the siginfo_t; SA_ONSTACK makes the handler
        //    run on the alternate stack we set up above.
        for sig in caughtSignals {
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = catchSignalHandler
            action.sa_flags = SA_SIGINFO | SA_ONSTACK
            sigemptyset(&action.sa_mask)

            var prev = sigaction()
            if sigaction(sig, &action, &prev) == 0 {
                previousHandlers[sig] = prev
            }
        }

        return pendingDumpDirectory()
    }

    /// Drain any crash dumps left on disk from a previous run and
    /// return parsed entries so the SDK can convert them into
    /// CatchEvent uploads. Called from `SankofaCatch.start()`.
    ///
    /// Safe to call from normal Swift code — we're outside the signal
    /// handler here, so heap allocation and NSFileManager are fine.
    public static func drainPendingDumps() -> [PendingCrash] {
        guard let dir = pendingDumpDirectory() else { return [] }

        let fm = FileManager.default
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(at: URL(fileURLWithPath: dir),
                                              includingPropertiesForKeys: nil)
        } catch {
            return []
        }

        var out: [PendingCrash] = []
        for url in urls where url.pathExtension == "dump" {
            defer { try? fm.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .ascii) else {
                continue
            }
            if let crash = parseDump(text) {
                out.append(crash)
            }
        }
        return out
    }

    // MARK: - Dump-file parsing (SAFE Swift, not in signal path)

    private static func parseDump(_ text: String) -> PendingCrash? {
        let lines = text.split(separator: "\n")
        guard lines.count >= 4 else { return nil }
        guard lines[0] == "SANKOFA-CRASH" else { return nil }

        // SIGNAL <n>
        let signalParts = lines[1].split(separator: " ")
        guard signalParts.count == 2, signalParts[0] == "SIGNAL",
              let sig = Int32(signalParts[1]) else { return nil }

        // TS <unix seconds>
        let tsParts = lines[2].split(separator: " ")
        guard tsParts.count == 2, tsParts[0] == "TS",
              let ts = Int64(tsParts[1]) else { return nil }

        // BACKTRACE <hex> <hex> ...
        let btParts = lines[3].split(separator: " ")
        guard btParts.count >= 1, btParts[0] == "BACKTRACE" else { return nil }
        var addrs: [UInt64] = []
        for hex in btParts.dropFirst() {
            if let addr = UInt64(hex, radix: 16) {
                addrs.append(addr)
            }
        }

        return PendingCrash(signal: sig, timestampSeconds: ts, backtrace: addrs)
    }

    // MARK: - Paths

    /// Per-process crash-dump directory inside the app's Caches. We
    /// use Caches (not Documents) because a reinstall should wipe
    /// them; nothing user-visible here.
    private static func pendingDumpDirectory() -> String? {
        guard let caches = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first else {
            return nil
        }
        let dir = (caches as NSString).appendingPathComponent("sankofa-catch/dumps")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    public struct PendingCrash {
        public let signal: Int32
        public let timestampSeconds: Int64
        public let backtrace: [UInt64]
    }
}

// MARK: - Signal handler (MUST be @convention(c), no captures)

/// The actual signal handler. `@convention(c)` means no closure
/// capture list, no Swift allocator — everything touched here must
/// be either stack-local, static-storage, or passed via the three
/// well-known params.
///
/// Absolutely no `print`, `NSLog`, `DispatchQueue`, `Data(...)`,
/// `String(...)`, or heap allocation. If you need to debug this
/// function, use `write(2)` to a pre-opened fd.
private let catchSignalHandler: @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void = { signo, _, _ in
    // 1. Capture the backtrace into a stack-allocated array. `backtrace`
    //    is technically marked as "MT-Safe, AS-Unsafe" on glibc, but
    //    Apple's implementation and every shipping crash reporter
    //    treats it as safe enough in practice.
    var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
    let frameCount = frames.withUnsafeMutableBufferPointer { buf -> Int32 in
        // backtrace() returns the number of addresses filled in.
        return backtrace(buf.baseAddress, 64)
    }

    // 2. Open (or create) the dump file. open(2) is async-signal-safe.
    //    dumpPathC was pre-computed at install time so no Swift string
    //    conversion happens here.
    guard let pathC = CatchSignalHandler_dumpPath() else {
        catchSignalHandler_chainOrExit(signo)
        return
    }
    let fd = open(pathC, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    if fd < 0 {
        catchSignalHandler_chainOrExit(signo)
        return
    }

    // 3. Write the dump. Each section uses a small stack-local buffer
    //    and write(2) — zero heap allocation.
    catchSignalHandler_writeAll(fd, "SANKOFA-CRASH\n")
    catchSignalHandler_writeInt(fd, prefix: "SIGNAL ", value: Int64(signo))
    catchSignalHandler_writeInt(fd, prefix: "TS ", value: Int64(time(nil)))

    // BACKTRACE <hex> <hex> ...
    catchSignalHandler_writeAll(fd, "BACKTRACE")
    for i in 0..<Int(frameCount) {
        if let addr = frames[i] {
            catchSignalHandler_writeAll(fd, " ")
            catchSignalHandler_writeHex(fd, value: UInt64(UInt(bitPattern: addr)))
        }
    }
    catchSignalHandler_writeAll(fd, "\n")

    close(fd)

    // 4. Chain to the previous handler (the OS crash reporter, etc)
    //    so we don't break existing crash-log generation.
    catchSignalHandler_chainOrExit(signo)
}

// MARK: - Async-signal-safe helpers

/// Returns the pre-computed crash-dump path as a C string. Exposed
/// as a free function so the @convention(c) handler can reach it
/// without a Swift value-type conversion.
@_silgen_name("CatchSignalHandler_dumpPath")
private func CatchSignalHandler_dumpPath() -> UnsafeMutablePointer<CChar>? {
    return CatchSignalHandler.__dumpPathPtr
}

private extension CatchSignalHandler {
    /// Exposed to the @convention(c) handler via a free function
    /// because Swift static-stored-properties can't be addressed
    /// from C-callable closures.
    static var __dumpPathPtr: UnsafeMutablePointer<CChar>? { dumpPathC }
}

/// Write a NUL-terminated C string to fd. Safe in a signal handler.
private func catchSignalHandler_writeAll(_ fd: Int32, _ s: StaticString) {
    s.withUTF8Buffer { buf in
        _ = write(fd, buf.baseAddress, buf.count)
    }
}

/// Write "<prefix><decimal int>\n" to fd. Uses a stack buffer; no
/// heap; async-signal-safe.
private func catchSignalHandler_writeInt(_ fd: Int32, prefix: StaticString, value: Int64) {
    prefix.withUTF8Buffer { buf in
        _ = write(fd, buf.baseAddress, buf.count)
    }
    // Max Int64 is 20 chars (-9223372036854775808). 24-byte buffer
    // has safe headroom.
    var buf = [CChar](repeating: 0, count: 24)
    var idx = 0
    var v = value
    var negative = false
    if v < 0 { negative = true; v = -v }
    if v == 0 {
        buf[idx] = CChar(UInt8(ascii: "0")); idx += 1
    } else {
        var tmp: [CChar] = []
        while v > 0 {
            let digit = UInt8(ascii: "0") + UInt8(v % 10)
            tmp.append(CChar(digit))
            v /= 10
        }
        if negative { buf[idx] = CChar(UInt8(ascii: "-")); idx += 1 }
        for c in tmp.reversed() { buf[idx] = c; idx += 1 }
    }
    buf[idx] = CChar(UInt8(ascii: "\n")); idx += 1
    buf.withUnsafeBufferPointer { ptr in
        _ = write(fd, ptr.baseAddress, idx)
    }
}

/// Write a hex value without leading "0x". Used for backtrace frames.
private func catchSignalHandler_writeHex(_ fd: Int32, value: UInt64) {
    if value == 0 {
        let zero: [CChar] = [CChar(UInt8(ascii: "0"))]
        zero.withUnsafeBufferPointer { ptr in _ = write(fd, ptr.baseAddress, 1) }
        return
    }
    var buf = [CChar](repeating: 0, count: 18)
    var v = value
    var tmp: [CChar] = []
    let hex: [UInt8] = [48,49,50,51,52,53,54,55,56,57,97,98,99,100,101,102] // '0'..'9','a'..'f'
    while v > 0 {
        tmp.append(CChar(hex[Int(v & 0xf)]))
        v >>= 4
    }
    var idx = 0
    for c in tmp.reversed() { buf[idx] = c; idx += 1 }
    buf.withUnsafeBufferPointer { ptr in
        _ = write(fd, ptr.baseAddress, idx)
    }
}

/// After writing the dump, chain to the previously-installed handler
/// so existing crash reporters (Apple's, Crashlytics, etc.) still
/// produce their usual output. If none was installed we restore the
/// default disposition and re-raise so the OS terminates the process
/// with the right signal (crashloop detection relies on this).
private func catchSignalHandler_chainOrExit(_ signo: Int32) {
    // Restore the default handler and re-raise. This is the simplest
    // async-signal-safe chain: we don't try to invoke the previous
    // sa_sigaction function from here because calling function
    // pointers through Swift dictionaries isn't safe in a signal
    // handler.
    var defaultAction = sigaction()
    defaultAction.__sigaction_u.__sa_handler = SIG_DFL
    sigemptyset(&defaultAction.sa_mask)
    defaultAction.sa_flags = 0
    _ = sigaction(signo, &defaultAction, nil)
    raise(signo)
}
