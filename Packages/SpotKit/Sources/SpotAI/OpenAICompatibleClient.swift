import Foundation
import Logging
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenAI
import SpotCore

/// Why a request failed, in terms the interface can show.
public enum ChatServiceError: Error, Equatable, Sendable {
    /// The service answered with an error message, such as an invalid API key.
    case api(message: String)
    /// The service answered with an HTTP error and no readable message.
    case http(statusCode: Int)
    /// The service could not be reached.
    case network(message: String)
    /// The base URL in settings cannot be used.
    case invalidEndpoint
    case other(message: String)

    /// Whether the service turned the request down because of its effort or thinking field, as OpenAI does
    /// for models without reasoning ("Unsupported parameter: 'reasoning_effort' …").
    public var rejectsThinking: Bool {
        switch self {
        case let .api(message):
            let text = message.lowercased()
            return text.contains("reasoning") || text.contains("thinking")
        case let .http(statusCode):
            return statusCode == 400 || statusCode == 422
        default:
            return false
        }
    }

    /// From a response that wasn't a success, using the service's own message when it sent one.
    public init(statusCode: Int, body: Data) {
        struct Body: Decodable {
            struct Detail: Decodable { var message: String? }
            var error: Detail?
        }
        if let message = (try? JSONDecoder().decode(Body.self, from: body))?.error?.message, !message.isEmpty {
            self = .api(message: message)
        } else {
            self = .http(statusCode: statusCode)
        }
    }

    public init(_ error: Error) {
        switch error {
        case let error as ChatServiceError:
            self = error
        case let error as APIErrorResponse:
            self = .api(message: error.error.message)
        case let error as APIError:
            self = .api(message: error.message)
        case let OpenAIError.statusError(_, statusCode):
            self = .http(statusCode: statusCode)
        case let error as URLError:
            self = .network(message: error.localizedDescription)
        default:
            self = .other(message: String(describing: error))
        }
    }
}

/// Talks to any service that implements the OpenAI chat completions API.
public struct OpenAICompatibleClient: ChatResponder {
    public let endpoint: ProviderEndpoint
    public let apiKey: String

    public init(endpoint: ProviderEndpoint, apiKey: String) {
        self.endpoint = endpoint
        self.apiKey = apiKey
    }

    public init(baseURL: String, apiKey: String) throws {
        guard let endpoint = ProviderEndpoint(baseURL: baseURL) else { throw ChatServiceError.invalidEndpoint }
        self.init(endpoint: endpoint, apiKey: apiKey)
    }

    private func makeClient() -> OpenAI {
        OpenAI(configuration: .init(
            token: apiKey.isEmpty ? nil : apiKey,
            host: endpoint.host,
            port: endpoint.port,
            scheme: endpoint.scheme,
            basePath: endpoint.basePath,
            timeoutInterval: 120,
            // Many compatible services leave out fields OpenAI always sends.
            parsingOptions: .relaxed
        ))
    }

