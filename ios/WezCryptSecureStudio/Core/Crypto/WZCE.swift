import CryptoKit
import Foundation

/// WZCE v1: the client-side encrypted container format (byte-compatible with
/// `backend/tools/wzce.py`, verified by WZCETests). Full specification in SECURITY.md.
///
/// ```
/// header (104 B): "WZCE" | ver=1 | alg=1 | flags | segment_size u32 | plaintext_size u64
///                 | object_id 16 | nonce_prefix 8 | key_nonce 12 | wrapped_dek 48
/// segment i:      AES-256-GCM(DEK, data_i, nonce = nonce_prefix‖u32(i),
///                             aad = header‖u32(i)‖u8(final))
/// ```
/// * a fresh random DEK per object, wrapped by the vault's file-wrap key;
/// * every segment is bound to the header (object id, sizes), its index and the
///   final flag, so segments cannot be swapped, reordered, truncated or moved
///   between objects.
enum WZCE {
    static let magic = Data("WZCE".utf8)
    static let version: UInt8 = 1
    static let algorithm: UInt8 = 1
    static let headerSize = 104
    static let prefixSize = 44
    static let tagSize = 16
    static let defaultSegmentSize = 4 * 1024 * 1024

    enum Failure: Error, Equatable, LocalizedError {
        case malformedHeader
        case unsupportedVersion
        case wrongObject
        case keyUnwrapFailed
        case segmentAuthenticationFailed(Int)
        case truncated
        case trailingData
        case invalidSegmentLength

        var errorDescription: String? {
            switch self {
            case .malformedHeader: return String(localized: "The encrypted file header is malformed.")
            case .unsupportedVersion: return String(localized: "The encrypted file uses an unsupported format version.")
            case .wrongObject: return String(localized: "The encrypted file belongs to a different item.")
            case .keyUnwrapFailed: return String(localized: "Wrong recovery key, or the encrypted file header is corrupted.")
            case .segmentAuthenticationFailed(let index): return String(localized: "Encrypted data is corrupted or out of order (segment \(index)).")
            case .truncated: return String(localized: "The encrypted file is incomplete.")
            case .trailingData: return String(localized: "The encrypted file has unexpected trailing data.")
            case .invalidSegmentLength: return String(localized: "Invalid segment length.")
            }
        }
    }

    struct Header: Equatable, Sendable {
        var segmentSize: UInt32
        var plaintextSize: UInt64
        var objectID: Data
        var noncePrefix: Data
        var keyNonce: Data
        var wrappedKey: Data

        var prefixBytes: Data {
            var data = Data()
            data.reserveCapacity(WZCE.prefixSize)
            data.append(WZCE.magic)
            data.append(WZCE.version)
            data.append(WZCE.algorithm)
            data.append(.bigEndian(UInt16(0)))
            data.append(.bigEndian(segmentSize))
            data.append(.bigEndian(plaintextSize))
            data.append(objectID)
            data.append(noncePrefix)
            return data
        }

        func serialized() -> Data {
            var data = prefixBytes
            data.append(keyNonce)
            data.append(wrappedKey)
            return data
        }

        init(segmentSize: UInt32, plaintextSize: UInt64, objectID: Data, noncePrefix: Data, keyNonce: Data, wrappedKey: Data) {
            self.segmentSize = segmentSize
            self.plaintextSize = plaintextSize
            self.objectID = objectID
            self.noncePrefix = noncePrefix
            self.keyNonce = keyNonce
            self.wrappedKey = wrappedKey
        }

        init(parsing input: Data) throws {
            let data = Data(input.prefix(WZCE.headerSize))
            guard data.count == WZCE.headerSize else { throw Failure.truncated }
            guard data.subdata(in: 0..<4) == WZCE.magic else { throw Failure.malformedHeader }
            guard data[4] == WZCE.version, data[5] == WZCE.algorithm else { throw Failure.unsupportedVersion }
            segmentSize = data.readBigEndian(UInt32.self, at: 8)
            plaintextSize = data.readBigEndian(UInt64.self, at: 12)
            objectID = data.subdata(in: 20..<36)
            noncePrefix = data.subdata(in: 36..<44)
            keyNonce = data.subdata(in: 44..<56)
            wrappedKey = data.subdata(in: 56..<104)
            guard segmentSize > 0 else { throw Failure.malformedHeader }
        }

