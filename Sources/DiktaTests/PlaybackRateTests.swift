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
