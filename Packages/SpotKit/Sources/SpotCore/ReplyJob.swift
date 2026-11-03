import Foundation

/// One reply for the reply writer, SpotChatWriter, to write: the app hands it over as JSON on the writer's
/// input, and the writer saves the reply into the database as it arrives, whether or not the app is still
/// running. The provider's address and key are read from the database, so they never pass through here.
public struct ReplyJob: Codable, Equatable, Sendable {
    /// The reply's row, already saved as pending.
    public var replyID: UUID
    public var topicID: UUID
    public var providerID: String
    public var request: ChatRequest
    /// The question being answered, which web search uses.
    public var question: String
    /// Where DeepSeek's web search and page reading are served, when the reply may use them.
    public var webToolsURL: String?
    /// The app's data folder, holding its database and the writers' marks.
    public var dataDirectory: String

    public init(
        replyID: UUID, topicID: UUID, providerID: String, request: ChatRequest, question: String,
        webToolsURL: String?, dataDirectory: String
    ) {
        self.replyID = replyID
        self.topicID = topicID
        self.providerID = providerID
        self.request = request
        self.question = question
        self.webToolsURL = webToolsURL
        self.dataDirectory = dataDirectory
    }

    /// The folder where each writer at work leaves a file named after its reply, holding its process id.
    public static func writersDirectory(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("Writers", isDirectory: true)
    }
}

/// A line the writer prints, one JSON object each, for the app while it is running.
public enum ReplyWriterLine: Codable, Equatable, Sendable {
    case progress(ReplyProgress)
    case usage(TokenUsage)
    case effortRejected
    /// The reply is saved in its final state.
    case finished(failure: String?, stopped: Bool)
}
