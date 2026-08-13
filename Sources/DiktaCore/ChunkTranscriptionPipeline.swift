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
            // The rate in force. An explicit --speed is taken as given; anything
            // else is learned from the first chunk that comes back broken and
            // then reused, so the search happens at most once per recording.
            let rateIsExplicit = playbackRate != 1
            var rate: Double? = rateIsExplicit ? playbackRate : nil
            let sampleRate = AudioFileLoader.whisperFormat.sampleRate
            /// Tail of the previous chunk, replayed into this one for context.
            var carried: [Float] = []
            /// Absolute time already written, so the overlap isn't written twice.
            var acceptedUpTo: TimeInterval = 0
            /// The cut-off last segment, kept out of the file until we know
            /// whether another chunk is coming to supersede it.
            var heldBack: [TranscriptSegment] = []

            for await chunk in stream {
                do {
                    let captured = try AudioFileLoader.loadSamples(from: chunk.url)
                    guard !captured.isEmpty else {
                        Self.discard(chunk, keepAudio: keepAudio)
                        continue
                    }
                    // Replay the end of the previous chunk so the sentence that
                    // straddles the seam is transcribed once, whole.
                    let combined = carried + captured
                    let audioStart = max(0, chunk.startOffset - Double(carried.count) / sampleRate)

                    // Undo sped-up playback before whisper sees it; the segment
                    // times that come back are then in stretched time and have
                    // to be divided by the same rate on the way out.
                    // Explicit rate on the first chunk, the learned one after
                    // that, and plain 1x while it is still unknown.
                    let samples = AudioFileLoader.slowed(combined, playbackRate: rate ?? 1)

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

                    var segments = try await transcriber.transcribeSegments(
                        samples: samples, language: resolved.language,
                        modelPath: resolved.modelPath)

                    // Nobody remembers to pass --speed, and forgetting it fails
                    // silently: a full-looking index.md with no content in it.
                    // So when loud audio comes back as near-nothing, work the
                    // rate out here — once, off the first chunk that shows it.
                    if rate == nil, !rateIsExplicit,
                       Self.looksBroken(segments: segments, seconds: chunk.duration,
                                        rms: Self.rms(of: combined)) {
                        let best = try await Self.detectRate(
                            captured: combined, seconds: chunk.duration,
                            language: resolved.language, modelPath: resolved.modelPath,
                            baseline: segments, transcriber: transcriber)
                        if best.rate != 1 {
                            NSLog("Dikta: audio looks sped up — transcribing at %.2fx", best.rate)
                            rate = best.rate
                            segments = best.segments
                            var updated = meta
                            updated.modelPath = resolved.modelPath
                            updated.language = resolved.language
                            updated.playbackRate = best.rate
                            try? workspace.writeMeta(updated)
                        } else {
                            // Nothing beat the plain reading — stop paying for
                            // the search on every later chunk.
                            rate = 1
                        }
                    }

                    let effective = rate ?? playbackRate
                    let (write, held) = Self.merge(
                        segments: segments, audioStart: audioStart, timeScale: 1 / effective,
                        chunkEnd: chunk.startOffset + chunk.duration, acceptedUpTo: acceptedUpTo,
                        overlapSeconds: Self.overlapSeconds)

                    try workspace.appendSegments(write, startOffset: 0)
                    if let last = write.last { acceptedUpTo = max(acceptedUpTo, last.end) }
                    // Dropped on purpose if another chunk follows: its overlap
                    // covers this audio and reads it better. Flushed after the
                    // loop when nothing else is coming.
                    heldBack = held
                    carried = Array(captured.suffix(Int(Self.overlapSeconds * sampleRate)))

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
            // Nothing follows the last chunk, so its cut-off tail is the real
            // end of the recording rather than something to be re-read.
            if !heldBack.isEmpty {
                try? workspace.appendSegments(heldBack, startOffset: 0)
            }
        }
    }

    /// Turn one chunk's segments into what should be written now, plus what
    /// should wait for the next chunk to re-read.
    ///
    /// Times arrive relative to the start of the audio that was transcribed —
    /// which begins in the *previous* chunk, because of the overlap — so they
    /// are rescaled and shifted to absolute recording time first. Anything the
    /// previous chunk already wrote is then dropped, and a segment cut off by
    /// the chunk boundary is held back so the next chunk can produce it whole.
    static func merge(
        segments: [TranscriptSegment], audioStart: TimeInterval, timeScale: Double,
        chunkEnd: TimeInterval, acceptedUpTo: TimeInterval, overlapSeconds: Double
    ) -> (write: [TranscriptSegment], held: [TranscriptSegment]) {
        var absolute = segments.map {
            TranscriptSegment(start: $0.start * timeScale + audioStart,
                              end: $0.end * timeScale + audioStart,
                              text: $0.text)
        }
        // Judge on the midpoint: a sentence that starts inside the overlap but
        // mostly belongs to this chunk is this chunk's to write.
        absolute = absolute.filter { $0.midpoint > acceptedUpTo }

        // Only hold back a tail the next chunk's overlap can actually re-read;
        // a long final segment would otherwise be dropped and never replaced.
        if let last = absolute.last,
           last.end >= chunkEnd - truncatedTailSeconds,
           last.end - last.start <= overlapSeconds {
            return (Array(absolute.dropLast()), [last])
        }
        return (absolute, [])
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

    // MARK: - Playback rate detection

    /// Rates tried when the first chunk comes back broken, in the order people
    /// actually use them.
    static let candidateRates: [Double] = [1.5, 2, 1.25, 3]

    /// Audio carried from the end of one chunk into the start of the next.
    ///
    /// Cutting on a quiet moment keeps most seams off a word, but not all of
    /// them: a real capture split "If a claim isn't / backed by a real source"
    /// and whisper finished the first half by inventing a sentence. Re-reading
    /// the boundary with the audio that follows it fixes that — six seconds is
    /// well past the longest sentence fragment a cut can strand.
    static let overlapSeconds: Double = 6

    /// A segment ending this close to the end of its chunk was cut off by the
    /// chunk boundary rather than by the speaker, so it is held back and left
    /// to the next chunk, which sees the whole thing.
    static let truncatedTailSeconds: Double = 1.5

    /// Loud audio that produced almost no text. Neither half is suspicious on
    /// its own — a silent chunk is quiet, and a quiet chunk legitimately
    /// transcribes to nothing — but together they are the signature of whisper
    /// being handed speech at the wrong speed. Measured on a real 1.5x capture:
    /// RMS 0.108 in, "Thank you." four times out.
    static func looksBroken(segments: [TranscriptSegment], seconds: TimeInterval,
                            rms: Float) -> Bool {
        guard seconds > 5, rms > 0.02 else { return false }
        return score(segments: segments, seconds: seconds) < 3
    }

    /// Distinct characters of transcript per second of audio. Ordinary speech
    /// runs well into double figures; the degenerate output that comes back
    /// from wrong-speed audio scores near zero because it repeats one phrase.
    static func score(segments: [TranscriptSegment], seconds: TimeInterval) -> Double {
        guard seconds > 0 else { return 0 }
        var seen = Set<String>()
        var characters = 0
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text).inserted else { continue }
            characters += text.count
        }
        return Double(characters) / seconds
    }

    /// Re-transcribe one chunk at each candidate rate and keep whichever reads
    /// most like speech. Costs a few seconds, once per recording, and only when
    /// the plain reading already came back broken — so the common case pays
    /// nothing. Stops early on a clearly good result rather than trying them all.
    private static func detectRate(
        captured: [Float], seconds: TimeInterval, language: String?, modelPath: String,
        baseline: [TranscriptSegment], transcriber: Transcriber
    ) async throws -> (rate: Double, segments: [TranscriptSegment]) {
        var best = (rate: 1.0, segments: baseline, score: score(segments: baseline, seconds: seconds))
        for candidate in candidateRates {
            let stretched = AudioFileLoader.slowed(captured, playbackRate: candidate)
            let segments = try await transcriber.transcribeSegments(
                samples: stretched, language: language, modelPath: modelPath)
            // Score against the real duration either way: a rate that invents
            // more audio must earn it in transcript, not in seconds.
            let candidateScore = score(segments: segments, seconds: seconds)
            NSLog("Dikta: rate probe %.2fx scored %.1f chars/s", candidate, candidateScore)
            if candidateScore > best.score {
                best = (candidate, segments, candidateScore)
            }
            if best.score > 8 { break }
        }
        return (best.rate, best.segments)
    }

    static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}
