import Testing
@testable import SpotCore

struct AppVersionTests {
    @Test func aPackagedBuildIsNamedByItsAlpha() {
        #expect(AppVersion.display(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "161"]) == "0.1.0 alpha 161")
    }

    @Test func aLocalBuildShowsOnlyTheVersion() {
        #expect(AppVersion.display(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "0"]) == "0.1.0")
        #expect(AppVersion.display(info: ["CFBundleShortVersionString": "0.1.0"]) == "0.1.0")
    }
}
