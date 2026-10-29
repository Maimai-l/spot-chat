import Foundation

public enum ChatRole: String, Sendable, Codable {
    case user
    case assistant
}

public struct ChatMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var role: ChatRole
    public var text: String

    public init(id: UUID = UUID(), role: ChatRole, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

public struct Conversation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var messages: [ChatMessage]

    public init(id: UUID = UUID(), messages: [ChatMessage] = []) {
        self.id = id
        self.messages = messages
    }
}

/// Produces the assistant's reply as a stream of text chunks.
public protocol ChatResponder: Sendable {
    func reply(to messages: [ChatMessage]) -> AsyncThrowingStream<String, Error>
}

/// Stage 1 stand-in for the model: replies with the user's last message unchanged.
public struct EchoResponder: ChatResponder {
    public init() {}

    public func reply(to messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        let text = messages.last(where: { $0.role == .user })?.text ?? ""
        return AsyncThrowingStream { continuation in
            continuation.yield(text)
            continuation.finish()
        }
    }
}
