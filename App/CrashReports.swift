import Foundation
import SpotCore

/// The crash reports macOS keeps for Spot Chat's own processes: the app, the reply writer and the Node that
/// runs dsh, all inside the app's bundle. They go into the exported log, so a crash comes with its evidence.
enum CrashReports {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    /// Older reports are left out; a bug report is about what happened lately.
    static let maxAge: TimeInterval = 30 * 24 * 3600
    /// The newest reports kept in an export, so a crash loop doesn't fill it.
    static let maxCount = 10
    private static let lastSeenKey = "SpotChat.lastSeenCrashReport"

    /// Reports from the last 30 days whose process ran from this app, newest first.
    static func recent(now: Date = Date()) -> [(url: URL, date: Date)] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
            )
        } catch {
            // No folder yet is the usual case on a Mac that never crashed.
            if (error as NSError).code != NSFileReadNoSuchFileError {
                SpotLog.app.notice("Couldn't read the crash reports folder", metadata: ["error": "\(error)"])
            }
            return []
        }
        let bundlePath = Bundle.main.bundleURL.path
        return files
            .filter { $0.pathExtension == "ips" || $0.pathExtension == "crash" }
            .compactMap { url -> (url: URL, date: Date)? in
                guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      now.timeIntervalSince(date) < maxAge,
                      let text = try? String(contentsOf: url, encoding: .utf8),
                      text.contains(bundlePath) || text.contains("com.maimai.spotchat")
                else { return nil }
                return (url, date)
            }
            .sorted { $0.date > $1.date }
    }

    /// The reports as a section of the exported log.
    static func exportSection() -> Data {
        let reports = recent().prefix(maxCount)
        guard !reports.isEmpty else { return Data("\n\nCrash reports: none\n".utf8) }
        var data = Data("\n\nCrash reports: \(reports.count)\n".utf8)
        for report in reports {
            data.append(Data("\n===== \(report.url.lastPathComponent) (\(report.date.formatted(.iso8601)))\n".utf8))
            if let contents = FileManager.default.contents(atPath: report.url.path) { data.append(contents) }
        }
        return data
    }

    /// Notes in the log the crashes since the last launch, so they show among the lines around them.
    static func logNewSinceLastLaunch() {
        let defaults = UserDefaults.standard
        let lastSeen = defaults.object(forKey: lastSeenKey) as? Date ?? .distantPast
        let new = recent().filter { $0.date > lastSeen }
        if let newest = new.first {
            SpotLog.app.warning("Spot Chat crashed since the last launch", metadata: [
                "reports": "\(new.map(\.url.lastPathComponent).joined(separator: ","))",
            ])
            defaults.set(newest.date, forKey: lastSeenKey)
        }
    }
}
