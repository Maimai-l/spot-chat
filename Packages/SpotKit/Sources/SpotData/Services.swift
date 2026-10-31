import Foundation
import GRDB
import SpotCore

public enum DataError: Error, Equatable {
    case notFound
    case invalidModelID
    case builtInProvider
    case emptyName
}

// MARK: Topics

public struct TopicService: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    @discardableResult
    public func create(id: UUID = UUID(), name: String = "", at date: Date = Date()) throws -> TopicSummary {
        let now = Timestamp.milliseconds(date)
        let record = TopicRecord(
            id: id.uuidString, name: name, isNameManuallyEdited: false,
            lastActivityAt: now, createdAt: now, updatedAt: now, assistantId: nil,
            commandFolder: nil, agentSessionId: nil
        )
        try database.writer.write { db in try record.insert(db) }
        return TopicSummary(id: id, name: name, lastActivityAt: date)
    }

    /// Most recently active first.
    public func list() throws -> [TopicSummary] {
        try database.writer.read { db in
            try TopicRecord
                .order(Column("lastActivityAt").desc, Column("createdAt").desc)
                .fetchAll(db)
        }.compactMap(Self.summary)
    }

    public func get(_ id: UUID) throws -> TopicSummary? {
        try database.writer.read { db in
            try TopicRecord.fetchOne(db, key: id.uuidString)
        }.flatMap(Self.summary)
    }

    /// A name the user typed. Automatic names never replace it.
    public func rename(_ id: UUID, to name: String) throws {
        try update(id) { record in
            record.name = name
            record.isNameManuallyEdited = true
        }
    }

    /// Sets a generated name unless the user has renamed the conversation.
    public func setAutomaticName(_ id: UUID, to name: String) throws {
        try update(id) { record in
            guard !record.isNameManuallyEdited else { return }
            record.name = name
        }
    }

    /// The assistant preset the conversation uses, if any.
    public func assistantID(of id: UUID) throws -> UUID? {
        try database.writer.read { db in
            try TopicRecord.fetchOne(db, key: id.uuidString)?.assistantId.flatMap(UUID.init(uuidString:))
        }
    }

    public func setAssistant(_ assistantID: UUID?, for id: UUID) throws {
        try update(id) { record in
            record.assistantId = assistantID?.uuidString
        }
    }

    /// The folder the conversation runs commands in, and dsh's session for it.
    public func commandSetup(of id: UUID) throws -> CommandSetup? {
        try database.writer.read { db in
            try TopicRecord.fetchOne(db, key: id.uuidString)
        }.flatMap { record in
            record.commandFolder.map { CommandSetup(folder: URL(fileURLWithPath: $0), sessionID: record.agentSessionId) }
        }
    }

    /// Turns commands on in `folder`, or off with nil. A new folder starts a new dsh session.
    public func setCommandFolder(_ folder: URL?, for id: UUID) throws {
        try update(id) { record in
            if record.commandFolder != folder?.path { record.agentSessionId = nil }
            record.commandFolder = folder?.path
        }
    }

    public func setAgentSession(_ sessionID: String?, for id: UUID) throws {
        try update(id) { record in
            record.agentSessionId = sessionID
        }
    }

    public func touch(_ id: UUID, at date: Date = Date()) throws {
        try update(id) { record in
            record.lastActivityAt = Timestamp.milliseconds(date)
        }
    }

    /// Deletes the conversation with its messages.
    public func delete(_ id: UUID) throws {
        _ = try database.writer.write { db in
            try TopicRecord.deleteOne(db, key: id.uuidString)
        }
    }

    private func update(_ id: UUID, _ change: @escaping @Sendable (inout TopicRecord) -> Void) throws {
        try database.writer.write { db in
            guard var record = try TopicRecord.fetchOne(db, key: id.uuidString) else { throw DataError.notFound }
            change(&record)
            record.updatedAt = Timestamp.milliseconds(Date())
            try record.update(db)
        }
    }

    static func summary(_ record: TopicRecord) -> TopicSummary? {
        guard let id = UUID(uuidString: record.id) else { return nil }
        return TopicSummary(
            id: id, name: record.name, lastActivityAt: Timestamp.date(record.lastActivityAt),
            runsCommands: record.commandFolder != nil
        )
    }
}

// MARK: Assistants

