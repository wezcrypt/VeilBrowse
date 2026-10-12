import XCTest
@testable import WezCryptSecureStudio

final class SubtitleTests: XCTestCase {
    func testSRTParsing() {
        let srt = """
        1
        00:00:01,000 --> 00:00:03,500
        <i>Hello</i> world

        2
        00:00:04,000 --> 00:00:06,000
        Second line
        continues here

        3
        00:01:00,250 --> 00:01:02,000 position:50%
        مرحبا
        """
        let cues = SubtitleParser.parse(srt)
        XCTAssertEqual(cues.count, 3)
        XCTAssertEqual(cues[0], SubtitleCue(start: 1, end: 3.5, text: "Hello world"))
        XCTAssertEqual(cues[1].text, "Second line\ncontinues here")
        XCTAssertEqual(cues[2].start, 60.25, accuracy: 0.001)
        XCTAssertEqual(cues[2].text, "مرحبا")
        let track = SubtitleTrack(name: "t", cues: cues)
        XCTAssertEqual(track.cue(at: 2)?.text, "Hello world")
        XCTAssertNil(track.cue(at: 3.7), "gap between cues shows nothing")
        XCTAssertEqual(track.cue(at: 5)?.text, "Second line\ncontinues here")
        XCTAssertNil(track.cue(at: 0.5))
        XCTAssertNil(track.cue(at: 500))
    }

    func testWebVTTAndMalformedInput() {
        let vtt = "WEBVTT\r\n\r\n00:01.000 --> 00:02.000\r\nShort form\r\n\r\nbroken --> nonsense\r\nIgnored\r\n\r\n00:05.000 --> 00:04.000\r\nBackwards is ignored\r\n"
        let cues = SubtitleParser.parse(vtt)
        XCTAssertEqual(cues, [SubtitleCue(start: 1, end: 2, text: "Short form")])
        XCTAssertEqual(SubtitleParser.timestamp("01:02:03,500"), 3723.5)
        XCTAssertNil(SubtitleParser.timestamp("abc"))
        XCTAssertTrue(SubtitleParser.parse("").isEmpty)
    }

    func testPlaybackPositionsResumeAndForgetFinished() {
        let defaults = UserDefaults(suiteName: "tests.positions.\(UUID().uuidString)")!
        PlaybackPositions.save(42, duration: 600, for: "a", defaults: defaults)
        XCTAssertEqual(PlaybackPositions.position(for: "a", defaults: defaults), 42)
        PlaybackPositions.save(590, duration: 600, for: "a", defaults: defaults)
        XCTAssertNil(PlaybackPositions.position(for: "a", defaults: defaults), "a finished video starts over")
        PlaybackPositions.save(2, duration: 600, for: "b", defaults: defaults)
        XCTAssertNil(PlaybackPositions.position(for: "b", defaults: defaults))
    }
}

/// Large-image decoding stays bounded: a 9,000 × 6,000 image (54 MP, like a 48 MP ProRAW capture) is decoded
/// to screen size and to the 5,000 px detail limit without materialising the
/// full bitmap.
final class LargeImageTests: XCTestCase {
    func testVeryLargeImageDownsamplesWithinBounds() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("huge-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: 9_000, height: 6_000)
        let data = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.6) { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            context.fill(CGRect(x: 1000, y: 1000, width: 4000, height: 3000))
        }
        try data.write(to: url)
        let start = Date()
        let screen = try XCTUnwrap(ImageDownsampler.downsample(fileURL: url, maxPixelSize: 2_000))
        XCTAssertEqual(max(screen.size.width, screen.size.height), 2_000, accuracy: 1)
        let detail = try XCTUnwrap(ImageDownsampler.downsample(fileURL: url, maxPixelSize: 5_000))
        XCTAssertEqual(max(detail.size.width, detail.size.height), 5_000, accuracy: 1)
        print("[benchmark] decoded 54 MP JPEG to 2,000 px and 5,000 px in \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
    }

    func testEncryptedCacheKeepsOnlyCiphertextAndEvictsLRU() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = MediaCache(directory: directory)
        await cache.setLimit(250_000)
        for index in 0..<4 {
            let url = directory.appendingPathComponent("obj\(index).wzce")
            try Data(repeating: UInt8(index), count: 100_000).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: TimeInterval(index - 10))], ofItemAtPath: url.path)
        }
        _ = await cache.cachedURL("obj0")  // touch: most recently used
        await cache.trim()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(remaining, ["obj0.wzce", "obj3.wzce"])
        let size = await cache.size()
        XCTAssertLessThanOrEqual(size, 250_000)
        await cache.clear()
        let afterClear = await cache.size()
        XCTAssertEqual(afterClear, 0)
    }
}
