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
}
