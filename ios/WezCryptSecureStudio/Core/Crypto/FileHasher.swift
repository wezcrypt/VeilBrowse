import CryptoKit
import Foundation

enum FileHasher {
    /// Streaming SHA-256 of a file; memory use is bounded by `chunkSize`.
    static func sha256Hex(of url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try autoreleasepool { try handle.read(upToCount: chunkSize) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize()).hexString
    }

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func sha256Hex(_ data: Data) -> String {
        sha256(data).hexString
    }

    static func sha256Base64(_ data: Data) -> String {
        sha256(data).base64EncodedString()
    }
}
