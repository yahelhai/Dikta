import Foundation

/// Summary engine that runs the local Claude Code CLI (`claude -p`) instead of
/// the paid Messages API — it authenticates against the user's Claude
/// subscription (Pro/Max), so summaries cost no API credits.
///
/// The CLI reads the slide PNGs itself with its Read tool (full resolution, no
/// JPEG downscaling needed); we only hand it the per-slide transcript and the
/// same Hebrew instructions the API engine uses.
enum ClaudeCLISummarizer {
    /// Reading dozens of images + writing a long document can take a while.
    static let timeout: TimeInterval = 15 * 60
    static let maxSlides = ClaudeSummarizer.maxSlides

    typealias ProgressHandler = @Sendable (String) -> Void

    /// Well-known install locations, checked before falling back to a login
    /// shell `which` (the app's own PATH is nearly empty when launched from
    /// Finder).
    private static let candidatePaths: [String] = {
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
        ]
    }()

    /// Fast check for menu enablement — file probes only, no shell.
    static var isAvailable: Bool {
        candidatePaths.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func claudeBinary() -> URL? {
        if let path = candidatePaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) {
            return URL(fileURLWithPath: path)
        }
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/bin/zsh")
        which.arguments = ["-lc", "which claude"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        guard (try? which.run()) != nil else { return nil }
        which.waitUntilExit()
        guard which.terminationStatus == 0,
              let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                               encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !out.isEmpty else { return nil }
        return URL(fileURLWithPath: out)
    }

    /// Summarize `frames` + `segments` into `<sessionDirectory>/summary.md`.
    @discardableResult
    static func summarize(frames: [MarkdownExporter.Frame],
                          segments: [TranscriptSegment],
                          sessionDirectory: URL,
                          progress: @escaping ProgressHandler = { _ in }) async throws -> URL {
        guard !frames.isEmpty else {
            throw DiktaError.summaryFailed("no frames to summarize")
        }
        guard let binary = claudeBinary() else {
            throw DiktaError.summaryFailed(
                "Claude Code CLI לא נמצא — התקן אותו או עבור למנוע API key בתפריט")
        }

        let prompt = buildPrompt(frames: frames, segments: segments)
        progress("מריץ את Claude ברקע…")
        let output = try await run(binary: binary, prompt: prompt, cwd: sessionDirectory)

        progress("כותב סיכום…")
        let markdown = stripCodeFence(output)
        let url = sessionDirectory.appendingPathComponent("summary.md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Prompt

    private static func buildPrompt(frames: [MarkdownExporter.Frame],
                                    segments: [TranscriptSegment]) -> String {
        let spokenPerFrame = MarkdownExporter.align(frames: frames, segments: segments)
        let usedCount = min(frames.count, maxSlides)

        var slides: [String] = []
        for index in 0..<usedCount {
            let frame = frames[index]
            let spoken = spokenPerFrame[index].map(\.text).joined(separator: " ")
            slides.append("""
                שקופית \(index + 1) — קובץ \(frame.file) — [\(MarkdownExporter.timecode(frame.timestamp))]
                תמלול: \(spoken.isEmpty ? "(ללא דיבור)" : spoken)
                """)
        }

        var prompt = ClaudeSummarizer.systemPrompt
        prompt += "\n\nהשקופיות שנקלטו, לפי הסדר:\n\n"
        prompt += slides.joined(separator: "\n\n")
        prompt += """


        קרא כל אחת מתמונות השקופיות שצוינו למעלה (הנתיבים היחסיים תחת frames/) \
        בעזרת כלי ה-Read שלך כדי לראות מה כתוב ומוצג על כל שקופית.

        """
        prompt += ClaudeSummarizer.instructionText
        if frames.count > maxSlides {
            NSLog("Dikta: %d slides — CLI summary covers the first %d only",
                  frames.count, maxSlides)
            prompt += """

                שים לב: ההקלטה כללה \(frames.count) שקופיות ונשלחו רק \(usedCount) \
                הראשונות. ציין זאת בסוף המסמך.
                """
        }
        return prompt
    }

    /// The model was told to emit raw Markdown, but strip a wrapping code fence
    /// if one sneaks in anyway.
    private static func stripCodeFence(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            if let firstNewline = trimmed.firstIndex(of: "\n") {
                trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
            }
            if trimmed.hasSuffix("```") {
                trimmed = String(trimmed.dropLast(3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return trimmed + "\n"
    }

    // MARK: - Process

    private static func run(binary: URL, prompt: String, cwd: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = binary
                process.arguments = [
                    "-p", prompt,
                    "--allowedTools", "Read",
                    "--output-format", "text",
                ]
                process.currentDirectoryURL = cwd
                // Don't inherit markers of an enclosing Claude Code session
                // (relevant when Dikta itself was launched from one during dev).
                var environment = ProcessInfo.processInfo.environment
                environment.removeValue(forKey: "CLAUDECODE")
                environment.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
                process.environment = environment

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: DiktaError.summaryFailed(
                        "cannot launch claude: \(error.localizedDescription)"))
                    return
                }

                let watchdog = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                // Drain the pipes BEFORE waitUntilExit — a full pipe buffer
                // would deadlock a long summary otherwise.
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()

                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""

                guard process.terminationStatus == 0 else {
                    let reason = err.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: DiktaError.summaryFailed(
                        "claude exited \(process.terminationStatus): "
                        + (reason.isEmpty ? "(no stderr)" : String(reason.prefix(300)))))
                    return
                }
                guard !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continuation.resume(throwing: DiktaError.summaryFailed(
                        "empty output from claude CLI"))
                    return
                }
                continuation.resume(returning: out)
            }
        }
    }
}
