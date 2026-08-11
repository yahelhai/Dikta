import AppKit
@preconcurrency import CoreGraphics

/// Lets a non-Sendable value cross the assumeIsolated boundary; safe because the
/// tap callback and the MainActor both run on the main run loop.
private struct UnsafeBox<T>: @unchecked Sendable { let value: T }

/// Global press-and-hold hotkey via CGEventTap.
/// A tap (rather than NSEvent monitors) is required so shortcuts that include a
/// regular key (e.g. ⌃⌥Space) can be swallowed while held instead of typing
/// into the focused app. Requires Input Monitoring + Accessibility.
@MainActor
final class HotkeyManager {
    enum Event {
        case holdStarted
        case holdEnded
        case shortcutCaptured(Shortcut)
    }

    var onEvent: ((Event) -> Void)?
    var shortcut: Shortcut = .rightOption

    private(set) var isHolding = false
    private var isCapturing = false
    private var captureCandidate: Shortcut?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Modifier flags that participate in shortcut matching.
    private static let relevantFlags: CGEventFlags = [
        .maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn,
    ]

    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            // The tap runs on the main run loop, so MainActor state is safe here.
            nonisolated(unsafe) let unsafeEvent = event
            let box = MainActor.assumeIsolated {
                UnsafeBox(value: manager.handle(type: type, event: unsafeEvent))
            }
            return box.value
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("Dikta: failed to create event tap (missing Input Monitoring permission?)")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    /// Enter capture mode: the next combo pressed becomes the new shortcut.
    func beginCapture() {
        isCapturing = true
        captureCandidate = nil
        endHold()
    }

    func cancelCapture() {
        isCapturing = false
        captureCandidate = nil
    }

    // MARK: - Event handling (must return fast — tap gets disabled if slow)

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp, .flagsChanged:
            break
        default:
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.intersection(Self.relevantFlags)

        if isCapturing {
            return handleCapture(type: type, keyCode: keyCode, flags: flags, event: event)
        }

        if shortcut.isModifierOnly {
            return handleModifierOnly(type: type, keyCode: keyCode, event: event)
        }
        return handleKeyCombo(type: type, keyCode: keyCode, flags: flags, event: event)
    }

    private func handleModifierOnly(type: CGEventType, keyCode: UInt16, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .flagsChanged, keyCode == shortcut.modifierKeyCode else {
            // Any regular keyDown while holding a modifier-only shortcut means the user
            // is typing a real keyboard shortcut (e.g. ⌥E) — cancel the dictation hold
            // and let the event through.
            if isHolding, type == .keyDown {
                endHold()
            }
            return Unmanaged.passUnretained(event)
        }
        let modifierFlag = CGEventFlags(rawValue: UInt64(nsFlagsToCG(shortcut.modifiers)))
        if event.flags.contains(modifierFlag) {
            beginHold()
        } else {
            endHold()
        }
        // Never swallow modifier transitions — the system needs them.
        return Unmanaged.passUnretained(event)
    }

    private func handleKeyCombo(type: CGEventType, keyCode: UInt16, flags: CGEventFlags, event: CGEvent) -> Unmanaged<CGEvent>? {
        let requiredFlags = CGEventFlags(rawValue: UInt64(nsFlagsToCG(shortcut.modifiers)))
            .intersection(Self.relevantFlags)

        switch type {
        case .keyDown where keyCode == shortcut.keyCode && flags == requiredFlags:
            beginHold()
            return nil // swallow (including autorepeat)
        case .keyDown where isHolding && keyCode == shortcut.keyCode:
            return nil // swallow autorepeat even if modifiers wobbled
        case .keyUp where keyCode == shortcut.keyCode && isHolding:
            endHold()
            return nil
        case .flagsChanged where isHolding && !flags.contains(requiredFlags):
            // A required modifier was released before the key — end the hold.
            endHold()
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleCapture(type: CGEventType, keyCode: UInt16, flags: CGEventFlags, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .keyDown:
            // Escape cancels capture
            if keyCode == 53 && flags.isEmpty {
                cancelCapture()
                return nil
            }
            let captured = Shortcut(keyCode: keyCode, modifiers: cgFlagsToNS(flags), modifierKeyCode: nil)
            finishCapture(with: captured)
            return nil // swallow
        case .flagsChanged:
            let modifierFlag = Self.modifierFlag(for: keyCode)
            if let modifierFlag, flags.contains(modifierFlag) {
                // Modifier pressed — candidate for a modifier-only shortcut.
                captureCandidate = Shortcut(
                    keyCode: nil,
                    modifiers: cgFlagsToNS(CGEventFlags(rawValue: modifierFlag.rawValue)),
                    modifierKeyCode: keyCode)
            } else if let candidate = captureCandidate, keyCode == candidate.modifierKeyCode {
                // Released the candidate without pressing a regular key → commit it.
                finishCapture(with: candidate)
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func finishCapture(with shortcut: Shortcut) {
        isCapturing = false
        captureCandidate = nil
        self.shortcut = shortcut
        onEvent?(.shortcutCaptured(shortcut))
    }

    private func beginHold() {
        guard !isHolding else { return }
        isHolding = true
        onEvent?(.holdStarted)
    }

    private func endHold() {
        guard isHolding else { return }
        isHolding = false
        onEvent?(.holdEnded)
    }

    // MARK: - Flag conversion (NSEvent.ModifierFlags <-> CGEventFlags)

    private static func modifierFlag(for keyCode: UInt16) -> CGEventFlags? {
        switch keyCode {
        case 54, 55: return .maskCommand
        case 58, 61: return .maskAlternate
        case 56, 60: return .maskShift
        case 59, 62: return .maskControl
        case 63: return .maskSecondaryFn
        default: return nil
        }
    }

    private func nsFlagsToCG(_ ns: UInt64) -> UInt64 {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(ns))
        var cg: CGEventFlags = []
        if flags.contains(.command) { cg.insert(.maskCommand) }
        if flags.contains(.option) { cg.insert(.maskAlternate) }
        if flags.contains(.shift) { cg.insert(.maskShift) }
        if flags.contains(.control) { cg.insert(.maskControl) }
        if flags.contains(.function) { cg.insert(.maskSecondaryFn) }
        return cg.rawValue
    }

    private func cgFlagsToNS(_ cg: CGEventFlags) -> UInt64 {
        var ns: NSEvent.ModifierFlags = []
        if cg.contains(.maskCommand) { ns.insert(.command) }
        if cg.contains(.maskAlternate) { ns.insert(.option) }
        if cg.contains(.maskShift) { ns.insert(.shift) }
        if cg.contains(.maskControl) { ns.insert(.control) }
        if cg.contains(.maskSecondaryFn) { ns.insert(.function) }
        return UInt64(ns.rawValue)
    }
}
