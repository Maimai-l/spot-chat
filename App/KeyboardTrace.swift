import AppKit
import ApplicationServices
import Carbon
import Logging
import SpotCore

/// Writes down where the keyboard is, so a report like "after Spot Chat closed, every key beeped until it
/// quit" can be traced from the log alone. It records which keys are held (the modifiers, as the user's
/// own keyboard and as the system as a whole see them), which app is in front and which window of Spot
/// Chat has the keyboard, the input method and whether secure input is on. It never records which letters were typed: only that a key was pressed, whether
/// it was a modifier, and which modifiers were down with it.
@MainActor
enum KeyboardTrace {
    /// The state at one moment, such as "Option-Space" or "after the mini window hid".
    static func note(_ moment: String) {
        SpotLog.window.info("Keyboard", metadata: state(moment))
    }

    /// For a minute after a window of Spot Chat hides, notes every key pressed anywhere and where it went, then stops.
    /// Keys pressed in other apps are seen only with Accessibility access, which bringing selected text has.
    static func watchAfterHiding(_ window: String = "the mini window", seconds: TimeInterval = 60, limit: Int = 20) {
        stopWatching()
        watch += 1
        let current = watch
        note("after \(window) hid")
        var seen = 0
        let handle: (NSEvent, String) -> Void = { event, place in
            seen += 1
            guard seen <= limit else { return }
            var metadata = state("key pressed \(place)")
            metadata["event"] = "\(event.type == .flagsChanged ? "modifier changed" : "key down")"
            metadata["eventModifiers"] = "\(names(of: event.modifierFlags))"
            SpotLog.window.info("Keyboard", metadata: metadata)
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            MainActor.assumeIsolated { handle(event, "in another app") }
        }
        local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event, "in Spot Chat")
            return event
        }
        if global == nil {
            SpotLog.window.notice("Can't see keys pressed in other apps without Accessibility access")
        }
        // A few notes along the way, so a key typed late in the minute still has the state beside it.
        for after in [2.0, 10.0, 30.0] where after < seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                guard watch == current else { return }
                note("\(Int(after)) s after \(window) hid")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            // A later hide started a watch of its own.
            guard watch == current else { return }
            var metadata = state("\(Int(seconds)) s after \(window) hid")
            metadata["keysSeen"] = "\(seen)"
            SpotLog.window.info("Keyboard", metadata: metadata)
            stopWatching()
        }
    }

    /// Always on: a key that reaches Spot Chat while no window of it can take keys is beeped at by macOS.
    static func watchForKeysWithNowhereToGo() {
        orphan = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if NSApp.keyWindow == nil || NSApp.keyWindow?.isVisible == false {
                var metadata = state("key with no window to take it")
                metadata["eventModifiers"] = "\(names(of: event.modifierFlags))"
                SpotLog.window.warning("A key reached Spot Chat with no window to take it", metadata: metadata)
            }
            return event
        }
    }

    private static func stopWatching() {
        if let global { NSEvent.removeMonitor(global) }
        if let local { NSEvent.removeMonitor(local) }
        global = nil
        local = nil
    }

    /// Counts watches, so one that a later hide replaced doesn't stop the new one.
    nonisolated(unsafe) private static var watch = 0
    nonisolated(unsafe) private static var global: Any?
    nonisolated(unsafe) private static var local: Any?
    nonisolated(unsafe) private static var orphan: Any?

    private static func state(_ moment: String) -> Logger.Metadata {
        let front = NSWorkspace.shared.frontmostApplication
        let key = NSApp.keyWindow
        return [
            "moment": "\(moment)",
            "front": "\(front?.localizedName ?? "none")",
            "spotChatActive": "\(NSApp.isActive)",
            "keyWindow": "\(key.map { "\(type(of: $0))\($0.isVisible ? "" : " (hidden)")" } ?? "none")",
            // What the user's own keyboard holds, and what the system as a whole thinks is held, which
            // includes keys Spot Chat itself posted.
            "heldOnKeyboard": "\(names(of: CGEventSource.flagsState(.hidSystemState)))",
            "heldForSystem": "\(names(of: CGEventSource.flagsState(.combinedSessionState)))",
            // Secure input, which a password field turns on, keeps keys from every app's monitors; an app
            // that leaves it on hides typing from them all.
            "secureInput": "\(secureInput())",
            // The input method keys pass through first, and whether a text field of Spot Chat still holds
            // it: one left holding it after its window hid gets every key, typed anywhere.
            "inputSource": "\(inputSource())",
            "spotChatTextInput": "\(NSTextInputContext.current.map { "\(type(of: $0.client))" } ?? "none")",
            // Where the app in front has its keyboard focus, by role only, never the contents.
            "frontFocus": "\(focus(of: front))",
        ]
    }

    private static func inputSource() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return "unknown" }
        return Unmanaged<CFString>.fromOpaque(id).takeUnretainedValue() as String
    }

    private static func secureInput() -> String {
        guard IsSecureEventInputEnabled() else { return "off" }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard let pid = (session?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value else { return "on" }
        return "on by \(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "process \(pid)")"
    }

    private static func focus(of app: NSRunningApplication?) -> String {
        guard let app, SelectionReader.hasAccess(prompt: false) else { return "unknown" }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        let hasWindow = AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success
            && window != nil
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return hasWindow ? "window, no focused element" : "no focused window" }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXRoleAttribute as CFString, &role)
        return "\(hasWindow ? "window" : "no focused window"), \(role as? String ?? "unknown role")"
    }

    private static func names(of flags: CGEventFlags) -> String {
        names(of: NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)))
    }

    private static func names(of flags: NSEvent.ModifierFlags) -> String {
        var held: [String] = []
        if flags.contains(.command) { held.append("command") }
        if flags.contains(.option) { held.append("option") }
        if flags.contains(.control) { held.append("control") }
        if flags.contains(.shift) { held.append("shift") }
        if flags.contains(.capsLock) { held.append("capsLock") }
        if flags.contains(.function) { held.append("fn") }
        return held.isEmpty ? "none" : held.joined(separator: "+")
    }
}
