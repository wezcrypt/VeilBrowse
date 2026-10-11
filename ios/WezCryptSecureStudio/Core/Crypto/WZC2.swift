import CryptoKit
import Foundation

/// Swift implementation of the WZC2 segmented AES-256-GCM container, byte-for-byte
/// compatible with `backend/wezcrypt_mobile/crypto.py` (verified by WZC2InteropTests).
///
/// Used today for the on-device encrypted cache, and designed for future
/// client-side (end-to-end) encryption where the data key is wrapped by a key
/// that never leaves the user's devices (`clientKeyID`).
enum WZC2 {
    static let magic = Data("WZC2".utf8)
    static let version: UInt8 = 1
    static let headerSize = 89
    static let tagSize = 16
    static let clientKeyID: UInt32 = 0xFFFF_FFFF
    static let defaultSegmentSize = 1 << 20

    enum Failure: Error, Equatable, LocalizedError {
        case malformedHeader
        case unsupportedVersion(UInt8)
        case unknownKey(UInt32)
        case keyUnwrapFailed
        case segmentAuthenticationFailed(Int)
        case truncated
        case invalidSegmentLength
        case rangeOutOfBounds

        var errorDescription: String? {
            switch self {
            case .malformedHeader: return "The encrypted container header is malformed."
            case .unsupportedVersion(let version): return "Unsupported container version \(version)."
            case .unknownKey(let id): return "No key is available for key id \(id)."
            case .keyUnwrapFailed: return "The data key could not be unwrapped."
            case .segmentAuthenticationFailed(let index): return "Segment \(index) failed authentication."
            case .truncated: return "The encrypted container is truncated."
            case .invalidSegmentLength: return "Invalid segment length."
            case .rangeOutOfBounds: return "Requested range is out of bounds."
            }
        }
    }

    struct Header: Equatable, Sendable {
        var segmentSize: UInt32
        var keyID: UInt32
        var wrapNonce: Data
        var wrappedKey: Data
        var noncePrefix: Data
        var plaintextSize: UInt64

        func serialized() -> Data {
            var data = Data()
            data.reserveCapacity(WZC2.headerSize)
            data.append(WZC2.magic)
            data.append(WZC2.version)
            data.append(.bigEndian(segmentSize))
            data.append(.bigEndian(keyID))
            data.append(wrapNonce)
            data.append(wrappedKey)
            data.append(noncePrefix)
            data.append(.bigEndian(plaintextSize))
            return data
        }

        init(segmentSize: UInt32, keyID: UInt32, wrapNonce: Data, wrappedKey: Data, noncePrefix: Data, plaintextSize: UInt64) {
            self.segmentSize = segmentSize
            self.keyID = keyID
            self.wrapNonce = wrapNonce
            self.wrappedKey = wrappedKey
            self.noncePrefix = noncePrefix
            self.plaintextSize = plaintextSize
        }

        init(parsing input: Data) throws {
            let data = Data(input.prefix(WZC2.headerSize))
            guard data.count == WZC2.headerSize else { throw Failure.truncated }
            guard data.subdata(in: 0..<4) == WZC2.magic else { throw Failure.malformedHeader }
            guard data[4] == WZC2.version else { throw Failure.unsupportedVersion(data[4]) }
            segmentSize = data.readBigEndian(UInt32.self, at: 5)
            keyID = data.readBigEndian(UInt32.self, at: 9)
            wrapNonce = data.subdata(in: 13..<25)
            wrappedKey = data.subdata(in: 25..<73)
            noncePrefix = data.subdata(in: 73..<81)
            plaintextSize = data.readBigEndian(UInt64.self, at: 81)
            guard segmentSize > 0, segmentSize <= 64 << 20 else { throw Failure.malformedHeader }
        }

        var segmentCount: Int {
            plaintextSize == 0 ? 1 : Int((plaintextSize + UInt64(segmentSize) - 1) / UInt64(segmentSize))
        }

