import AppKit
import Logging
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
            logged { try app.topicService.setCommandFolder(folder, for: topicID) }
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
            SpotLog.reply.error("Commands unavailable", metadata: ["reason": "\(reason.errorDescription ?? "")"])
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
        SpotLog.reply.info("Command reply started", metadata: [
            "reply": "\(replyID)", "topic": "\(topicID)", "folder": "\(folder.path)",
            "resumes": "\(earlierSession ?? "")",
        ])
        isGenerating = true

        lastReplySave = Date()
        let app = app
        generation = Task { [weak self] in
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
                    await self?.showProgress(progress, ofReply: replyID)
                }
            )
            self?.updateReply(replyID) { $0.commands = result.progress.steps }
            self?.finishReply(
                replyID, text: result.progress.text, reasoningDuration: nil, failure: result.failure, cancelled: result.stopped
            )
        }
    }
}
