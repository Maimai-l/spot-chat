import Logging
import AppKit
import PDFKit
import SpotAgent
import SpotAI
import SpotCore

/// One conversation being shown: its messages and the reply being generated.
/// The mini window and the full window each own one.
@MainActor
final class ChatSession: ObservableObject {
    @Published private(set) var topicID: UUID? {
        didSet { reportActivity() }
    }
    @Published private(set) var messages: [ChatMessage] = []
    @Published var isGenerating = false {
        didSet { reportActivity() }
    }
    /// The folder this conversation runs commands in; nil when it only chats.
    @Published private(set) var commandFolder: URL?
    /// A command dsh wants to run outside the folder, waiting for the user.
    @Published var pendingApproval: CommandRun? {
        didSet { reportActivity() }
    }
    /// The conversation whose activity this session last told the app about.
    private var reportedActivity: (topicID: UUID, activity: TopicActivity)?

    let app: AppModel
    var generation: Task<Void, Never>?
    var agent: CommandAgent?
    var approvalAnswer: CheckedContinuation<CommandApproval, Never>?
    /// When the reply being written was last saved.
    var lastReplySave = Date.distantPast
    /// The reply writer at work on the reply shown, in a process of its own; nil while the app writes it.
    private var writerPID: pid_t? {
        didSet { reportActivity() }
    }

    init(app: AppModel, topicID: UUID? = nil) {
        self.app = app
        load(topicID)
    }

    /// Shows a stored conversation, or none.
    func load(_ topicID: UUID?) {
        guard topicID != self.topicID || topicID == nil else { return }
        // A reply the writer writes goes on without the window; one the app writes stops.
        if writerPID != nil { leaveWriter() } else { stop() }
        self.topicID = topicID
        messages = stored(topicID.flatMap { try? app.messageService.list(topicID: $0) } ?? [])
        watchWriterOfShownReply()
        // A stored conversation runs commands where it did; one not stored yet keeps the current folder.
        if let topicID, (try? app.topicService.get(topicID)) != nil {
            setCommandFolderShown((try? app.topicService.commandSetup(of: topicID))?.folder)
        }
    }

    /// A reply left pending by a quit or crash is shown as stopped, unless the writer is still at work on it.
    private func stored(_ messages: [ChatMessage]) -> [ChatMessage] {
        let dataDirectory = AppStorageLocation.dataDirectory()
        return messages.map { message in
            var message = message
            if message.status == .pending, ReplyWriter.writer(of: message.id, dataDirectory: dataDirectory) == nil {
                message.status = .paused
                for index in message.commands.indices where !message.commands[index].isFinished {
                    message.commands[index].state = .stopped
                }
            }
            return message
        }
    }

    /// Tells the history what this conversation is doing: waiting for the user, working, or nothing.
    private func reportActivity() {
        let activity: TopicActivity? = pendingApproval != nil ? .needsInput : (isGenerating ? .working : nil)
        let current = topicID.flatMap { id in activity.map { (topicID: id, activity: $0) } }
        if let old = reportedActivity, old.topicID != current?.topicID {
            app.setActivity(nil, for: old.topicID)
            app.setStoppedByQuitting(false, for: old.topicID)
        }
        // Only what this process writes ends with it; the writer finishes its replies regardless.
        if let topicID {
            app.setStoppedByQuitting(current != nil && writerPID == nil, for: topicID)
        }
        if let current {
            app.setActivity(current.activity, for: current.topicID)
        }
        reportedActivity = current
    }

    func setCommandFolderShown(_ folder: URL?) {
        if folder != commandFolder { endAgent() }
        commandFolder = folder
    }

    func reload() {
        guard let topicID, !isGenerating else { return }
        messages = stored((try? app.messageService.list(topicID: topicID)) ?? [])
        watchWriterOfShownReply()
    }

    /// Adds the user's message and starts the reply. Starts a conversation with `newTopicID` when there is none.
    func send(text: String, attachments: [Attachment], paths: [URL] = [], newTopicID: UUID) {
        guard !isGenerating else { return }
        let topicID = self.topicID ?? newTopicID
        // The mini window shows a new conversation before its first message, so the topic may not be stored yet.
        if (try? app.topicService.get(topicID)) == nil {
            _ = try? app.topicService.create(id: topicID, name: TopicName.make(fromFirstMessage: text.isEmpty ? (attachments.first?.displayName ?? paths.first?.lastPathComponent ?? "") : text))
            if let commandFolder { try? app.topicService.setCommandFolder(commandFolder, for: topicID) }
        }
        self.topicID = topicID
        let message = ChatMessage(role: .user, text: text, attachments: attachments, paths: paths.map(\.path))
        store(message)
        app.historyDidChange()
        generateReply()
    }

