import AVFoundation
import AppKit
import ApplicationServices

@MainActor
enum Permissions {
    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static var inputMonitoringGranted: Bool {
        CGPreflightListenEventAccess()
    }

    static var allGranted: Bool {
        microphoneGranted && accessibilityGranted && inputMonitoringGranted
    }

    /// Fire the system prompts for anything not yet granted.
    static func requestAll() {
        if !microphoneGranted {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        if !accessibilityGranted {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        if !inputMonitoringGranted {
            CGRequestListenEventAccess()
        }
    }

    static func openSettings(pane: SettingsPane) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
        NSWorkspace.shared.open(url)
    }

    enum SettingsPane: String {
        case accessibility = "Privacy_Accessibility"
        case microphone = "Privacy_Microphone"
        case inputMonitoring = "Privacy_ListenEvent"
    }
}
