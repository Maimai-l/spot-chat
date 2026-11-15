import Testing
@testable import SpotCore

struct AppVersionTests {
    @Test func aPackagedBuildIsNamedByItsAlpha() {
        #expect(AppVersion.display(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "161"]) == "0.1.0 alpha 161")
        // An update's, as Sparkle's dialogs show it.
        #expect(AppVersion.display(version: "0.1.0", build: "190") == "0.1.0 alpha 190")
    }

    @Test func aLocalBuildShowsOnlyTheVersion() {
        #expect(AppVersion.display(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "0"]) == "0.1.0")
        #expect(AppVersion.display(info: ["CFBundleShortVersionString": "0.1.0"]) == "0.1.0")
    }
}
