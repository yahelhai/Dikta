import Foundation

/// Picks the whisper model + language for a batch of samples.
///
/// Shared by every transcription path (dictation, video files, live screen
/// recording) so language routing behaves identically everywhere.
enum LanguageRouter {
    /// In Auto mode with the ivrit model available, detect the language first
    /// (fast encoder pass on the stock model) and route Hebrew to the ivrit
    /// fine-tune — it is far more accurate for Hebrew but must run with an
    /// explicit "he" and can't handle other languages.
    static func route(samples: [Float], mode: LanguageMode,
                      transcriber: Transcriber) async throws -> (modelPath: String, language: String?) {
        let stockPath = ModelManager.shared.localURL(for: ModelManager.stockTurboQ5).path
        let ivritPath = ModelManager.shared.localURL(for: ModelManager.ivritTurbo).path
        let ivritAvailable = ModelManager.shared.isDownloaded(ModelManager.ivritTurbo)

        switch mode {
        case .english:
            return (stockPath, "en")
        case .hebrew:
            return (ivritAvailable ? ivritPath : stockPath, "he")
        case .auto:
            guard ivritAvailable else { return (stockPath, nil) }
            let detected = try await transcriber.detectLanguage(samples: samples, modelPath: stockPath)
            NSLog("Dikta: detected language '%@'", detected)
            return detected == "he" ? (ivritPath, "he") : (stockPath, detected)
        }
    }
}
