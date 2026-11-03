import Foundation
import Testing
@testable import SpotCore

/// The app and the reply writer speak in JSON; what one sends the other must read back unchanged.
struct ReplyJobTests {
    @Test func aJobReadsBackAsItWasSent() throws {
        let request = ChatRequest(
            model: "deepseek-flash",
            messages: [
                ChatRequestMessage(role: .user, parts: [.text("What's on Mars?"), .image(data: Data([1, 2, 3]), mimeType: "image/png")]),
                ChatRequestMessage(
                    role: .assistant, parts: [],
                    toolCalls: [ToolCall(id: "call_1", name: "web_search", arguments: #"{"queries":["mars"]}"#)],
                    reasoning: "Search first."
                ),
                .toolResult("Results", for: "call_1"),
            ],
            systemPrompt: "Current date: 2026-11-03",
            thinking: .high,
            tools: [ToolDefinition(name: "web_search", description: "Search the web", parameters: "{}")]
        )
        let job = ReplyJob(
            replyID: UUID(), topicID: UUID(), providerID: "deepseek", request: request, question: "What's on Mars?",
            webToolsURL: "https://api.deepseek.com/v1/tools", dataDirectory: "/tmp/SpotChat"
        )
        let decoded = try JSONDecoder().decode(ReplyJob.self, from: JSONEncoder().encode(job))
        #expect(decoded == job)
    }

    @Test func everyLineReadsBackAsItWasPrinted() throws {
        var step = CommandRun(id: "call_1", tool: .webSearch, summary: "", detail: "mars", startedAt: Date(timeIntervalSince1970: 1))
        step.textOffset = 4
        let lines: [ReplyWriterLine] = [
            .progress(ReplyProgress(text: "Mars", reasoning: "Hm", reasoningDuration: 1.5, steps: [step])),
            .usage(TokenUsage(promptTokens: 10, completionTokens: 2, cachedTokens: 8)),
            .effortRejected,
            .finished(failure: nil, stopped: false),
            .finished(failure: "The service returned HTTP 500.", stopped: false),
        ]
        for line in lines {
            let data = try JSONEncoder().encode(line)
            #expect(!data.contains(0x0A), "Each line stays on one line")
            #expect(try JSONDecoder().decode(ReplyWriterLine.self, from: data) == line)
        }
    }
}
