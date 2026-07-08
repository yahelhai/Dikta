import ApplicationServices
import Foundation

/// Decides whether the currently focused UI element accepts text input.
@MainActor
enum FocusInspector {
    private static let textRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField",
        "AXWebArea", // web content areas report focus here in some browsers
    ]

    static func focusedElementAcceptsText() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard err == .success, let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return false
        }
        let element = unsafeDowncast(focusedRef as AnyObject, to: AXUIElement.self)

        // 1. Known text roles
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String, textRoles.contains(role) {
            return true
        }

        // 2. Heuristic for web/Electron apps with nonstandard roles:
        //    an element you can select text in is a text input.
        var selectedRangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRangeRef) == .success,
           selectedRangeRef != nil {
            // Static text also exposes a selection range in some apps — require the
            // value to be settable so read-only text doesn't count.
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
               settable.boolValue {
                return true
            }
            // Some editors (and web areas) don't report AXValue settable but do
            // support AXSelectedText insertion — treat a settable selected-text
            // attribute as text input too.
            if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
               settable.boolValue {
                return true
            }
        }

        return false
    }
}