/// Assistant presets: a name, a system prompt and optionally a model and effort, as in Cherry Studio.
/// There is no screen for them yet.
public struct AssistantService: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Oldest first.
    public func list() throws -> [AssistantPreset] {
        try database.writer.read { db in
            try AssistantRecord.order(Column("createdAt"), Column("rowid")).fetchAll(db)
        }.compactMap(Self.preset)
    }

    public func get(_ id: UUID) throws -> AssistantPreset? {
        try database.writer.read { db in try AssistantRecord.fetchOne(db, key: id.uuidString) }.flatMap(Self.preset)
    }

    @discardableResult
    public func create(
        name: String, prompt: String = "", emoji: String = "🌟", description: String = "",
        modelID: String? = nil, thinking: ThinkingLevel? = nil
    ) throws -> AssistantPreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DataError.emptyName }
        let now = Timestamp.milliseconds(Date())
        let record = AssistantRecord(
            id: UUID().uuidString, name: trimmed, prompt: prompt, emoji: emoji, description: description,
            modelId: modelID, settings: .init(reasoningEffort: thinking), createdAt: now, updatedAt: now
        )
        try database.writer.write { db in try record.insert(db) }
        guard let preset = Self.preset(record) else { throw DataError.notFound }
        return preset
    }

    public func update(_ preset: AssistantPreset) throws {
        try database.writer.write { db in
            guard var record = try AssistantRecord.fetchOne(db, key: preset.id.uuidString) else { throw DataError.notFound }
            record.name = preset.name
            record.prompt = preset.prompt
            record.emoji = preset.emoji
            record.description = preset.description
            record.modelId = preset.modelID
            record.settings = .init(reasoningEffort: preset.thinking)
            record.updatedAt = Timestamp.milliseconds(Date())
            try record.update(db)
        }
    }

    /// Conversations that used it keep going without one.
    public func delete(_ id: UUID) throws {
        _ = try database.writer.write { db in try AssistantRecord.deleteOne(db, key: id.uuidString) }
    }

    static func preset(_ record: AssistantRecord) -> AssistantPreset? {
        guard let id = UUID(uuidString: record.id) else { return nil }
        return AssistantPreset(
            id: id, name: record.name, prompt: record.prompt, emoji: record.emoji, description: record.description,
            modelID: record.modelId, thinking: record.settings.reasoningEffort
        )
    }
}

// MARK: Messages

public struct MessageService: Sendable {
    let database: AppDatabase
    let files: FileEntryService

    public init(database: AppDatabase, files: FileEntryService) {
        self.database = database
        self.files = files
    }

    /// Oldest first, with attachments.
    public func list(topicID: UUID) throws -> [ChatMessage] {
        let directory = files.directory
        return try database.writer.read { db in
            let records = try MessageRecord
                .filter(Column("topicId") == topicID.uuidString)
                .order(Column("createdAt"), Column("rowid"))
                .fetchAll(db)
            let rows = try Row.fetchAll(db, sql: """
                SELECT r.sourceId AS sourceId, f.id AS id, f.name AS name, f.ext AS ext, f.size AS size
                FROM chat_message_file_ref r
                JOIN file_entry f ON f.id = r.fileEntryId
                JOIN message m ON m.id = r.sourceId
                WHERE m.topicId = ?
                ORDER BY r.createdAt, r.rowid
                """, arguments: [topicID.uuidString])
            var attachments: [String: [Attachment]] = [:]
            for row in rows {
                let entryID: String = row["id"]
                guard let id = UUID(uuidString: entryID) else { continue }
                let ext: String? = row["ext"]
                let attachment = Attachment(
                    id: id, name: row["name"], ext: ext, size: row["size"] ?? 0,
                    fileURL: FileEntryService.fileURL(directory: directory, id: entryID, ext: ext)
                )
                attachments[row["sourceId"], default: []].append(attachment)
            }
            return records.compactMap { record in
                Self.message(record, attachments: attachments[record.id] ?? [])
            }
        }
    }

