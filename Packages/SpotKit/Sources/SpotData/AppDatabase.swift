import Foundation
import GRDB

/// The single SQLite file that holds conversations, attachments, providers, models and settings.
/// Tables and columns follow Cherry Studio's `src/main/data/db/schemas`, keeping only what Spot Chat uses.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public static func onDisk(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try AppDatabase(DatabasePool(path: url.path))
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE user_provider (
                    providerId TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    endpointConfigs TEXT,
                    apiKeys TEXT NOT NULL DEFAULT '[]',
                    isEnabled INTEGER NOT NULL DEFAULT 1,
                    order_key TEXT NOT NULL,
                    createdAt INTEGER NOT NULL,
                    updatedAt INTEGER NOT NULL
                );

                CREATE TABLE user_model (
                    id TEXT PRIMARY KEY NOT NULL,
                    providerId TEXT NOT NULL REFERENCES user_provider(providerId) ON DELETE CASCADE,
                    modelId TEXT NOT NULL,
                    name TEXT,
                    isEnabled INTEGER NOT NULL DEFAULT 1,
                    order_key TEXT NOT NULL,
                    createdAt INTEGER NOT NULL,
                    updatedAt INTEGER NOT NULL
                );
                CREATE INDEX user_model_provider_idx ON user_model(providerId);

                CREATE TABLE topic (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL DEFAULT '',
                    isNameManuallyEdited INTEGER NOT NULL DEFAULT 0,
                    lastActivityAt INTEGER NOT NULL,
                    createdAt INTEGER NOT NULL,
                    updatedAt INTEGER NOT NULL
                );
                CREATE INDEX topic_last_activity_at_idx ON topic(lastActivityAt);

                CREATE TABLE message (
                    id TEXT PRIMARY KEY NOT NULL,
                    parentId TEXT REFERENCES message(id) ON DELETE CASCADE,
                    topicId TEXT NOT NULL REFERENCES topic(id) ON DELETE CASCADE,
                    role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
                    data TEXT NOT NULL,
                    searchableText TEXT NOT NULL DEFAULT '',
                    status TEXT NOT NULL CHECK (status IN ('pending', 'success', 'error', 'paused')),
                    modelId TEXT REFERENCES user_model(id) ON DELETE SET NULL,
                    createdAt INTEGER NOT NULL,
                    updatedAt INTEGER NOT NULL
                );
                CREATE INDEX message_topic_created_idx ON message(topicId, createdAt);
                CREATE INDEX message_parent_id_idx ON message(parentId);

                CREATE TABLE file_entry (
                    id TEXT PRIMARY KEY NOT NULL,
                    origin TEXT NOT NULL CHECK (origin IN ('internal', 'external')),
                    name TEXT NOT NULL,
                    ext TEXT,
                    size INTEGER,
                    createdAt INTEGER NOT NULL,
                    updatedAt INTEGER NOT NULL
                );

                CREATE TABLE chat_message_file_ref (
                    id TEXT PRIMARY KEY NOT NULL,
                    fileEntryId TEXT NOT NULL REFERENCES file_entry(id) ON DELETE CASCADE,
                    sourceId TEXT NOT NULL REFERENCES message(id) ON DELETE CASCADE,
                    role TEXT NOT NULL,
                    createdAt INTEGER NOT NULL,
                    updatedAt INTEGER NOT NULL,
                    UNIQUE (fileEntryId, sourceId, role)
                );
                CREATE INDEX cmfr_source_id_idx ON chat_message_file_ref(sourceId);

                CREATE TABLE preference (
                    scope TEXT NOT NULL DEFAULT 'default',
                    key TEXT NOT NULL,
                    value TEXT,
                    createdAt INTEGER NOT NULL,
                    updatedAt INTEGER NOT NULL,
                    PRIMARY KEY (scope, key)
                );
                """)
        }
        return migrator
    }
}

enum Timestamp {
    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }
}
