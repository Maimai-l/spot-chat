import AppKit
import Logging
import SpotAgent
import SpotCore

/// Commands belong to a conversation, not to the window showing it. Each conversation that runs commands
/// has one dsh, and its turn goes on when the window shows another conversation or closes; a window showing
/// the conversation follows the turn. Before, each window had a dsh of its own: a new conversation stopped
/// the turn, and the other window could not resume a session the first dsh still held.
@MainActor
final class CommandRuns {
    enum Event {
        case progress(ReplyProgress)
        case approval(CommandRun?)
        case finished(CommandReplyRunner.Result)
    }

    /// One conversation's dsh, and the turn it is on.
    private final class Conversation {
        let agent: CommandAgent
        let folder: URL
        var replyID: UUID?
        var progress = ReplyProgress()
        var task: Task<Void, Never>?
        var pendingApproval: CommandRun?
        var approvalAnswer: CheckedContinuation<CommandApproval, Never>?
        var followers: [ObjectIdentifier: (Event) -> Void] = [:]
        var lastSave = Date.distantPast
        var lastUsed = Date()

        init(agent: CommandAgent, folder: URL) {
            self.agent = agent
            self.folder = folder
        }

        var isRunning: Bool { task != nil }
    }

    /// How many dsh processes stay open for conversations with no turn under way.
    private static let idleKept = 2

    private unowned let app: AppModel
    private var conversations: [UUID: Conversation] = [:]

    init(app: AppModel) {
        self.app = app
    }

    func isRunning(_ topicID: UUID) -> Bool {
        conversations[topicID]?.isRunning == true
    }

    /// Whether a turn is writing this reply now, so the window doesn't take it for one a quit left behind.
    func isWriting(_ replyID: UUID) -> Bool {
        conversations.values.contains { $0.isRunning && $0.replyID == replyID }
    }

    /// The reply the conversation's turn is writing, while it runs.
    func runningReply(of topicID: UUID) -> UUID? {
        guard let conversation = conversations[topicID], conversation.isRunning else { return nil }
        return conversation.replyID
    }

    /// Starts a turn on the conversation's dsh, starting dsh when the conversation has none open.
    func start(
        topicID: UUID, folder: URL, connection: CommandConnection, options: CommandAgentOptions,
        question: ChatMessage, replyID: UUID, earlierSession: String?
    ) {
        // A new folder, or commands moved between Spot Chat and DeepSeek Harness, needs another dsh.
        if let existing = conversations[topicID], existing.folder != folder || existing.agent.connection != connection {
            end(topicID)
        }
        let conversation = conversations[topicID] ?? {
            let made = Conversation(agent: CommandAgent(connection: connection, options: options, folder: folder) { [weak self] run in
                await self?.askApproval(for: run, in: topicID) ?? .cancel
            }, folder: folder)
            conversations[topicID] = made
            return made
        }()
        guard !conversation.isRunning else { return }
        conversation.replyID = replyID
        conversation.progress = ReplyProgress()
        conversation.lastUsed = Date()
        app.setActivity(.working, for: topicID)
        app.setStoppedByQuitting(true, for: topicID)

        let app = app
        let agent = conversation.agent
        conversation.task = Task { [weak self] in
            let result = await CommandReplyRunner.run(
                agent: agent,
                options: options,
                question: question.text,
                paths: question.paths.map { URL(fileURLWithPath: $0) },
                earlierSession: earlierSession,
                onSession: { sessionID in
                    await MainActor.run { logged { try app.topicService.setAgentSession(sessionID, for: topicID) } }
                },
                describe: ErrorText.describe,
                onProgress: { progress in
                    await self?.report(progress, in: topicID)
                }
            )
            self?.finish(topicID, with: result)
        }
        trimIdle()
    }

    /// Stops the conversation's turn; it ends as stopped, as a turn the user stops does.
    func stop(_ topicID: UUID) {
        guard let conversation = conversations[topicID], conversation.isRunning else { return }
        SpotLog.agent.info("Stopping the command turn", metadata: ["topic": "\(topicID)"])
        conversation.task?.cancel()
        answer(.cancel, in: topicID)
    }

    /// Stops the turn and closes the conversation's dsh, when its folder changes or it is deleted.
    func end(_ topicID: UUID) {
        guard let conversation = conversations.removeValue(forKey: topicID) else { return }
        conversation.task?.cancel()
        conversation.approvalAnswer?.resume(returning: .cancel)
        conversation.approvalAnswer = nil
        let agent = conversation.agent
        Task { await agent.shutDown() }
        app.setActivity(nil, for: topicID)
        app.setStoppedByQuitting(false, for: topicID)
    }

