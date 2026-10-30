import Foundation
import GRDB
import SpotCore

struct TopicRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "topic"

    var id: String
    var name: String
    var isNameManuallyEdited: Bool
    var lastActivityAt: Int64
    var createdAt: Int64
    var updatedAt: Int64
}

struct MessageRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "message"

    /// The JSON in the `data` column.
    struct Payload: Codable, Equatable, Sendable {
        var content: String
        var error: String?
        var reasoning: String?
        /// Seconds.
        var reasoningDuration: Double?
        var usage: TokenUsage?
    }

    var id: String
    var parentId: String?
    var topicId: String
    var role: String
    var data: Payload
    var searchableText: String
    var status: String
    var modelId: String?
    var createdAt: Int64
    var updatedAt: Int64
}

struct FileEntryRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "file_entry"

    var id: String
    var origin: String
    var name: String
    var ext: String?
    var size: Int64?
    var createdAt: Int64
    var updatedAt: Int64
}

struct ChatMessageFileRefRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "chat_message_file_ref"
    static let attachmentRole = "attachment"

    var id: String
    var fileEntryId: String
    var sourceId: String
    var role: String
    var createdAt: Int64
    var updatedAt: Int64
}

struct UserProviderRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "user_provider"
    static let chatEndpoint = "openai-chat-completions"

    struct EndpointConfig: Codable, Equatable, Sendable {
        var baseUrl: String?
    }

    struct ApiKeyEntry: Codable, Equatable, Sendable {
        var id: String
        var key: String
        var isEnabled: Bool
    }

    var providerId: String
    var name: String
    var endpointConfigs: [String: EndpointConfig]?
    var apiKeys: [ApiKeyEntry]
    var isEnabled: Bool
    var orderKey: String
    var createdAt: Int64
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case providerId, name, endpointConfigs, apiKeys, isEnabled
        case orderKey = "order_key"
        case createdAt, updatedAt
    }

    var baseURL: String {
        endpointConfigs?[Self.chatEndpoint]?.baseUrl ?? ""
    }

    var apiKey: String {
        apiKeys.first(where: \.isEnabled)?.key ?? ""
    }
}

struct UserModelRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "user_model"

    var id: String
    var providerId: String
    var modelId: String
    var name: String?
    var isEnabled: Bool
    var orderKey: String
    var createdAt: Int64
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, providerId, modelId, name, isEnabled
        case orderKey = "order_key"
        case createdAt, updatedAt
    }
}

struct PreferenceRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "preference"

    var scope: String
    var key: String
    /// JSON text.
    var value: String?
    var createdAt: Int64
    var updatedAt: Int64
}

/// Order keys sort as text, so they are zero-padded integers.
enum OrderKey {
    static func make(_ index: Int) -> String {
        let digits = String(index)
        return String(repeating: "0", count: max(0, 10 - digits.count)) + digits
    }
}
