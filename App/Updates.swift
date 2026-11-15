import Combine
import Foundation
import Logging
import Sparkle
import SpotCore

/// Alpha builds update themselves with Sparkle, from the feed CI publishes to GitHub Pages: a new build
/// comes as a delta from the one installed when CI made one, so the dsh runtime isn't downloaded again
/// when it didn't change. Updates are signed with an EdDSA key, which is what Sparkle trusts here, since
/// each build is signed ad hoc. A build without a build number or a key, as in tests, doesn't check.
@MainActor
final class Updates: NSObject, ObservableObject {
    static let shared = Updates()

    @Published private(set) var canCheck = false
    private var controller: SPUStandardUpdaterController?

    /// Whether this build updates itself.
    var isOn: Bool { controller != nil }

    private override init() {
        super.init()
        let info = Bundle.main.infoDictionary ?? [:]
        let build = info["CFBundleVersion"] as? String ?? "0"
        let key = info["SUPublicEDKey"] as? String ?? ""
        guard build != "0", !key.isEmpty else {
            SpotLog.app.info("Updates are off in this build", metadata: ["build": "\(build)", "hasKey": "\(!key.isEmpty)"])
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        SpotLog.app.info("Updates are on", metadata: [
            "feed": "\(info["SUFeedURL"] as? String ?? "")", "channel": "\(Self.channel)",
            "automatic": "\(controller.updater.automaticallyChecksForUpdates)",
        ])
    }

    func checkNow() {
        SpotLog.app.info("Checking for updates")
        controller?.checkForUpdates(nil)
    }

    /// The channel this build takes updates from, as the build names it.
    nonisolated static var channel: String {
        Bundle.main.object(forInfoDictionaryKey: "SpotChatReleaseChannel") as? String ?? "alpha"
    }
}

/// Sparkle's dialogs name versions as Settings does, "0.1.0 alpha 189": the short version alone is the same
/// for every alpha, so "Spot Chat 0.1.0 is the newest version" said nothing.
extension Updates: SPUStandardUserDriverDelegate {
    nonisolated func standardUserDriverRequestsVersionDisplayer() -> (any SUVersionDisplay)? {
        VersionNames()
    }
}

/// Sparkle calls these by their Objective-C selectors, named here, since Swift shortens their names.
private final class VersionNames: NSObject, SUVersionDisplay {
    @objc(formatUpdateDisplayVersionFromUpdate:andBundleDisplayVersion:withBundleVersion:)
    func formatUpdateVersion(
        fromUpdate update: SUAppcastItem, andBundleDisplayVersion inOutBundleDisplayVersion: AutoreleasingUnsafeMutablePointer<NSString>,
        withBundleVersion bundleVersion: String
    ) -> String {
        inOutBundleDisplayVersion.pointee = AppVersion.display(version: inOutBundleDisplayVersion.pointee as String, build: bundleVersion) as NSString
        return AppVersion.display(version: update.displayVersionString, build: update.versionString)
    }

    @objc(formatBundleDisplayVersion:withBundleVersion:matchingUpdate:)
    func formatBundleDisplayVersion(_ bundleDisplayVersion: String, withBundleVersion bundleVersion: String, matchingUpdate: SUAppcastItem?) -> String {
        AppVersion.display(version: bundleDisplayVersion, build: bundleVersion)
    }
}

extension Updates: SPUUpdaterDelegate {
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        [Self.channel]
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        SpotLog.app.info("Found an update", metadata: [
            "version": "\(item.displayVersionString) (\(item.versionString))", "bytes": "\(item.contentLength)",
            "deltas": "\(item.deltaUpdates?.keys.sorted().joined(separator: ",") ?? "")",
        ])
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        SpotLog.app.info("No update")
    }

    nonisolated func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        SpotLog.app.info("Downloaded the update", metadata: ["version": "\(item.versionString)"])
    }

    nonisolated func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        SpotLog.app.error("Couldn't download the update", metadata: ["version": "\(item.versionString)", "error": "\(error)"])
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        SpotLog.app.info("Installing the update", metadata: ["version": "\(item.versionString)"])
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        SpotLog.app.error("Updating stopped", metadata: ["error": "\(error)"])
    }
}
