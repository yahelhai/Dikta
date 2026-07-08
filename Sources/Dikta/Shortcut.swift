import AppKit
import Carbon.HIToolbox

/// A press-and-hold shortcut: either a modifier-only key (e.g. Right Option)
/// or a regular key plus required modifiers (e.g. ⌃⌥Space).
struct Shortcut: Codable, Equatable, Sendable {
    /// Virtual key code of the non-modifier key, or nil for a modifier-only shortcut.
    var keyCode: UInt16?
    /// Required modifier flags (device-independent). For modifier-only shortcuts this
    /// is the flag of the modifier itself and `modifierKeyCode` identifies left/right.
    var modifiers: UInt64
    /// For modifier-only shortcuts: the keyCode of the modifier key (distinguishes
    /// Right Option 61 from Left Option 58).
    var modifierKeyCode: UInt16?

    static let rightOption = Shortcut(keyCode: nil, modifiers: UInt64(NSEvent.ModifierFlags.option.rawValue), modifierKeyCode: 61)

    var isModifierOnly: Bool { keyCode == nil }

    var displayString: String {
        var parts: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        if flags.contains(.function) { parts.append("fn") }
        if let keyCode {
            parts.append(Self.keyName(for: keyCode))
        } else if let modifierKeyCode {
            // Annotate side for modifier-only shortcuts
            switch modifierKeyCode {
            case 61: parts = ["Right ⌥"]
            case 58: parts = ["Left ⌥"]
            case 54: parts = ["Right ⌘"]
            case 55: parts = ["Left ⌘"]
            case 60: parts = ["Right ⇧"]
            case 56: parts = ["Left ⇧"]
            case 62: parts = ["Right ⌃"]
            case 59: parts = ["Left ⌃"]
            case 63: parts = ["fn"]
            default: break
            }
        }
        return parts.joined()
    }

    static func keyName(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_F1...kVK_F1 + 0: return "F1"
        default: break
        }
        // Translate via the current keyboard layout
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "key\(keyCode)"
        }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        var deadKeyState: UInt32 = 0
        let status = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> OSStatus in
            let layout = ptr.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "key\(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}
