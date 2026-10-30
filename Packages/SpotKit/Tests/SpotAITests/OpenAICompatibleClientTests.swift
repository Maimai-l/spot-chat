import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import SpotCore
@testable import SpotAI

/// Runs against scripts/mock_openai_server.py. CI starts it and sets MOCK_OPENAI_BASE_URL.
let mockBaseURL = ProcessInfo.processInfo.environment["MOCK_OPENAI_BASE_URL"]

@Suite(.serialized, .enabled(if: mockBaseURL != nil, "Start scripts/mock_openai_server.py and set MOCK_OPENAI_BASE_URL"))
struct OpenAICompatibleClientTests {
    func client(apiKey: String = "test-key") throws -> OpenAICompatibleClient {
        try OpenAICompatibleClient(baseURL: mockBaseURL!, apiKey: apiKey)
    }

    func ask(_ text: String, client: OpenAICompatibleClient) async throws -> String {
        let request = ChatRequest(model: "mock-fast", messages: [ChatRequestMessage(role: .user, parts: [.text(text)])])
        var reply = ""
        for try await chunk in client.reply(to: request) {
            reply += chunk
        }
        return reply
    }

    @Test func streamsTheReply() async throws {
        #expect(try await ask("hello", client: client()) == "Echo: hello")
    }

    @Test func streamsThinkingBeforeTheReply() async throws {
        let request = ChatRequest(model: "mock-fast", messages: [ChatRequestMessage(role: .user, parts: [.text("think")])])
        var chunks: [ReplyChunk] = []
        for try await chunk in try client().stream(request) {
            chunks.append(chunk)
        }
        let reasoning = chunks.compactMap { chunk -> String? in
            if case let .reasoning(text) = chunk { return text }
            return nil
        }
        let text = chunks.compactMap { chunk -> String? in
            if case let .text(text) = chunk { return text }
            return nil
        }
        #expect(reasoning.joined().hasPrefix("The user asks"))
        #expect(text.joined() == "Two plus two is four.")
        if case .reasoning = chunks.first {} else { Issue.record("Thinking comes first") }
        // The text alone leaves the thinking out.
        #expect(try await ask("think", client: client()) == "Two plus two is four.")
    }

    @Test func reportsCacheHitsForARepeatedPrefix() async throws {
        let long = String(repeating: "Background for the question. ", count: 120)
        let request = ChatRequest(model: "mock-fast", messages: [ChatRequestMessage(role: .user, parts: [.text(long)])])
        func usage() async throws -> TokenUsage? {
            var usage: TokenUsage?
            for try await chunk in try client().stream(request) {
                if case let .usage(value) = chunk { usage = value }
            }
            return usage
        }
        _ = try await usage()
        let second = try #require(try await usage())
        #expect(second.promptTokens > 0)
        #expect(second.cachedTokens > second.promptTokens / 2, "\(second)")
    }

    @Test func listsModels() async throws {
        #expect(try await client().listModels() == ["mock-fast", "mock-vision"])
    }

    @Test func wrongKeyGivesTheServiceMessage() async throws {
        await #expect(throws: ChatServiceError.api(message: "Incorrect API key provided.")) {
            _ = try await ask("hello", client: client(apiKey: "wrong"))
        }
    }

    @Test func serverErrorGivesTheServiceMessage() async throws {
        await #expect(throws: ChatServiceError.api(message: "The server had an error.")) {
            _ = try await ask("fail", client: client())
        }
    }

    @Test func unreachableServiceIsANetworkError() async throws {
        let offline = try OpenAICompatibleClient(baseURL: "http://127.0.0.1:9/v1", apiKey: "test-key")
        do {
            _ = try await ask("hello", client: offline)
            Issue.record("Expected a network error")
        } catch let error as ChatServiceError {
            guard case .network = error else {
                Issue.record("Expected a network error, got \(error)")
                return
            }
        }
    }

    @Test func cancellingStopsTheStream() async throws {
        let client = try client()
        let request = ChatRequest(model: "mock-fast", messages: [ChatRequestMessage(role: .user, parts: [.text("slow")])])
        let task = Task {
            var chunks = 0
            for try await _ in client.reply(to: request) {
                chunks += 1
                if chunks == 2 { break }
            }
            return chunks
        }
        let received = try await task.value
        #expect(received == 2)
    }

    @Test func imagesAreSentAsContentParts() async throws {
        let request = ChatRequest(model: "mock-vision", messages: [ChatRequestMessage(role: .user, parts: [
            .text("what is this"), .image(data: Data([0x89, 0x50]), mimeType: "image/png"),
        ])])
        var reply = ""
        for try await chunk in try client().reply(to: request) {
            reply += chunk
        }
        #expect(reply == "I can see 1 image(s).")

        let (data, _) = try await URLSession.shared.data(from: URL(string: mockBaseURL! + "/last-request")!)
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let messages = body?["messages"] as? [[String: Any]]
        let parts = messages?.last?["content"] as? [[String: Any]]
        let image = parts?.first { $0["type"] as? String == "image_url" }?["image_url"] as? [String: Any]
        #expect((image?["url"] as? String)?.hasPrefix("data:image/png;base64,") == true)
    }
}

