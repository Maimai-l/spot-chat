import AppKit
import SpotAgent
import SpotCore

/// Running commands: a conversation with a folder sends its questions to dsh, which answers with
/// the commands it runs in that folder.
extension ChatSession {
    /// Turns commands on in `folder`, or off with nil.
    func setCommandFolder(_ folder: URL?) {
        guard folder != commandFolder else { return }
        stop()
        endAgent()
        if let topicID {
            try? app.topicService.setCommandFolder(folder, for: topicID)
            app.historyDidChange()
        }
        setCommandFolderShown(folder)
    }

    /// The user's answer on the approval card.
    func answerApproval(_ answer: CommandApproval) {
        guard let approvalAnswer else { return }
        self.approvalAnswer = nil
        pendingApproval = nil
        approvalAnswer.resume(returning: answer)
    }

    func endAgent() {
        if let agent {
            Task { await agent.shutDown() }
        }
        agent = nil
    }

    /// Waits for the user to allow or deny a command outside the folder.
    private func askApproval(for run: CommandRun) async -> CommandApproval {
        answerApproval(.cancel)
        return await withCheckedContinuation { continuation in
            approvalAnswer = continuation
            pendingApproval = run
        }
    }

    func generateCommandReply() {
        guard let folder = commandFolder, let topicID else { return }
        var reply = ChatMessage(role: .assistant, text: "", status: .pending, modelID: app.currentModel?.id)
        let options: CommandAgentOptions
        switch app.commandOptions() {
        case let .failure(reason):
            reply.status = .error
            reply.errorMessage = reason.errorDescription
            store(reply)
            return
        case let .success(value):
            options = value
        }
        guard let runtime = app.commandRuntime, let question = messages.last, question.role == .user else { return }

        let agent: CommandAgent
        if let existing = self.agent {
            agent = existing
        } else {
            agent = CommandAgent(runtime: runtime, options: options, folder: folder) { [weak self] run in
                await self?.askApproval(for: run) ?? .cancel
            }
            self.agent = agent
        }
        let earlierSession = (try? app.topicService.commandSetup(of: topicID))?.sessionID
        store(reply)
        let replyID = reply.id
        isGenerating = true

        generation = Task { [weak self] in
            let (events, sink) = AsyncStream<CommandEvent>.makeStream()
            // The turn and its updates run on their own: stopping asks dsh to stop and still shows how it ended.
            let turn = Task {
                defer { sink.finish() }
                let sessionID = try await agent.start(resuming: earlierSession)
                if sessionID != earlierSession { try? self?.app.topicService.setAgentSession(sessionID, for: topicID) }
                await agent.update(model: options.model, effort: options.effort)
                return try await agent.send(question.text, paths: question.paths.map { URL(fileURLWithPath: $0) }) { event in
                    sink.yield(event)
                }
            }
            let updates = Task {
                var text = ""
                var reasoning = ""
                var commands: [CommandRun] = []
                var lastSave = Date()
                for await event in events {
                    switch event {
                    case let .text(part):
                        text += part
                    case let .thought(part):
                        reasoning += part
                    case let .run(run):
                        if let index = commands.firstIndex(where: { $0.id == run.id }) {
                            commands[index] = run
                        } else {
                            commands.append(run)
                        }
                    }
                    self?.updateReply(replyID) { reply in
                        reply.text = text
                        reply.reasoning = reasoning
                        reply.commands = commands
                    }
                    // Saved as it goes, so a quit or crash keeps what ran.
                    if Date().timeIntervalSince(lastSave) > 1 {
                        lastSave = Date()
                        self?.saveReply(replyID)
                    }
                }
                return text
            }
            let text = await withTaskCancellationHandler {
                await updates.value
            } onCancel: {
                Task { await agent.cancel() }
            }
            var failure: String?
            var finished = false
            do {
                finished = try await turn.value
            } catch {
                failure = ErrorText.describe(error)
            }
            let stopped = !finished || Task.isCancelled
            self?.updateReply(replyID) { reply in
                for index in reply.commands.indices where !reply.commands[index].isFinished {
                    reply.commands[index].state = .stopped
                }
            }
            self?.finishReply(replyID, text: text, reasoningDuration: nil, failure: failure, cancelled: stopped && failure == nil)
        }
    }
}
