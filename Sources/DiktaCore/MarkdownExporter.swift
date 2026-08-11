import Foundation

/// Writes the `index.md` that pairs every captured frame ("slide") with what
/// was said while it was on screen, followed by the full transcript.
enum MarkdownExporter {
    /// A kept frame: its path relative to the output directory, and the time in
    /// the recording at which it appeared.
    struct Frame: Sendable {
        let file: String
        let timestamp: TimeInterval

        init(file: String, timestamp: TimeInterval) {
            self.file = file
            self.timestamp = timestamp
        }
    }

    /// Build `index.md` in `directory` and return its URL.
    @discardableResult
    static func write(title: String, date: Date, duration: TimeInterval,
                      frames: [Frame], segments: [TranscriptSegment],
                      to directory: URL) throws -> URL {
        let markdown = render(title: title, date: date, duration: duration,
                              frames: frames, segments: segments)
        let url = directory.appendingPathComponent("index.md")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Pure rendering — separated from disk I/O so it is easy to reason about
    /// (and to test) on its own.
    static func render(title: String, date: Date, duration: TimeInterval,
                       frames: [Frame], segments: [TranscriptSegment]) -> String {
        let clean = deduplicated(segments)
        let spokenPerFrame = align(frames: frames, segments: segments)
        var lines: [String] = []
        lines.append("# \(title) — \(dateString(date)) (משך \(timecode(duration)))")
        lines.append("")

        for (index, frame) in frames.enumerated() {
            let spoken = spokenPerFrame[index]

            lines.append("## שקופית \(index + 1) · [\(timecode(frame.timestamp))]")
            lines.append("")
            lines.append("![frame](\(frame.file))")
            lines.append("")
            if spoken.isEmpty {
                lines.append("> _(ללא דיבור)_")
            } else {
                for segment in spoken {
                    lines.append("> \(segment.text)")
                }
            }
            lines.append("")
            lines.append("---")
            lines.append("")
        }

        lines.append("## תמלול מלא")
        lines.append("")
        if clean.isEmpty {
            lines.append("_(לא זוהה דיבור)_")
        } else {
            for segment in clean {
                lines.append("[\(timecode(segment.start))] \(segment.text)")
            }
        }
        lines.append("")

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// What was said while each frame was on screen, in frame order: a frame at
    /// time t_i owns the (deduplicated) segments whose midpoint falls in
    /// [t_i, t_{i+1}). The first frame also owns anything said before it
    /// appeared. Shared with the Claude summarizer so both documents describe
    /// the same slides.
    static func align(frames: [Frame], segments: [TranscriptSegment]) -> [[TranscriptSegment]] {
        let clean = deduplicated(segments)
        return frames.enumerated().map { index, frame in
            let upperBound = index + 1 < frames.count ? frames[index + 1].timestamp : .infinity
            let lowerBound = index == 0 ? -Double.infinity : frame.timestamp
            return clean.filter { $0.midpoint >= lowerBound && $0.midpoint < upperBound }
        }
    }

    /// Whisper hallucinates repeated phrases over silence — drop segments whose
    /// text repeats the previous one.
    static func deduplicated(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var previous: String?
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let previous, previous == text { continue }
            previous = text
            result.append(TranscriptSegment(start: segment.start, end: segment.end, text: text))
        }
        return result
    }

    /// MM:SS, or H:MM:SS once the recording passes an hour.
    static func timecode(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