    func stop() {
        // The writer saves the reply as stopped and reports it; the app keeps listening until it has.
        if let writerPID {
            ReplyWriter.stop(writerPID)
            return
        }
        generation?.cancel()
        answerApproval(.cancel)
    }

    /// Replaces a failed reply with a new attempt.
    func retry(_ messageID: UUID) {
        guard !isGenerating, messages.last?.id == messageID, messages.last?.role == .assistant else { return }
        removeLastReply()
        generateReply()
    }

    /// Replaces the last reply with a new one.
    func regenerateLastReply() {
        guard !isGenerating, messages.last?.role == .assistant else { return }
        removeLastReply()
        generateReply()
    }

    // MARK: Generation

    private func generateReply() {
        if commandFolder != nil {
            generateCommandReply()
            return
        }
        // A conversation tied to an assistant preset uses its model, prompt and effort.
        let preset = app.preset(forTopic: topicID)
        let model = preset?.modelID.flatMap { id in app.allModels.first { $0.id == id } } ?? app.currentModel
        var reply = ChatMessage(role: .assistant, text: "", status: .pending, modelID: model?.id)
        let history = messages

        var request: ChatRequest
        let responder: ChatResponder
        let webTools = model.flatMap { app.webTools(for: $0) }
        let question = history.last(where: { $0.role == .user })?.text ?? ""
        switch app.responder(for: model) {
        case let .failure(error):
            reply.status = .error
            reply.errorMessage = ErrorText.describe(error)
            store(reply)
            return
        case let .success((client, modelName)):
            do {
                request = ChatRequest(
                    model: modelName,
                    messages: try ChatRequestBuilder.messages(from: history, loadAttachment: AttachmentLoader.load),
                    systemPrompt: PromptVariables.resolve(
                        (preset?.prompt.isEmpty == false ? preset?.prompt ?? "" : app.systemPrompt)
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                        in: app.promptContext(start: history.first?.createdAt ?? Date(), modelName: modelName)
                    ),
                    thinking: preset?.thinking ?? model.map { app.requestThinking(for: $0) } ?? .automatic
                )
                // With web search on, the model may search and read pages, and decides when to.
                if webTools != nil {
                    request.tools = DeepSeekWebTools.definitions
                    request.systemPrompt = [request.systemPrompt, DeepSeekWebTools.guidance]
                        .filter { !$0.isEmpty }.joined(separator: "\n\n")
                }
            } catch {
                reply.status = .error
                reply.errorMessage = ErrorText.describe(error)
                store(reply)
                return
            }
            responder = client
        }

        store(reply)
        let replyID = reply.id
        let firstRequest = request
        SpotLog.reply.info("Reply started", metadata: [
            "reply": "\(replyID)", "topic": "\(topicID?.uuidString ?? "new")", "model": "\(request.model)",
            "messages": "\(request.messages.count)", "thinking": "\(request.thinking)", "web": "\(webTools != nil)",
            "preset": "\(preset?.name ?? "")",
        ])
        if let topicID, let model, writeElsewhere(
            firstRequest, reply: replyID, topicID: topicID, model: model, question: question, webTools: webTools
        ) {
            return
        }
        isGenerating = true
        lastReplySave = Date()
        let runner = ChatReplyRunner(responder: responder, tools: webTools, describe: ErrorText.describe)
        generation = Task { [weak self] in
            let result = await runner.run(firstRequest, question: question, replyID: replyID) { event in
                await self?.apply(event, toReply: replyID, model: model)
            }
            self?.updateReply(replyID) { $0.commands = result.progress.steps }
            self?.finishReply(
                replyID, text: result.progress.text, reasoningDuration: result.progress.reasoningDuration,
                failure: result.failure, cancelled: result.stopped
            )
        }
    }

    /// Shows what the reply reported, saving it as it streams so a quit or crash keeps what has arrived.
    private func apply(_ event: ChatReplyRunner.Event, toReply id: UUID, model: ProviderModel?) {
        switch event {
        case let .progress(progress):
            showProgress(progress, ofReply: id)
        case let .usage(usage):
            updateReply(id) { $0.usage = usage }
        case .effortRejected:
            if let modelID = model?.id { app.markWithoutEffort(modelID) }
        }
    }

