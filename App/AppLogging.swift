import AppKit
import CocoaLumberjackSwift
import CocoaLumberjackSwiftLogBackend
import Logging
import SpotCore

/// Sends SpotLog's lines to rolling files in ~/Library/Logs/Spot Chat, where Console also finds them, and
/// to the system log. Nothing is sent anywhere else; Settings exports the files for a bug report.
enum AppLogging {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Spot Chat", isDirectory: true)

    nonisolated(unsafe) private static var fileLogger: DDFileLogger?

    static func start() {
        guard fileLogger == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = DDLogFileManagerDefault(logsDirectory: directory.path)
        manager.maximumNumberOfLogFiles = 10
        manager.logFilesDiskQuota = 100 * 1024 * 1024
        let file = DDFileLogger(logFileManager: manager)
        // A new file every 10 MB, kept by size rather than age.
        file.maximumFileSize = 10 * 1024 * 1024
        file.rollingFrequency = 0
        file.logFormatter = LineFormatter(includesDate: true)
        DDLog.add(file, with: .all)

        let system = DDOSLogger(subsystem: Bundle.main.bundleIdentifier ?? "SpotChat", category: "app")
        system.logFormatter = LineFormatter(includesDate: false)
        DDLog.add(system, with: .info)

        // Everything down to each line a service streams back, so a strange reply can be traced.
        LoggingSystem.bootstrapWithCocoaLumberjack(defaultLogLevel: .trace)
        fileLogger = file

        NSSetUncaughtExceptionHandler { exception in
            SpotLog.app.critical("Uncaught exception", metadata: [
                "name": "\(exception.name.rawValue)", "reason": "\(exception.reason ?? "")",
                "stack": "\(exception.callStackSymbols.joined(separator: "\n"))",
            ])
            DDLog.flushLog()
        }

        let info = Bundle.main.infoDictionary ?? [:]
        SpotLog.app.info("Launched", metadata: [
            "version": "\(info["CFBundleShortVersionString"] as? String ?? "")",
            "build": "\(info["CFBundleVersion"] as? String ?? "")",
            "macOS": "\(ProcessInfo.processInfo.operatingSystemVersionString)",
            "language": "\(Locale.preferredLanguages.first ?? "")",
        ])
    }

    /// Writes every log file, oldest first, into one file at `url`.
    static func export(to url: URL) throws {
        DDLog.flushLog()
        let paths = (fileLogger?.logFileManager.sortedLogFilePaths ?? []).reversed()
        let info = Bundle.main.infoDictionary ?? [:]
        var data = Data("""
        Spot Chat \(info["CFBundleShortVersionString"] as? String ?? "") (\(info["CFBundleVersion"] as? String ?? ""))
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Exported \(Date().formatted(.iso8601))


        """.utf8)
        for path in paths {
            if let contents = FileManager.default.contents(atPath: path) { data.append(contents) }
        }
        try data.write(to: url, options: .atomic)
        SpotLog.app.info("Exported the log", metadata: ["files": "\(paths.count)", "bytes": "\(data.count)"])
    }

    static func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }
}

/// One line per entry: time, level, category, the entry's fields, then its message.
private final class LineFormatter: NSObject, DDLogFormatter {
    let includesDate: Bool

    init(includesDate: Bool) {
        self.includesDate = includesDate
    }

    func format(message: DDLogMessage) -> String? {
        let time = includesDate
            ? message.timestamp.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)) + " "
            : ""
        guard let info = message.swiftLogInfo else {
            return "\(time)\(message.message)"
        }
        let category = info.logger.label.replacingOccurrences(of: "spotchat.", with: "")
        var fields = info.logger.metadataSources.logger
        for (key, value) in info.message.metadata ?? [:] { fields[key] = value }
        let details = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\(Self.quoted("\($0.value)"))" }
        let level = info.message.level.rawValue.uppercased()
        return "\(time)\(level) [\(category)] \(info.message.message)" + (details.isEmpty ? "" : " " + details.joined(separator: " "))
    }

    /// A value with spaces or line breaks is quoted, so each entry stays on one line.
    private static func quoted(_ value: String) -> String {
        guard value.contains(where: { $0 == " " || $0 == "\n" || $0 == "\"" || $0 == "=" }) else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
