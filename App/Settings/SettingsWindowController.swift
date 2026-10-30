import AppKit
import SwiftUI

/// The settings window, with the standard toolbar tabs.
@MainActor
final class SettingsWindowController {
    static let contentSize = NSSize(width: 700, height: 480)

    private let app: AppModel
    private var window: NSWindow?

    init(app: AppModel) {
        self.app = app
    }

    func show() {
        if window == nil {
            window = makeWindow()
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(item(
            ProvidersSettingsView(app: app),
            label: String(localized: "Providers"),
            symbol: "server.rack"
        ))
        tabs.addTabViewItem(item(
            GeneralSettingsView(app: app),
            label: String(localized: "General"),
            symbol: "slider.horizontal.3"
        ))

        let window = EditingWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.setContentSize(Self.contentSize)
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier("settingsWindow")
        window.center()
        return window
    }

    private func item(_ view: some View, label: String, symbol: String) -> NSTabViewItem {
        let controller = NSHostingController(rootView: view.frame(width: Self.contentSize.width, height: Self.contentSize.height))
        // The window takes its title from the tab shown.
        controller.title = label
        let item = NSTabViewItem(viewController: controller)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }
}
