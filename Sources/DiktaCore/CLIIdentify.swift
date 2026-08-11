import AppKit
import Foundation
import ScreenCaptureKit

/// `dikta displays --identify` — the numbered cards from the menu's display
/// picker, on demand.
///
/// Without this, `dikta displays` can tell you that screen 2 has id 1, but
/// nothing tells you *which physical monitor* that is; the numbers only ever
/// appeared while the menu submenu was open. Anything driving the CLI — a person
/// with three identical monitors, or an agent that has to record the screen a
/// video is playing on — needs to see the number on the glass.
///
/// This is the one CLI path that touches AppKit: drawing windows needs a run
/// loop. `RecordingDaemon` deliberately never does.
func identifyDisplays(seconds: Double) -> Int32 {
    let app = NSApplication.shared
    // Accessory, so flashing the cards never steals focus from whatever is
    // being staged for recording.
    app.setActivationPolicy(.accessory)

    Task { @MainActor in
        let displays: [SCDisplayList]
        do {
            displays = try await LiveRecorder.availableDisplays().map(SCDisplayList.init)
        } catch {
            note("displays", "\(error)")
            cleanExit(1)
        }

        let overlay = DisplayNumberOverlay()
        overlay.show(for: displays.map(\.display))
        for (offset, entry) in displays.enumerated() {
            let pixels = LiveRecorder.pixelSize(of: entry.display)
            let main = entry.display.displayID == CGMainDisplayID() ? "  main" : ""
            print("\(offset + 1)  id=\(entry.display.displayID)  "
                  + "\(pixels.width)x\(pixels.height)px\(main)")
        }
        fflush(stdout)

        try? await Task.sleep(for: .seconds(seconds))
        overlay.hide()
        cleanExit(0)
    }

    app.run()
    return 0
}

/// `SCDisplay` is an immutable descriptor that simply isn't marked `Sendable`;
/// this box carries it across the await without weakening anything real.
private struct SCDisplayList: @unchecked Sendable {
    let display: SCDisplay
    init(_ display: SCDisplay) { self.display = display }
}
