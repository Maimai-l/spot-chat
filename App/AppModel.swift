import AppKit
import Combine
import SpotAI
import SpotCore
import SpotData

/// App-wide state: the database, providers and models, settings and conversation history.
@MainActor
final class AppModel: ObservableObject {
    static let defaultCardHeight = 560
    /// The system message of the first request in DeepSeek's API documentation (api-docs.deepseek.com).
    /// Replaced by whatever is set in Settings; an empty setting sends none.
    static let defaultSystemPrompt = "You are a helpful assistant."
    static let cardHeightRange = 400...900

    @Published private(set) var providers: [Provider] = []
    @Published private(set) var defaultModelID: String?
    @Published private(set) var retentionPolicy: RetentionPolicy = .default
    @Published private(set) var cardHeight = AppModel.defaultCardHeight
    @Published private(set) var topics: [TopicSummary] = []
    @Published private(set) var systemPrompt = AppModel.defaultSystemPrompt
    /// Thinking level by model; a model not listed thinks as its service decides.
    @Published private(set) var thinkingLevels: [String: ThinkingLevel] = [:]
    /// Bumped whenever a conversation's messages change outside the session showing it.
    @Published private(set) var historyRevision = 0

    let topicService: TopicService
    let messageService: MessageService
    let fileService: FileEntryService
    let providerService: ProviderService
    let modelService: ModelService
    let preferenceService: PreferenceService
    let assistantService: AssistantService

    init(database: AppDatabase, filesDirectory: URL) {
        fileService = FileEntryService(database: database, directory: filesDirectory)
        topicService = TopicService(database: database)
        messageService = MessageService(database: database, files: fileService)
        providerService = ProviderService(database: database)
        modelService = ModelService(database: database)
        preferenceService = PreferenceService(database: database)
        assistantService = AssistantService(database: database)
        try? providerService.ensureBuiltInProviders()
        reloadProviders()
        reloadPreferences()
        reloadTopics()
    }

    // MARK: Models

    /// The models of the providers that are turned on.
    var allModels: [ProviderModel] {
        providers.filter(\.isEnabled).flatMap(\.models)
    }

    /// The model new messages use: the default if it still exists, otherwise the first one.
    var currentModel: ProviderModel? {
        allModels.first { $0.id == defaultModelID } ?? allModels.first
    }

    func provider(for model: ProviderModel) -> Provider? {
        providers.first { $0.id == model.providerID }
    }

    func thinking(for model: ProviderModel) -> ThinkingLevel {
        thinkingLevels[model.id] ?? .automatic
    }

    func setThinking(_ level: ThinkingLevel, for model: ProviderModel) {
        thinkingLevels[model.id] = level == .automatic ? nil : level
        try? preferenceService.set(PreferenceKey.thinkingLevels, to: thinkingLevels)
    }

    /// Whether the model is served by DeepSeek's own API, whose thinking levels differ.
    func isDeepSeek(_ model: ProviderModel) -> Bool {
        provider(for: model).flatMap { ProviderEndpoint(baseURL: $0.baseURL) }?.isDeepSeek ?? false
    }

    /// The assistant preset a conversation uses, if it names one.
    func preset(forTopic topicID: UUID?) -> AssistantPreset? {
        guard let topicID, let id = try? topicService.assistantID(of: topicID) else { return nil }
        return try? assistantService.get(id)
    }

    func setDefaultModel(_ id: String) {
        defaultModelID = id
        try? preferenceService.set(PreferenceKey.defaultModel, to: id)
    }

    /// A client for the model, or the reason there is none.
    func responder(for model: ProviderModel?) -> Result<(ChatResponder, String), ChatServiceError> {
        guard let model, let provider = provider(for: model) else {
            return .failure(.other(message: String(localized: "Add a model in Settings to get replies.")))
        }
        do {
            let client = try OpenAICompatibleClient(baseURL: provider.baseURL, apiKey: provider.apiKey)
            return .success((client, model.modelID))
        } catch {
            return .failure(ChatServiceError(error))
        }
    }

