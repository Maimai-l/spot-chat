import SwiftUI

@main
struct SpotChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Spot Chat", systemImage: "smallcircle.filled.circle") {
            Button("打开小窗") {
                appDelegate.miniController.handle(.openRequested)
            }
            Button("打开完整窗口") {}
                .disabled(true)
            Button("设置…") {}
                .disabled(true)
            Divider()
            Button("退出 Spot Chat") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
