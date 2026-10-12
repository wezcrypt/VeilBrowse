import Foundation

/// External subtitles (SubRip .srt and WebVTT .vtt) loaded from the Files app and
/// rendered by the player's own overlay. Embedded subtitle tracks are handled by
/// AVFoundation's media-selection groups instead.
struct SubtitleCue: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

struct SubtitleTrack: Sendable, Equatable {
    let name: String
    let cues: [SubtitleCue]

    /// Cue visible at `time` (binary search; cues are sorted by start).
    func cue(at time: TimeInterval) -> SubtitleCue? {
        var low = 0
        var high = cues.count - 1
        var candidate: Int?
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].start <= time {
                candidate = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard let index = candidate else { return nil }
        // Overlapping cues: walk back to find one still on screen.
        var i = index
        while i >= 0 && i > index - 4 {
            if cues[i].start <= time && time < cues[i].end { return cues[i] }
            i -= 1
        }
        return nil
    }
}

enum SubtitleParser {
    enum Failure: Error, LocalizedError, Equatable {
        case unreadable
        case empty

        var errorDescription: String? {
            switch self {
            case .unreadable: return String(localized: "The subtitle file could not be read (use UTF-8 .srt or .vtt).")
            case .empty: return String(localized: "The subtitle file contains no subtitles.")
            }
        }
    }

    static let maximumBytes = 5 * 1024 * 1024

    static func load(_ url: URL) throws -> SubtitleTrack {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw Failure.unreadable }
        let arabic = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsArabic.rawValue)))
        // UTF-8 first, then Windows-1256 (common for Arabic .srt files), then Latin-1.
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: arabic) ?? String(data: data, encoding: .isoLatin1) else {
            throw Failure.unreadable
        }
        let cues = parse(text)
        guard !cues.isEmpty else { throw Failure.empty }
        return SubtitleTrack(name: url.deletingPathExtension().lastPathComponent, cues: cues)
    }

    /// Parses SRT or WebVTT text into cues sorted by start time. Formatting tags are removed.
    static func parse(_ raw: String) -> [SubtitleCue] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        var cues: [SubtitleCue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2, let start = timestamp(parts[0]),
                  let end = timestamp(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""),
                  end > start else { continue }
            let body = lines[(timingIndex + 1)...].map(stripTags).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: body))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// "00:01:02,345", "01:02.345" or "00:01:02.345" → seconds.
    static func timestamp(_ raw: String) -> TimeInterval? {
        let value = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let fields = value.split(separator: ":").map(String.init)
        guard (2...3).contains(fields.count) else { return nil }
        var seconds: TimeInterval = 0
        for field in fields {
            guard let number = Double(field), number >= 0 else { return nil }
            seconds = seconds * 60 + number
        }
        return seconds
    }

    private static func stripTags(_ line: String) -> String {
        line.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\{\\\\[^}]*\\}", with: "", options: .regularExpression)
    }
}
