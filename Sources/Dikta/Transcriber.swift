import Foundation
import whisper

/// Owns whisper contexts. Actor-confined: whisper_context is not thread-safe.
/// Multiple models can be resident at once (stock multilingual + ivrit Hebrew);
/// all contexts are freed after `idleUnloadDelay` without use so model memory
/// (up to ~2GB) is not held while the user isn't dictating.
actor Transcriber {
    /// Sendable wrapper so deinit may release the pointer; all use stays actor-confined.
    private struct Context: @unchecked Sendable { let ptr: OpaquePointer }

    static let idleUnloadDelay: Duration = .seconds(5 * 60)

    private var contexts: [String: Context] = [:]
    private var unloadTask: Task<Void, Never>?

    deinit {
        for context in contexts.values { whisper_free(context.ptr) }
    }

    /// Warm a model so the next dictation doesn't pay the load cost.
    func preload(modelPath: String) throws {
        _ = try context(for: modelPath)
        scheduleIdleUnload()
    }

    /// Detect the spoken language using the (multilingual) model at `modelPath`.
    /// Runs mel + encoder only — much cheaper than a full transcription.
    func detectLanguage(samples: [Float], modelPath: String) throws -> String {
        let ctx = try context(for: modelPath)
        defer { scheduleIdleUnload() }

        let nThreads = Int32(min(8, ProcessInfo.processInfo.activeProcessorCount))
        let melStatus = samples.withUnsafeBufferPointer { buf in
            whisper_pcm_to_mel(ctx, buf.baseAddress, Int32(buf.count), nThreads)
        }
        guard melStatus == 0 else { throw DiktaError.transcriptionFailed(Int(melStatus)) }
        let langID = whisper_lang_auto_detect(ctx, 0, nThreads, nil)
        guard langID >= 0, let cstr = whisper_lang_str(langID) else {
            throw DiktaError.transcriptionFailed(Int(langID))
        }
        return String(cString: cstr)
    }

    /// Transcribe 16kHz mono Float32 samples with the model at `modelPath`.
    /// `language` is a whisper language code ("he", "en") or nil for auto-detect.
    func transcribe(samples: [Float], language: String?, modelPath: String) throws -> String {
        guard !samples.isEmpty else { return "" }
        let ctx = try context(for: modelPath)
        defer { scheduleIdleUnload() }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.no_timestamps = true
        params.suppress_blank = true
        params.n_threads = Int32(min(8, ProcessInfo.processInfo.activeProcessorCount))

        let run: (UnsafePointer<CChar>?) throws -> String = { langPtr in
            params.language = langPtr
            let status = samples.withUnsafeBufferPointer { buf in
                whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
            }
            guard status == 0 else { throw DiktaError.transcriptionFailed(Int(status)) }
            var out = ""
            for i in 0..<whisper_full_n_segments(ctx) {
                if let text = whisper_full_get_segment_text(ctx, i) {
                    out += String(cString: text)
                }
            }
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let language {
            return try language.withCString { try run($0) }
        }
        return try run(nil)
    }

    // MARK: - Context cache

    private func context(for path: String) throws -> OpaquePointer {
        if let cached = contexts[path] { return cached.ptr }
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let ctx = whisper_init_from_file_with_params(path, params) else {
            throw DiktaError.modelLoadFailed(path)
        }
        contexts[path] = Context(ptr: ctx)
        return ctx
    }

    private func scheduleIdleUnload() {
        unloadTask?.cancel()
        unloadTask = Task {
            try? await Task.sleep(for: Self.idleUnloadDelay)
            guard !Task.isCancelled else { return }
            unloadAll()
        }
    }

    private func unloadAll() {
        guard !contexts.isEmpty else { return }
        for context in contexts.values { whisper_free(context.ptr) }
        contexts.removeAll()
        NSLog("Dikta: unloaded idle models (memory released)")
    }
}

enum DiktaError: Error, CustomStringConvertible {
    case modelLoadFailed(String)
    case modelNotLoaded
    case transcriptionFailed(Int)
    case audioLoadFailed(String)
    case audioEngineFailed(String)

    var description: String {
        switch self {
        case .modelLoadFailed(let path): return "Failed to load model at \(path)"
        case .modelNotLoaded: return "No model loaded"
        case .transcriptionFailed(let code): return "whisper_full failed with code \(code)"
        case .audioLoadFailed(let reason): return "Audio load failed: \(reason)"
        case .audioEngineFailed(let reason): return "Audio engine failed: \(reason)"
        }
    }
}
