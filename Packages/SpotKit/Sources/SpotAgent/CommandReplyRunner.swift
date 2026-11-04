import Foundation
import SpotCore

extension ReplyProgress {
    /// Adds what dsh reported: text, thinking, or a command that started or changed. A command keeps the
    /// place in the text where it began, so it shows there rather than after all of the reply.
    public mutating func apply(_ event: CommandEvent) {
        switch event {
        case let .text(part):
            text += part
        case let .thought(part):
            reasoning += part
        case let .run(run):
            var run = run
            if let index = steps.firstIndex(where: { $0.id == run.id }) {
                run.textOffset = steps[index].textOffset
                steps[index] = run
            } else {
                run.textOffset = text.count
                steps.append(run)
            }
        }
    }
}

/// Writes one reply that runs commands: dsh takes the question, runs commands in the folder, and answers.
/// Like `ChatReplyRunner` it knows nothing of windows or storage; whoever runs it shows and saves the
/// reply it reports.
public enum CommandReplyRunner {
    public struct Result: Equatable, Sendable {
        public var progress: ReplyProgress
        /// What went wrong, as the app words it; nil when the turn finished or was stopped.
        public var failure: String?
        /// Whether the turn was stopped before dsh finished it.
        public var stopped: Bool
    }

    /// Runs the turn on `agent` with `options`, resuming dsh's session `earlierSession` when there is one.
    /// `onSession` hears the session the turn ran in, to resume next time. Cancelling the calling task asks
    /// dsh to stop, and the result still shows how the turn ended.
    ///
    /// A session dsh can no longer send (`isBrokenSession`) is left behind: when the turn failed before it
    /// did anything, it runs once more in a new session.
    public static func run(
        agent: CommandAgent,
        options: CommandAgentOptions,
        question: String,
        paths: [URL],
        earlierSession: String?,
        onSession: @escaping @Sendable (String) async -> Void,
        describe: @escaping @Sendable (Error) -> String,
        onProgress: @escaping @Sendable (ReplyProgress) async -> Void
    ) async -> Result {
        var result = await attempt(
            agent: agent, options: options, question: question, paths: paths, resuming: earlierSession,
            onSession: onSession, onProgress: onProgress
        )
        if let error = result.error, isBrokenSession(error) {
            let untouched = result.progress.text.isEmpty && result.progress.steps.isEmpty
            SpotLog.agent.warning("dsh's session can't be sent any more; starting a new one", metadata: [
                "error": "\(SpotLog.clip("\(error)"))", "retrying": "\(untouched && !Task.isCancelled)",
            ])
            await agent.shutDown()
            if untouched && !Task.isCancelled {
                result = await attempt(
                    agent: agent, options: options, question: question, paths: paths, resuming: nil,
                    onSession: onSession, onProgress: onProgress
                )
            }
        }
        var progress = result.progress
        progress.stopUnfinishedSteps()
        var failure = result.error.map(describe)
        let stopped = !result.finished || Task.isCancelled
        // A turn that ends with nothing to show, such as one where the model only thought, is offered again.
        if failure == nil, !stopped, progress.steps.isEmpty,
           progress.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            SpotLog.agent.warning("dsh finished the turn without a reply", metadata: [
                "reasoningCharacters": "\(progress.reasoning.count)",
            ])
            failure = String(localized: "The reply was empty.")
        }
        return Result(progress: progress, failure: failure, stopped: stopped && failure == nil)
    }

    /// Whether dsh failed because the session's history can't be sent again. DeepSeek's thinking mode
    /// rejects a history whose tool call has no thinking with it, and dsh then fails every later turn of
    /// the session (deepseek-harness discussions 7050 and 11029).
    public static func isBrokenSession(_ error: Error) -> Bool {
        let text = "\(error) \(error.localizedDescription)".lowercased()
        return text.contains("must be passed back") || text.contains("reasoning_content")
    }

    private struct Attempt {
        var progress: ReplyProgress
        var error: Error?
        var finished: Bool
    }

    private static func attempt(
        agent: CommandAgent,
        options: CommandAgentOptions,
        question: String,
        paths: [URL],
        resuming earlierSession: String?,
        onSession: @escaping @Sendable (String) async -> Void,
        onProgress: @escaping @Sendable (ReplyProgress) async -> Void
    ) async -> Attempt {
        let (events, sink) = AsyncStream<CommandEvent>.makeStream()
        // The turn and its updates run on their own: stopping asks dsh to stop and still shows how it ended.
        let turn = Task {
            defer { sink.finish() }
            await agent.update(model: options.model, effort: options.effort, searchesTheWeb: options.searchesTheWeb)
            let sessionID = try await agent.start(resuming: earlierSession)
            if sessionID != earlierSession { await onSession(sessionID) }
            return try await agent.send(question, paths: paths) { event in
                sink.yield(event)
            }
        }
        let updates = Task {
            var progress = ReplyProgress()
            for await event in events {
                progress.apply(event)
                await onProgress(progress)
            }
            return progress
        }
        let progress = await withTaskCancellationHandler {
            await updates.value
        } onCancel: {
            Task { await agent.cancel() }
        }
        do {
            return Attempt(progress: progress, error: nil, finished: try await turn.value)
        } catch {
            return Attempt(progress: progress, error: error, finished: false)
        }
    }
}
