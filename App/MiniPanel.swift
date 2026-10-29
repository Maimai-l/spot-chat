import AppKit

/// The floating mini window. It takes keyboard focus without activating the app,
/// so the app the user was in stays frontmost, and it can float over full screen apps.
final class MiniPanel: NSPanel {
    var onEscape: (() -> Void)?

    static func make(width: CGFloat, height: CGFloat) -> MiniPanel {
        let panel = MiniPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .utilityWindow
        panel.setAccessibilityIdentifier("miniWindow")
        return panel
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        EditingKeys.handle(event, in: self) || super.performKeyEquivalent(with: event)
    }
}
