import CryptoKit
import Foundation

struct PreparedChunk: Sendable, Equatable {
    let index: Int
    let url: URL
    let size: Int
    let sha256: String
}

struct PreparedObject: Sendable {
    let objectID: String
    let plainSize: Int64
    let plainSHA256: String
    let cipherSize: Int64
    let cipherSHA256: String
    let chunkSize: Int
    let chunks: [PreparedChunk]
}

enum StorageError: Error, LocalizedError, Equatable {
    case lowStorage(needed: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .lowStorage(let needed, let available):
            return String(localized: "Not enough free space on this iPhone (needs \(Formatters.bytes(needed)), \(Formatters.bytes(available)) free).")
        }
    }
}

/// Free-space checks before writing plaintext exports or encrypted chunk files.
struct StorageGuard: Sendable {
    /// Space always left free for the system and other apps.
    var reserve: Int64 = 1_000_000_000
    var availableCapacity: @Sendable () -> Int64? = { AppDirectories.availableDeviceCapacity() }

    func ensure(_ bytes: Int64) throws {
        guard let available = availableCapacity() else { return }
        if available - bytes < reserve {
            throw StorageError.lowStorage(needed: bytes + reserve, available: available)
        }
    }
}

/// Encrypts a plaintext file into WZCE ciphertext split into upload-ready chunk
/// files on disk (required for background URLSession uploads). Memory use is
/// bounded by one segment; plaintext and ciphertext SHA-256 are computed in the
/// same pass, as is the SHA-256 of every chunk.
enum ChunkPreparer {
    static func encrypt(
        file source: URL,
        objectID: Data,
        kek: SymmetricKey,
        segmentSize: Int,
        chunkSize: Int,
        into directory: URL
    ) throws -> PreparedObject {
        let size = UInt64((try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0)
        let encryptor = try WZCE.Encryptor(kek: kek, objectID: objectID, plaintextSize: size, segmentSize: segmentSize)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let writer = try ChunkWriter(directory: directory, prefix: objectID.hexString, chunkSize: chunkSize)
        var plainHasher = SHA256()
        do {
            try writer.write(encryptor.headerData)
            for index in 0..<encryptor.header.segmentCount {
                try Task.checkCancellation()
                try autoreleasepool {
                    let length = encryptor.header.plainLength(ofSegment: index)
                    let block = try input.read(upToCount: length) ?? Data()
                    guard block.count == length else { throw WZCE.Failure.truncated }
                    plainHasher.update(data: block)
                    try writer.write(try encryptor.encryptSegment(index: index, plaintext: block))
                }
            }
            let chunks = try writer.finish()
            return PreparedObject(
                objectID: objectID.hexString,
                plainSize: Int64(size),
                plainSHA256: Data(plainHasher.finalize()).hexString,
                cipherSize: Int64(encryptor.header.ciphertextSize),
                cipherSHA256: writer.totalSHA256,
                chunkSize: chunkSize,
                chunks: chunks
            )
        } catch {
            writer.discard()
            throw error
        }
    }

    static func encrypt(data: Data, objectID: Data, kek: SymmetricKey, chunkSize: Int, into directory: URL) throws -> PreparedObject {
        let temp = directory.appendingPathComponent(UUID().uuidString + ".plain")
        try data.write(to: temp, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        defer { try? FileManager.default.removeItem(at: temp) }
        return try encrypt(file: temp, objectID: objectID, kek: kek, segmentSize: 1024 * 1024, chunkSize: chunkSize, into: directory)
    }
}

/// Writes a byte stream into consecutive chunk files of exactly `chunkSize`
/// bytes (the last one may be shorter).
final class ChunkWriter {
    private let directory: URL
    private let prefix: String
    private let chunkSize: Int
    private var handle: FileHandle?
    private var currentSize = 0
    private var currentHasher = SHA256()
    private var totalHasher = SHA256()
    private var chunks: [PreparedChunk] = []
    private var currentURL: URL?
    private(set) var totalSHA256 = ""

    init(directory: URL, prefix: String, chunkSize: Int) throws {
        precondition(chunkSize > 0)
        self.directory = directory
        self.prefix = prefix
        self.chunkSize = chunkSize
    }

    func write(_ data: Data) throws {
        var offset = data.startIndex
        while offset < data.endIndex {
            if handle == nil { try openChunk() }
            let room = chunkSize - currentSize
            let end = data.index(offset, offsetBy: min(room, data.distance(from: offset, to: data.endIndex)))
            let slice = data[offset..<end]
            try handle?.write(contentsOf: slice)
            currentHasher.update(data: slice)
            totalHasher.update(data: slice)
            currentSize += slice.count
            offset = end
            if currentSize == chunkSize { try closeChunk() }
        }
    }

    func finish() throws -> [PreparedChunk] {
        if handle != nil { try closeChunk() }
        totalSHA256 = Data(totalHasher.finalize()).hexString
        return chunks
    }

    func discard() {
        try? handle?.close()
        handle = nil
        if let currentURL { try? FileManager.default.removeItem(at: currentURL) }
        for chunk in chunks { try? FileManager.default.removeItem(at: chunk.url) }
        chunks.removeAll()
    }

    private func openChunk() throws {
        let url = directory.appendingPathComponent("\(prefix).\(chunks.count).chunk")
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        handle = try FileHandle(forWritingTo: url)
        currentURL = url
        currentSize = 0
        currentHasher = SHA256()
    }

    private func closeChunk() throws {
        try handle?.synchronize()
        try handle?.close()
        handle = nil
        guard let url = currentURL else { return }
        chunks.append(PreparedChunk(index: chunks.count, url: url, size: currentSize, sha256: Data(currentHasher.finalize()).hexString))
        currentURL = nil
    }
}
