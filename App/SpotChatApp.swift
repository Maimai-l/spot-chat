import SwiftUI

@main
struct SpotChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            Button("Open Mini Window") {
                appDelegate.miniController.handle(.openRequested)
            }
            Button("Open Full Window") {
                appDelegate.openFullWindow()
            }
            Button("Settings…") {
                appDelegate.showSettings()
            }
            .keyboardShortcut(",")
            if Updates.shared.isOn {
                Button("Check for Updates…") {
                    Updates.shared.checkNow()
                }
            }
            Divider()
            Button("Quit Spot Chat") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            MenuBarLabel(state: appDelegate.menuBar)
        }
    }
}
