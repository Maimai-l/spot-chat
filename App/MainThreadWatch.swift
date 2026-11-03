import AppKit
import Foundation
import SpotCore

/// Logs when the interface stops responding: the main thread is busy long enough that clicks, scrolling and
/// typing wait. A background thread asks the main thread to answer every 0.1 seconds and times the answer, so
/// a report of lag can be matched to what the log shows happening at that moment.
enum MainThreadWatch {
    /// Shorter waits aren't felt.
    static let threshold: TimeInterval = 0.25
    /// Longer waits are the Mac sleeping, not the app.
    static let ceiling: TimeInterval = 60

    static func start() {
        let thread = Thread {
            while true {
                let asked = Date()
                let answered = DispatchSemaphore(value: 0)
                let shows = ShowsWindow()
                DispatchQueue.main.async {
                    shows.value = NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
                    answered.signal()
                }
                answered.wait()
                let waited = Date().timeIntervalSince(asked)
                // A hidden app is slowed down by the system on purpose; only lag someone could see counts.
                if waited >= threshold, waited < ceiling, shows.value {
                    SpotLog.app.warning("The interface stopped responding", metadata: [
                        "seconds": "\(String(format: "%.2f", waited))",
                    ])
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        thread.name = "MainThreadWatch"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Whether a window was on screen, written on the main thread before the background thread reads it.
    private final class ShowsWindow: @unchecked Sendable {
        var value = false
    }
}
