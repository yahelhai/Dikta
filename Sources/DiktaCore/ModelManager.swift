import Foundation

struct ModelSpec: Sendable {
    let id: String
    let displayName: String
    let url: URL
    let filename: String
    let approximateSizeMB: Int
    /// Language this model is restricted to (the ivrit fine-tune must run with "he").
    let forcedLanguage: String?
}

/// Knows where models live on disk and how to download them.
final class ModelManager: Sendable {
    static let shared = ModelManager()

    static let stockTurboQ5 = ModelSpec(
        id: "stock-turbo-q5",
        displayName: "Whisper large-v3-turbo (q5, 574MB)",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!,
        filename: "ggml-large-v3-turbo-q5_0.bin",
        approximateSizeMB: 574,
        forcedLanguage: nil
    )

    static let ivritTurbo = ModelSpec(
        id: "ivrit-turbo",
        displayName: "ivrit.ai עברית (large-v3-turbo, 1.6GB)",
        url: URL(string: "https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml/resolve/main/ggml-model.bin")!,
        filename: "ggml-ivrit-large-v3-turbo.bin",
        approximateSizeMB: 1620,
        forcedLanguage: "he"
    )

    static let allModels: [ModelSpec] = [stockTurboQ5, ivritTurbo]

    var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dikta/models", isDirectory: true)
    }

    func localURL(for spec: ModelSpec) -> URL {
        modelsDirectory.appendingPathComponent(spec.filename)
    }

    func isDownloaded(_ spec: ModelSpec) -> Bool {
        FileManager.default.fileExists(atPath: localURL(for: spec).path)
    }

    /// Pick the model + language for a dictation given the user's language mode.
    /// Hebrew prefers the ivrit fine-tune when available (forced "he");
    /// everything else uses the stock multilingual turbo.
    func resolve(for mode: LanguageMode) -> (spec: ModelSpec, language: String?) {
        if mode == .hebrew && isDownloaded(Self.ivritTurbo) {
            return (Self.ivritTurbo, "he")
        }
        return (Self.stockTurboQ5, mode.whisperLanguage)
    }

    func download(_ spec: ModelSpec, progress: @escaping @Sendable (Double) -> Void) async throws {
        let dir = modelsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let delegate = DownloadProgressDelegate(onProgress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (tmpURL, response) = try await session.download(from: spec.url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let dest = localURL(for: spec)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmpURL, to: dest)
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
}

extension URLSession {
    /// async download that routes through a delegate for progress callbacks.
    func download(from url: URL) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = downloadTask(with: url) { tmpURL, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let tmpURL, let response {
                    // Move out of the system tmp location before the completion handler returns,
                    // otherwise the file is deleted.
                    let holding = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                    do {
                        try FileManager.default.moveItem(at: tmpURL, to: holding)
                        continuation.resume(returning: (holding, response))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(throwing: URLError(.unknown))
                }
            }
            task.resume()
        }
    }
}
