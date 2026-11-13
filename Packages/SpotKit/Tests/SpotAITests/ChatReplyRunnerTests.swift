import Foundation
import Testing
import SpotCore
@testable import SpotAI

/// Answers each request with the next script: chunks streamed a moment apart, then an error or the end.
final class ScriptedResponder: ChatResponder, @unchecked Sendable {
    struct Script: @unchecked Sendable {
        var chunks: [ReplyChunk]
        var error: Error?
        var pause: Duration = .zero
    }

    private let lock = NSLock()
    private var scripts: [Script]
    private var received: [ChatRequest] = []

    init(_ scripts: [Script]) {
        self.scripts = scripts
    }

    var requests: [ChatRequest] {
        lock.withLock { received }
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ReplyChunk, Error> {
        let script = lock.withLock {
            received.append(request)
            return scripts.isEmpty ? Script(chunks: []) : scripts.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                for chunk in script.chunks {
                    if script.pause > .zero { try? await Task.sleep(for: script.pause) }
                    if Task.isCancelled { break }
                    continuation.yield(chunk)
                }
                if let error = script.error { continuation.finish(throwing: error) } else { continuation.finish() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Gives back a fixed result for every call, after `pause`.
struct FixedTools: ToolRunning {
    var pause: Duration = .zero

    func run(_ call: ToolCall, question: String) async -> String {
        if pause > .zero { try? await Task.sleep(for: pause) }
        return "Results for \(question)"
    }
}

/// What the runner reported, in order.
actor ReportedEvents {
    var progress: [ReplyProgress] = []
    var usage: [TokenUsage] = []
    var effortRejected = 0

    func record(_ event: ChatReplyRunner.Event) {
        switch event {
        case let .progress(value): progress.append(value)
        case let .usage(value): usage.append(value)
        case .effortRejected: effortRejected += 1
        }
    }
}

struct ChatReplyRunnerTests {
    let searchCall = ToolCall(id: "call_1", name: "web_search", arguments: #"{"queries":["mars rovers"]}"#)

    func request(thinking: ThinkingLevel = .automatic) -> ChatRequest {
        ChatRequest(model: "test", messages: [ChatRequestMessage(role: .user, parts: [.text("question")])], thinking: thinking)
    }

    func run(
        _ responder: ScriptedResponder, tools: ToolRunning? = nil, request: ChatRequest? = nil, events: ReportedEvents
    ) async -> ChatReplyRunner.Result {
        let runner = ChatReplyRunner(responder: responder, tools: tools, describe: { _ in "described" })
        return await runner.run(request ?? self.request(), question: "question", replyID: UUID()) { await events.record($0) }
    }

    @Test func streamsThinkingThenTextAndTimesTheThinking() async {
        let usage = TokenUsage(promptTokens: 10, completionTokens: 3, cachedTokens: 0)
        let responder = ScriptedResponder([.init(chunks: [
            .reasoning("Two and "), .reasoning("two."), .text("Four"), .text("."), .usage(usage),
        ])])
        let events = ReportedEvents()
        let result = await run(responder, events: events)

        #expect(result.progress.reasoning == "Two and two.")
        #expect(result.progress.text == "Four.")
        #expect(result.progress.reasoningDuration != nil)
        #expect(result.failure == nil)
        #expect(!result.stopped)
        let progress = await events.progress
        #expect(progress.map(\.text) == ["", "", "Four", "Four."], "Each piece is reported as it arrives")
        #expect(progress[1].reasoningDuration == nil, "The thinking is timed once the answer starts")
        #expect(await events.usage == [usage])
    }

    @Test func asksAgainWithoutEffortWhenTheModelTurnsItDown() async {
        let responder = ScriptedResponder([
            .init(chunks: [], error: ChatServiceError.api(message: "Unsupported parameter: 'reasoning_effort'")),
            .init(chunks: [.text("Hi")]),
        ])
        let events = ReportedEvents()
        let result = await run(responder, request: request(thinking: .low), events: events)

        #expect(result.progress.text == "Hi")
        #expect(result.failure == nil)
        #expect(responder.requests.map(\.thinking) == [.low, .automatic])
        #expect(await events.effortRejected == 1)
    }

    @Test func aFailureAfterTextArrivedIsNotAskedAgain() async {
        let responder = ScriptedResponder([
            .init(chunks: [.text("Hal")], error: ChatServiceError.api(message: "reasoning failed")),
        ])
        let result = await run(responder, request: request(thinking: .low), events: ReportedEvents())

        #expect(result.progress.text == "Hal", "What arrived is kept")
        #expect(result.failure == "described")
        #expect(responder.requests.count == 1)
    }

    @Test func runsTheToolsAndGivesTheModelTheirResults() async {
        let responder = ScriptedResponder([
            .init(chunks: [.text("Let me look."), .toolCalls([searchCall])]),
            .init(chunks: [.text("Found it.")]),
        ])
        let result = await run(responder, tools: FixedTools(), events: ReportedEvents())

        #expect(result.progress.text == "Let me look.\n\nFound it.", "Text after a search starts a new paragraph")
        #expect(result.progress.steps.count == 1)
        #expect(result.progress.steps.first?.state == .succeeded)
        #expect(result.progress.steps.first?.textOffset == "Let me look.".count, "The step shows where it began")
        let second = responder.requests[1].messages
        #expect(second.count == 3)
        #expect(second[1].role == .assistant)
        #expect(second[1].toolCalls == [searchCall])
        #expect(second[2].toolCallID == "call_1")
    }

    @Test func callsAreIgnoredWhenNoToolsAreOffered() async {
        let responder = ScriptedResponder([.init(chunks: [.text("Hm."), .toolCalls([searchCall])])])
        let result = await run(responder, tools: nil, events: ReportedEvents())

        #expect(result.progress.text == "Hm.")
        #expect(result.progress.steps.isEmpty)
        #expect(responder.requests.count == 1)
    }

    @Test func aQuestionThatKeepsSearchingStopsAfterTheLastRound() async {
        let rounds = ChatReplyRunner.maxToolRounds
        let responder = ScriptedResponder(Array(repeating: .init(chunks: [.toolCalls([searchCall])]), count: rounds + 2))
        let result = await run(responder, tools: FixedTools(), events: ReportedEvents())

        #expect(responder.requests.count == rounds)
        #expect(result.failure == nil)
    }

    @Test func stoppingKeepsWhatArrivedAndSaysItStopped() async throws {
        let chunks = (0..<100).map { ReplyChunk.text("tick \($0) ") }
        let responder = ScriptedResponder([.init(chunks: chunks, pause: .milliseconds(10))])
        let events = ReportedEvents()
        let task = Task { await run(responder, events: events) }
        // Stopped once text has arrived, however long a busy machine takes to start it.
        for _ in 0..<500 {
            if let text = await events.progress.last?.text, !text.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.value

        #expect(result.stopped)
        #expect(result.failure == nil)
        #expect(result.progress.text.hasPrefix("tick 0 "))
        #expect(!result.progress.text.contains("tick 99"), "It stopped before the end")
    }

    @Test func aStepUnderWayWhenStoppedIsMarkedStopped() async throws {
        let responder = ScriptedResponder([.init(chunks: [.toolCalls([searchCall])]), .init(chunks: [.text("Never")])])
        let task = Task { await run(responder, tools: FixedTools(pause: .seconds(5)), events: ReportedEvents()) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = await task.value

        #expect(result.stopped)
        #expect(result.progress.steps.map(\.state) == [.stopped])
        #expect(responder.requests.count == 1, "The model isn't asked again after the stop")
    }

    @Test func aFailureIsWordedByTheApp() async {
        let responder = ScriptedResponder([.init(chunks: [], error: ChatServiceError.http(statusCode: 500))])
        let result = await run(responder, events: ReportedEvents())

        #expect(result.failure == "described")
        #expect(!result.stopped)
    }
}