    /// Streams the reply, with the thinking of reasoning models and the token usage at the end.
    /// Cancelling the consuming task cancels the request.
    ///
    /// The request is built with the OpenAI library but the stream is read here, to follow DeepSeek's
    /// streaming contract (as catalogued by deepseek-harness): keep-alive comments and chunks without
    /// choices are skipped, thinking arrives as `reasoning_content`, and cache hits are reported as
    /// `prompt_cache_hit_tokens` rather than OpenAI's `cached_tokens`.
    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ReplyChunk, Error> {
        let log = SpotLog.network.with(id: "request")
        let urlRequest: URLRequest
        do {
            urlRequest = try makeStreamRequest(request)
        } catch {
            log.error("Couldn't build the request", metadata: ["error": "\(error)"])
            return AsyncThrowingStream { $0.finish(throwing: ChatServiceError(error)) }
        }
        log.info("Request", metadata: [
            "url": "\(urlRequest.url?.absoluteString ?? "")",
            "model": "\(request.model)",
            "messages": "\(request.messages.count)",
            "tools": "\(request.tools.map(\.name).joined(separator: ","))",
            "thinking": "\(request.thinking)",
        ])
        log.debug("Request body", metadata: ["body": "\(SpotLog.body(urlRequest.httpBody ?? Data()))"])
        return AsyncThrowingStream { continuation in
            let task = Task {
                let started = Date()
                var lineCount = 0
                var text = ""
                var reasoning = ""
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                    log.info("Response", metadata: [
                        "status": "\(status)", "ms": "\(Int(Date().timeIntervalSince(started) * 1000))",
                    ])
                    guard (200..<300).contains(status) else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 65_536 { break }
                        }
                        log.error("Service refused the request", metadata: [
                            "status": "\(status)", "body": "\(SpotLog.clip(String(decoding: body, as: UTF8.self)))",
                        ])
                        throw ChatServiceError(statusCode: status, body: body)
                    }
                    // Services that put the thinking inside the reply as <think>…</think> get it folded too.
                    var tags = ThinkTagSplitter()
                    var toolCalls = ToolCallAssembler()
                    func pass(_ chunks: [ReplyChunk]) {
                        for chunk in chunks {
                            switch chunk {
                            case let .text(part): text += part
                            case let .reasoning(part): reasoning += part
                            default: break
                            }
                            if case let .text(text) = chunk {
                                for part in tags.feed(text) { continuation.yield(part) }
                            } else {
                                continuation.yield(chunk)
                            }
                        }
                    }
                    lines: for try await line in bytes.lines {
                        lineCount += 1
                        // Every line as the service sent it, to tell its mistakes from ours.
                        log.trace("Line", metadata: ["n": "\(lineCount)", "line": "\(SpotLog.clip(line))"])
                        switch try StreamLine.decode(line) {
                        case let .chunks(chunks):
                            pass(chunks)
                        case let .toolDeltas(chunks, deltas):
                            pass(chunks)
                            deltas.forEach { toolCalls.add($0) }
                        case .done:
                            break lines
                        case .ignored:
                            break
                        }
                    }
                    for part in tags.finish() { continuation.yield(part) }
                    let calls = toolCalls.result
                    if !calls.isEmpty { continuation.yield(.toolCalls(calls)) }
                    log.info("Finished", metadata: [
                        "ms": "\(Int(Date().timeIntervalSince(started) * 1000))", "lines": "\(lineCount)",
                        "characters": "\(text.count)", "reasoningCharacters": "\(reasoning.count)",
                        "toolCalls": "\(calls.map(\.name).joined(separator: ","))",
                    ])
                    log.debug("Reply text", metadata: ["text": "\(SpotLog.clip(text))"])
                    continuation.finish()
                } catch is CancellationError {
                    log.info("Cancelled", metadata: ["lines": "\(lineCount)", "characters": "\(text.count)"])
                    continuation.finish(throwing: CancellationError())
                } catch let error as URLError where error.code == .cancelled {
                    log.info("Cancelled", metadata: ["lines": "\(lineCount)", "characters": "\(text.count)"])
                    continuation.finish(throwing: CancellationError())
                } catch {
                    log.error("Failed", metadata: [
                        "error": "\(error)", "lines": "\(lineCount)", "characters": "\(text.count)",
                        "ms": "\(Int(Date().timeIntervalSince(started) * 1000))",
                    ])
                    continuation.finish(throwing: ChatServiceError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The same bytes for the same conversation, so a service's prompt cache can match the prefix:
    /// keys are sorted and nothing in the body changes from one request to the next.
    func makeStreamRequest(_ request: ChatRequest) throws -> URLRequest {
        var messages = request.messages.compactMap(Self.messageParam)
        if !request.systemPrompt.isEmpty {
            messages.insert(.system(.init(content: .textContent(request.systemPrompt))), at: 0)
        }
        let query = ChatQuery(
            messages: messages,
            model: request.model,
            stream: true,
            streamOptions: .init(includeUsage: true)
        )
        var urlRequest = URLRequest(url: endpoint.url(path: "chat/completions"), timeoutInterval: 120)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var body = try encoder.encode(query)
        var extra = Self.thinkingFields(request.thinking, isDeepSeek: endpoint.isDeepSeek)
        if !request.tools.isEmpty {
            extra["tools"] = try request.tools.map { tool -> [String: Any] in
                let parameters = try JSONSerialization.jsonObject(with: Data(tool.parameters.utf8))
                return ["type": "function", "function": ["name": tool.name, "description": tool.description, "parameters": parameters]]
            }
        }
        if !extra.isEmpty, var object = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
            object.merge(extra) { _, new in new }
            body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        urlRequest.httpBody = body
        return urlRequest
    }

    /// DeepSeek's sampling temperature when thinking is off (its default is 1.0).
    static let nonThinkingTemperature = 0.7

    /// The request fields for a thinking level, after Cherry Studio's provider registry
    /// (packages/provider-registry/src/providers/deepseek.ts and reasoningProfiles.ts).
    static func thinkingFields(_ level: ThinkingLevel, isDeepSeek: Bool) -> [String: Any] {
        if isDeepSeek {
            switch level {
            case .automatic: return [:]
            // Without thinking, deepseek-flash fixes top_p at 1.0, so at the default temperature of 1.0 it
            // samples from the whole tail and now and then drops a stray token mid-word ("帮S助"). A lower
            // temperature trims that tail; it has no effect when thinking is on.
            case .off: return ["thinking": ["type": "disabled"], "temperature": Self.nonThinkingTemperature]
            // DeepSeek has no medium; Cherry Studio sends high for it.
            case .low: return ["thinking": ["type": "enabled"], "reasoning_effort": "low"]
            case .medium, .high: return ["thinking": ["type": "enabled"], "reasoning_effort": "high"]
            case .max: return ["thinking": ["type": "enabled"], "reasoning_effort": "max"]
            }
        }
        switch level {
        case .automatic: return [:]
        case .off: return ["reasoning_effort": "none"]
        case .low: return ["reasoning_effort": "low"]
        case .medium: return ["reasoning_effort": "medium"]
        case .high, .max: return ["reasoning_effort": "high"]
        }
    }

    /// The model ids the service offers, sorted.
    public func listModels() async throws -> [String] {
        let log = SpotLog.network.with(id: "request")
        log.info("Listing models", metadata: ["host": "\(endpoint.host)"])
        do {
            let result: ModelsResult = try await makeClient().models()
            log.info("Listed models", metadata: ["models": "\(result.data.map(\.id).sorted().joined(separator: ","))"])
            return result.data.map(\.id).sorted()
        } catch {
            log.error("Couldn't list models", metadata: ["error": "\(error)"])
            throw ChatServiceError(error)
        }
    }

    static func messageParam(_ message: ChatRequestMessage) -> ChatQuery.ChatCompletionMessageParam? {
        let text = message.parts.compactMap { part -> String? in
            if case let .text(text) = part { return text }
            return nil
        }.joined(separator: "\n")
        if let callID = message.toolCallID {
            return .tool(.init(content: .textContent(text), toolCallId: callID))
        }
        switch message.role {
        case .assistant:
            guard !message.toolCalls.isEmpty else {
                return .assistant(.init(content: .textContent(text)))
            }
            // DeepSeek needs the thinking behind tool calls back until the question is answered.
            return .assistant(.init(
                content: text.isEmpty ? nil : .textContent(text),
                reasoningContent: message.reasoning,
                toolCalls: message.toolCalls.map { call in
                    .init(id: call.id, function: .init(arguments: call.arguments, name: call.name))
                }
            ))
        case .user:
            if message.parts.count == 1, case let .text(text) = message.parts[0] {
                return .user(.init(content: .string(text)))
            }
            let parts: [ChatQuery.ChatCompletionMessageParam.UserMessageParam.Content.ContentPart] = message.parts.map { part in
                switch part {
                case let .text(text):
                    return .text(.init(text: text))
                case let .image(data, mimeType):
                    let url = "data:\(mimeType);base64,\(data.base64EncodedString())"
                    return .image(.init(imageUrl: .init(url: url, detail: .auto)))
                }
            }
            return .user(.init(content: .contentParts(parts)))
        }
    }
}
