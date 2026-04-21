import Foundation
import MachO

// Debug-meta capture — builds the CatchDebugImage table from dyld so
// the M5 symbolicator can match native frames to their dSYMs under
// ASLR.
//
// Output: one CatchDebugImage per loaded Mach-O image, with:
//   - type:         "macho"
//   - debug_id:     the LC_UUID formatted as a standard UUID string
//   - image_addr:   "0x" + hex address where dyld loaded this image
//                   in the current process (the ASLR-randomised base)
//   - image_vmaddr: "0x" + hex of the linker's __TEXT vmaddr, for
//                   `file_offset = addr - image_addr + image_vmaddr`
//   - image_size:   __TEXT segment size
//   - code_file:    absolute path of the dylib on device
//   - arch:         "arm64" / "x86_64" etc.
//
// Keep this cheap — it runs once per error event. dyld's image table
// is in-process and scan-only, no syscalls.

enum CatchDebugMetaCapture {

    /// Build the debug-image list for every Mach-O currently loaded
    /// in this process. Called at error-event composition time.
    static func capture() -> CatchDebugMeta {
        var images: [CatchDebugImage] = []
        let count = _dyld_image_count()
        images.reserveCapacity(Int(count))
        for i in 0..<count {
            if let image = buildImage(at: i) {
                images.append(image)
            }
        }
        return CatchDebugMeta(images: images, sdk_info: sdkInfo())
    }

    // MARK: - Per-image walk

    private static func buildImage(at idx: UInt32) -> CatchDebugImage? {
        guard let header = _dyld_get_image_header(idx) else { return nil }
        let namePtr = _dyld_get_image_name(idx)
        let path = namePtr.map { String(cString: $0) } ?? ""
        let slide = _dyld_get_image_vmaddr_slide(idx)
        let imageAddr = UInt(bitPattern: header)

        // Walk load commands to grab LC_UUID + __TEXT segment info.
        var uuidString: String?
        var textVMAddr: UInt64 = 0
        var textVMSize: UInt64 = 0

        let is64 = is64BitHeader(header)
        var cmdPtr: UnsafeRawPointer
        var ncmds: UInt32
        if is64 {
            let h = header.withMemoryRebound(to: mach_header_64.self, capacity: 1) { $0.pointee }
            ncmds = h.ncmds
            cmdPtr = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        } else {
            let h = header.pointee
            ncmds = h.ncmds
            cmdPtr = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header>.size)
        }

        for _ in 0..<ncmds {
            let cmd = cmdPtr.load(as: load_command.self)
            switch cmd.cmd {
            case UInt32(LC_UUID):
                let uuidCmd = cmdPtr.load(as: uuid_command.self)
                uuidString = uuidStringFrom(uuidCmd.uuid)
            case UInt32(LC_SEGMENT_64):
                let seg = cmdPtr.load(as: segment_command_64.self)
                let segName = segmentName(seg.segname)
                if segName == "__TEXT" {
                    textVMAddr = seg.vmaddr
                    textVMSize = seg.vmsize
                }
            case UInt32(LC_SEGMENT):
                let seg = cmdPtr.load(as: segment_command.self)
                let segName = segmentName(seg.segname)
                if segName == "__TEXT" {
                    textVMAddr = UInt64(seg.vmaddr)
                    textVMSize = UInt64(seg.vmsize)
                }
            default:
                break
            }
            cmdPtr = cmdPtr.advanced(by: Int(cmd.cmdsize))
        }

        guard let uuid = uuidString else { return nil }

        return CatchDebugImage(
            type: "macho",
            debug_id: uuid,
            code_id: nil,
            code_file: path.isEmpty ? nil : path,
            image_addr: hexAddress(UInt64(imageAddr)),
            image_size: textVMSize > 0 ? Int64(textVMSize) : nil,
            image_vmaddr: textVMAddr > 0 ? hexAddress(textVMAddr) : nil,
            arch: currentArch(slide: slide)
        )
    }

    // MARK: - Helpers

    private static func is64BitHeader(_ p: UnsafePointer<mach_header>) -> Bool {
        let magic = p.pointee.magic
        return magic == MH_MAGIC_64 || magic == MH_CIGAM_64
    }

    private static func hexAddress(_ addr: UInt64) -> String {
        return String(format: "0x%llx", addr)
    }

    private static func uuidStringFrom(_ raw: (UInt8, UInt8, UInt8, UInt8,
                                               UInt8, UInt8, UInt8, UInt8,
                                               UInt8, UInt8, UInt8, UInt8,
                                               UInt8, UInt8, UInt8, UInt8)) -> String {
        let bytes: [UInt8] = [
            raw.0, raw.1, raw.2, raw.3, raw.4, raw.5, raw.6, raw.7,
            raw.8, raw.9, raw.10, raw.11, raw.12, raw.13, raw.14, raw.15,
        ]
        let u = NSUUID(uuidBytes: bytes)
        return u.uuidString
    }

    private static func segmentName(_ raw: (Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8,
                                            Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8)) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = UInt8(bitPattern: raw.0); bytes[1] = UInt8(bitPattern: raw.1)
        bytes[2] = UInt8(bitPattern: raw.2); bytes[3] = UInt8(bitPattern: raw.3)
        bytes[4] = UInt8(bitPattern: raw.4); bytes[5] = UInt8(bitPattern: raw.5)
        bytes[6] = UInt8(bitPattern: raw.6); bytes[7] = UInt8(bitPattern: raw.7)
        bytes[8] = UInt8(bitPattern: raw.8); bytes[9] = UInt8(bitPattern: raw.9)
        bytes[10] = UInt8(bitPattern: raw.10); bytes[11] = UInt8(bitPattern: raw.11)
        bytes[12] = UInt8(bitPattern: raw.12); bytes[13] = UInt8(bitPattern: raw.13)
        bytes[14] = UInt8(bitPattern: raw.14); bytes[15] = UInt8(bitPattern: raw.15)
        return String(bytes: bytes, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
    }

    private static func currentArch(slide: Int) -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #elseif arch(i386)
        return "i386"
        #elseif arch(arm)
        return "armv7"
        #else
        return "unknown"
        #endif
    }

    private static func sdkInfo() -> CatchDebugSDKInfo {
        #if os(iOS)
        let name = "iOS"
        #elseif os(macOS)
        let name = "macOS"
        #elseif os(tvOS)
        let name = "tvOS"
        #elseif os(watchOS)
        let name = "watchOS"
        #else
        let name = "AppleOS"
        #endif
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return CatchDebugSDKInfo(
            sdk_name: name,
            version_major: version.majorVersion,
            version_minor: version.minorVersion,
            version_patchlevel: version.patchVersion
        )
    }
}
