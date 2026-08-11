import Foundation

/// Which backend writes `summary.md`.
enum SummaryEngine: String, CaseIterable, Sendable {
    /// Claude Code CLI (`claude -p`) — uses the user's Claude subscription.
    case claudeCLI
    /// Anthropic Messages API — uses API credits and the Keychain key.
    case apiKey

    var displayName: String {
        switch self {
        case .claudeCLI: return "Claude CLI (מנוי — מומלץ)"
        case .apiKey: return "API key (קרדיט API)"
        }
    }
}

enum LanguageMode: String, CaseIterable {
    case auto
    case english
    case hebrew

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .english: return "English"
        case .hebrew: return "עברית"
        }
    }

    /// Language code passed to whisper, or nil for auto-detect.
    var whisperLanguage: String? {
        switch self {
        case .auto: return nil
        case .english: return "en"
        case .hebrew: return "he"
        }
    }
}

@MainActor
final class Settings {
    static let shared = Settings()

    private let defaults = Settings.store

    /// Named explicitly rather than `.standard` so the CLI agrees with the app.
    /// `.standard` keys off the bundle identifier, which a bare SwiftPM binary
    /// like `.build/debug/Dikta` does not have — it would silently read a
    /// different domain and, for instance, record into the wrong folder.
    /// Computed rather than stored: `UserDefaults` is not `Sendable`, and
    /// `UserDefaults(suiteName:)` hands back the same shared instance anyway.
    nonisolated static var store: UserDefaults {
        UserDefaults(suiteName: "com.yahel.dikta") ?? .standard
    }

    fileprivate enum Key {
        static let languageMode = "dikta.languageMode"
        static let shortcut = "dikta.shortcut"
        static let launchAtLogin = "dikta.launchAtLogin"
        static let appendTrailingSpace = "dikta.appendTrailingSpace"
        static let recordingsFolder = "dikta.recordingsFolder"
        static let autoSummarize = "dikta.autoSummarize"
        static let summaryEngine = "dikta.summaryEngine"
        static let apiKeyConfigured = "dikta.apiKeyConfigured"
    }

    var languageMode: LanguageMode {
        get { LanguageMode(rawValue: defaults.string(forKey: Key.languageMode) ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: Key.languageMode) }
    }

    var shortcut: Shortcut {
        get {
            guard let data = defaults.data(forKey: Key.shortcut),
                  let s = try? JSONDecoder().decode(Shortcut.self, from: data) else {
                return .rightOption
            }
            return s
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.shortcut)
            }
        }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin) }
        set { defaults.set(newValue, forKey: Key.launchAtLogin) }
    }

    /// Append a trailing space to every transcript so consecutive dictations
    /// don't run together. Default: on.
    var appendTrailingSpace: Bool {
        get { defaults.object(forKey: Key.appendTrailingSpace) == nil
            ? true
            : defaults.bool(forKey: Key.appendTrailingSpace) }
        set { defaults.set(newValue, forKey: Key.appendTrailingSpace) }
    }

    /// Run the (optional) Claude summary stage after a screen recording.
    /// Default: off.
    var autoSummarize: Bool {
        get { defaults.bool(forKey: Key.autoSummarize) }
        set { defaults.set(newValue, forKey: Key.autoSummarize) }
    }

    /// How summaries are produced: the local Claude Code CLI (billed to the
    /// user's Claude subscription) or the Messages API (billed to API credits).
    var summaryEngine: SummaryEngine {
        get { SummaryEngine(rawValue: defaults.string(forKey: Key.summaryEngine) ?? "") ?? .claudeCLI }
        set { defaults.set(newValue.rawValue, forKey: Key.summaryEngine) }
    }

    /// Mirror of "an API key is stored in the Keychain", maintained by the
    /// set-key dialog. The menu reads THIS flag, never the Keychain itself —
    /// a passive SecItem read from a rebuilt binary makes macOS pop a Keychain
    /// authorization dialog on every menu open, which made the app unusable.
    /// The Keychain is only touched when an API-engine summary actually runs.
    var apiKeyConfigured: Bool {
        get { defaults.bool(forKey: Key.apiKeyConfigured) }
        set { defaults.set(newValue, forKey: Key.apiKeyConfigured) }
    }

    /// Where screen recordings are written. Stored as a path string; the folder
    /// itself is created on demand by `ensureRecordingsFolder()`.
    var recordingsFolder: URL {
        get { Self.storedRecordingsFolder }
        set { defaults.set(newValue.path, forKey: Key.recordingsFolder) }
    }

    nonisolated static var defaultRecordingsFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return documents.appendingPathComponent("Dikta", isDirectory: true)
    }

    /// Create the recordings folder if it isn't there yet, and return it.
    @discardableResult
    func ensureRecordingsFolder() -> URL {
        let folder = recordingsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

// MARK: - Reading settings off the main actor

/// `dikta record` runs before any UI — and therefore any main actor — exists,
/// but it must honour the same preferences the menu would have used. The
/// `@MainActor` properties above delegate here, so the keys and the defaults
/// stay defined in exactly one place.
extension Settings {
    nonisolated static var storedRecordingsFolder: URL {
        if let path = store.string(forKey: Key.recordingsFolder), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return defaultRecordingsFolder
    }

    nonisolated static var storedLanguageMode: LanguageMode {
        LanguageMode(rawValue: store.string(forKey: Key.languageMode) ?? "") ?? .auto
    }

    nonisolated static var storedAutoSummarize: Bool {
        store.bool(forKey: Key.autoSummarize)
    }

    nonisolated static var storedSummaryEngine: SummaryEngine {
        SummaryEngine(rawValue: store.string(forKey: Key.summaryEngine) ?? "") ?? .claudeCLI
    }
}