/// The stream shapes deepseek-harness catalogues for DeepSeek, decoded without a server.
struct StreamLineTests {
    @Test func keepAliveCommentsAndEmptyChunksAreSkipped() throws {
        #expect(try StreamLine.decode(": keep-alive") == .ignored)
        #expect(try StreamLine.decode("") == .ignored)
        #expect(try StreamLine.decode("data: {}") == .ignored)
        #expect(try StreamLine.decode(#"data: {"choices": []}"#) == .ignored)
        #expect(try StreamLine.decode(#"data: {"choices":[{"index":0,"delta":{"content":null}}]}"#) == .ignored)
        #expect(try StreamLine.decode("data: [DONE]") == .done)
    }

    @Test func thinkingAndTextAreTold() throws {
        #expect(try StreamLine.decode(#"data: {"choices":[{"delta":{"reasoning_content":"Hmm"}}]}"#) == .chunks([.reasoning("Hmm")]))
        #expect(try StreamLine.decode(#"data: {"choices":[{"delta":{"reasoning":"Hmm"}}]}"#) == .chunks([.reasoning("Hmm")]))
        #expect(try StreamLine.decode(#"data:{"choices":[{"delta":{"content":"Hi"}}]}"#) == .chunks([.text("Hi")]))
    }

    @Test func cacheHitsAreReadFromEitherField() throws {
        let deepSeek = #"data: {"choices":[],"usage":{"prompt_tokens":1300,"completion_tokens":40,"prompt_cache_hit_tokens":1280,"prompt_cache_miss_tokens":20}}"#
        #expect(try StreamLine.decode(deepSeek) == .chunks([.usage(TokenUsage(promptTokens: 1300, completionTokens: 40, cachedTokens: 1280))]))
        let openAI = #"data: {"choices":[],"usage":{"prompt_tokens":1300,"completion_tokens":40,"prompt_tokens_details":{"cached_tokens":1024}}}"#
        #expect(try StreamLine.decode(openAI) == .chunks([.usage(TokenUsage(promptTokens: 1300, completionTokens: 40, cachedTokens: 1024))]))
    }

    @Test func anErrorInTheStreamIsThrown() {
        #expect(throws: ChatServiceError.api(message: "Overloaded")) {
            try StreamLine.decode(#"data: {"error":{"message":"Overloaded"}}"#)
        }
    }

    @Test func theRequestBodyIsTheSameEveryTime() throws {
        let client = try OpenAICompatibleClient(baseURL: "https://api.deepseek.com/v1", apiKey: "key")
        let request = ChatRequest(model: "deepseek-chat", messages: [
            ChatRequestMessage(role: .user, parts: [.text("Hello")]),
            ChatRequestMessage(role: .assistant, parts: [.text("Hi! How can I help?")]),
            ChatRequestMessage(role: .user, parts: [.text("A question")]),
        ])
        let first = try client.makeStreamRequest(request)
        let second = try client.makeStreamRequest(request)
        #expect(first.httpBody == second.httpBody)
        #expect(first.url?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
        let body = String(decoding: first.httpBody ?? Data(), as: UTF8.self)
        // The conversation comes first, so a later turn starts with the same bytes as this one.
        #expect(body.hasPrefix(#"{"messages":[{"content":"Hello","role":"user"}"#), "\(body)")
        #expect(body.contains(#""stream_options":{"include_usage":true}"#))
    }

    @Test func thinkingLevelsFollowEachService() throws {
        func body(_ baseURL: String, _ level: ThinkingLevel, system: String = "") throws -> [String: Any] {
            let client = try OpenAICompatibleClient(baseURL: baseURL, apiKey: "key")
            let request = ChatRequest(
                model: "m", messages: [ChatRequestMessage(role: .user, parts: [.text("Hi")])], systemPrompt: system, thinking: level
            )
            let data = try #require(try client.makeStreamRequest(request).httpBody)
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let deepSeek = "https://api.deepseek.com/v1"
        #expect(try body(deepSeek, .automatic)["thinking"] == nil)
        #expect((try body(deepSeek, .off)["thinking"] as? [String: String]) == ["type": "disabled"])
        #expect(try body(deepSeek, .off)["reasoning_effort"] == nil)
        #expect((try body(deepSeek, .max)["thinking"] as? [String: String]) == ["type": "enabled"])
        #expect(try body(deepSeek, .max)["reasoning_effort"] as? String == "max")
        #expect(try body(deepSeek, .medium)["reasoning_effort"] as? String == "high")

        let openAI = "https://api.openai.com/v1"
        #expect(try body(openAI, .automatic)["reasoning_effort"] == nil)
        #expect(try body(openAI, .off)["reasoning_effort"] as? String == "none")
        #expect(try body(openAI, .medium)["reasoning_effort"] as? String == "medium")
        #expect(try body(openAI, .high)["thinking"] == nil)

        let messages = try body(openAI, .automatic, system: "Be brief.")["messages"] as? [[String: Any]]
        #expect(messages?.first?["role"] as? String == "system")
        #expect(messages?.first?["content"] as? String == "Be brief.")
    }
}
