import Foundation

/// What is sent to the model for one reply.
public struct ChatRequest: Equatable, Sendable {
    public var model: String
    public var messages: [ChatRequestMessage]

    public init(model: String, messages: [ChatRequestMessage]) {
        self.model = model
        self.messages = messages
    }
}

public struct ChatRequestMessage: Equatable, Sendable {
    public enum Part: Equatable, Sendable {
        case text(String)
        case image(data: Data, mimeType: String)
    }

    public var role: ChatRole
    public var parts: [Part]

    public init(role: ChatRole, parts: [Part]) {
        self.role = role
        self.parts = parts
    }
}

/// A piece of a streamed reply: the model's thinking, which reasoning models send first, or the reply itself.
public enum ReplyChunk: Equatable, Sendable {
    case reasoning(String)
    case text(String)
}

/// Produces the assistant's reply as a stream of chunks.
public protocol ChatResponder: Sendable {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ReplyChunk, Error>
}

extension ChatResponder {
    /// The reply's text alone, without the thinking.
    public func reply(to request: ChatRequest) -> AsyncThrowingStream<String, Error> {
        let upstream = stream(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in upstream {
                        if case let .text(text) = chunk { continuation.yield(text) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Replies with the user's last message unchanged. Used in tests.
public struct EchoResponder: ChatResponder {
    public init() {}

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ReplyChunk, Error> {
        let text = request.messages.last(where: { $0.role == .user })?.parts.compactMap { part -> String? in
            if case let .text(text) = part { return text }
            return nil
        }.joined(separator: "\n") ?? ""
        return AsyncThrowingStream { continuation in
            continuation.yield(.text(text))
            continuation.finish()
        }
    }
}

/// The content of an attachment as the model receives it.
public enum AttachmentContent: Equatable, Sendable {
    case image(data: Data, mimeType: String)
    case text(String)
}

public enum ChatRequestBuilder {
    /// Turns the stored conversation into request messages.
    /// Replies that failed or are still being generated are left out, as is a reply with no text yet.
    public static func messages(
        from history: [ChatMessage],
        loadAttachment: (Attachment) throws -> AttachmentContent
    ) rethrows -> [ChatRequestMessage] {
        var result: [ChatRequestMessage] = []
        for message in history {
            switch message.role {
            case .assistant:
                guard message.status == .success || message.status == .paused,
                      !message.text.isEmpty
                else { continue }
                result.append(ChatRequestMessage(role: .assistant, parts: [.text(message.text)]))
            case .user:
                var parts: [ChatRequestMessage.Part] = []
                if !message.text.isEmpty {
                    parts.append(.text(message.text))
                }
                for attachment in message.attachments {
                    switch try loadAttachment(attachment) {
                    case let .image(data, mimeType):
                        parts.append(.image(data: data, mimeType: mimeType))
                    case let .text(content):
                        parts.append(.text(fileBlock(name: attachment.displayName, content: content)))
                    }
                }
                guard !parts.isEmpty else { continue }
                result.append(ChatRequestMessage(role: .user, parts: parts))
            }
        }
        return result
    }

    public static func fileBlock(name: String, content: String) -> String {
        "[File: \(name)]\n```\n\(content)\n```"
    }

    public static func mimeType(forImageExtension ext: String?) -> String {
        switch ext?.lowercased() {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/jpeg"
        }
    }
}
