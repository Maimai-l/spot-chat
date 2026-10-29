import AppKit
import KeyboardShortcuts
import SpotCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Launch arguments used by the UI tests.
    enum LaunchOption {
        static let showMiniWindow = "SpotChatShowMiniOnLaunch"
        static let resetState = "SpotChatResetState"
    }

    lazy var miniController = MiniWindowController(draftStorage: UserDefaultsDraftStorage())

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: LaunchOption.resetState) {
            UserDefaultsDraftStorage().saveDraft("")
            PlacementStore().reset()
        }

        KeyboardShortcuts.onKeyDown(for: .toggleMiniWindow) { [weak self] in
            self?.miniController.handle(.toggleShortcut)
        }

        if defaults.bool(forKey: LaunchOption.showMiniWindow) {
            miniController.handle(.openRequested)
        }
    }
}
