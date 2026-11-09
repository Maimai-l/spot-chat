import AppKit
import Logging
import SpotAgent
import SpotCore

/// Running commands: a conversation with a folder sends its questions to dsh, which answers with
/// the commands it runs in that folder.
extension ChatSession {
    /// Turns commands on in `folder`, or off with nil. The conversation's dsh ran in the old folder, so it
    /// closes, and the next question starts one in the new folder.
    func setCommandFolder(_ folder: URL?) {
        guard folder != commandFolder else { return }
        stop()
        if let topicID {
            app.commandRuns.end(topicID)
            logged { try app.topicService.setCommandFolder(folder, for: topicID) }
            app.historyDidChange()
        }
        setCommandFolderShown(folder)
    }

    /// The user's answer on the approval card.
    func answerApproval(_ answer: CommandApproval) {
        guard let topicID else { return }
        app.commandRuns.answer(answer, in: topicID)
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

        let earlierSession = (try? app.topicService.commandSetup(of: topicID))?.sessionID
        store(reply)
        SpotLog.reply.info("Command reply started", metadata: [
            "reply": "\(reply.id)", "topic": "\(topicID)", "folder": "\(folder.path)",
            "resumes": "\(earlierSession ?? "")",
        ])
        app.commandRuns.start(
            topicID: topicID, folder: folder, runtime: runtime, options: options,
            question: question, replyID: reply.id, earlierSession: earlierSession
        )
        followCommandTurn(of: topicID)
    }

    /// Shows the conversation's command turn here as it goes: the reply, the approval card, and how it ends.
    func followCommandTurn(of topicID: UUID) {
        guard let replyID = app.commandRuns.runningReply(of: topicID) else { return }
        followedCommandReply = replyID
        isGenerating = true
        lastReplySave = Date()
        app.commandRuns.follow(topicID, by: self) { [weak self] event in
            guard let self, self.followedCommandReply == replyID else { return }
            switch event {
            case let .progress(progress):
                // The turn saves the reply itself.
                self.showProgress(progress, ofReply: replyID, saves: false)
            case let .approval(run):
                self.pendingApproval = run
            case let .finished(result):
                self.followedCommandReply = nil
                self.pendingApproval = nil
                app.commandRuns.unfollow(topicID, by: self)
                self.updateReply(replyID) { $0.commands = result.progress.steps }
                self.finishReply(
                    replyID, text: result.progress.text, reasoningDuration: nil,
                    failure: result.failure, cancelled: result.stopped
                )
            }
        }
    }

    /// Stops showing the command turn without stopping it, when the window shows another conversation.
    func leaveCommandTurn() {
        if let topicID { app.commandRuns.unfollow(topicID, by: self) }
        followedCommandReply = nil
        pendingApproval = nil
        isGenerating = false
    }
}
