import Foundation
import SpotCore

/// One line of a chat completions event stream.
enum StreamLine: Equatable {
    case chunks([ReplyChunk])
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
        for choice in chunk.choices ?? [] {
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
                var content: String?
                var reasoningContent: String?
                var reasoning: String?
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