    /// Conversations with a message containing `text`, ignoring case, using the `searchableText`
    /// column Cherry Studio keeps for this.
    public func topicIDs(containing text: String) throws -> Set<UUID> {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return try database.writer.read { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT DISTINCT topicId FROM message WHERE instr(lower(searchableText), lower(?)) > 0
                """, arguments: [query])
            return Set(ids.compactMap(UUID.init(uuidString:)))
        }
    }

    /// Adds a message after the last one in the conversation and marks the conversation active.
    public func append(_ message: ChatMessage, to topicID: UUID) throws {
        let topic = topicID.uuidString
        try database.writer.write { db in
            let parent = try String.fetchOne(db, sql: """
                SELECT id FROM message WHERE topicId = ? ORDER BY createdAt DESC, rowid DESC LIMIT 1
                """, arguments: [topic])
            let record = Self.record(message, topicID: topic, parentID: parent)
            try record.insert(db)
            for attachment in message.attachments {
                try ChatMessageFileRefRecord(
                    id: UUID().uuidString, fileEntryId: attachment.id.uuidString, sourceId: record.id,
                    role: ChatMessageFileRefRecord.attachmentRole, createdAt: record.createdAt, updatedAt: record.createdAt
                ).insert(db)
            }
            try db.execute(
                sql: "UPDATE topic SET lastActivityAt = ?, updatedAt = ? WHERE id = ?",
                arguments: [record.createdAt, record.createdAt, topic]
            )
        }
    }

    /// Saves the text, status, error and model of an existing message.
    public func update(_ message: ChatMessage) throws {
        try database.writer.write { db in
            guard var record = try MessageRecord.fetchOne(db, key: message.id.uuidString) else { throw DataError.notFound }
            record.data = Self.payload(message)
            record.searchableText = message.text
            record.status = message.status.rawValue
            record.modelId = message.modelID
            record.updatedAt = Timestamp.milliseconds(Date())
            try record.update(db)
        }
    }

    public func delete(_ id: UUID) throws {
        _ = try database.writer.write { db in
            try MessageRecord.deleteOne(db, key: id.uuidString)
        }
    }

    static func record(_ message: ChatMessage, topicID: String, parentID: String?) -> MessageRecord {
        let created = Timestamp.milliseconds(message.createdAt)
        return MessageRecord(
            id: message.id.uuidString, parentId: parentID, topicId: topicID, role: message.role.rawValue,
            data: payload(message), searchableText: message.text,
            status: message.status.rawValue, modelId: message.modelID, createdAt: created, updatedAt: created
        )
    }

    static func payload(_ message: ChatMessage) -> MessageRecord.Payload {
        .init(
            content: message.text, error: message.errorMessage,
            reasoning: message.reasoning.isEmpty ? nil : message.reasoning, reasoningDuration: message.reasoningDuration,
            usage: message.usage,
            commands: message.commands.isEmpty ? nil : message.commands,
            paths: message.paths.isEmpty ? nil : message.paths
        )
    }

    static func message(_ record: MessageRecord, attachments: [Attachment]) -> ChatMessage? {
        guard let id = UUID(uuidString: record.id),
              let role = ChatRole(rawValue: record.role),
              let status = MessageStatus(rawValue: record.status)
        else { return nil }
        return ChatMessage(
            id: id, role: role, text: record.data.content, status: status, errorMessage: record.data.error,
            attachments: attachments, modelID: record.modelId, createdAt: Timestamp.date(record.createdAt),
            reasoning: record.data.reasoning ?? "", reasoningDuration: record.data.reasoningDuration,
            usage: record.data.usage, commands: record.data.commands ?? [], paths: record.data.paths ?? []
        )
    }
}

// MARK: Files

public struct FileEntryService: Sendable {
    let database: AppDatabase
    /// Where attachment copies are kept.
    public let directory: URL

    public init(database: AppDatabase, directory: URL) {
        self.database = database
        self.directory = directory
    }

    /// Copies a file the user picked so the conversation keeps working if the original moves.
    public func importFile(at url: URL) throws -> Attachment {
        let data = try Data(contentsOf: url)
        return try importData(data, fileName: url.lastPathComponent)
    }

    public func importData(_ data: Data, fileName: String) throws -> Attachment {
        let (name, ext) = Attachment.split(fileName: fileName)
        let id = UUID()
        let destination = Self.fileURL(directory: directory, id: id.uuidString, ext: ext)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        let now = Timestamp.milliseconds(Date())
        let record = FileEntryRecord(
            id: id.uuidString, origin: "internal", name: name, ext: ext, size: Int64(data.count),
            createdAt: now, updatedAt: now
        )
        try database.writer.write { db in try record.insert(db) }
        return Attachment(id: id, name: name, ext: ext, size: Int64(data.count), fileURL: destination)
    }

    /// Attachments by id, in the order asked, skipping any that no longer exist.
    public func attachments(withIDs ids: [UUID]) throws -> [Attachment] {
        let directory = self.directory
        let records = try database.writer.read { db in
            try FileEntryRecord.fetchAll(db, keys: ids.map(\.uuidString))
        }
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        return ids.compactMap { id in
            guard let record = byID[id.uuidString] else { return nil }
            let url = Self.fileURL(directory: directory, id: record.id, ext: record.ext)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Attachment(id: id, name: record.name, ext: record.ext, size: record.size ?? 0, fileURL: url)
        }
    }

    static func fileURL(directory: URL, id: String, ext: String?) -> URL {
        let fileName = ext.map { "\(id).\($0)" } ?? id
        return directory.appendingPathComponent(fileName)
    }
}

// MARK: Providers and models

public struct ProviderService: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// In the order they were added, each with its models.
    public func list() throws -> [Provider] {
        try database.writer.read { db in
            let providers = try UserProviderRecord.order(Column("order_key")).fetchAll(db)
            let models = try UserModelRecord
                .filter(Column("isEnabled") == true)
                .order(Column("order_key"))
                .fetchAll(db)
            let byProvider = Dictionary(grouping: models, by: \.providerId)
            let listed = providers.map { record in
                Provider(
                    id: record.providerId, name: record.name, baseURL: record.baseURL, apiKey: record.apiKey,
                    isEnabled: record.isEnabled,
                    models: (byProvider[record.providerId] ?? []).map {
                        ProviderModel(providerID: $0.providerId, modelID: $0.modelId)
                    }
                )
            }
            // Built-in providers first, in their own order; then the user's, in the order added.
            let builtIn = ProviderTemplate.all.compactMap { template in listed.first { $0.id == template.id } }
            return builtIn + listed.filter { !$0.isBuiltIn }
        }
    }

    /// Adds the built-in providers that are missing. Empty copies of them left by an earlier alpha,
    /// with no key and no models, are removed; copies with a key stay as the user's own providers.
    public func ensureBuiltInProviders() throws {
        try database.writer.write { db in
            for template in ProviderTemplate.all {
                let leftovers = try UserProviderRecord
                    .filter(Column("name") == template.name && Column("providerId") != template.id)
                    .fetchAll(db)
                    .filter { $0.baseURL == template.baseURL && $0.apiKey.isEmpty }
                for leftover in leftovers {
                    let models = try UserModelRecord.filter(Column("providerId") == leftover.providerId).fetchCount(db)
                    if models == 0 { try leftover.delete(db) }
                }
                guard try !UserProviderRecord.exists(db, key: template.id) else { continue }
                let now = Timestamp.milliseconds(Date())
                let count = try UserProviderRecord.fetchCount(db)
                try UserProviderRecord(
                    providerId: template.id, name: template.name,
                    endpointConfigs: [UserProviderRecord.chatEndpoint: .init(baseUrl: template.baseURL)],
                    apiKeys: [], isEnabled: true, orderKey: OrderKey.make(count), createdAt: now, updatedAt: now
                ).insert(db)
            }
        }
    }

    public func setEnabled(_ id: String, _ isEnabled: Bool) throws {
        try database.writer.write { db in
            guard var record = try UserProviderRecord.fetchOne(db, key: id) else { throw DataError.notFound }
            record.isEnabled = isEnabled
            record.updatedAt = Timestamp.milliseconds(Date())
            try record.update(db)
        }
    }

    @discardableResult
    public func create(name: String, baseURL: String, apiKey: String) throws -> Provider {
        let id = UUID().uuidString
        let now = Timestamp.milliseconds(Date())
        try database.writer.write { db in
            let count = try UserProviderRecord.fetchCount(db)
            try UserProviderRecord(
                providerId: id, name: name,
                endpointConfigs: [UserProviderRecord.chatEndpoint: .init(baseUrl: baseURL)],
                apiKeys: apiKey.isEmpty ? [] : [.init(id: UUID().uuidString, key: apiKey, isEnabled: true)],
                isEnabled: true, orderKey: OrderKey.make(count), createdAt: now, updatedAt: now
            ).insert(db)
        }
        return Provider(id: id, name: name, baseURL: baseURL, apiKey: apiKey)
    }

    /// Saves the name, base URL and API key.
    public func update(_ provider: Provider) throws {
        try database.writer.write { db in
            guard var record = try UserProviderRecord.fetchOne(db, key: provider.id) else { throw DataError.notFound }
            record.name = provider.name
            record.endpointConfigs = [UserProviderRecord.chatEndpoint: .init(baseUrl: provider.baseURL)]
            record.apiKeys = provider.apiKey.isEmpty ? [] : [.init(id: record.apiKeys.first?.id ?? UUID().uuidString, key: provider.apiKey, isEnabled: true)]
            record.updatedAt = Timestamp.milliseconds(Date())
            try record.update(db)
        }
    }

    /// Deletes the provider and its models. Built-in providers can only be turned off.
    public func delete(_ id: String) throws {
        guard !ProviderTemplate.all.contains(where: { $0.id == id }) else { throw DataError.builtInProvider }
        _ = try database.writer.write { db in
            try UserProviderRecord.deleteOne(db, key: id)
        }
    }
}

public struct ModelService: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Adds a model by its id. Adding one that is already there does nothing.
    @discardableResult
    public func add(modelID: String, to providerID: String) throws -> ProviderModel {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DataError.invalidModelID }
        _ = try merge(modelIDs: [trimmed], into: providerID)
        return ProviderModel(providerID: providerID, modelID: trimmed)
    }

    /// Adds the models that are not in the list yet and returns how many were added.
    public func merge(modelIDs: [String], into providerID: String) throws -> Int {
        try database.writer.write { db in
            guard try UserProviderRecord.exists(db, key: providerID) else { throw DataError.notFound }
            var count = try UserModelRecord.filter(Column("providerId") == providerID).fetchCount(db)
            var added = 0
            let now = Timestamp.milliseconds(Date())
            for modelID in modelIDs {
                let id = ProviderModel.makeID(providerID: providerID, modelID: modelID)
                if try UserModelRecord.exists(db, key: id) { continue }
                try UserModelRecord(
                    id: id, providerId: providerID, modelId: modelID, name: nil, isEnabled: true,
                    orderKey: OrderKey.make(count), createdAt: now, updatedAt: now
                ).insert(db)
                count += 1
                added += 1
            }
            return added
        }
    }

    public func remove(_ id: String) throws {
        _ = try database.writer.write { db in
            try UserModelRecord.deleteOne(db, key: id)
        }
    }
}

// MARK: Preferences

public enum PreferenceKey {
    /// The `user_model` id used for new messages.
    public static let defaultModel = "chat.default_model"
    /// Minutes a closed card stays recoverable; 0 clears it immediately.
    public static let miniRetentionMinutes = "mini_window.retention_minutes"
    /// Height of the expanded card in points.
    public static let cardHeight = "mini_window.card_height"
    /// Whether opening the mini window brings the selected text.
    public static let bringSelection = "mini_window.bring_selection"
    /// Set once macOS has been asked for Accessibility access, so it is asked only once.
    public static let selectionAccessRequested = "mini_window.selection_access_requested"
    /// The system prompt sent before every conversation.
    public static let systemPrompt = "chat.system_prompt"
    /// Thinking level by `user_model` id.
    public static let thinkingLevels = "chat.thinking_levels"
    /// `user_model` ids whose service turned down an effort level; none is sent to them.
    public static let modelsWithoutEffort = "chat.models_without_effort"
    /// The folder new conversations run commands in.
    public static let commandFolder = "commands.default_folder"
}

/// Key-value settings, stored as JSON like Cherry Studio's preference table.
public struct PreferenceService: Sendable {
    let database: AppDatabase
    let scope = "default"

    public init(database: AppDatabase) {
        self.database = database
    }

    public func value<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T? {
        let text = try database.writer.read { [scope] db in
            try String.fetchOne(db, sql: "SELECT value FROM preference WHERE scope = ? AND key = ?", arguments: [scope, key])
        }
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }

    public func set<T: Encodable>(_ key: String, to value: T) throws {
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        let now = Timestamp.milliseconds(Date())
        try database.writer.write { [scope] db in
            try db.execute(sql: """
                INSERT INTO preference (scope, key, value, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (scope, key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt
                """, arguments: [scope, key, text, now, now])
        }
    }

    public func remove(_ key: String) throws {
        try database.writer.write { [scope] db in
            try db.execute(sql: "DELETE FROM preference WHERE scope = ? AND key = ?", arguments: [scope, key])
        }
    }
}