    /// Shows the reply as it stands, and saves it at most once a second unless the writer saves it.
    func showProgress(_ progress: ReplyProgress, ofReply id: UUID, saves: Bool = true) {
        updateReply(id) { reply in
            reply.text = progress.text
            reply.reasoning = progress.reasoning
            reply.reasoningDuration = progress.reasoningDuration
            reply.commands = progress.steps
        }
        if saves, Date().timeIntervalSince(lastReplySave) > 1 {
            lastReplySave = Date()
            saveReply(id)
        }
    }

    // MARK: The reply writer

    /// Hands the reply to the writer, which saves it as it arrives and finishes it if the app quits. False
    /// when the writer isn't there or wouldn't start, and the app then writes the reply itself.
    private func writeElsewhere(
        _ request: ChatRequest, reply replyID: UUID, topicID: UUID, model: ProviderModel, question: String,
        webTools: DeepSeekWebTools?
    ) -> Bool {
        let job = ReplyJob(
            replyID: replyID, topicID: topicID, providerID: model.providerID, request: request, question: question,
            webToolsURL: webTools?.baseURL, dataDirectory: AppStorageLocation.dataDirectory().path
        )
        guard let started = ReplyWriter.start(job) else { return false }
        let lines = started.lines
        writerPID = started.pid
        isGenerating = true
        let app = app
        generation = Task { [weak self] in
            var finished = false
            for await line in lines {
                guard let self, !Task.isCancelled else { return }
                switch line {
                case let .progress(progress):
                    self.showProgress(progress, ofReply: replyID, saves: false)
                case let .usage(usage):
                    self.updateReply(replyID) { $0.usage = usage }
                case .effortRejected:
                    app.markWithoutEffort(model.id)
                case .finished:
                    finished = true
                    self.finishWrittenReply(replyID)
                }
            }
            // The writer exited without saying it finished; what it saved is all there is.
            guard !finished, !Task.isCancelled else { return }
            SpotLog.reply.error("The writer ended without finishing", metadata: ["reply": "\(replyID)"])
            self?.finishWrittenReply(replyID)
        }
        return true
    }

    /// Follows a reply the writer is still writing, as after a relaunch or in a second window: it reads the
    /// reply from the database as the writer saves it, until the writer is done.
    private func watchWriterOfShownReply() {
        guard writerPID == nil, let reply = messages.last(where: { $0.status == .pending }),
              let pid = ReplyWriter.writer(of: reply.id, dataDirectory: AppStorageLocation.dataDirectory())
        else { return }
        let replyID = reply.id
        SpotLog.reply.info("Following the writer's reply", metadata: ["reply": "\(replyID)", "pid": "\(pid)"])
        writerPID = pid
        isGenerating = true
        let app = app
        generation = Task { [weak self] in
            while true {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                guard let self, let saved = logged({ try app.messageService.get(replyID) }) ?? nil else { return }
                self.updateReply(replyID) { reply in
                    reply.text = saved.text
                    reply.reasoning = saved.reasoning
                    reply.reasoningDuration = saved.reasoningDuration
                    reply.usage = saved.usage
                    reply.commands = saved.commands
                }
                if saved.status != .pending || ReplyWriter.writer(of: replyID, dataDirectory: AppStorageLocation.dataDirectory()) == nil {
                    self.finishWrittenReply(replyID)
                    return
                }
            }
        }
    }

    /// Shows the reply as the writer saved it at the end. One it left pending, by crashing, is stopped.
    private func finishWrittenReply(_ id: UUID) {
        if var saved = logged({ try app.messageService.get(id) }) ?? nil {
            if saved.status == .pending {
                saved.status = .paused
                for index in saved.commands.indices where !saved.commands[index].isFinished {
                    saved.commands[index].state = .stopped
                }
                logged { try app.messageService.update(saved) }
            }
            updateReply(id) { reply in
                reply.text = saved.text
                reply.reasoning = saved.reasoning
                reply.reasoningDuration = saved.reasoningDuration
                reply.usage = saved.usage
                reply.commands = saved.commands
                reply.status = saved.status
                reply.errorMessage = saved.errorMessage
            }
            SpotLog.reply.info("Reply written by the writer", metadata: [
                "reply": "\(id)", "status": "\(saved.status.rawValue)", "characters": "\(saved.text.count)",
            ])
        }
        generation = nil
        // In this order, so the reply never counts for a moment as one the app writes itself.
        isGenerating = false
        writerPID = nil
        app.historyDidChange()
        if messages.last?.id == id, messages.last?.status == .success { nameTopicAfterFirstReply() }
    }

