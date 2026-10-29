import AppKit

/// Cut, copy, paste, select all, undo and redo for windows of an app that has no visible Edit menu.
/// The window gets the key press first, so these work whether or not a menu bar is shown.
enum EditingKeys {
    static func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.type == .keyDown, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let selector: Selector?
        if flags == .command {
            switch key {
            case "x": selector = #selector(NSText.cut(_:))
            case "c": selector = #selector(NSText.copy(_:))
            case "v": selector = #selector(NSText.paste(_:))
            case "a": selector = #selector(NSResponder.selectAll(_:))
            case "z": selector = Selector(("undo:"))
            case "w": selector = window.styleMask.contains(.closable) ? #selector(NSWindow.performClose(_:)) : nil
            default: selector = nil
            }
        } else if flags == [.command, .shift], key == "z" {
            selector = Selector(("redo:"))
        } else {
            selector = nil
        }
        guard let selector else { return false }
        return NSApp.sendAction(selector, to: nil, from: window)
    }
}

/// A standard window that handles the editing keys itself.
class EditingWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        EditingKeys.handle(event, in: self) || super.performKeyEquivalent(with: event)
    }
}
