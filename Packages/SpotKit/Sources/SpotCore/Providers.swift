import Foundation

/// An OpenAI-compatible service the user has added in settings.
public struct Provider: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var baseURL: String
    public var apiKey: String
    /// A turned-off provider keeps its settings but offers no models.
    public var isEnabled: Bool
    public var models: [ProviderModel]

    public init(
        id: String, name: String, baseURL: String, apiKey: String, isEnabled: Bool = true, models: [ProviderModel] = []
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.isEnabled = isEnabled
        self.models = models
    }

    /// Built-in providers are always listed and can be turned off but not deleted.
    public var isBuiltIn: Bool {
        ProviderTemplate.all.contains { $0.id == id }
    }
}

/// A provider built into the app, listed with its address filled in so it only needs a key.
/// Its id is also the provider's id, as with Cherry Studio's preset providers.
public struct ProviderTemplate: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let baseURL: String

    public static let deepSeek = ProviderTemplate(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1")
    public static let openAI = ProviderTemplate(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1")

    /// In the order they are listed.
    public static let all: [ProviderTemplate] = [.deepSeek, .openAI]
}

public struct ProviderModel: Identifiable, Equatable, Hashable, Sendable {
    /// "providerId::modelId", like Cherry Studio's user_model primary key.
    public let id: String
    public let providerID: String
    public let modelID: String

    public init(providerID: String, modelID: String) {
        self.id = Self.makeID(providerID: providerID, modelID: modelID)
        self.providerID = providerID
        self.modelID = modelID
    }

    public static func makeID(providerID: String, modelID: String) -> String {
        "\(providerID)::\(modelID)"
    }
}

/// The pieces of a base URL such as "https://api.openai.com/v1".
public struct ProviderEndpoint: Equatable, Sendable {
    public var scheme: String
    public var host: String
    public var port: Int
    public var basePath: String

    /// Accepts a base URL with or without a scheme, a trailing slash or a pasted "/chat/completions".
    public init?(baseURL: String) {
        var text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "https://" + text
        }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }

        var path = components.path
        for suffix in ["/chat/completions", "/models"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
        }
        while path.hasSuffix("/") {
            path.removeLast()
        }

        self.scheme = scheme
        self.host = host
        self.port = components.port ?? (scheme == "https" ? 443 : 80)
        self.basePath = path
    }

    /// An API address under the base URL, such as "chat/completions".
    public func url(path: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if port != (scheme == "https" ? 443 : 80) {
            components.port = port
        }
        components.path = basePath + "/" + path
        // Built from parts that were parsed from a URL, so it is always valid.
        return components.url ?? URL(fileURLWithPath: "/")
    }
}
