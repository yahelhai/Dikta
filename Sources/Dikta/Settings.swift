import Foundation

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

    private let defaults = UserDefaults.standard

    private enum Key {
        static let languageMode = "dikta.languageMode"
        static let shortcut = "dikta.shortcut"
        static let launchAtLogin = "dikta.launchAtLogin"
        static let appendTrailingSpace = "dikta.appendTrailingSpace"
        static let recordingsFolder = "dikta.recordingsFolder"
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

    /// Where screen recordings are written. Stored as a path string; the folder
    /// itself is created on demand by `ensureRecordingsFolder()`.
    var recordingsFolder: URL {
        get {
            if let path = defaults.string(forKey: Key.recordingsFolder), !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return Self.defaultRecordingsFolder
        }
        set { defaults.set(newValue.path, forKey: Key.recordingsFolder) }
    }

    static var defaultRecordingsFolder: URL {
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
