import Foundation

/// One tool call dsh made while answering: a shell command, a web search, a page fetch.
/// Kept with the reply so the conversation shows what ran.
public struct CommandRun: Identifiable, Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case running
        /// dsh asked to run it outside the folder and waits for the user.
        case waitingForApproval
        case succeeded
        /// It ran and exited with an error.
        case failed
        /// The sandbox stopped it from touching something outside the folder.
        case blocked
        /// The user said no to running it outside the folder.
        case denied
        /// The user stopped the reply while it ran.
        case stopped
    }

    public enum Tool: String, Codable, Sendable {
        case shell
        case webSearch
        case webFetch
        case other
    }

    /// dsh's tool call id.
    public let id: String
    public var tool: Tool
    /// dsh's one-line summary, such as "Compress the video".
    public var summary: String
    /// The shell command, search query or address.
    public var detail: String
    /// Why it has to run outside the folder, when it asked.
    public var justification: String?
    /// Whether it ran with the sandbox lifted.
    public var outsideFolder: Bool
    /// The end of what it printed.
    public var output: String
    public var exitCode: Int?
    public var state: State
    public var startedAt: Date
    public var duration: TimeInterval?
    /// What a web search found.
    public var sources: [WebSource]?
    /// The title of a page that was read, when it has one.
    public var pageTitle: String?

    public init(
        id: String, tool: Tool, summary: String, detail: String, justification: String? = nil,
        outsideFolder: Bool = false, output: String = "", exitCode: Int? = nil, state: State = .running,
        startedAt: Date = Date(), duration: TimeInterval? = nil
    ) {
        self.id = id
        self.tool = tool
        self.summary = summary
        self.detail = detail
        self.justification = justification
        self.outsideFolder = outsideFolder
        self.output = output
        self.exitCode = exitCode
        self.state = state
        self.startedAt = startedAt
        self.duration = duration
    }

    public var isFinished: Bool {
        state != .running && state != .waitingForApproval
    }
}

/// Reads what dsh's bash tool reports back: the output, then notes in brackets such as
/// `[exit code: 1]` and `[sandbox: file access denied …]`.
public enum CommandOutput {
    /// Characters of output kept with a run.
    public static let keptLength = 4000

    public struct Result: Equatable, Sendable {
        public var text: String
        public var exitCode: Int?
        public var blockedBySandbox: Bool
    }

    public static func read(_ raw: String) -> Result {
        var exitCode: Int?
        var blocked = false
        var lines: [Substring] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[exit code:"), trimmed.hasSuffix("]") {
                exitCode = Int(trimmed.dropFirst("[exit code:".count).dropLast().trimmingCharacters(in: .whitespaces))
                continue
            }
            if trimmed.hasPrefix("[sandbox:") {
                if trimmed.contains("denied") { blocked = true }
                // Notes meant for the model, such as how to ask for wider access.
                continue
            }
            if trimmed == "[stderr]" || trimmed == "[stdout]" || trimmed == "(no output)" { continue }
            lines.append(line)
        }
        var text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > keptLength {
            text = "…" + text.suffix(keptLength)
        }
        return Result(text: text, exitCode: exitCode, blockedBySandbox: blocked)
    }
}

/// How a conversation runs commands: in which folder, and which dsh session holds its context.
public struct CommandSetup: Equatable, Sendable {
    public var folder: URL
    public var sessionID: String?

    public init(folder: URL, sessionID: String? = nil) {
        self.folder = folder
        self.sessionID = sessionID
    }
}

/// One result of a web search.
public struct WebSource: Codable, Equatable, Sendable, Hashable {
    public var title: String
    public var url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }

    /// The site, such as "github.com".
    public var host: String {
        guard let host = URL(string: url)?.host() else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Reads what dsh's web tools report: `- [title](url)` lines for a search, a page's Markdown for a read.
public enum WebResult {
    public static func sources(in text: String) -> [WebSource] {
        text.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("- ["), let close = line.range(of: "]("),
                  let end = line[close.upperBound...].firstIndex(of: ")")
            else { return nil }
            let title = String(line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound])
            let url = String(line[close.upperBound..<end])
            return WebSource(title: title.isEmpty ? url : title, url: url)
        }
    }

    /// The page's first heading.
    public static func pageTitle(in text: String) -> String? {
        for line in text.split(separator: "\n") where line.hasPrefix("# ") {
            let title = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        return nil
    }
}
