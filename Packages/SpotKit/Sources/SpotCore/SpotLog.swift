import Foundation
import Logging

/// Where Spot Chat writes down what it does, so a strange bug can be traced after the fact.
///
/// Everything is recorded in full, requests and replies included, because the log never leaves the Mac:
/// it goes to the system log and to a file the user can export from Settings. API keys are never
/// recorded; they travel only in request headers, which are not logged.
public enum SpotLog {
    public enum Category: String, Sendable {
        case app
        /// Requests to chat services and their replies, line by line.
        case network
        /// Replies as the app assembles, saves and shows them.
        case reply
        /// Web search and page fetches.
        case web
        /// dsh and the Agent Client Protocol.
        case agent
        case data
        case window
    }

    public static func logger(_ category: Category) -> Logger {
        Logger(label: "spotchat.\(category.rawValue)")
    }

    public static var app: Logger { logger(.app) }
    public static var network: Logger { logger(.network) }
    public static var reply: Logger { logger(.reply) }
    public static var web: Logger { logger(.web) }
    public static var agent: Logger { logger(.agent) }
    public static var data: Logger { logger(.data) }
    public static var window: Logger { logger(.window) }

    /// Text short enough for one log line: very long text keeps its start and end.
    public static func clip(_ text: String, limit: Int = 20_000) -> String {
        guard text.count > limit else { return text }
        let half = limit / 2
        return "\(text.prefix(half)) …[\(text.count - limit) characters left out]… \(text.suffix(half))"
    }

    /// A request body for the log: images and files sent inline are replaced by their size.
    public static func body(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        let inline = /data:[A-Za-z0-9.+\/-]+;base64,[A-Za-z0-9+\/=]+/
        let shortened = text.replacing(inline) { match in "<inline data, \(match.output.count) characters>" }
        return clip(shortened)
    }

    /// A short identifier that ties together the lines of one request or reply.
    public static func newID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }
}

extension Logger {
    /// This logger with a new identifier under `key`, carried by every line it writes.
    public func with(id key: String) -> Logger {
        var logger = self
        logger[metadataKey: key] = "\(SpotLog.newID())"
        return logger
    }

    /// This logger with `value` under `key` on every line it writes.
    public func with(_ key: String, _ value: String) -> Logger {
        var logger = self
        logger[metadataKey: key] = "\(value)"
        return logger
    }
}
