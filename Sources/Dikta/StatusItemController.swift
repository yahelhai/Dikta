import AppKit
import ScreenCaptureKit
import ServiceManagement

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    enum IconState {
        case idle
        case recording
        case transcribing
        case screenRecording
    }

    var onSetShortcut: (() -> Void)?
    var onLanguageChange: ((LanguageMode) -> Void)?
    var onDownloadIvrit: (() -> Void)?
    var onStartScreenRecording: ((SCDisplay) -> Void)?
    var onStopScreenRecording: (() -> Void)?
    var onChangeRecordingsFolder: ((URL) -> Void)?

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private(set) var lastTranscript: String = ""
    var downloadProgressText: String? {
        didSet { rebuildMenu() }
    }
    var isCapturingShortcut = false {
        didSet { rebuildMenu() }
    }

    // MARK: - Screen recording state (pushed in by the coordinator)

    /// Displays offered in the "הקלט מסך" submenu, refreshed asynchronously
    /// because `SCShareableContent` is an async API and menu building is not.
    private var displays: [SCDisplay] = []
    private var isRefreshingDisplays = false

    /// Seconds elapsed in the current screen recording, or nil when not recording.
    var screenRecordingElapsed: (() -> TimeInterval?)?
    /// Hebrew phase label while post-processing, or nil.
    var screenProcessingPhase: String? {
        didSet { if oldValue != screenProcessingPhase { rebuildMenu() } }
    }

    private var elapsedItem: NSMenuItem?
    private var elapsedTimer: Timer?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        // We drive enablement ourselves (the summary toggle is disabled until
        // an API key exists); AppKit's automatic enabling would override it.
        menu.autoenablesItems = false
        statusItem.menu = menu
        setIcon(.idle)
        rebuildMenu()
    }

    private var iconState: IconState = .idle

    func setIcon(_ state: IconState) {
        iconState = state
        guard let button = statusItem.button else { return }
        let (symbol, description): (String, String)
        switch state {
        case .idle: (symbol, description) = ("mic", "Dikta idle")
        case .recording: (symbol, description) = ("mic.fill", "Dikta recording")
        case .transcribing: (symbol, description) = ("waveform", "Dikta transcribing")
        case .screenRecording: (symbol, description) = ("record.circle", "Dikta screen recording")
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        let isRed = state == .recording || state == .screenRecording
        image?.isTemplate = !isRed
        button.image = image
        button.contentTintColor = isRed ? .systemRed : nil
    }

    /// The dictation flow drives the icon too; while a screen recording is live
    /// its red `record.circle` wins over dictation's idle state.
    func setScreenRecordingActive(_ active: Bool) {
        if active {
            setIcon(.screenRecording)
            startElapsedTimer()
        } else {
            stopElapsedTimer()
            if iconState == .screenRecording { setIcon(.idle) }
        }
        rebuildMenu()
    }

    func setLastTranscript(_ text: String) {
        lastTranscript = text
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshDisplays()
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        elapsedItem = nil
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
            addPermissionItem("Screen Recording", granted: Permissions.screenRecordingGranted, pane: .screenRecording)
            menu.addItem(.separator())
        }

        addScreenRecordingSection()
        menu.addItem(.separator())

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

        // Trailing space
        let spaceItem = NSMenuItem(title: "רווח אוטומטי בסוף הטקסט", action: #selector(toggleTrailingSpace), keyEquivalent: "")
        spaceItem.target = self
        spaceItem.state = settings.appendTrailingSpace ? .on : .off
        menu.addItem(spaceItem)

        // Launch at login
        let loginItem = NSMenuItem(title: "פתח בהפעלת המחשב", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        // SMAppService only works from a bundled app
        loginItem.isEnabled = Bundle.main.bundleURL.pathExtension == "app"
        menu.addItem(loginItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "צא מ-Dikta", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: - Screen recording section

    private func addScreenRecordingSection() {
        if let phase = screenProcessingPhase {
            let item = NSMenuItem(title: phase, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else if let elapsed = screenRecordingElapsed?() {
            let stop = NSMenuItem(title: "⏹ עצור הקלטה ועבד",
                                  action: #selector(stopScreenRecordingSelected), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)

            let timer = NSMenuItem(title: elapsedTitle(elapsed), action: nil, keyEquivalent: "")
            timer.isEnabled = false
            menu.addItem(timer)
            elapsedItem = timer
        } else {
            let root = NSMenuItem(title: "🖥 הקלט מסך", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            if !Permissions.screenRecordingGranted {
                let item = NSMenuItem(title: "נדרשת הרשאת Screen Recording…",
                                      action: #selector(openPermissionPane(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = Permissions.SettingsPane.screenRecording.rawValue
                submenu.addItem(item)
            } else if displays.isEmpty {
                let item = NSMenuItem(title: "טוען מסכים…", action: nil, keyEquivalent: "")
                item.isEnabled = false
                submenu.addItem(item)
            } else {
                for (offset, display) in displays.enumerated() {
                    let item = NSMenuItem(title: LiveRecorder.label(for: display, index: offset),
                                          action: #selector(startScreenRecordingSelected(_:)),
                                          keyEquivalent: "")
                    item.target = self
                    item.tag = offset
                    submenu.addItem(item)
                }
            }
            root.submenu = submenu
            menu.addItem(root)
        }

        let folder = Settings.shared.recordingsFolder
        let folderItem = NSMenuItem(
            title: "תיקיית הקלטות: \(abbreviated(folder)) — שנה…",
            action: #selector(changeRecordingsFolderSelected), keyEquivalent: "")
        folderItem.target = self
        menu.addItem(folderItem)

        addSummarySection()
    }

    /// Optional Claude summary: the key lives in the Keychain, and the toggle
    /// only becomes usable once one is stored.
    private func addSummarySection() {
        let hasKey = KeychainStore.hasAPIKey

        let keyItem = NSMenuItem(
            title: hasKey ? "הגדר Anthropic API Key… (מוגדר ✓)" : "הגדר Anthropic API Key…",
            action: #selector(setAPIKeySelected), keyEquivalent: "")
        keyItem.target = self
        menu.addItem(keyItem)

        let summaryItem = NSMenuItem(title: "סיכום אוטומטי עם Claude",
                                     action: #selector(toggleAutoSummarize), keyEquivalent: "")
        summaryItem.target = self
        summaryItem.state = (hasKey && Settings.shared.autoSummarize) ? .on : .off
        summaryItem.isEnabled = hasKey
        if !hasKey {
            summaryItem.toolTip = "נדרש Anthropic API Key כדי לסכם עם Claude"
        }
        menu.addItem(summaryItem)
    }

    private func elapsedTitle(_ elapsed: TimeInterval) -> String {
        "מקליט… \(MarkdownExporter.timecode(elapsed))"
    }

    private func abbreviated(_ url: URL) -> String {
        let home = NSHomeDirectory()
        return url.path.hasPrefix(home)
            ? "~" + url.path.dropFirst(home.count)
            : url.path
    }

    /// `SCShareableContent` is async; cache the result and rebuild once it lands.
    private func refreshDisplays() {
        guard Permissions.screenRecordingGranted, !isRefreshingDisplays else { return }
        isRefreshingDisplays = true
        Task { [weak self] in
            let found = (try? await LiveRecorder.availableDisplays()) ?? []
            guard let self else { return }
            self.isRefreshingDisplays = false
            let changed = found.map(\.displayID) != self.displays.map(\.displayID)
            self.displays = found
            if changed { self.rebuildMenu() }
        }
    }

    /// Keep the elapsed-time item ticking while the menu is open. `.common`
    /// includes the modal event-tracking mode menus run in.
    private func startElapsedTimer() {
        stopElapsedTimer()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let item = self.elapsedItem,
                      let elapsed = self.screenRecordingElapsed?() else { return }
                item.title = self.elapsedTitle(elapsed)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        elapsedItem = nil
    }

    @objc private func startScreenRecordingSelected(_ sender: NSMenuItem) {
        guard displays.indices.contains(sender.tag) else { return }
        onStartScreenRecording?(displays[sender.tag])
    }

    @objc private func stopScreenRecordingSelected() {
        onStopScreenRecording?()
    }

    @objc private func changeRecordingsFolderSelected() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "בחר"
        panel.message = "בחר תיקייה לשמירת הקלטות המסך"
        panel.directoryURL = Settings.shared.recordingsFolder
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onChangeRecordingsFolder?(url)
        rebuildMenu()
    }

    /// Prompt for the API key. The value goes straight to the Keychain and is
    /// never logged or held anywhere else; an empty field deletes it.
    @objc private func setAPIKeySelected() {
        let alert = NSAlert()
        alert.messageText = "מפתח Anthropic API"
        alert.informativeText =
            "הדבק מפתח API כדי לאפשר סיכום אוטומטי עם Claude. שדה ריק מוחק את המפתח השמור."
        alert.addButton(withTitle: "שמור")
        alert.addButton(withTitle: "ביטול")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "sk-ant-…"
        alert.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        KeychainStore.setAPIKey(field.stringValue)
        if !KeychainStore.hasAPIKey { Settings.shared.autoSummarize = false }
        NSLog("Dikta: Anthropic API key %@",
              KeychainStore.hasAPIKey ? "stored" : "cleared")
        rebuildMenu()
    }

    @objc private func toggleAutoSummarize() {
        guard KeychainStore.hasAPIKey else { return }
        Settings.shared.autoSummarize.toggle()
        rebuildMenu()
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

    @objc private func toggleTrailingSpace() {
        Settings.shared.appendTrailingSpace.toggle()
        rebuildMenu()
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
