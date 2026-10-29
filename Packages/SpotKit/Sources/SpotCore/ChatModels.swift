import Foundation

public enum ChatRole: String, Sendable, Codable {
    case user
    case assistant
}

/// Mirrors the `status` column of Cherry Studio's message table.
public enum MessageStatus: String, Sendable, Codable {
    /// The reply is still being generated.
    case pending
    case success
    case error
    /// Generation was stopped by the user; the text so far is kept.
    case paused
}

public struct Attachment: Identifiable, Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable, Codable {
        case image
        case file
    }

    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]

    public let id: UUID
    /// File name without the extension, as in Cherry Studio's file_entry table.
    public var name: String
    /// Extension without the leading dot.
    public var ext: String?
    public var size: Int64
    /// Where the bytes are stored.
    public var fileURL: URL

    public init(id: UUID = UUID(), name: String, ext: String?, size: Int64, fileURL: URL) {
        self.id = id
        self.name = name
        self.ext = ext
        self.size = size
        self.fileURL = fileURL
    }

    public var kind: Kind {
        guard let ext else { return .file }
        return Self.imageExtensions.contains(ext.lowercased()) ? .image : .file
    }

    public var displayName: String {
        guard let ext, !ext.isEmpty else { return name }
        return "\(name).\(ext)"
    }

    /// Splits "report.final.pdf" into ("report.final", "pdf").
    public static func split(fileName: String) -> (name: String, ext: String?) {
        let url = URL(fileURLWithPath: fileName)
        let ext = url.pathExtension
        guard !ext.isEmpty else { return (fileName, nil) }
        return (url.deletingPathExtension().lastPathComponent, ext)
    }
}

public struct ChatMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var role: ChatRole
    public var text: String
    public var status: MessageStatus
    /// Shown in place of the reply when `status` is `.error`.
    public var errorMessage: String?
    public var attachments: [Attachment]
    /// The `user_model` id the reply came from.
    public var modelID: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        status: MessageStatus = .success,
        errorMessage: String? = nil,
        attachments: [Attachment] = [],
        modelID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.status = status
        self.errorMessage = errorMessage
        self.attachments = attachments
        self.modelID = modelID
        self.createdAt = createdAt
    }
}

/// A conversation as listed in history. Cherry Studio calls it a topic.
public struct TopicSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var lastActivityAt: Date

    public init(id: UUID, name: String, lastActivityAt: Date) {
        self.id = id
        self.name = name
        self.lastActivityAt = lastActivityAt
    }
}

public enum TopicName {
    public static let maxLength = 40

    /// A name for a new conversation, taken from the first line of its first message.
    public static func make(fromFirstMessage text: String) -> String {
        let line = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard line.count > maxLength else { return line }
        return String(line.prefix(maxLength)) + "…"
    }
}
