import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum State {
        case idle
        case recording(startedAt: Date)
        case transcribing
    }

    private var state: State = .idle
    private var statusItemController: StatusItemController!
    private let hotkeyManager = HotkeyManager()
    private let audioRecorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let outputRouter = OutputRouter()
    private var watchdog: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController()
        Permissions.requestAll()

        hotkeyManager.shortcut = Settings.shared.shortcut
        hotkeyManager.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .holdStarted: self.startRecording()
            case .holdEnded: self.stopRecordingAndTranscribe()
            case .shortcutCaptured(let shortcut): self.shortcutCaptured(shortcut)
            }
        }
        if !hotkeyManager.start() {
            NSLog("Dikta: event tap unavailable — grant Input Monitoring and relaunch")
        }

        statusItemController.onSetShortcut = { [weak self] in
            self?.statusItemController.isCapturingShortcut = true
            self?.hotkeyManager.beginCapture()
        }
        statusItemController.onLanguageChange = { mode in
            Settings.shared.languageMode = mode
        }
        statusItemController.onDownloadIvrit = { [weak self] in
            self?.downloadIvritModel()
        }

        // Warm the default model in the background so the first dictation is fast.
        preloadModelIfAvailable()
        NSLog("Dikta: ready (shortcut: %@)", Settings.shared.shortcut.displayString)
    }

    // MARK: - Recording flow

    private func startRecording() {
        guard case .idle = state else { return }
        guard Permissions.microphoneGranted else {
            Permissions.requestAll()
            return
        }
        do {
            try audioRecorder.start()
        } catch {
            NSLog("Dikta: failed to start recording: \(error)")
            return
        }
        state = .recording(startedAt: Date())
        statusItemController.setIcon(.recording)

        // Watchdog: if the key-release event was lost (Cmd-Tab mid-hold etc.),
        // don't record forever.
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, !Task.isCancelled else { return }
            if case .recording = self.state {
                NSLog("Dikta: watchdog fired — cancelling stuck recording")
                self.cancelRecording()
            }
        }
    }

    private func stopRecordingAndTranscribe() {
        guard case .recording(let startedAt) = state else { return }
        watchdog?.cancel()
        let samples = audioRecorder.stop()
        let duration = Date().timeIntervalSince(startedAt)

        // Debounce accidental taps and skip silence — whisper hallucinates on
        // empty audio.
        let rms = samples.isEmpty ? 0 : sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        guard duration >= 0.3, samples.count >= 8000, rms > 0.001 else {
            state = .idle
            statusItemController.setIcon(.idle)
            return
        }

        state = .transcribing
        statusItemController.setIcon(.transcribing)

        let mode = Settings.shared.languageMode

        Task { [weak self] in
            guard let self else { return }
            do {
                let (modelPath, language) = try await self.route(samples: samples, mode: mode)
                let text = try await self.transcriber.transcribe(
                    samples: samples, language: language, modelPath: modelPath)
                if !text.isEmpty {
                    let delivery = await self.outputRouter.deliver(text)
                    NSLog("Dikta: %@ (%@)", text, delivery == .injected ? "injected" : "clipboard")
                    self.statusItemController.setLastTranscript(text)
                }
            } catch {
                NSLog("Dikta: transcription failed: \(error)")
            }
            self.state = .idle
            self.statusItemController.setIcon(.idle)
        }
    }

    private func cancelRecording() {
        audioRecorder.cancel()
        watchdog?.cancel()
        state = .idle
        statusItemController.setIcon(.idle)
    }

    /// Pick model + language for this dictation. In Auto mode with the ivrit
    /// model available, detect the language first (fast encoder pass on the
    /// stock model) and route Hebrew to the ivrit fine-tune — it is far more
    /// accurate for Hebrew but must run with an explicit "he" and can't handle
    /// other languages.
    private func route(samples: [Float], mode: LanguageMode) async throws -> (modelPath: String, language: String?) {
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

    // MARK: - Shortcut capture

    private func shortcutCaptured(_ shortcut: Shortcut) {
        Settings.shared.shortcut = shortcut
        statusItemController.isCapturingShortcut = false
        NSLog("Dikta: shortcut set to %@", shortcut.displayString)
    }

    // MARK: - Models

    private func preloadModelIfAvailable() {
        let resolved = ModelManager.shared.resolve(for: Settings.shared.languageMode)
        guard ModelManager.shared.isDownloaded(resolved.spec) else {
            NSLog("Dikta: default model missing — download it from the menu or run `make models`")
            return
        }
        let path = ModelManager.shared.localURL(for: resolved.spec).path
        Task { [transcriber] in
            try? await transcriber.preload(modelPath: path)
        }
    }

    private func downloadIvritModel() {
        let controller = statusItemController!
        controller.downloadProgressText = "מוריד מודל ivrit.ai… 0%"
        Task {
            do {
                try await ModelManager.shared.download(ModelManager.ivritTurbo) { progress in
                    Task { @MainActor in
                        controller.downloadProgressText =
                            "מוריד מודל ivrit.ai… \(Int(progress * 100))%"
                    }
                }
                controller.downloadProgressText = nil
                NSLog("Dikta: ivrit model downloaded")
            } catch {
                controller.downloadProgressText = nil
                NSLog("Dikta: ivrit model download failed: \(error)")
            }
        }
    }
}
