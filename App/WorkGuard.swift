import AppKit
import Combine
import SpotCore

/// Looks after what the app itself runs, as Cherry Studio does: commands, and replies when the reply writer
/// isn't there. The Mac doesn't fall asleep on its own partway through, and quitting asks first, so walking
/// away or pressing Command-Q doesn't cut one short without the user knowing.
@MainActor
final class WorkGuard {
    private var sleepHold: NSObjectProtocol?
    private var observer: AnyCancellable?
    private weak var app: AppModel?

    func watch(_ app: AppModel) {
        self.app = app
        // Replies the writer writes keep the Mac awake from there.
        observer = app.$activity.combineLatest(app.$workStoppedByQuitting).sink { [weak self] activity, inProcess in
            self?.holdSleep(while: activity.contains { $0.value == .working && inProcess.contains($0.key) })
        }
    }

    /// Keeps idle sleep off while a reply is written, and not while one only waits for the user, which
    /// could keep the Mac awake for hours. Closing the lid or choosing Sleep still sleeps.
    private func holdSleep(while working: Bool) {
        if working, sleepHold == nil {
            sleepHold = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Writing a reply"
            )
            SpotLog.app.info("Keeping the Mac awake while a reply is written")
        } else if !working, let hold = sleepHold {
            ProcessInfo.processInfo.endActivity(hold)
            sleepHold = nil
            SpotLog.app.info("Letting the Mac sleep again")
        }
    }

    /// Whether quitting may go ahead: at once when nothing is under way or the system is logging out,
    /// restarting or shutting down, and otherwise once the user agrees to stop what is.
    func mayQuit() -> Bool {
        guard let app, !app.workStoppedByQuitting.isEmpty else { return true }
        if Self.systemAsksToQuit {
            SpotLog.app.notice("Quitting for the system with a reply under way")
            return true
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Quit Spot Chat?")
        alert.informativeText = String(localized: "A reply is still being written. Quitting stops it.")
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Quit"))
        NSApp.activate()
        let quits = alert.runModal() == .alertSecondButtonReturn
        SpotLog.app.info("Asked before quitting with a reply under way", metadata: ["quits": "\(quits)"])
        return quits
    }

    /// A quit the system sends for logging out, restarting or shutting down carries its reason; one from
    /// the user, through the menu, the Dock or Command-Q, carries none.
    private static var systemAsksToQuit: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication)
        else { return false }
        return event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
    }
}
