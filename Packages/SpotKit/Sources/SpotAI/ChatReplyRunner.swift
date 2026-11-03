import Foundation
import Logging
import SpotCore

/// Runs a tool the model called and returns what to give it back: DeepSeek's web search and page reading.
public protocol ToolRunning: Sendable {
    func run(_ call: ToolCall, question: String) async -> String
}

extension DeepSeekWebTools: ToolRunning {}

/// Writes one chat reply. It streams the model's answer, runs the tools the model calls and gives it their
/// results, and asks again without the effort level when the model turns one down. It knows nothing of
/// windows or storage: whoever runs it shows and saves what it reports, so the app runs it today and a
/// separate process could run it unchanged.
public struct ChatReplyRunner: Sendable {
    /// A question that keeps searching stops after this many rounds.
    public static let maxToolRounds = 10

    public enum Event: Sendable {
        /// The reply as it stands, after each piece that arrived.
        case progress(ReplyProgress)
        case usage(TokenUsage)
        /// The model turned the effort level down, so it was asked again without one.
        case effortRejected
    }

    public struct Result: Equatable, Sendable {
        public var progress: ReplyProgress
        /// What went wrong, as the app words it; nil when the reply finished or was stopped.
        public var failure: String?
        /// Whether the reply was stopped before it finished.
        public var stopped: Bool
    }

    let responder: ChatResponder
    let tools: ToolRunning?
    let describe: @Sendable (Error) -> String

    /// `tools` runs the calls the model makes, or nil when the request offers it none.
    /// `describe` words a failure for the reader.
    public init(responder: ChatResponder, tools: ToolRunning?, describe: @escaping @Sendable (Error) -> String) {
        self.responder = responder
        self.tools = tools
        self.describe = describe
    }

    /// Writes the reply to `firstRequest`, whose last question is `question`, reporting it as it goes.
    /// Cancelling the calling task stops it; the result then says so and keeps what arrived.
    public func run(
        _ firstRequest: ChatRequest, question: String, replyID: UUID, onEvent: @Sendable (Event) async -> Void
    ) async -> Result {
        var progress = ReplyProgress()
        var thinkingStarted: Date?
        var failure: String?
        var request = firstRequest

        rounds: for _ in 0..<Self.maxToolRounds {
            var roundText = ""
            var roundReasoning = ""
            var calls: [ToolCall] = []
            attempts: while true {
                do {
                    for try await chunk in responder.stream(request) {
                        if Task.isCancelled { break }
                        switch chunk {
                        case let .reasoning(part):
                            if thinkingStarted == nil { thinkingStarted = Date() }
                            progress.reasoning += part
                            roundReasoning += part
                        case let .text(part):
                            if let thinkingStarted, progress.reasoningDuration == nil {
                                progress.reasoningDuration = Date().timeIntervalSince(thinkingStarted)
                            }
                            // Text after a search starts a new paragraph.
                            if roundText.isEmpty, !progress.text.isEmpty, !progress.text.hasSuffix("\n") { progress.text += "\n\n" }
                            progress.text += part
                            roundText += part
                        case let .usage(usage):
                            await onEvent(.usage(usage))
                            continue
                        case let .toolCalls(made):
                            calls = made
                            continue
                        }
                        await onEvent(.progress(progress))
                    }
                    break attempts
                } catch let error as ChatServiceError
                    where error.rejectsThinking && request.thinking != .automatic
                    && progress.text.isEmpty && progress.reasoning.isEmpty {
                    // A model without reasoning turned the effort down: ask again without it, and from now on.
                    SpotLog.reply.notice("The model turned the effort down; asking again without it", metadata: ["reply": "\(replyID)"])
                    request.thinking = .automatic
                    await onEvent(.effortRejected)
                    continue attempts
                } catch is CancellationError {
                    break attempts
                } catch {
                    failure = describe(error)
                    break attempts
                }
            }
            guard let tools, !calls.isEmpty, failure == nil, !Task.isCancelled else { break rounds }

            // The model searched or read a page: run each call and give it the results.
            SpotLog.reply.info("Tool round", metadata: [
                "reply": "\(replyID)", "calls": "\(calls.map(\.name).joined(separator: ","))",
            ])
            request.messages.append(ChatRequestMessage(
                role: .assistant, parts: roundText.isEmpty ? [] : [.text(roundText)],
                toolCalls: calls, reasoning: roundReasoning.isEmpty ? nil : roundReasoning
            ))
            for call in calls {
                var step = WebStep.started(call)
                // Shown where it began in the reply, not after all of it.
                step.textOffset = progress.text.count
                progress.steps.append(step)
                await onEvent(.progress(progress))
                let output = await tools.run(call, question: question)
                if Task.isCancelled { break rounds }
                WebStep.finish(&step, output: output)
                progress.steps[progress.steps.count - 1] = step
                await onEvent(.progress(progress))
                request.messages.append(.toolResult(output, for: call.id))
            }
        }
        if let thinkingStarted, progress.reasoningDuration == nil {
            progress.reasoningDuration = Date().timeIntervalSince(thinkingStarted)
        }
        progress.stopUnfinishedSteps()
        return Result(progress: progress, failure: failure, stopped: Task.isCancelled)
    }
}
