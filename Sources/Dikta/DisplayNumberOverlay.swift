import AppKit
import ScreenCaptureKit

/// Big "1", "2", … cards drawn on every physical screen while the display
/// picker is open, so the numbers in the menu map to actual monitors.
///
/// The app is `.accessory` and never activates, and these panels go up while an
/// `NSMenu` is running its modal tracking loop — hence non-activating panels
/// ordered front with `orderFrontRegardless()`.
@MainActor
final class DisplayNumberOverlay {
    private var panels: [NSPanel] = []
    private var cards: [CardView] = []

    private static let cardSize = NSSize(width: 280, height: 180)

    /// One card per display, numbered `index + 1` to match the menu rows.
    func show(for displays: [SCDisplay]) {
        hide()
        for (index, display) in displays.enumerated() {
            guard let frame = Self.cardFrame(for: display) else { continue }
            let card = CardView(
                number: index + 1,
                subtitle: LiveRecorder.subtitle(for: display),
                frame: NSRect(origin: .zero, size: Self.cardSize))
            let panel = Self.makePanel(contentRect: frame)
            panel.contentView = card
            panel.orderFrontRegardless()
            panels.append(panel)
            cards.append(card)
        }
    }

    /// Highlight the card for `index` (the menu item's tag), clearing the rest.
    func setHighlighted(_ index: Int?) {
        for (offset, card) in cards.enumerated() {
            card.setHighlighted(offset == index)
        }
    }

    func hide() {
        for panel in panels {
            panel.orderOut(nil)
            panel.contentView = nil
        }
        panels.removeAll()
        cards.removeAll()
    }

    // MARK: - Geometry

    /// Centered card rect in AppKit coordinates for `display`'s monitor.
    private static func cardFrame(for display: SCDisplay) -> NSRect? {
        guard let screen = screenFrame(for: display.displayID) else { return nil }
        return NSRect(
            x: screen.midX - cardSize.width / 2,
            y: screen.midY - cardSize.height / 2,
            width: cardSize.width,
            height: cardSize.height)
    }

    /// `NSScreen` is the source of truth (AppKit coordinates, origin bottom-left).
    /// `SCDisplay.frame` is deliberately not used — it is in CoreGraphics space
    /// and would place windows flipped vertically.
    private static func screenFrame(for displayID: CGDirectDisplayID) -> NSRect? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let screen = NSScreen.screens.first(where: {
            $0.deviceDescription[key] as? CGDirectDisplayID == displayID
        }) {
            return screen.frame
        }
        // Rare fallback (e.g. a mirrored display with no NSScreen of its own):
        // flip CG bounds against the primary screen's height.
        guard let primary = NSScreen.screens.first else { return nil }
        let bounds = CGDisplayBounds(displayID)
        guard !bounds.isEmpty else { return nil }
        return NSRect(
            x: bounds.origin.x,
            y: primary.frame.height - bounds.maxY,
            width: bounds.width,
            height: bounds.height)
    }

    // MARK: - Panel

    private static func makePanel(contentRect: NSRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Below .popUpMenu (101) on purpose: the card must never cover the menu
        // it is helping the user read.
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary,
        ]
        return panel
    }

    // MARK: - Card

    private final class CardView: NSView {
        private let numberLabel = NSTextField(labelWithString: "")
        private let subtitleLabel = NSTextField(labelWithString: "")

        init(number: Int, subtitle: String, frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 28
            layer?.borderWidth = 4

            numberLabel.stringValue = "\(number)"
            numberLabel.font = .systemFont(ofSize: 110, weight: .bold)
            numberLabel.textColor = .white
            numberLabel.alignment = .center
            numberLabel.translatesAutoresizingMaskIntoConstraints = false

            subtitleLabel.stringValue = subtitle
            subtitleLabel.font = .systemFont(ofSize: 15, weight: .medium)
            subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.85)
            subtitleLabel.alignment = .center
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

            addSubview(numberLabel)
            addSubview(subtitleLabel)
            NSLayoutConstraint.activate([
                numberLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
                numberLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -14),
                subtitleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
                subtitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
                subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
                subtitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            ])

            setHighlighted(false)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// Immediate, unanimated — this runs inside the menu's modal tracking loop.
        func setHighlighted(_ highlighted: Bool) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let accent = NSColor.controlAccentColor
            layer?.backgroundColor = highlighted
                ? accent.withAlphaComponent(0.95).cgColor
                : NSColor.black.withAlphaComponent(0.9).cgColor
            layer?.borderColor = highlighted
                ? NSColor.white.withAlphaComponent(0.9).cgColor
                : NSColor.clear.cgColor
            CATransaction.commit()
        }
    }
}