    // MARK: Providers

    func reloadProviders() {
        providers = (try? providerService.list()) ?? []
    }

    @discardableResult
    func addProvider(name: String, baseURL: String, apiKey: String) -> Provider? {
        let provider = try? providerService.create(name: name, baseURL: baseURL, apiKey: apiKey)
        reloadProviders()
        return provider
    }

    func setProviderEnabled(_ id: String, _ isEnabled: Bool) {
        try? providerService.setEnabled(id, isEnabled)
        reloadProviders()
    }

    func updateProvider(_ provider: Provider) {
        try? providerService.update(provider)
        reloadProviders()
    }

    func deleteProvider(_ id: String) {
        try? providerService.delete(id)
        reloadProviders()
    }

    func addModel(_ modelID: String, to providerID: String) {
        let added = try? modelService.add(modelID: modelID, to: providerID)
        reloadProviders()
        if defaultModelID == nil, let added {
            setDefaultModel(added.id)
        }
    }

    func removeModel(_ id: String) {
        try? modelService.remove(id)
        reloadProviders()
    }

    /// Asks the service for its models and adds the new ones. Returns how many were added.
    func fetchModels(for providerID: String) async throws -> Int {
        guard let provider = providers.first(where: { $0.id == providerID }) else { return 0 }
        let client = try OpenAICompatibleClient(baseURL: provider.baseURL, apiKey: provider.apiKey)
        let ids = try await client.listModels()
        let added = try modelService.merge(modelIDs: ids, into: providerID)
        reloadProviders()
        if defaultModelID == nil, let first = currentModel {
            setDefaultModel(first.id)
        }
        return added
    }

    // MARK: Settings

    func reloadPreferences() {
        defaultModelID = try? preferenceService.value(PreferenceKey.defaultModel, as: String.self)
        if let minutes = try? preferenceService.value(PreferenceKey.miniRetentionMinutes, as: Int.self) {
            retentionPolicy = RetentionPolicy(storedMinutes: minutes)
        }
        if let height = try? preferenceService.value(PreferenceKey.cardHeight, as: Int.self) {
            cardHeight = height.clamped(to: Self.cardHeightRange)
        }
        systemPrompt = (try? preferenceService.value(PreferenceKey.systemPrompt, as: String.self)) ?? Self.defaultSystemPrompt
        thinkingLevels = (try? preferenceService.value(PreferenceKey.thinkingLevels, as: [String: ThinkingLevel].self)) ?? [:]
    }

    func setSystemPrompt(_ prompt: String) {
        systemPrompt = prompt
        try? preferenceService.set(PreferenceKey.systemPrompt, to: prompt)
    }

    func setRetentionPolicy(_ policy: RetentionPolicy) {
        retentionPolicy = policy
        try? preferenceService.set(PreferenceKey.miniRetentionMinutes, to: policy.storedMinutes)
    }

    func setCardHeight(_ height: Int) {
        cardHeight = height.clamped(to: Self.cardHeightRange)
        try? preferenceService.set(PreferenceKey.cardHeight, to: cardHeight)
    }

    // MARK: History

    func reloadTopics() {
        topics = (try? topicService.list()) ?? []
    }

    func renameTopic(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? topicService.rename(id, to: trimmed)
        reloadTopics()
    }

    func deleteTopic(_ id: UUID) {
        try? topicService.delete(id)
        reloadTopics()
        historyRevision += 1
    }

    func historyDidChange() {
        reloadTopics()
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// Where the app keeps its database and attachment copies.
enum AppStorageLocation {
    static func dataDirectory() -> URL {
        if let override = UserDefaults.standard.string(forKey: AppDelegate.LaunchOption.dataDirectory), !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("SpotChat", isDirectory: true)
    }

    static var databaseURL: URL { dataDirectory().appendingPathComponent("SpotChat.sqlite") }
    static var filesDirectory: URL { dataDirectory().appendingPathComponent("Files", isDirectory: true) }
}
