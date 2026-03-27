import Foundation
import Compression
import zlib

extension Data {
    /// Compresses the data using standard GZIP (RFC 1952) format.
    /// This includes the 10-byte header and 8-byte trailer (CRC32 + length),
    /// which `NSData.compressed(using: .zlib)` does NOT provide.
    func sankofa_gzipped() -> Data? {
        guard !self.isEmpty else { return self }

        var stream = z_stream()
        stream.next_in = UnsafeMutablePointer<Bytef>(mutating: (self as NSData).bytes.bindMemory(to: Bytef.self, capacity: self.count))
        stream.avail_in = uint(self.count)
        stream.total_out = 0

        // windowBits 31 = GZIP header/footer (16 + 15)
        let status = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        
        guard status == Z_OK else { return nil }

        var compressed = Data(capacity: self.count / 2)
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<Bytef>.allocate(capacity: bufferSize)
        defer {
            deflateEnd(&stream)
            buffer.deallocate()
        }

        while stream.avail_out == 0 {
            stream.next_out = buffer
            stream.avail_out = uint(bufferSize)
            deflate(&stream, Z_FINISH)
            let count = bufferSize - Int(stream.avail_out)
            if count > 0 {
                compressed.append(buffer, count: count)
            }
        }

        return compressed
    }
}
