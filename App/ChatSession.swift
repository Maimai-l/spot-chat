import AppKit
import PDFKit
import SpotAI
import SpotCore

/// One conversation being shown: its messages and the reply being generated.
/// The mini window and the full window each own one.
@MainActor
final class ChatSession: ObservableObject {
    @Published private(set) var topicID: UUID?
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isGenerating = false

    private let app: AppModel
    private var generation: Task<Void, Never>?

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
    }

    /// A reply left pending by a quit or crash is shown as stopped.
    private static func stored(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.map { message in
            var message = message
            if message.status == .pending {
                message.status = .paused
            }
            return message
        }
    }

    func reload() {
        guard let topicID, !isGenerating else { return }
        messages = Self.stored((try? app.messageService.list(topicID: topicID)) ?? [])
    }

    /// Adds the user's message and starts the reply. Starts a conversation with `newTopicID` when there is none.
    func send(text: String, attachments: [Attachment], newTopicID: UUID) {
        guard !isGenerating else { return }
        let topicID = self.topicID ?? newTopicID
        // The mini window shows a new conversation before its first message, so the topic may not be stored yet.
        if (try? app.topicService.get(topicID)) == nil {
            try? app.topicService.create(id: topicID, name: TopicName.make(fromFirstMessage: text.isEmpty ? (attachments.first?.displayName ?? "") : text))
        }
        self.topicID = topicID
        let message = ChatMessage(role: .user, text: text, attachments: attachments)
        store(message)
        app.historyDidChange()
        generateReply()
    }

    func stop() {
        generation?.cancel()
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
        let model = app.currentModel
        var reply = ChatMessage(role: .assistant, text: "", status: .pending, modelID: model?.id)
        let history = messages

        let request: ChatRequest
        let responder: ChatResponder
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
                    messages: try ChatRequestBuilder.messages(from: history, loadAttachment: AttachmentLoader.load)
                )
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
        isGenerating = true
        generation = Task { [weak self] in
            var text = ""
            var reasoning = ""
            var thinkingStarted: Date?
            var thinkingTook: TimeInterval?
            var lastSave = Date()
            var failure: String?
            do {
                for try await chunk in responder.stream(request) {
                    if Task.isCancelled { break }
                    switch chunk {
                    case let .reasoning(part):
                        if thinkingStarted == nil { thinkingStarted = Date() }
                        reasoning += part
                    case let .text(part):
                        if let thinkingStarted, thinkingTook == nil { thinkingTook = Date().timeIntervalSince(thinkingStarted) }
                        text += part
                    case let .usage(usage):
                        self?.updateReply(replyID) { $0.usage = usage }
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
            } catch is CancellationError {
            } catch {
                failure = ErrorText.describe(error)
            }
            if let thinkingStarted, thinkingTook == nil { thinkingTook = Date().timeIntervalSince(thinkingStarted) }
            let cancelled = Task.isCancelled
            self?.finishReply(replyID, text: text, reasoningDuration: thinkingTook, failure: failure, cancelled: cancelled)
        }
    }

    private func saveReply(_ id: UUID) {
        if let reply = messages.first(where: { $0.id == id }) {
            try? app.messageService.update(reply)
        }
    }

    private func finishReply(_ id: UUID, text: String, reasoningDuration: TimeInterval?, failure: String?, cancelled: Bool) {
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
            try? app.messageService.update(reply)
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
        let request = TopicTitle.request(model: modelName, question: question, answer: messages[1].text)
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
            try? app.topicService.setAutomaticName(topicID, to: title)
            app.historyDidChange()
        }
    }

    private func updateReply(_ id: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    private func store(_ message: ChatMessage) {
        guard let topicID else { return }
        try? app.messageService.append(message, to: topicID)
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
        for message in messages[index...] {
            try? app.messageService.delete(message.id)
        }
        messages.removeSubrange(index...)
        store(ChatMessage(role: .user, text: text, attachments: attachments))
        app.historyDidChange()
        generateReply()
    }

    private func removeLastReply() {
        guard let last = messages.last, last.role == .assistant else { return }
        try? app.messageService.delete(last.id)
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
