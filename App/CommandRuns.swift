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
    /// Replies to questions asked in DeepSeek Harness whose turn goes on there; Spot Chat shows them as
    /// they catch up.
    private var repliesElsewhere: Set<UUID> = []
    /// Catching up a conversation from DeepSeek Harness, waiting or under way.
    private var catchUps: [UUID: Task<Void, Never>] = [:]

    init(app: AppModel) {
        self.app = app
    }

    func isRunning(_ topicID: UUID) -> Bool {
        conversations[topicID]?.isRunning == true
    }

    /// Whether a turn is writing this reply now, here or in DeepSeek Harness, so the window doesn't take it
    /// for one a quit left behind.
    func isWriting(_ replyID: UUID) -> Bool {
        repliesElsewhere.contains(replyID) || conversations.values.contains { $0.isRunning && $0.replyID == replyID }
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
        let conversation = self.conversation(topicID, folder: folder, connection: connection, options: options)
        guard !conversation.isRunning else { return }
        catchUps[topicID]?.cancel()
        catchUps[topicID] = nil
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

    /// The conversation's dsh, opened when it has none, or when its folder or where it runs changed.
    private func conversation(
        _ topicID: UUID, folder: URL, connection: CommandConnection, options: CommandAgentOptions
    ) -> Conversation {
        if let existing = conversations[topicID], existing.folder != folder || existing.agent.connection != connection {
            end(topicID)
        }
        if let existing = conversations[topicID] { return existing }
        let agent = CommandAgent(connection: connection, options: options, folder: folder) { [weak self] run in
            await self?.askApproval(for: run, in: topicID) ?? .cancel
        }
        let made = Conversation(agent: agent, folder: folder)
        conversations[topicID] = made
        if connection.isHarness {
            Task {
                await agent.whenElsewhere { [weak self] in
                    Task { @MainActor in self?.catchUp(topicID, after: .seconds(1)) }
                }
            }
        }
        return made
    }

    /// Opens a conversation that runs commands in DeepSeek Harness and brings it up to date from the
    /// session there, where it may have gone on: in dsh's interface, or after Spot Chat quit mid-turn.
    func open(_ topicID: UUID) {
        guard app.runsCommandsInHarness, !isRunning(topicID),
              let stored = logged({ try app.topicService.commandSetup(of: topicID) }), let setup = stored,
              setup.sessionID != nil,
              case let .success((connection, options)) = app.commandSetup()
        else { return }
        _ = conversation(topicID, folder: setup.folder, connection: connection, options: options)
        catchUp(topicID, after: .zero)
    }

    /// Rebuilds the conversation from DeepSeek Harness's history after `delay`, once what is going on there
    /// has settled. A catch-up already waiting gives way to this one.
    private func catchUp(_ topicID: UUID, after delay: Duration) {
        guard let conversation = conversations[topicID], conversation.agent.connection.isHarness else { return }
        catchUps[topicID]?.cancel()
        let agent = conversation.agent
        catchUps[topicID] = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return  // Another catch-up took its place.
            }
            do {
                // A connection opened only to catch up joins the conversation's session, never a new one.
                if await agent.sessionID == nil {
                    guard let earlier = self?.storedSession(of: topicID) else { return }
                    _ = try await agent.start(resuming: earlier, newWhenGone: false)
                }
                let turns = try await agent.history()
                guard !Task.isCancelled else { return }
                self?.apply(turns, to: topicID)
            } catch {
                SpotLog.agent.error("Couldn't catch up from DeepSeek Harness", metadata: [
                    "topic": "\(topicID)", "error": "\(error)",
                ])
            }
        }
    }

    private func storedSession(of topicID: UUID) -> String? {
        guard let setup = logged({ try app.topicService.commandSetup(of: topicID) }) else { return nil }
        return setup?.sessionID
    }

    /// Brings the stored conversation in line with DeepSeek Harness's history: the reply to Spot Chat's last
    /// question when Spot Chat didn't see it finish, and the questions asked in dsh since, with their replies.
    /// A reply Spot Chat finished stays as Spot Chat saved it, with what only Spot Chat knows, such as a
    /// command the user declined.
    private func apply(_ turns: [CommandHistory.Turn], to topicID: UUID) {
        guard !isRunning(topicID), let messages = logged({ try app.messageService.list(topicID: topicID) }) else { return }
        let questions = messages.filter { $0.role == .user }
        let matches = CommandHistory.matches(of: questions.map(\.text), in: turns)
        guard let last = matches.last else {
            SpotLog.agent.notice("None of the conversation's questions is in DeepSeek Harness's history", metadata: [
                "topic": "\(topicID)", "questions": "\(questions.count)", "turns": "\(turns.count)",
            ])
            return
        }
        var changed = false
        // Replies Spot Chat didn't see finish: one a quit left, or one to a question asked in dsh.
        for match in matches {
            guard let index = messages.firstIndex(where: { $0.id == questions[match.question].id }),
                  index + 1 < messages.count, messages[index + 1].role == .assistant, messages[index + 1].status == .pending
            else { continue }
            var reply = messages[index + 1]
            Self.fill(&reply, from: turns[match.turn])
            logged { try app.messageService.update(reply) }
            note(reply)
            changed = true
        }
        // Questions asked in dsh since.
        for turn in turns[(last.turn + 1)...] {
            logged { try app.messageService.append(ChatMessage(role: .user, text: turn.question), to: topicID) }
            var reply = ChatMessage(role: .assistant, text: "")
            Self.fill(&reply, from: turn)
            logged { try app.messageService.append(reply, to: topicID) }
            note(reply)
            changed = true
        }
        // A turn going on in dsh shows in the history as one going on here.
        app.setActivity(turns.last?.stopReason == nil ? .working : nil, for: topicID)
        SpotLog.reply.info("Caught up from DeepSeek Harness", metadata: [
            "topic": "\(topicID)", "turns": "\(turns.count)", "matched": "\(matches.count)",
            "added": "\(turns.count - last.turn - 1)", "changed": "\(changed)",
        ])
        guard changed else { return }
        app.conversationChanged.send(topicID)
        app.historyDidChange()
    }

    private static func fill(_ reply: inout ChatMessage, from turn: CommandHistory.Turn) {
        reply.text = turn.progress.text
        reply.reasoning = turn.progress.reasoning
        reply.commands = turn.progress.steps
        reply.status = turn.status
        reply.errorMessage = turn.error
    }

    /// Keeps track of a reply whose turn goes on in DeepSeek Harness.
    private func note(_ reply: ChatMessage) {
        if reply.status == .pending {
            repliesElsewhere.insert(reply.id)
        } else {
            repliesElsewhere.remove(reply.id)
        }
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
        catchUps.removeValue(forKey: topicID)?.cancel()
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
        // A question asked in DeepSeek Harness may have joined the turn; its reply comes from the history.
        if conversation.agent.connection.isHarness { catchUp(topicID, after: .zero) }
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