        func plainLength(ofSegment index: Int) throws -> Int {
            guard index >= 0, index < segmentCount else { throw Failure.rangeOutOfBounds }
            if index < segmentCount - 1 { return Int(segmentSize) }
            return Int(plaintextSize - UInt64(segmentSize) * UInt64(segmentCount - 1))
        }

        func segmentOffset(_ index: Int) -> UInt64 {
            UInt64(WZC2.headerSize) + UInt64(index) * UInt64(Int(segmentSize) + WZC2.tagSize)
        }

        var ciphertextSize: UInt64 {
            UInt64(WZC2.headerSize) + plaintextSize + UInt64(segmentCount * WZC2.tagSize)
        }
    }

    static func wrapAAD(segmentSize: UInt32, keyID: UInt32) -> Data {
        var data = magic
        data.append(version)
        data.append(.bigEndian(segmentSize))
        data.append(.bigEndian(keyID))
        return data
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

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    struct Encryptor {
        let header: Header
        let headerData: Data
        private let dataKey: SymmetricKey

        init(
            kek: SymmetricKey,
            keyID: UInt32,
            plaintextSize: UInt64,
            segmentSize: Int = WZC2.defaultSegmentSize,
            dataKey: SymmetricKey? = nil,
            wrapNonce: Data? = nil,
            noncePrefix: Data? = nil
        ) throws {
            let dek = dataKey ?? SymmetricKey(size: .bits256)
            let nonceData = wrapNonce ?? WZC2.randomBytes(12)
            let sealed = try AES.GCM.seal(
                dek.withUnsafeBytes { Data($0) },
                using: kek,
                nonce: AES.GCM.Nonce(data: nonceData),
                authenticating: WZC2.wrapAAD(segmentSize: UInt32(segmentSize), keyID: keyID)
            )
            header = Header(
                segmentSize: UInt32(segmentSize),
                keyID: keyID,
                wrapNonce: nonceData,
                wrappedKey: sealed.ciphertext + sealed.tag,
                noncePrefix: noncePrefix ?? WZC2.randomBytes(8),
                plaintextSize: plaintextSize
            )
            headerData = header.serialized()
            self.dataKey = dek
        }

        func encryptSegment(index: Int, plaintext: Data) throws -> Data {
            guard plaintext.count == (try header.plainLength(ofSegment: index)) else { throw Failure.invalidSegmentLength }
            let final = index == header.segmentCount - 1
            let sealed = try AES.GCM.seal(
                plaintext,
                using: dataKey,
                nonce: WZC2.segmentNonce(prefix: header.noncePrefix, index: index),
                authenticating: WZC2.segmentAAD(header: headerData, index: index, final: final)
            )
            return sealed.ciphertext + sealed.tag
        }
    }

    struct Decryptor {
        let header: Header
        let headerData: Data
        private let dataKey: SymmetricKey

        init(headerData input: Data, keyProvider: (UInt32) -> SymmetricKey?) throws {
            header = try Header(parsing: input)
            headerData = header.serialized()
            guard let kek = keyProvider(header.keyID) else { throw Failure.unknownKey(header.keyID) }
            do {
                let box = try AES.GCM.SealedBox(
                    nonce: AES.GCM.Nonce(data: header.wrapNonce),
                    ciphertext: header.wrappedKey.prefix(32),
                    tag: header.wrappedKey.suffix(16)
                )
                let raw = try AES.GCM.open(box, using: kek, authenticating: WZC2.wrapAAD(segmentSize: header.segmentSize, keyID: header.keyID))
                dataKey = SymmetricKey(data: raw)
            } catch {
                throw Failure.keyUnwrapFailed
            }
        }

        func decryptSegment(index: Int, ciphertext input: Data) throws -> Data {
            let expected = try header.plainLength(ofSegment: index) + WZC2.tagSize
            let ciphertext = Data(input)
            guard ciphertext.count == expected else { throw Failure.truncated }
            let final = index == header.segmentCount - 1
            do {
                let box = try AES.GCM.SealedBox(
                    nonce: WZC2.segmentNonce(prefix: header.noncePrefix, index: index),
                    ciphertext: ciphertext.prefix(expected - WZC2.tagSize),
                    tag: ciphertext.suffix(WZC2.tagSize)
                )
                return try AES.GCM.open(box, using: dataKey, authenticating: WZC2.segmentAAD(header: headerData, index: index, final: final))
            } catch {
                throw Failure.segmentAuthenticationFailed(index)
            }
        }
    }

    // MARK: - Convenience

    static func encrypt(_ plaintext: Data, kek: SymmetricKey, keyID: UInt32, segmentSize: Int = defaultSegmentSize) throws -> Data {
        let data = Data(plaintext)
        let encryptor = try Encryptor(kek: kek, keyID: keyID, plaintextSize: UInt64(data.count), segmentSize: segmentSize)
        var output = encryptor.headerData
        output.reserveCapacity(Int(encryptor.header.ciphertextSize))
        for index in 0..<encryptor.header.segmentCount {
            let start = index * segmentSize
            let end = min(start + segmentSize, data.count)
            output.append(try encryptor.encryptSegment(index: index, plaintext: data.subdata(in: start..<end)))
        }
        return output
    }

    static func decrypt(_ blob: Data, keyProvider: (UInt32) -> SymmetricKey?) throws -> Data {
        let data = Data(blob)
        let decryptor = try Decryptor(headerData: data, keyProvider: keyProvider)
        let header = decryptor.header
        guard UInt64(data.count) == header.ciphertextSize else { throw Failure.truncated }
        var output = Data()
        output.reserveCapacity(Int(header.plaintextSize))
        for index in 0..<header.segmentCount {
            let start = Int(header.segmentOffset(index))
            let length = try header.plainLength(ofSegment: index) + tagSize
            output.append(try decryptor.decryptSegment(index: index, ciphertext: data.subdata(in: start..<(start + length))))
        }
        return output
    }

    static func decrypt(_ blob: Data, kek: SymmetricKey) throws -> Data {
        try decrypt(blob) { _ in kek }
    }

    /// Streams a file into a WZC2 container without loading it into memory.
    static func encryptFile(at source: URL, to destination: URL, kek: SymmetricKey, keyID: UInt32, segmentSize: Int = defaultSegmentSize) throws {
        let size = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? UInt64 ?? 0
        let encryptor = try Encryptor(kek: kek, keyID: keyID, plaintextSize: size, segmentSize: segmentSize)
        FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete])
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }
        try output.write(contentsOf: encryptor.headerData)
        for index in 0..<encryptor.header.segmentCount {
            try Task.checkCancellation()
            let length = try encryptor.header.plainLength(ofSegment: index)
            let chunk = try input.read(upToCount: length) ?? Data()
            try output.write(contentsOf: try encryptor.encryptSegment(index: index, plaintext: chunk))
        }
    }

    /// Decrypts a plaintext byte range from a WZC2 file, touching only the needed segments.
    static func decryptRange(of url: URL, range: Range<UInt64>, keyProvider: (UInt32) -> SymmetricKey?) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let headerData = try handle.read(upToCount: headerSize) ?? Data()
        let decryptor = try Decryptor(headerData: headerData, keyProvider: keyProvider)
        let header = decryptor.header
        guard range.lowerBound < range.upperBound, range.upperBound <= header.plaintextSize else { throw Failure.rangeOutOfBounds }
        let segment = UInt64(header.segmentSize)
        let first = Int(range.lowerBound / segment)
        let last = Int((range.upperBound - 1) / segment)
        var output = Data()
        for index in first...last {
            try handle.seek(toOffset: header.segmentOffset(index))
            let length = try header.plainLength(ofSegment: index) + tagSize
            let ciphertext = try handle.read(upToCount: length) ?? Data()
            let plain = try decryptor.decryptSegment(index: index, ciphertext: ciphertext)
            let segmentStart = UInt64(index) * segment
            let lower = Int(max(range.lowerBound, segmentStart) - segmentStart)
            let upper = Int(min(range.upperBound, segmentStart + UInt64(plain.count)) - segmentStart)
            output.append(plain.subdata(in: lower..<upper))
        }
        return output
    }
}
