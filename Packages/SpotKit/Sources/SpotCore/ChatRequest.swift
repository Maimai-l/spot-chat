import Foundation

/// What is sent to the model for one reply.
public struct ChatRequest: Equatable, Sendable {
    public var model: String
    public var messages: [ChatRequestMessage]
    /// Sent first, as the system message. Empty sends none.
    public var systemPrompt: String
    public var thinking: ThinkingLevel
    /// Tools the model may call, such as web search. The model decides whether to.
    public var tools: [ToolDefinition]

    public init(
        model: String, messages: [ChatRequestMessage], systemPrompt: String = "", thinking: ThinkingLevel = .automatic,
        tools: [ToolDefinition] = []
    ) {
        self.model = model
        self.messages = messages
        self.systemPrompt = systemPrompt
        self.thinking = thinking
        self.tools = tools
    }
}

/// A function the model may call. `parameters` is its JSON Schema as JSON text.
public struct ToolDefinition: Equatable, Sendable {
    public var name: String
    public var description: String
    public var parameters: String

    public init(name: String, description: String, parameters: String) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// A call the model made; `arguments` is JSON text.
public struct ToolCall: Equatable, Sendable, Codable {
    public var id: String
    public var name: String
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// How much a reasoning model thinks before it replies, chosen per model as in Cherry Studio.
/// `automatic` sends nothing and leaves it to the service.
public enum ThinkingLevel: String, Codable, CaseIterable, Sendable {
    case automatic
    case off
    case low
    case medium
    case high
    case max

    /// The levels a service offers. DeepSeek's are low, high and max
    /// (api-docs.deepseek.com/guides/thinking_mode); OpenAI-style services take low, medium and high.
    public static func choices(isDeepSeek: Bool) -> [ThinkingLevel] {
        isDeepSeek ? [.off, .low, .high, .max] : [.off, .low, .medium, .high]
    }

    /// The level shown before one is chosen: dsh's default for DeepSeek, and the middle one elsewhere
    /// (Cherry Studio's "auto" for OpenAI-style services).
    public static func standard(isDeepSeek: Bool) -> ThinkingLevel {
        isDeepSeek ? .high : .medium
    }
}

public struct ChatRequestMessage: Equatable, Sendable {
    public enum Part: Equatable, Sendable {
        case text(String)
        case image(data: Data, mimeType: String)
    }

    public var role: ChatRole
    public var parts: [Part]
    /// For a reply that called tools within the current question.
    public var toolCalls: [ToolCall]
    /// The thinking behind those calls, which DeepSeek needs back until the question is answered.
    public var reasoning: String?
    /// Set on a tool's result, which goes back to the model as a message of its own.
    public var toolCallID: String?

    public init(role: ChatRole, parts: [Part], toolCalls: [ToolCall] = [], reasoning: String? = nil, toolCallID: String? = nil) {
        self.role = role
        self.parts = parts
        self.toolCalls = toolCalls
        self.reasoning = reasoning
        self.toolCallID = toolCallID
    }

    /// A tool's result.
    public static func toolResult(_ text: String, for callID: String) -> ChatRequestMessage {
        ChatRequestMessage(role: .assistant, parts: [.text(text)], toolCallID: callID)
    }
}

/// A piece of a streamed reply: the model's thinking, which reasoning models send first, the reply itself,
/// or, at the end, how many tokens the request used.
public enum ReplyChunk: Equatable, Sendable {
    case reasoning(String)
    case text(String)
    case usage(TokenUsage)
    /// The tools the model called, once its message is complete.
    case toolCalls([ToolCall])
}

/// Tokens a reply used. `cachedTokens` of the prompt were served from the service's prompt cache,
/// which DeepSeek and OpenAI bill at a fraction of the price.
public struct TokenUsage: Equatable, Sendable, Codable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var cachedTokens: Int

    public init(promptTokens: Int, completionTokens: Int, cachedTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedTokens = cachedTokens
    }
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
