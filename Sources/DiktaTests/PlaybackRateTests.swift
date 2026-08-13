import Foundation

@testable import DiktaCore

/// Recording a lecture at 1.5x is the normal way to use this thing, and it
/// silently produced garbage: two minutes of clean audio came back as
/// "Thank you." repeated four times, and transcribed perfectly the moment the
/// same samples were slowed to real time. These pin down the correction.
func registerPlaybackRateTests(_ runner: TestRunner) {
    runner.test("slowed: 1x is left completely alone") { context in
        let samples: [Float] = [0, 0.5, -0.5, 1, -1]
        context.expectEqual(AudioFileLoader.slowed(samples, playbackRate: 1), samples)
    }

    runner.test("slowed: 1.5x playback stretches by half again") { context in
        let samples = (0..<100).map { Float($0) / 100 }
        let out = AudioFileLoader.slowed(samples, playbackRate: 1.5)
        context.expectEqual(out.count, 150, "1.5x audio needs 1.5x the samples to run in real time")
    }

    runner.test("slowed: endpoints survive the resample") { context in
        let samples: [Float] = [1, 2, 3, 4, 5]
        let out = AudioFileLoader.slowed(samples, playbackRate: 2)
        context.expectEqual(out.first, 1)
        context.expectEqual(out.last, 5)
        context.expectEqual(out.count, 10)
    }

    runner.test("slowed: interpolates rather than repeating samples") { context in
        // A ramp stays a ramp: the midpoint of 0…1 must land near 0.5, which a
        // nearest-neighbour resample would not manage.
        let samples: [Float] = [0, 1]
        let out = AudioFileLoader.slowed(samples, playbackRate: 3)
        context.expect(out.count == 6, "expected 6 samples, got \(out.count)")
        let middle = out[out.count / 2]
        context.expect(abs(middle - 0.6) < 0.11, "midpoint \(middle) is not on the ramp")
    }

    runner.test("slowed: degenerate rates are refused, not crashed on") { context in
        let samples: [Float] = [1, 2, 3]
        context.expectEqual(AudioFileLoader.slowed(samples, playbackRate: 0), samples)
        context.expectEqual(AudioFileLoader.slowed(samples, playbackRate: -2), samples)
        context.expectEqual(AudioFileLoader.slowed([], playbackRate: 1.5), [])
    }

    runner.test("timeScale: stretched timestamps come back to recording time") { context in
        try await withTemporaryDirectory { directory in
            let workspace = SessionWorkspace(session: directory)
            try workspace.create()
            // Whisper saw audio slowed from 1.5x, so a word it puts at 30s in
            // that stretched stream was really spoken 20s into the chunk.
            try workspace.appendSegments(
                [TranscriptSegment(start: 30, end: 45, text: "אחרי ההאטה")],
                startOffset: 120, timeScale: 1 / 1.5)

            let read = workspace.readSegments()
            context.expectEqual(read.count, 1)
            guard let segment = read.first else { return }
            context.expect(abs(segment.start - 140) < 0.01,
                           "expected 120 + 30/1.5 = 140, got \(segment.start)")
            context.expect(abs(segment.end - 150) < 0.01,
                           "expected 120 + 45/1.5 = 150, got \(segment.end)")
        }
    }

    runner.test("timeScale: 1 leaves ordinary recordings untouched") { context in
        try await withTemporaryDirectory { directory in
            let workspace = SessionWorkspace(session: directory)
            try workspace.create()
            try workspace.appendSegments(
                [TranscriptSegment(start: 5, end: 9, text: "רגיל")], startOffset: 240)
            guard let segment = workspace.readSegments().first else {
                context.fail("nothing was written")
                return
            }
            context.expectEqual(segment.start, 245)
            context.expectEqual(segment.end, 249)
        }
    }

    runner.test("keep-audio: chunks survive the workspace being removed") { context in
        try await withTemporaryDirectory { directory in
            let workspace = SessionWorkspace(session: directory)
            try workspace.create()
            let chunk = workspace.root.appendingPathComponent("chunk-0001.wav")
            try Data([1, 2, 3]).write(to: chunk)

            workspace.remove(keepingAudio: true)
            let kept = directory.appendingPathComponent("audio/chunk-0001.wav")
            context.expect(FileManager.default.fileExists(atPath: kept.path),
                           "--keep-audio must outlive the workspace it was recorded into")
            context.expect(!FileManager.default.fileExists(atPath: workspace.root.path),
                           "the workspace itself should still be gone")
        }
    }

    // Detection: forgetting --speed must not be a silent failure, so the
    // pipeline works the rate out from the shape of its own output.

    /// Roughly what whisper returned for two minutes of real 1.5x narration.
    let degenerate = [
        TranscriptSegment(start: 0, end: 30, text: "Thank you."),
        TranscriptSegment(start: 30, end: 60, text: "Thank you."),
        TranscriptSegment(start: 60, end: 90, text: "Thank you."),
        TranscriptSegment(start: 90, end: 92, text: "Thank you."),
        TranscriptSegment(start: 120, end: 120.4, text: "to fill the gap."),
    ]
    /// And roughly what the same audio produced once slowed to real time.
    let healthy = [
        TranscriptSegment(start: 0, end: 8, text: "New Claude Obsidian 2.0 changes everything you use AI every single day."),
        TranscriptSegment(start: 8, end: 16, text: "So why does it still know nothing about you? Every chat you have is packed with insight."),
        TranscriptSegment(start: 16, end: 24, text: "And almost all of it disappears the second you close the tab. A free tool just fixed that."),
    ]

    runner.test("score: repetition counts once, however often it repeats") { context in
        let repeated = Array(repeating: TranscriptSegment(start: 0, end: 1, text: "Thank you."),
                             count: 40)
        context.expect(ChunkTranscriptionPipeline.score(segments: repeated, seconds: 120) < 1,
                       "forty copies of one phrase is not two minutes of speech")
    }

    runner.test("score: real speech scores well clear of the threshold") { context in
        let value = ChunkTranscriptionPipeline.score(segments: healthy, seconds: 24)
        context.expect(value > 8, "expected healthy narration to score high, got \(value)")
    }

    runner.test("detect: loud audio with no transcript is the signature") { context in
        context.expect(
            ChunkTranscriptionPipeline.looksBroken(segments: degenerate, seconds: 120, rms: 0.108),
            "loud audio that produced nothing is exactly the wrong-speed case")
    }

    runner.test("detect: genuine silence is left alone") { context in
        // A muted player or a gap in the lecture: same empty transcript, but the
        // audio is quiet, so there is nothing to fix by changing the speed.
        context.expect(
            !ChunkTranscriptionPipeline.looksBroken(segments: degenerate, seconds: 120, rms: 0.0005),
            "quiet audio transcribing to nothing is correct, not broken")
        context.expect(
            !ChunkTranscriptionPipeline.looksBroken(segments: [], seconds: 120, rms: 0.001),
            "an empty transcript over silence must not trigger a rate search")
    }

    runner.test("detect: a good transcript is never second-guessed") { context in
        context.expect(
            !ChunkTranscriptionPipeline.looksBroken(segments: healthy, seconds: 24, rms: 0.1),
            "a chunk that transcribed well should cost nothing extra")
    }

    runner.test("detect: a very short chunk is not judged") { context in
        // The tail chunk of a recording can be a couple of seconds long; there
        // isn't enough there to conclude anything from.
        context.expect(
            !ChunkTranscriptionPipeline.looksBroken(segments: [], seconds: 2, rms: 0.2),
            "too little audio to draw a conclusion from")
    }

    runner.test("rms: distinguishes speech-level audio from silence") { context in
        let silence = [Float](repeating: 0, count: 1000)
        let speech = (0..<1000).map { Float(sin(Double($0) * 0.3)) * 0.3 }
        context.expect(ChunkTranscriptionPipeline.rms(of: silence) < 0.001, "silence should read as silent")
        context.expect(ChunkTranscriptionPipeline.rms(of: speech) > 0.02, "a signal should read as loud")
        context.expectEqual(ChunkTranscriptionPipeline.rms(of: []), 0)
    }

    runner.test("keep-audio: off still clears everything") { context in
        try await withTemporaryDirectory { directory in
            let workspace = SessionWorkspace(session: directory)
            try workspace.create()
            try Data([1]).write(to: workspace.root.appendingPathComponent("chunk-0001.wav"))

            workspace.remove()
            context.expect(!FileManager.default.fileExists(atPath: workspace.root.path),
                           "the workspace should be gone")
            context.expect(
                !FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("audio").path),
                "nothing should be preserved when the caller didn't ask for it")
        }
    }
}
