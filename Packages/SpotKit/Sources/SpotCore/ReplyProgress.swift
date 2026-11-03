import Foundation

/// A reply as it stands while it is written: what the app shows and saves after each piece that arrives.
public struct ReplyProgress: Equatable, Sendable {
    public var text = ""
    public var reasoning = ""
    /// How long the model thought before it started answering; nil until then.
    public var reasoningDuration: TimeInterval?
    /// The searches, page reads or commands the reply ran, each shown where it began in the text.
    public var steps: [CommandRun] = []

    public init(text: String = "", reasoning: String = "", reasoningDuration: TimeInterval? = nil, steps: [CommandRun] = []) {
        self.text = text
        self.reasoning = reasoning
        self.reasoningDuration = reasoningDuration
        self.steps = steps
    }

    /// Marks the steps still running as stopped, as a reply that ended leaves them.
    public mutating func stopUnfinishedSteps() {
        for index in steps.indices where !steps[index].isFinished {
            steps[index].state = .stopped
        }
    }
}
