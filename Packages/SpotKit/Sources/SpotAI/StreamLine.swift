import Foundation
import SpotCore

/// One line of a chat completions event stream.
enum StreamLine: Equatable {
    case chunks([ReplyChunk])
    /// Pieces of tool calls, which arrive split over many lines, with any text in the same line.
    case toolDeltas([ReplyChunk], [ToolCallDelta])
    case done
    /// A comment such as DeepSeek's ": keep-alive", an event name, or a chunk with nothing in it.
    case ignored

    /// Throws when the service sends an error in the middle of the stream.
    static func decode(_ line: String) throws -> StreamLine {
        guard line.hasPrefix("data:") else { return .ignored }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let chunk = try? decoder.decode(Chunk.self, from: data)
        else { return .ignored }
        if let message = chunk.error?.message, !message.isEmpty {
            throw ChatServiceError.api(message: message)
        }
        var result: [ReplyChunk] = []
        var deltas: [ToolCallDelta] = []
        for choice in chunk.choices ?? [] {
            for call in choice.delta?.toolCalls ?? [] {
                deltas.append(ToolCallDelta(
                    index: call.index ?? 0, id: call.id, name: call.function?.name, arguments: call.function?.arguments
                ))
            }
            if let reasoning = choice.delta?.reasoningContent ?? choice.delta?.reasoning, !reasoning.isEmpty {
                result.append(.reasoning(reasoning))
            }
            if let content = choice.delta?.content, !content.isEmpty {
                result.append(.text(content))
            }
        }
        if let usage = chunk.usage, let prompt = usage.promptTokens {
            // DeepSeek reports cache hits in its own field; OpenAI and most others in cached_tokens.
            let cached = max(usage.promptCacheHitTokens ?? 0, usage.promptTokensDetails?.cachedTokens ?? 0)
            result.append(.usage(TokenUsage(
                promptTokens: prompt, completionTokens: usage.completionTokens ?? 0, cachedTokens: cached
            )))
        }
        if !deltas.isEmpty { return .toolDeltas(result, deltas) }
        return result.isEmpty ? .ignored : .chunks(result)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// Every field is optional: services leave out different ones, and DeepSeek sends chunks with none.
    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                struct ToolCallPart: Decodable {
                    struct Function: Decodable {
                        var name: String?
                        var arguments: String?
                    }
                    var index: Int?
                    var id: String?
                    var function: Function?
                }
                var content: String?
                var reasoningContent: String?
                var reasoning: String?
                var toolCalls: [ToolCallPart]?
            }
            var delta: Delta?
        }
        struct Usage: Decodable {
            struct PromptDetails: Decodable {
                var cachedTokens: Int?
            }
            var promptTokens: Int?
            var completionTokens: Int?
            var promptCacheHitTokens: Int?
            var promptTokensDetails: PromptDetails?
        }
        struct APIError: Decodable {
            var message: String?
        }
        var choices: [Choice]?
        var usage: Usage?
        var error: APIError?
    }
}

/// One piece of a streamed tool call. The first piece of a call has its id and name; the arguments
/// arrive over the following ones. Calls are told apart by `index`.
struct ToolCallDelta: Equatable {
    var index: Int
    var id: String?
    var name: String?
    var arguments: String?
}

/// Puts streamed tool calls back together.
struct ToolCallAssembler {
    private var calls: [Int: ToolCall] = [:]

    mutating func add(_ delta: ToolCallDelta) {
        var call = calls[delta.index] ?? ToolCall(id: "", name: "", arguments: "")
        // Later pieces may carry an empty id or name; the first non-empty one counts.
        if let id = delta.id, !id.isEmpty, call.id.isEmpty { call.id = id }
        if let name = delta.name, !name.isEmpty, call.name.isEmpty { call.name = name }
        call.arguments += delta.arguments ?? ""
        calls[delta.index] = call
    }

    var result: [ToolCall] {
        calls.sorted { $0.key < $1.key }.map { index, call in
            var call = call
            if call.id.isEmpty { call.id = "call_\(index)" }
            return call
        }
    }
}
