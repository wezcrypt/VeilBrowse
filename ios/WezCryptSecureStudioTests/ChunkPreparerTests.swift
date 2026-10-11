import CryptoKit
import Darwin
import XCTest
@testable import WezCryptSecureStudio

final class ChunkPreparerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    static func writeRandomFile(_ url: URL, size: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var remaining = size
        while remaining > 0 {
            let block = min(remaining, 4 << 20)
            try handle.write(contentsOf: WZCE.randomBytes(block))
            remaining -= block
        }
    }

    func testLargeFileChunksReassembleAndDecrypt() throws {
        let source = directory.appendingPathComponent("video.mov")
        try Self.writeRandomFile(source, size: 41 * 1024 * 1024 + 777)
        let kek = SymmetricKey(size: .bits256)
        let id = WZCE.randomBytes(16)
        let chunkSize = 16 * 1024 * 1024
        let prepared = try ChunkPreparer.encrypt(file: source, objectID: id, kek: kek, segmentSize: WZCE.defaultSegmentSize, chunkSize: chunkSize, into: directory)
        XCTAssertEqual(prepared.chunks.count, 3)
        XCTAssertEqual(prepared.chunks.dropLast().map(\.size), [chunkSize, chunkSize])
        XCTAssertEqual(Int64(prepared.chunks.map(\.size).reduce(0, +)), prepared.cipherSize)
        XCTAssertEqual(prepared.plainSHA256, try FileHasher.sha256Hex(of: source))

        let assembled = directory.appendingPathComponent("assembled.wzce")
        FileManager.default.createFile(atPath: assembled.path, contents: nil)
        let out = try FileHandle(forWritingTo: assembled)
        for chunk in prepared.chunks {
            let data = try Data(contentsOf: chunk.url)
            XCTAssertEqual(FileHasher.sha256Hex(data), chunk.sha256)
            try out.write(contentsOf: data)
        }
        try out.close()
        XCTAssertEqual(try FileHasher.sha256Hex(of: assembled), prepared.cipherSHA256)
        let restored = directory.appendingPathComponent("restored.mov")
        let sha = try WZCE.decryptFile(at: assembled, to: restored, kek: kek, expectedObjectID: id)
        XCTAssertEqual(sha, prepared.plainSHA256)
        XCTAssertTrue(FileManager.default.contentsEqual(atPath: source.path, andPath: restored.path))
    }

    func testEncryptionMemoryStaysBounded() throws {
        let source = directory.appendingPathComponent("big.bin")
        try Self.writeRandomFile(source, size: 120 * 1024 * 1024)
        let before = Self.residentMemory()
        var peak = before
        let prepared = try ChunkPreparer.encrypt(file: source, objectID: WZCE.randomBytes(16), kek: SymmetricKey(size: .bits256),
                                                 segmentSize: WZCE.defaultSegmentSize, chunkSize: 16 << 20, into: directory)
        peak = max(peak, Self.residentMemory())
        print("[benchmark] encrypting 120 MB grew resident memory by \(Formatters.bytes(Int64(peak) - Int64(before)))")
        XCTAssertLessThan(Int64(peak) - Int64(before), 80 * 1024 * 1024, "the whole file must never be loaded into memory")
        XCTAssertEqual(prepared.chunks.count, 8)
    }

    func testEncryptionThroughputBenchmark() throws {
        let source = directory.appendingPathComponent("bench.bin")
        try Self.writeRandomFile(source, size: 64 * 1024 * 1024)
        for (segment, chunk) in [(1 << 20, 8 << 20), (4 << 20, 8 << 20), (4 << 20, 16 << 20), (8 << 20, 16 << 20)] {
            let start = Date()
            let prepared = try ChunkPreparer.encrypt(file: source, objectID: WZCE.randomBytes(16), kek: SymmetricKey(size: .bits256),
                                                     segmentSize: segment, chunkSize: chunk, into: directory)
            let seconds = Date().timeIntervalSince(start)
            print("[benchmark] encrypt 64 MB segment=\(segment >> 20)MB chunk=\(chunk >> 20)MB: \(String(format: "%.2f", seconds)) s, \(Formatters.speed(64 * 1024 * 1024 / seconds))")
            prepared.chunks.forEach { try? FileManager.default.removeItem(at: $0.url) }
        }
    }

    func testLowStorageGuard() {
        let guardTight = StorageGuard(reserve: 1_000_000_000, availableCapacity: { 500_000_000 })
        XCTAssertThrowsError(try guardTight.ensure(10)) { error in
            guard case StorageError.lowStorage = error else { return XCTFail("expected lowStorage") }
        }
        let guardRoomy = StorageGuard(reserve: 1_000_000_000, availableCapacity: { 5_000_000_000 })
        XCTAssertNoThrow(try guardRoomy.ensure(1_000_000_000))
    }

    static func residentMemory() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}
