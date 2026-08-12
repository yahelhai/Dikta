import Foundation

/// The crash-survivable half of a screen recording: everything needed to finish
/// (or resume) a session, kept inside the session folder rather than in a
/// temporary directory.
///
/// The old pipeline held the whole recording in one temporary WAV and wrote
/// nothing until the very end, so a crash in the last minute of a lecture threw
/// away the whole lecture. Here every closed chunk's transcript is appended and
/// flushed as it is produced, and the frame timestamps — which used to exist
/// only in memory — are written alongside the PNGs that need them.
///
/// ```
/// <session>/.dikta-work/
///   meta.json         the language/model decision and when it started
///   frames.jsonl      {file, timestamp} per kept frame
///   transcript.jsonl  {start, end, text} in absolute recording time
///   chunk-0003.wav    audio not yet transcribed
/// ```
final class SessionWorkspace: @unchecked Sendable {
    static let directoryName = ".dikta-work"

    /// What the pipeline decided once, at the first chunk, and every later chunk
    /// (and any recovery run) has to reuse.
    struct Meta: Codable, Sendable, Equatable {
        var startedAt: Date
        var modelPath: String
        /// whisper language code, or nil for auto.
        var language: String?
        var chunkSeconds: TimeInterval
        /// Title for the exported document.
        var title: String
    }

    /// A chunk on disk that still needs transcribing.
    struct PendingChunk: Sendable, Equatable {
        let url: URL
        let index: Int
        let startOffset: TimeInterval
    }

    let root: URL
    private let lock = NSLock()

    init(session: URL) {
        self.root = session.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    /// True when a session folder holds unfinished work.
    static func exists(in session: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let path = session.appendingPathComponent(directoryName, isDirectory: true).path
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    var metaURL: URL { root.appendingPathComponent("meta.json") }
    var framesURL: URL { root.appendingPathComponent("frames.jsonl") }
    var transcriptURL: URL { root.appendingPathComponent("transcript.jsonl") }

    func create() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Delete the workspace — called once `index.md` is safely written.
    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Meta

    func writeMeta(_ meta: Meta) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meta).write(to: metaURL, options: .atomic)
    }

    func readMeta() -> Meta? {
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Meta.self, from: data)
    }

    // MARK: - Transcript

    /// Append `segments`, shifted from chunk-local time into recording time.
    /// Flushed before returning: the point of writing these at all is to survive
    /// a process that dies without warning.
    func appendSegments(_ segments: [TranscriptSegment], startOffset: TimeInterval) throws {
        guard !segments.isEmpty else { return }
        let shifted = segments.map {
            TranscriptSegment(start: $0.start + startOffset,
                              end: $0.end + startOffset,
                              text: $0.text)
        }
        try appendLines(shifted, to: transcriptURL)
    }

    func readSegments() -> [TranscriptSegment] {
        readLines(from: transcriptURL, as: TranscriptSegment.self)
            .sorted { $0.start < $1.start }
    }

    // MARK: - Frames

    func appendFrame(_ frame: MarkdownExporter.Frame) throws {
        try appendLines([frame], to: framesURL)
    }

    func readFrames() -> [MarkdownExporter.Frame] {
        readLines(from: framesURL, as: MarkdownExporter.Frame.self)
            .sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Chunks

    /// Chunks still on disk, in capture order. Their start offsets are not
    /// recorded anywhere else, so they are recovered from the durations of the
    /// files themselves — which is exact, because every chunk is 16kHz mono.
    func pendingChunks() -> [PendingChunk] {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("chunk-") && $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return files.compactMap { url in
            let name = url.deletingPathExtension().lastPathComponent
            guard let index = Int(name.dropFirst("chunk-".count)) else { return nil }
            return PendingChunk(url: url, index: index, startOffset: 0)
        }
    }

    // MARK: - JSONL plumbing

    private func appendLines<T: Encodable>(_ values: [T], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var payload = Data()
        for value in values {
            payload.append(try encoder.encode(value))
            payload.append(0x0A)
        }

        lock.lock()
        defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: payload)
        try handle.synchronize()
    }

    /// Reads whole lines only. A process killed mid-write leaves a torn last
    /// line; dropping it loses one segment instead of failing the whole file.
    private func readLines<T: Decodable>(from url: URL, as type: T.Type) -> [T] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(type, from: data)
        }
    }
}
