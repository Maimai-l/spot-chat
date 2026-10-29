import Foundation

/// An OpenAI-compatible service the user has added in settings.
public struct Provider: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var baseURL: String
    public var apiKey: String
    public var models: [ProviderModel]

    public init(id: String, name: String, baseURL: String, apiKey: String, models: [ProviderModel] = []) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.models = models
    }
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
}
