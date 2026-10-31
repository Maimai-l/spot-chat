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

    init(app: AppModel, topicID: UUID? = nil) {
        self.app = app
        load(topicID)
    }

    /// Shows a stored conversation, or none.
    func load(_ topicID: UUID?) {
        guard topicID != self.topicID || topicID == nil else { return }
        stop()
        self.topicID = topicID
        messages = Self.stored(topicID.flatMap { try? app.messageService.list(topicID: $0) } ?? [])
        // A stored conversation runs commands where it did; one not stored yet keeps the current folder.
        if let topicID, (try? app.topicService.get(topicID)) != nil {
            setCommandFolderShown((try? app.topicService.commandSetup(of: topicID))?.folder)
        }
    }

    /// A reply left pending by a quit or crash is shown as stopped.
    private static func stored(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.map { message in
            var message = message
            if message.status == .pending {
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
        messages = Self.stored((try? app.messageService.list(topicID: topicID)) ?? [])
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
        isGenerating = true
        generation = Task { [weak self] in
            var text = ""
            var reasoning = ""
            var thinkingStarted: Date?
            var thinkingTook: TimeInterval?
            var lastSave = Date()
            var failure: String?
            var request = firstRequest
            var steps: [CommandRun] = []
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
                                reasoning += part
                                roundReasoning += part
                            case let .text(part):
                                if let thinkingStarted, thinkingTook == nil { thinkingTook = Date().timeIntervalSince(thinkingStarted) }
                                // Text after a search starts a new paragraph.
                                if roundText.isEmpty, !text.isEmpty, !text.hasSuffix("\n") { text += "\n\n" }
                                text += part
                                roundText += part
                            case let .usage(usage):
                                self?.updateReply(replyID) { $0.usage = usage }
                                continue
                            case let .toolCalls(made):
                                calls = made
                                continue
                            }
                            self?.updateReply(replyID) { reply in
                                reply.text = text
                                reply.reasoning = reasoning
                                reply.reasoningDuration = thinkingTook
                            }
                            // Saved as it streams, so a quit or crash keeps what has arrived.
                            if Date().timeIntervalSince(lastSave) > 1 {
                                lastSave = Date()
                                self?.saveReply(replyID)
                            }
                        }
                        break attempts
                    } catch let error as ChatServiceError
                        where error.rejectsThinking && request.thinking != .automatic && text.isEmpty && reasoning.isEmpty {
                        // A model without reasoning turned the effort down: ask again without it, and from now on.
                        SpotLog.reply.notice("The model turned the effort down; asking again without it", metadata: ["reply": "\(replyID)"])
                        request.thinking = .automatic
                        if let modelID = model?.id { self?.app.markWithoutEffort(modelID) }
                        continue attempts
                    } catch is CancellationError {
                        break attempts
                    } catch {
                        failure = ErrorText.describe(error)
                        break attempts
                    }
                }
                guard let webTools, !calls.isEmpty, failure == nil, !Task.isCancelled else { break rounds }

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
                    step.textOffset = text.count
                    steps.append(step)
                    self?.updateReply(replyID) { $0.commands = steps }
                    let output = await webTools.run(call, question: question)
                    if Task.isCancelled { break rounds }
                    WebStep.finish(&step, output: output)
                    steps[steps.count - 1] = step
                    self?.updateReply(replyID) { $0.commands = steps }
                    request.messages.append(.toolResult(output, for: call.id))
                }
            }
            if let thinkingStarted, thinkingTook == nil { thinkingTook = Date().timeIntervalSince(thinkingStarted) }
            let cancelled = Task.isCancelled
            self?.updateReply(replyID) { reply in
                for index in reply.commands.indices where !reply.commands[index].isFinished {
                    reply.commands[index].state = .stopped
                }
            }
            self?.finishReply(replyID, text: text, reasoningDuration: thinkingTook, failure: failure, cancelled: cancelled)
        }
    }

    /// A question that keeps searching stops after this many rounds.
    static let maxToolRounds = 10

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

/// Turns failures into the text shown in place of a reply.
enum ErrorText {
    static func describe(_ error: Error) -> String {
        if !(error is ChatServiceError), let description = (error as? LocalizedError)?.errorDescription {
            return description
        }
        switch ChatServiceError(error) {
        case let .api(message):
            return message
        case let .http(statusCode):
            return String(localized: "The service returned HTTP \(statusCode).")
        case .network:
            return String(localized: "Couldn't reach the service. Check the API address and your connection.")
        case .invalidEndpoint:
            return String(localized: "The API address in Settings isn't valid.")
        case let .other(message):
            return message
        }
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