    /// Tells `follower` of everything the turn does from now on, and of where it stands now.
    func follow(_ topicID: UUID, by follower: AnyObject, _ handler: @escaping (Event) -> Void) {
        guard let conversation = conversations[topicID] else { return }
        conversation.followers[ObjectIdentifier(follower)] = handler
        if conversation.isRunning {
            handler(.progress(conversation.progress))
            handler(.approval(conversation.pendingApproval))
        }
    }

    func unfollow(_ topicID: UUID, by follower: AnyObject) {
        conversations[topicID]?.followers[ObjectIdentifier(follower)] = nil
        trimIdle()
    }

    /// The user's answer on the approval card.
    func answer(_ answer: CommandApproval, in topicID: UUID) {
        guard let conversation = conversations[topicID], let continuation = conversation.approvalAnswer else { return }
        conversation.approvalAnswer = nil
        conversation.pendingApproval = nil
        tell(conversation, .approval(nil))
        if conversation.isRunning { app.setActivity(.working, for: topicID) }
        continuation.resume(returning: answer)
    }

    // MARK: The turn

    /// Waits for the user to allow or deny a command outside the folder, in whichever window shows the
    /// conversation; the history marks the conversation as waiting until then.
    private func askApproval(for run: CommandRun, in topicID: UUID) async -> CommandApproval {
        answer(.cancel, in: topicID)
        guard let conversation = conversations[topicID] else { return .cancel }
        return await withCheckedContinuation { continuation in
            conversation.approvalAnswer = continuation
            conversation.pendingApproval = run
            app.setActivity(.needsInput, for: topicID)
            tell(conversation, .approval(run))
        }
    }

    /// Passes the reply on to the window following it, and saves it at most once a second, so a reply no
    /// window shows is there when the conversation is opened.
    private func report(_ progress: ReplyProgress, in topicID: UUID) {
        guard let conversation = conversations[topicID], let replyID = conversation.replyID else { return }
        conversation.progress = progress
        tell(conversation, .progress(progress))
        guard Date().timeIntervalSince(conversation.lastSave) > 1 else { return }
        conversation.lastSave = Date()
        save(replyID) { reply in
            reply.text = progress.text
            reply.reasoning = progress.reasoning
            reply.commands = progress.steps
        }
    }

    private func finish(_ topicID: UUID, with result: CommandReplyRunner.Result) {
        guard let conversation = conversations[topicID], let replyID = conversation.replyID else { return }
        conversation.task = nil
        conversation.pendingApproval = nil
        conversation.lastUsed = Date()
        save(replyID) { reply in
            reply.text = result.progress.text
            reply.reasoning = result.progress.reasoning
            reply.commands = result.progress.steps
            if let failure = result.failure {
                reply.status = .error
                reply.errorMessage = failure
            } else {
                reply.status = result.stopped ? .paused : .success
            }
        }
        app.setActivity(nil, for: topicID)
        app.setStoppedByQuitting(false, for: topicID)
        let outcome = result.failure != nil ? "failed" : result.stopped ? "stopped" : "finished"
        SpotLog.reply.info("Command turn \(outcome)", metadata: [
            "topic": "\(topicID)", "reply": "\(replyID)", "followed": "\(!conversation.followers.isEmpty)",
        ])
        tell(conversation, .finished(result))
        app.historyDidChange()
        trimIdle()
    }

    private func save(_ replyID: UUID, _ change: (inout ChatMessage) -> Void) {
        guard var reply = logged({ try app.messageService.get(replyID) }) ?? nil else { return }
        change(&reply)
        logged { try app.messageService.update(reply) }
    }

    private func tell(_ conversation: Conversation, _ event: Event) {
        for handler in conversation.followers.values { handler(event) }
    }

    /// Closes the dsh of conversations with no turn under way and no window showing them, beyond the most
    /// recently used few, so many conversations don't mean many processes.
    private func trimIdle() {
        let idle = conversations
            .filter { !$0.value.isRunning && $0.value.followers.isEmpty }
            .sorted { $0.value.lastUsed > $1.value.lastUsed }
        for (topicID, _) in idle.dropFirst(Self.idleKept) {
            SpotLog.agent.info("Closing an idle conversation's dsh", metadata: ["topic": "\(topicID)"])
            end(topicID)
        }
    }
}
