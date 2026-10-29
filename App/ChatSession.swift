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
        if self.topicID == nil {
            try? app.topicService.create(id: topicID, name: TopicName.make(fromFirstMessage: text.isEmpty ? (attachments.first?.displayName ?? "") : text))
            self.topicID = topicID
        }
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
            var failure: String?
            do {
                for try await chunk in responder.reply(to: request) {
                    if Task.isCancelled { break }
                    text += chunk
                    self?.updateReply(replyID) { $0.text = text }
                }
            } catch is CancellationError {
            } catch {
                failure = ErrorText.describe(error)
            }
            let cancelled = Task.isCancelled
            self?.finishReply(replyID, text: text, failure: failure, cancelled: cancelled)
        }
    }

    private func finishReply(_ id: UUID, text: String, failure: String?, cancelled: Bool) {
        updateReply(id) { reply in
            reply.text = text
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
