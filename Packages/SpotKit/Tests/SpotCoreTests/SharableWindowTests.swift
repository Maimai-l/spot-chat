import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import SpotCore

@Suite struct SharableWindowTests {
    func window(_ id: UInt32, app: String = "Safari", bundle: String? = "com.apple.Safari", title: String = "Docs",
                size: CGSize = CGSize(width: 800, height: 600), layer: Int = 0, onScreen: Bool = true) -> SharableWindow {
        SharableWindow(id: id, appName: app, bundleID: bundle, processID: 1, title: title,
                       frame: CGRect(origin: .zero, size: size), layer: layer, isOnScreen: onScreen)
    }

    @Test func keepsOrdinaryWindowsInOrder() {
        let windows = [window(1), window(2, app: "Xcode", bundle: "com.apple.dt.Xcode", title: "AppDelegate.swift")]
        #expect(SharableWindowFilter.filter(windows, excludingBundleID: "com.maimai.spotchat").map(\.id) == [1, 2])
    }

    @Test func leavesOutOwnTinyHiddenAndOverlayWindows() {
        let windows = [
            window(1, app: "Spot Chat", bundle: "com.maimai.spotchat"),
            window(2, size: CGSize(width: 40, height: 40)),
            window(3, onScreen: false),
            window(4, app: "Dock", bundle: "com.apple.dock", layer: 20),
            window(5, app: ""),
            window(6),
        ]
        #expect(SharableWindowFilter.filter(windows, excludingBundleID: "com.maimai.spotchat").map(\.id) == [6])
    }

    @Test func labelNamesAppAndTitle() {
        #expect(window(1, title: "SQLite Docs").label == "Safari › SQLite Docs")
        #expect(window(1, app: "Finder", title: "").label == "Finder")
    }
}
