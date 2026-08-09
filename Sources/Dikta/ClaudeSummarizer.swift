import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Optional post-processing stage: sends the kept frames (as compressed JPEGs)
/// plus what was said over each of them to the Anthropic Messages API, and
/// writes the unified `summary.md` next to `index.md`.
///
/// Strictly additive — `index.md` is always produced locally first, and every
/// failure here (network, HTTP, malformed JSON) leaves it untouched.
enum ClaudeSummarizer {
    /// Cheapest model with vision; a typical lecture costs a few cents.
    static let model = "claude-haiku-4-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"
    static let maxTokens = 16000
    /// Anthropic downscales anything larger, so do it here and save the tokens.
    static let maxImageEdge = 1568
    static let jpegQuality = 0.7
    /// Above this we'd risk the 32MB request cap; batching is future work.
    static let maxSlides = 60
    /// A lecture can take minutes to summarize — don't time out on it.
    static let requestTimeout: TimeInterval = 600

    /// Hebrew phase labels for the menu / CLI.
    typealias ProgressHandler = @Sendable (String) -> Void

    /// Summarize `frames` + `segments` into `<sessionDirectory>/summary.md`.
    /// Returns the URL of the written file.
    @discardableResult
    static func summarize(frames: [MarkdownExporter.Frame],
                          segments: [TranscriptSegment],
                          sessionDirectory: URL,
                          apiKey: String,
                          progress: @escaping ProgressHandler = { _ in }) async throws -> URL {
        guard !frames.isEmpty else {
            throw DiktaError.summaryFailed("no frames to summarize")
        }

        progress("מכין תמונות…")
        let body = try requestBody(frames: frames, segments: segments,
                                   sessionDirectory: sessionDirectory)

        progress("שולח ל-Claude…")
        let (text, stopReason) = try await send(body: body, apiKey: apiKey)

        progress("כותב סיכום…")
        var markdown = text
        if stopReason == "max_tokens" {
            NSLog("Dikta: Claude summary hit max_tokens — output truncated")
            if !markdown.hasSuffix("\n") { markdown += "\n" }
            markdown += "\n> _(הסיכום נקטע — הגענו למגבלת האורך של המודל.)_\n"
        }
        let url = sessionDirectory.appendingPathComponent("summary.md")
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Request

    /// Build the JSON body: one user message whose content alternates a text
    /// block describing each slide with the slide's image, followed by the
    /// summarizing instructions.
    static func requestBody(frames: [MarkdownExporter.Frame],
                            segments: [TranscriptSegment],
                            sessionDirectory: URL) throws -> Data {
        let spokenPerFrame = MarkdownExporter.align(frames: frames, segments: segments)
        let truncated = frames.count > maxSlides
        if truncated {
            NSLog("Dikta: %d slides — summarizing the first %d only",
                  frames.count, maxSlides)
        }
        let usedCount = min(frames.count, maxSlides)

        var content: [[String: Any]] = []
        for index in 0..<usedCount {
            let frame = frames[index]
            let spoken = spokenPerFrame[index]
                .map(\.text)
                .joined(separator: " ")
            let transcript = spoken.isEmpty ? "(ללא דיבור)" : spoken
            let header = """
                שקופית \(index + 1) — קובץ \(frame.file) — [\(MarkdownExporter.timecode(frame.timestamp))]
                תמלול: \(transcript)
                """
            content.append(["type": "text", "text": header])
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": try jpegBase64(
                        at: sessionDirectory.appendingPathComponent(frame.file)),
                ],
            ])
        }

        var instructions = instructionText
        if truncated {
            instructions += """

                שים לב: ההקלטה כללה \(frames.count) שקופיות, וכאן נשלחו רק \
                \(usedCount) הראשונות. ציין בסוף המסמך שהסיכום מכסה רק את \
                \(usedCount) השקופיות הראשונות.
                """
        }
        content.append(["type": "text", "text": instructions])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": [["role": "user", "content": content]],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [])
    }

    /// POST the body and return (concatenated text, stop_reason).
    private static func send(body: Data, apiKey: String) async throws -> (String, String?) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = body
        request.timeoutInterval = requestTimeout

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DiktaError.summaryFailed("no HTTP response")
        }
        guard http.statusCode == 200 else {
            throw DiktaError.summaryFailed(
                "HTTP \(http.statusCode): \(errorMessage(in: data))")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = json["content"] as? [[String: Any]] else {
            throw DiktaError.summaryFailed("unexpected response shape")
        }
        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DiktaError.summaryFailed("empty response")
        }
        return (text, json["stop_reason"] as? String)
    }

    /// `{"error": {"message": "..."}}` if present, else the raw body.
    private static func errorMessage(in data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8) ?? "<no body>"
    }

    // MARK: - Images

    /// Load the saved PNG, cap its long edge at `maxImageEdge`, and re-encode
    /// as JPEG so the request stays inside the API's size budget.
    private static func jpegBase64(at url: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw DiktaError.summaryFailed("cannot read \(url.lastPathComponent)")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? Int) ?? 0

        let image: CGImage?
        if max(width, height) > maxImageEdge {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxImageEdge,
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image else {
            throw DiktaError.summaryFailed("cannot decode \(url.lastPathComponent)")
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw DiktaError.summaryFailed("cannot encode \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw DiktaError.summaryFailed("cannot encode \(url.lastPathComponent)")
        }
        return (data as Data).base64EncodedString()
    }

    // MARK: - Prompt

    static let systemPrompt = """
        אתה עוזר שמסכם הקלטות מסך של הרצאות והדגמות. אתה מקבל את השקופיות \
        (צילומי מסך) לפי הסדר, ולצד כל אחת את מה שנאמר בזמן שהיא הוצגה. \
        המשימה שלך היא להפיק מסמך סיכום אחד ומאוחד ב-Markdown, בעברית, \
        שמשלב את מה שנאמר בקול עם מה שכתוב על המסך עצמו — אתה רואה את \
        התמונות, אז קרא מהן טקסט, קוד, נוסחאות ונתונים ושלב אותם בסיכום. \
        אל תמציא תוכן שאינו מופיע בתמלול או בתמונות.
        """

    static let instructionText = """
        כתוב עכשיו את מסמך הסיכום המאוחד. כללים:

        1. לכל שקופית משמעותית: כותרת קצרה, מיד אחריה הטמעת התמונה בשורה \
        משלה בפורמט `![](frames/000N.png)` (בדיוק שם הקובץ שצוין עבור אותה \
        שקופית), ואחריה סיכום שמשלב את מה שנאמר (התמלול) עם מה שכתוב על \
        השקופית עצמה.
        2. הוסף בסוף סעיף בשם "נושאים נוספים" ובו נושאי צד שנדונו ואינם \
        שייכים לשקופית מסוימת. אם אין כאלה — השמט את הסעיף.
        3. כשרצף שקופיות מציג עבודה חיה שמתפתחת (כתיבת קוד, עריכת גיליון, \
        מילוי טופס) — אל תיצור סעיף לכל שקופית. סכם את רצף הפעולות שבוצעו \
        בפסקה אחת, והטמע רק את התמונה של המצב הסופי ברצף.
        4. הפלט הוא Markdown גולמי בלבד, בעברית, בלי הקדמה, בלי הסבר על מה \
        שאתה עומד לעשות, ובלי לעטוף את התשובה בגושי קוד.
        """
}
