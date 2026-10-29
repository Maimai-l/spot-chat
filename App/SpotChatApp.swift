import SwiftUI

@main
struct SpotChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Spot Chat", systemImage: "smallcircle.filled.circle") {
            Button("Open Mini Window") {
                appDelegate.miniController.handle(.openRequested)
            }
            Divider()
            Button("Quit Spot Chat") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
