import Foundation

/// Transcribes audio chunks as they close, while the recording is still going.
///
/// The old shape ran one `whisper_full` over the whole recording after capture
/// stopped: an 80-minute lecture meant ~250 seconds of waiting at the end, a
/// ~310MB `[Float]` in memory, and total loss of the audio if anything crashed.
/// Here each closed chunk is transcribed on its own, appended to the workspace
/// and then deleted, so the wait at the end is one chunk long, memory is one
/// chunk deep, and a crash costs at most the chunk in flight.
///
/// Chunks are consumed strictly in order by a single task. `Transcriber` is an
/// actor and would serialise them anyway, and in-order processing is what makes
/// "the first chunk picks the language" well defined.
final class ChunkTranscriptionPipeline: @unchecked Sendable {
    /// How far transcription has got, for `dikta status` and the menu.
    struct Progress: Sendable {
        let transcribedSeconds: TimeInterval
        let chunks: Int
    }

    private let workspace: SessionWorkspace
    private let mode: LanguageMode
    private let transcriber: Transcriber
    private let keepAudio: Bool
    private let playbackRate: Double
    private let onProgress: @Sendable (Progress) -> Void

    private let continuation: AsyncStream<AudioSpooler.Chunk>.Continuation
    private var consumer: Task<Void, Never>!

    init(workspace: SessionWorkspace,
         meta: SessionWorkspace.Meta,
         mode: LanguageMode,
         transcriber: Transcriber,
         keepAudio: Bool = false,
         playbackRate: Double = 1,
         onProgress: @escaping @Sendable (Progress) -> Void = { _ in }) {
        self.workspace = workspace
        self.mode = mode
        self.transcriber = transcriber
        self.keepAudio = keepAudio
        self.playbackRate = playbackRate
        self.onProgress = onProgress

        let (stream, continuation) = AsyncStream<AudioSpooler.Chunk>.makeStream()
        self.continuation = continuation

        // .utility: capture is the job that must not stutter. Transcribing a
        // 2-minute chunk takes a few seconds, so this sits idle most of the time,
        // but when it runs it should yield to the capture queues.
        consumer = Task(priority: .utility) {
            [workspace, mode, transcriber, keepAudio, playbackRate, onProgress] in
            var resolved: (modelPath: String, language: String?)?
            var transcribed: TimeInterval = 0
            var count = 0

            for await chunk in stream {
                do {
                    let captured = try AudioFileLoader.loadSamples(from: chunk.url)
                    // Undo sped-up playback before whisper sees it; the segment
                    // times that come back are then in stretched time and have
                    // to be divided by the same rate on the way out.
                    let samples = AudioFileLoader.slowed(captured, playbackRate: playbackRate)
                    guard !samples.isEmpty else {
                        Self.discard(chunk, keepAudio: keepAudio)
                        continue
                    }

                    // Routed once, off the first chunk, and reused for the rest:
                    // re-detecting per chunk would let the language flip mid-way
                    // through a lecture, and costs an encoder pass every time.
                    if resolved == nil {
                        let route = try await LanguageRouter.route(
                            samples: samples, mode: mode, transcriber: transcriber)
                        resolved = route
                        var updated = meta
                        updated.modelPath = route.modelPath
                        updated.language = route.language
                        try? workspace.writeMeta(updated)
                        NSLog("Dikta: transcribing with %@ (%@)",
                              (route.modelPath as NSString).lastPathComponent,
                              route.language ?? "auto")
                    }
                    guard let resolved else { continue }

                    let segments = try await transcriber.transcribeSegments(
                        samples: samples, language: resolved.language,
                        modelPath: resolved.modelPath)
                    try workspace.appendSegments(segments, startOffset: chunk.startOffset,
                                                 timeScale: 1 / playbackRate)

                    // Only now is the audio expendable: the transcript for it is
                    // on disk and flushed.
                    Self.discard(chunk, keepAudio: keepAudio)
                    transcribed = chunk.startOffset + chunk.duration
                    count += 1
                    onProgress(Progress(transcribedSeconds: transcribed, chunks: count))
                } catch {
                    // Keep the audio: a chunk that failed here is exactly what
                    // `dikta recover` should get another go at.
                    NSLog("Dikta: chunk %d failed, left on disk: %@", chunk.index, "\(error)")
                }
            }
        }
    }

    /// Hand over a closed chunk. Safe to call from the capture queue — it only
    /// enqueues.
    func submit(_ chunk: AudioSpooler.Chunk) {
        continuation.yield(chunk)
    }

    /// Stop accepting chunks and wait for the queue to drain.
    func finish() async {
        continuation.finish()
        await consumer.value
    }

    private static func discard(_ chunk: AudioSpooler.Chunk, keepAudio: Bool) {
        guard !keepAudio else { return }
        try? FileManager.default.removeItem(at: chunk.url)
    }
}
