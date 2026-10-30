import AppKit
import ApplicationServices

/// Reads the text selected in the app in front, so Option-Space brings it into the mini window.
/// Cherry Studio's selection assistant does the same with a native helper; here it is the
/// Accessibility API, with a simulated Copy for apps that don't expose their selection.
/// Both need Accessibility access, which macOS asks the user for once.
@MainActor
enum SelectionReader {
    /// Asks for Accessibility access when it hasn't been granted. Returns whether it is.
    static func hasAccess(prompt: Bool) -> Bool {
        // The key's literal value; the imported constant is a global var Swift 6 won't read here.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    /// The text selected in the app in front, or nil when there is none or access isn't granted.
    /// `askForAccess` shows macOS's request for Accessibility access when it hasn't been granted.
    static func selectedText(askForAccess: Bool) async -> String? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              hasAccess(prompt: askForAccess)
        else { return nil }
        switch accessibilitySelection() {
        case let .text(text):
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        case .none:
            return nil
        case .unknown:
            // Only for apps that don't say what is selected, so nothing is copied when nothing is selected.
            return await copiedSelection()
        }
    }

    private enum Selection {
        case text(String)
        /// The app says nothing is selected.
        case none
        /// The app doesn't expose its selection.
        case unknown
    }

    private static func accessibilitySelection() -> Selection {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return .unknown }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String
        else { return .unknown }
        return text.isEmpty ? .none : .text(text)
    }

    /// Presses Command-C in the app in front and reads the pasteboard, then puts back what was there.
    private static func copiedSelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        let before = pasteboard.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        let keyC: CGKeyCode = 8
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        for _ in 0..<8 where pasteboard.changeCount == before {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard pasteboard.changeCount != before else { return nil }
        let text = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        let items = saved.map { pairs in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
        return text
    }
}

/// "Ask Spot Chat" in the Services menu, for selected text in any app. It needs no Accessibility access.
final class SelectionService: NSObject {
    var onText: @MainActor (String) -> Void = { _ in }

    @objc func askAboutSelection(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string) else { return }
        MainActor.assumeIsolated { onText(text) }
    }
}