    /// Stops following the writer without stopping it, when the window shows another conversation.
    private func leaveWriter() {
        generation?.cancel()
        generation = nil
        isGenerating = false
        writerPID = nil
    }

    func saveReply(_ id: UUID) {
        if let reply = messages.first(where: { $0.id == id }) {
            logged { try app.messageService.update(reply) }
        }
    }

    func finishReply(_ id: UUID, text: String, reasoningDuration: TimeInterval?, failure: String?, cancelled: Bool) {
        let outcome = failure != nil ? "failed" : cancelled ? "stopped" : "finished"
        SpotLog.reply.info("Reply \(outcome)", metadata: [
            "reply": "\(id)", "characters": "\(text.count)", "error": "\(failure ?? "")",
        ])
        // The text as saved, to compare with what the service sent and what the page showed.
        SpotLog.reply.debug("Reply text", metadata: ["reply": "\(id)", "text": "\(SpotLog.clip(text))"])
        updateReply(id) { reply in
            reply.text = text
            reply.reasoningDuration = reasoningDuration
            if let failure {
                reply.status = .error
                reply.errorMessage = failure
            } else {
                reply.status = cancelled ? .paused : .success
            }
        }
        if let reply = messages.first(where: { $0.id == id }) {
            logged { try app.messageService.update(reply) }
        }
        generation = nil
        isGenerating = false
        app.historyDidChange()
        if failure == nil, !cancelled { nameTopicAfterFirstReply() }
    }

    /// After the first reply, asks the model for a short title; the first line of the question stands in
    /// until then. A name the user typed is never replaced.
    private func nameTopicAfterFirstReply() {
        guard let topicID, messages.count == 2,
              messages[0].role == .user, messages[1].role == .assistant, messages[1].status == .success,
              case let .success((client, modelName)) = app.responder(for: app.currentModel)
        else { return }
        let question = messages[0].text.isEmpty ? (messages[0].attachments.first?.displayName ?? "") : messages[0].text
        let usesDeepSeek = self.app.currentModel.map { self.app.isDeepSeek($0) } ?? false
        let thinking: ThinkingLevel = usesDeepSeek ? .off : .automatic
        let request = TopicTitle.request(model: modelName, question: question, answer: messages[1].text, thinking: thinking)
        let app = app
        Task {
            var reply = ""
            do {
                for try await chunk in client.reply(to: request) {
                    reply += chunk
                }
            } catch {
                return
            }
            guard let title = TopicTitle.clean(reply) else { return }
            logged { try app.topicService.setAutomaticName(topicID, to: title) }
            app.historyDidChange()
        }
    }

    func updateReply(_ id: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    func store(_ message: ChatMessage) {
        guard let topicID else { return }
        logged { try app.messageService.append(message, to: topicID) }
        messages.append(message)
    }

    /// Replaces a question with new text: everything after it is removed and a new reply is generated.
    func edit(_ messageID: UUID, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isGenerating, !text.isEmpty,
              let index = messages.firstIndex(where: { $0.id == messageID }),
              messages[index].role == .user
        else { return }
        let attachments = messages[index].attachments
        let paths = messages[index].paths
        for message in messages[index...] {
            logged { try app.messageService.delete(message.id) }
        }
        messages.removeSubrange(index...)
        store(ChatMessage(role: .user, text: text, attachments: attachments, paths: paths))
        app.historyDidChange()
        generateReply()
    }

    private func removeLastReply() {
        guard let last = messages.last, last.role == .assistant else { return }
        logged { try app.messageService.delete(last.id) }
        messages.removeLast()
    }
}

/// Reads attachments for sending: images as data, PDFs and text files as text.
enum AttachmentLoader {
    enum LoadError: LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case let .unreadable(name):
                return String(localized: "\(name) can't be read as text.")
            }
        }
    }

    static func load(_ attachment: Attachment) throws -> AttachmentContent {
        let data = try Data(contentsOf: attachment.fileURL)
        if attachment.kind == .image {
            return .image(data: data, mimeType: ChatRequestBuilder.mimeType(forImageExtension: attachment.ext))
        }
        if attachment.ext?.lowercased() == "pdf" {
            guard let text = PDFDocument(data: data)?.string else { throw LoadError.unreadable(attachment.displayName) }
            return .text(text)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw LoadError.unreadable(attachment.displayName) }
        return .text(text)
    }
}
