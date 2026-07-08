import AppKit
import Carbon.HIToolbox
import UserNotifications

/// Delivers a transcript: injects into the focused text field when there is one,
/// otherwise copies to the clipboard and notifies.
@MainActor
final class OutputRouter {
    enum Delivery {
        case injected
        case copiedToClipboard
    }

    func deliver(_ text: String) async -> Delivery {
        guard !text.isEmpty else { return .copiedToClipboard }

        // Secure input (password fields) silently drops synthetic events.
        let secureInput = IsSecureEventInputEnabled()
        if !secureInput && FocusInspector.focusedElementAcceptsText() {
            await inject(text)
            return .injected
        }

        copyToClipboard(text)
        await notifyCopied(text)
        return .copiedToClipboard
    }

    // MARK: - Injection via pasteboard + synthetic Cmd+V

    private func inject(_ text: String) async {
        let pasteboard = NSPasteboard.general

        // Snapshot current pasteboard contents for restoration.
        let savedItems: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy[type] = data
                }
            }
            return copy
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        postCmdV()

        // Give the target app time to read the pasteboard, then restore —
        // but only if nothing else has written to it meanwhile.
        try? await Task.sleep(for: .milliseconds(300))
        if pasteboard.changeCount == ourChangeCount && !savedItems.isEmpty {
            pasteboard.clearContents()
            let items = savedItems.map { saved in
                let item = NSPasteboardItem()
                for (type, data) in saved {
                    item.setData(data, forType: type)
                }
                return item
            }
            pasteboard.writeObjects(items)
        }
    }

    private func postCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        usleep(30_000)
        keyUp.post(tap: .cghidEventTap)
    }

    // MARK: - Clipboard fallback

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func notifyCopied(_ text: String) async {
        // UNUserNotificationCenter crashes when the process is not a real .app bundle
        // (bare executable during development) — beep instead.
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            NSSound.beep()
            NSLog("Dikta: copied to clipboard: %@", text)
            return
        }
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert])) ?? false
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = "התמלול הועתק ללוח"
        content.body = String(text.prefix(120))
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }
}
