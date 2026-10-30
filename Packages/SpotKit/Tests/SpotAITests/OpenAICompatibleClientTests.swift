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
