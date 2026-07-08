import AppKit
import ServiceManagement

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    enum IconState {
        case idle
        case recording
        case transcribing
    }

    var onSetShortcut: (() -> Void)?
    var onLanguageChange: ((LanguageMode) -> Void)?
    var onDownloadIvrit: (() -> Void)?

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private(set) var lastTranscript: String = ""
    var downloadProgressText: String? {
        didSet { rebuildMenu() }
    }
    var isCapturingShortcut = false {
        didSet { rebuildMenu() }
    }

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        setIcon(.idle)
        rebuildMenu()
    }

    func setIcon(_ state: IconState) {
        guard let button = statusItem.button else { return }
        let (symbol, description): (String, String)
        switch state {
        case .idle: (symbol, description) = ("mic", "Dikta idle")
        case .recording: (symbol, description) = ("mic.fill", "Dikta recording")
        case .transcribing: (symbol, description) = ("waveform", "Dikta transcribing")
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        image?.isTemplate = state != .recording
        button.image = image
        button.contentTintColor = state == .recording ? .systemRed : nil
    }

    func setLastTranscript(_ text: String) {
        lastTranscript = text
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let settings = Settings.shared

        // Permissions status (only when something is missing)
        if !Permissions.allGranted {
            let header = NSMenuItem(title: "חסרות הרשאות:", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            addPermissionItem("מיקרופון", granted: Permissions.microphoneGranted, pane: .microphone)
            addPermissionItem("Accessibility", granted: Permissions.accessibilityGranted, pane: .accessibility)
            addPermissionItem("Input Monitoring", granted: Permissions.inputMonitoringGranted, pane: .inputMonitoring)
            menu.addItem(.separator())
        }

        // Language
        let langHeader = NSMenuItem(title: "שפה", action: nil, keyEquivalent: "")
        langHeader.isEnabled = false
        menu.addItem(langHeader)
        for mode in LanguageMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(languageSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = settings.languageMode == mode ? .on : .off
            if mode == .hebrew && ModelManager.shared.isDownloaded(ModelManager.ivritTurbo) {
                item.title = "עברית (ivrit.ai)"
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // ivrit model download
        if let progress = downloadProgressText {
            let item = NSMenuItem(title: progress, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else if !ModelManager.shared.isDownloaded(ModelManager.ivritTurbo) {
            let item = NSMenuItem(
                title: "הורד מודל עברית משופר (ivrit.ai, ‏1.6GB)…",
                action: #selector(downloadIvritSelected), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        // Shortcut
        let shortcutTitle = isCapturingShortcut
            ? "הקש את הקיצור הרצוי… (Esc לביטול)"
            : "קיצור: \(settings.shortcut.displayString) — שנה…"
        let shortcutItem = NSMenuItem(title: shortcutTitle, action: #selector(setShortcutSelected), keyEquivalent: "")
        shortcutItem.target = self
        shortcutItem.isEnabled = !isCapturingShortcut
        menu.addItem(shortcutItem)

        // Launch at login
        let loginItem = NSMenuItem(title: "פתח בהפעלת המחשב", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        // SMAppService only works from a bundled app
        loginItem.isEnabled = Bundle.main.bundleURL.pathExtension == "app"
        menu.addItem(loginItem)
        menu.addItem(.separator())

        // Last transcript (debug aid)
        if !lastTranscript.isEmpty {
            let item = NSMenuItem(title: "‏\(String(lastTranscript.prefix(60)))", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }

        let quit = NSMenuItem(title: "צא מ-Dikta", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func addPermissionItem(_ name: String, granted: Bool, pane: Permissions.SettingsPane) {
        let item = NSMenuItem(
            title: "\(granted ? "✓" : "✗") \(name)",
            action: granted ? nil : #selector(openPermissionPane(_:)),
            keyEquivalent: "")
        item.target = self
        item.representedObject = pane.rawValue
        menu.addItem(item)
    }

    @objc private func openPermissionPane(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let pane = Permissions.SettingsPane(rawValue: raw) else { return }
        Permissions.openSettings(pane: pane)
    }

    @objc private func languageSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = LanguageMode(rawValue: raw) else { return }
        onLanguageChange?(mode)
        rebuildMenu()
    }

    @objc private func setShortcutSelected() {
        onSetShortcut?()
    }

    @objc private func downloadIvritSelected() {
        onDownloadIvrit?()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                Settings.shared.launchAtLogin = false
            } else {
                try SMAppService.mainApp.register()
                Settings.shared.launchAtLogin = true
            }
        } catch {
            NSLog("Dikta: launch-at-login toggle failed: \(error)")
        }
        rebuildMenu()
    }
}