        var segmentCount: Int {
            plaintextSize == 0 ? 1 : Int((plaintextSize + UInt64(segmentSize) - 1) / UInt64(segmentSize))
        }

        func plainLength(ofSegment index: Int) -> Int {
            index < segmentCount - 1 ? Int(segmentSize) : Int(plaintextSize - UInt64(segmentSize) * UInt64(segmentCount - 1))
        }

        var ciphertextSize: UInt64 {
            UInt64(WZCE.headerSize) + plaintextSize + UInt64(segmentCount * WZCE.tagSize)
        }

        func segmentOffset(_ index: Int) -> UInt64 {
            UInt64(WZCE.headerSize) + UInt64(index) * UInt64(Int(segmentSize) + WZCE.tagSize)
        }
    }

    static func ciphertextSize(plaintextSize: UInt64, segmentSize: Int) -> UInt64 {
        let segments = plaintextSize == 0 ? 1 : (plaintextSize + UInt64(segmentSize) - 1) / UInt64(segmentSize)
        return UInt64(headerSize) + plaintextSize + segments * UInt64(tagSize)
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "Secure random generator failed")
        return Data(bytes)
    }

    static func segmentNonce(prefix: Data, index: Int) throws -> AES.GCM.Nonce {
        var nonce = prefix
        nonce.append(.bigEndian(UInt32(index)))
        return try AES.GCM.Nonce(data: nonce)
    }

    static func segmentAAD(header: Data, index: Int, final: Bool) -> Data {
        var aad = header
        aad.append(.bigEndian(UInt32(index)))
        aad.append(final ? 1 : 0)
        return aad
    }

    struct Encryptor {
        let header: Header
        let headerData: Data
        private let dataKey: SymmetricKey

        init(kek: SymmetricKey, objectID: Data, plaintextSize: UInt64, segmentSize: Int = WZCE.defaultSegmentSize,
             dataKey: SymmetricKey? = nil, noncePrefix: Data? = nil, keyNonce: Data? = nil) throws {
            precondition(objectID.count == 16, "object id must be 16 bytes")
            let dek = dataKey ?? SymmetricKey(size: .bits256)
            var draft = Header(
                segmentSize: UInt32(segmentSize),
                plaintextSize: plaintextSize,
                objectID: objectID,
                noncePrefix: noncePrefix ?? WZCE.randomBytes(8),
                keyNonce: keyNonce ?? WZCE.randomBytes(12),
                wrappedKey: Data()
            )
            let sealed = try AES.GCM.seal(
                dek.withUnsafeBytes { Data($0) },
                using: kek,
                nonce: AES.GCM.Nonce(data: draft.keyNonce),
                authenticating: draft.prefixBytes
            )
            draft.wrappedKey = sealed.ciphertext + sealed.tag
            header = draft
            headerData = draft.serialized()
            self.dataKey = dek
        }

        func encryptSegment(index: Int, plaintext: Data) throws -> Data {
            guard index >= 0, index < header.segmentCount, plaintext.count == header.plainLength(ofSegment: index) else {
                throw Failure.invalidSegmentLength
            }
            let sealed = try AES.GCM.seal(
                plaintext,
                using: dataKey,
                nonce: WZCE.segmentNonce(prefix: header.noncePrefix, index: index),
                authenticating: WZCE.segmentAAD(header: headerData, index: index, final: index == header.segmentCount - 1)
            )
            return sealed.ciphertext + sealed.tag
        }
    }

    struct Decryptor {
        let header: Header
        let headerData: Data
        private let dataKey: SymmetricKey

        init(headerData input: Data, kek: SymmetricKey, expectedObjectID: Data?) throws {
            let parsed = try Header(parsing: input)
            if let expectedObjectID, expectedObjectID != parsed.objectID { throw Failure.wrongObject }
            do {
                let box = try AES.GCM.SealedBox(
                    nonce: AES.GCM.Nonce(data: parsed.keyNonce),
                    ciphertext: parsed.wrappedKey.prefix(32),
                    tag: parsed.wrappedKey.suffix(16)
                )
                dataKey = SymmetricKey(data: try AES.GCM.open(box, using: kek, authenticating: parsed.prefixBytes))
            } catch {
                throw Failure.keyUnwrapFailed
            }
            header = parsed
            headerData = parsed.serialized()
        }

        func decryptSegment(index: Int, ciphertext input: Data) throws -> Data {
            let expected = header.plainLength(ofSegment: index) + WZCE.tagSize
            let ciphertext = Data(input)
            guard index >= 0, index < header.segmentCount, ciphertext.count == expected else { throw Failure.truncated }
            do {
                let box = try AES.GCM.SealedBox(
                    nonce: WZCE.segmentNonce(prefix: header.noncePrefix, index: index),
                    ciphertext: ciphertext.prefix(expected - WZCE.tagSize),
                    tag: ciphertext.suffix(WZCE.tagSize)
                )
                return try AES.GCM.open(box, using: dataKey,
                                        authenticating: WZCE.segmentAAD(header: headerData, index: index, final: index == header.segmentCount - 1))
            } catch {
                throw Failure.segmentAuthenticationFailed(index)
            }
        }
    }

    // MARK: - In-memory helpers (manifests, thumbnails, tests)

    static func encrypt(_ plaintext: Data, kek: SymmetricKey, objectID: Data, segmentSize: Int = defaultSegmentSize) throws -> Data {
        let data = Data(plaintext)
        let encryptor = try Encryptor(kek: kek, objectID: objectID, plaintextSize: UInt64(data.count), segmentSize: segmentSize)
        var output = encryptor.headerData
        output.reserveCapacity(Int(encryptor.header.ciphertextSize))
        for index in 0..<encryptor.header.segmentCount {
            let start = index * segmentSize
            output.append(try encryptor.encryptSegment(index: index, plaintext: data.subdata(in: start..<min(start + segmentSize, data.count))))
        }
        return output
    }

    static func decrypt(_ blob: Data, kek: SymmetricKey, expectedObjectID: Data?) throws -> Data {
        let data = Data(blob)
        let decryptor = try Decryptor(headerData: data, kek: kek, expectedObjectID: expectedObjectID)
        let header = decryptor.header
        guard UInt64(data.count) >= header.ciphertextSize else { throw Failure.truncated }
        guard UInt64(data.count) == header.ciphertextSize else { throw Failure.trailingData }
        var output = Data()
        output.reserveCapacity(Int(header.plaintextSize))
        for index in 0..<header.segmentCount {
            let start = Int(header.segmentOffset(index))
            let length = header.plainLength(ofSegment: index) + tagSize
            output.append(try decryptor.decryptSegment(index: index, ciphertext: data.subdata(in: start..<(start + length))))
        }
        return output
    }

    // MARK: - Streaming file decryption (restore)

    /// Decrypts `source` into `destination`, authenticating every segment.
    /// Memory use is bounded by one segment. Returns the plaintext SHA-256 (hex).
    @discardableResult
    static func decryptFile(at source: URL, to destination: URL, kek: SymmetricKey, expectedObjectID: Data?) throws -> String {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let decryptor = try Decryptor(headerData: try input.read(upToCount: headerSize) ?? Data(), kek: kek, expectedObjectID: expectedObjectID)
        FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete])
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var hasher = SHA256()
        for index in 0..<decryptor.header.segmentCount {
            try Task.checkCancellation()
            try autoreleasepool {
                let length = decryptor.header.plainLength(ofSegment: index) + tagSize
                let blob = try input.read(upToCount: length) ?? Data()
                guard blob.count == length else { throw Failure.truncated }
                let plain = try decryptor.decryptSegment(index: index, ciphertext: blob)
                hasher.update(data: plain)
                try output.write(contentsOf: plain)
            }
        }
        if let extra = try input.read(upToCount: 1), !extra.isEmpty { throw Failure.trailingData }
        return Data(hasher.finalize()).hexString
    }
}
