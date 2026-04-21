import Foundation
import MachO

// Build a CatchStackTrace from either:
//   - Thread.callStackReturnAddresses (preferred — pre-symbolicated
//                                       raw instruction pointers)
//   - Thread.callStackSymbols         (fallback — pre-resolved strings,
//                                       used for NSError / Swift error
//                                       captures where return addresses
//                                       aren't available)
//
// Frames carry `instruction_addr` + `addr_mode = "rel:N"` pointing at
// the debug-image index, letting the server-side symbolicator subtract
// the ASLR slide and resolve against the dSYM.

enum CatchStackBuilder {

    /// Build from raw return addresses (preferred path).
    static func build(from addresses: [NSNumber], images: [CatchDebugImage]) -> CatchStackTrace {
        var frames: [CatchStackFrame] = []
        frames.reserveCapacity(addresses.count)
        for n in addresses {
            let addr = UInt64(truncating: n)
            frames.append(buildFrame(addr: addr, images: images))
        }
        // Oldest-first per the wire contract — callStackReturnAddresses
        // is newest-first (caller of top is at index 0? Actually the top
        // of the stack — the most-recent frame — is at index 0). Flip it.
        return CatchStackTrace(frames: frames.reversed())
    }

    /// Build from pre-resolved strings. Used when raw addresses are
    /// unavailable (NSError, arbitrary Swift throws).
    static func buildFromSymbols(_ symbols: [String]) -> CatchStackTrace {
        var frames: [CatchStackFrame] = []
        frames.reserveCapacity(symbols.count)
        for line in symbols {
            frames.append(parseSymbolLine(line))
        }
        return CatchStackTrace(frames: frames.reversed())
    }

    // MARK: - Internals

    private static func buildFrame(addr: UInt64, images: [CatchDebugImage]) -> CatchStackFrame {
        let imageAddrStr = String(format: "0x%llx", addr)
        // Find the image whose range [image_addr, image_addr + image_size)
        // contains addr. O(n) per frame is fine — even large apps load
        // fewer than ~1000 images, and stacks are at most ~100 frames.
        for (idx, img) in images.enumerated() {
            let base = parseHex(img.image_addr) ?? 0
            let size = UInt64(img.image_size ?? 0)
            if size == 0 { continue }
            if addr >= base && addr < base + size {
                return CatchStackFrame(
                    platform: "cocoa",
                    instruction_addr: imageAddrStr,
                    package: URL(fileURLWithPath: img.code_file ?? "").lastPathComponent,
                    addr_mode: "rel:\(idx)"
                )
            }
        }
        // No matching image — still emit the frame with absolute mode.
        // The symbolicator will skip it.
        return CatchStackFrame(
            platform: "cocoa",
            instruction_addr: imageAddrStr,
            addr_mode: "abs"
        )
    }

    // Parses lines of the shape:
    //   "3   MyApp                               0x0000000102345ab4  MyClass.foo() + 72"
    //
    // Columns: [index, package, address, ...function + " + offset"].
    // The function tail can contain spaces so we join everything
    // after the address. Whitespace-split is preferred over the
    // deprecated Scanner API.
    private static func parseSymbolLine(_ raw: String) -> CatchStackFrame {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            return CatchStackFrame(platform: "cocoa")
        }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3 else {
            return CatchStackFrame(platform: "cocoa")
        }
        var frame = CatchStackFrame(platform: "cocoa")
        frame.package = String(parts[1])
        frame.instruction_addr = String(parts[2])
        if parts.count > 3 {
            let tail = parts.dropFirst(3).joined(separator: " ")
            if !tail.isEmpty {
                // Drop " + N" offset suffix if present.
                if let plus = tail.range(of: " + ") {
                    frame.function = String(tail[..<plus.lowerBound])
                } else {
                    frame.function = tail
                }
            }
        }
        return frame
    }

    private static func parseHex(_ s: String) -> UInt64? {
        var str = s
        if str.hasPrefix("0x") || str.hasPrefix("0X") { str = String(str.dropFirst(2)) }
        return UInt64(str, radix: 16)
    }
}
