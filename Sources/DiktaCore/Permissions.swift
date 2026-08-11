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

    /// Needed only by the screen-recording feature — dictation works without it.
    static var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// The dictation permissions. Screen Recording is deliberately excluded —
    /// it's requested lazily on the first screen-recording attempt so
    /// dictation-only users are never prompted or nagged about it.
    static var allGranted: Bool {
        microphoneGranted && accessibilityGranted && inputMonitoringGranted
    }

    /// Fire the system prompts for anything not yet granted (dictation set only).
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

    /// Ask for Screen Recording. The system only shows the prompt once per
    /// binary; afterwards the user has to flip it in System Settings.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        guard !screenRecordingGranted else { return true }
        return CGRequestScreenCaptureAccess()
    }

    static func openSettings(pane: SettingsPane) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
        NSWorkspace.shared.open(url)
    }

    enum SettingsPane: String {
        case accessibility = "Privacy_Accessibility"
        case microphone = "Privacy_Microphone"
        case inputMonitoring = "Privacy_ListenEvent"
        case screenRecording = "Privacy_ScreenCapture"
    }
}
