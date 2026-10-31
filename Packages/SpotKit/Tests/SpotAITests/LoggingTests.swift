import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Logging
import Synchronization
import Testing
import SpotCore
@testable import SpotAI

/// Keeps every line logged in the test process, in place of the app's files.
final class CapturedLog: Sendable {
    static let shared = CapturedLog()
    private let lines = Mutex<[String]>([])

    /// LoggingSystem takes one backend per process, so it is installed once for every test.
    static let installed: Void = {
        LoggingSystem.bootstrap { label in Handler(label: label) }
    }()

    func append(_ line: String) {
        lines.withLock { $0.append(line) }
    }

    func lines(containing marker: String) -> [String] {
        lines.withLock { $0.filter { $0.contains(marker) } }
    }

    struct Handler: LogHandler {
        let label: String
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .trace

        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }

        func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
            let fields = self.metadata.merging(metadata ?? [:]) { $1 }
                .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            CapturedLog.shared.append("\(label) \(level) \(message) \(fields)")
        }
    }
}

struct SpotLogTests {
    @Test func inlineDataIsShortenedInLoggedBodies() {
        let body = Data(#"{"url":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAA","text":"hi"}"#.utf8)
        #expect(SpotLog.body(body) == #"{"url":"<inline data, 46 characters>","text":"hi"}"#)
    }

    @Test func longTextKeepsItsStartAndEnd() {
        let clipped = SpotLog.clip(String(repeating: "a", count: 50) + String(repeating: "b", count: 50), limit: 20)
        #expect(clipped.hasPrefix("aaaaaaaaaa …[80 characters left out]… "))
        #expect(clipped.hasSuffix("bbbbbbbbbb"))
    }
}

@Suite(.serialized, .enabled(if: mockBaseURL != nil, "Start scripts/mock_openai_server.py and set MOCK_OPENAI_BASE_URL"))
struct RequestLoggingTests {
    /// The request, every line the service streamed and the assembled reply are logged; the key is not.
    @Test func aReplyIsLoggedInFullWithoutTheKey() async throws {
        CapturedLog.installed
        let marker = "logged-\(UUID().uuidString.prefix(8))"
        let client = try OpenAICompatibleClient(baseURL: mockBaseURL!, apiKey: "test-key")
        let request = ChatRequest(model: "mock-fast", messages: [ChatRequestMessage(role: .user, parts: [.text(marker)])])
        var reply = ""
        for try await chunk in client.reply(to: request) { reply += chunk }
        #expect(reply == "Echo: \(marker)")

        // The reply arrives in pieces, so its lines are found by the request's identifier.
        let body = try #require(CapturedLog.shared.lines(containing: marker).first { $0.contains("Request body") }, "The body is logged")
        let id = try #require(body.split(separator: " ").first { $0.hasPrefix("request=") })
        let lines = CapturedLog.shared.lines(containing: String(id))
        #expect(lines.contains { $0.contains("Line") && $0.contains("data:") }, "Each streamed line is logged")
        #expect(lines.contains { $0.contains("Reply text") && $0.contains("Echo: \(marker)") }, "The assembled reply is logged")
        let all = CapturedLog.shared.lines(containing: "spotchat.")
        #expect(!all.contains { $0.contains("test-key") }, "The API key is never logged")
    }
}
