import Foundation
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

    /// Streams the reply, with the thinking of reasoning models (DeepSeek's `reasoning_content`, or `reasoning`).
    /// Cancelling the consuming task cancels the request.
    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ReplyChunk, Error> {
        let query = ChatQuery(
            messages: request.messages.compactMap(Self.messageParam),
            model: request.model,
            stream: true
        )
        let upstream: AsyncThrowingStream<ChatStreamResult, Error> = makeClient().chatsStream(query: query)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await result in upstream {
                        for choice in result.choices {
                            if let reasoning = choice.delta.reasoning, !reasoning.isEmpty {
                                continuation.yield(.reasoning(reasoning))
                            }
                            if let content = choice.delta.content, !content.isEmpty {
                                continuation.yield(.text(content))
                            }
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: ChatServiceError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The model ids the service offers, sorted.
    public func listModels() async throws -> [String] {
        do {
            let result: ModelsResult = try await makeClient().models()
            return result.data.map(\.id).sorted()
        } catch {
            throw ChatServiceError(error)
        }
    }

    static func messageParam(_ message: ChatRequestMessage) -> ChatQuery.ChatCompletionMessageParam? {
        switch message.role {
        case .assistant:
            let text = message.parts.compactMap { part -> String? in
                if case let .text(text) = part { return text }
                return nil
            }.joined(separator: "\n")
            return .assistant(.init(content: .textContent(text)))
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
