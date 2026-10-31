import AppKit
import Combine
import SpotAgent
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
    @Published private(set) var bringsSelection = true
    /// Whether chats with DeepSeek may search the web; the model decides when.
    @Published private(set) var searchesTheWeb = true
    /// Where commands run unless a conversation picks another folder, as dsh keeps a default workspace.
    @Published private(set) var defaultCommandFolder = AppModel.standardCommandFolder
    private(set) var askedForSelectionAccess = false
    /// Thinking level by model; a model not listed thinks as its service decides.
    @Published private(set) var thinkingLevels: [String: ThinkingLevel] = [:]
    /// Models whose service turned down an effort level.
    @Published private(set) var modelsWithoutEffort: Set<String> = []
    /// What conversations are doing right now, for the dots in the history.
    @Published private(set) var activity: [UUID: TopicActivity] = [:]
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

    /// The level chosen for the model, or the one it starts at.
    func thinking(for model: ProviderModel) -> ThinkingLevel {
        thinkingLevels[model.id] ?? ThinkingLevel.standard(isDeepSeek: isDeepSeek(model))
    }

    /// Whether the model takes an effort level. A model whose service turned one down is asked without it.
    func supportsEffort(_ model: ProviderModel) -> Bool {
        !modelsWithoutEffort.contains(model.id)
    }

    /// What a request sends: the level shown, unless the model turned levels down.
    func requestThinking(for model: ProviderModel) -> ThinkingLevel {
        supportsEffort(model) ? thinking(for: model) : .automatic
    }

    /// Remembers that the model's service rejects effort levels, as LiteLLM and others handle it.
    func markWithoutEffort(_ modelID: String) {
        modelsWithoutEffort.insert(modelID)
        try? preferenceService.set(PreferenceKey.modelsWithoutEffort, to: modelsWithoutEffort.sorted())
    }

    func setThinking(_ level: ThinkingLevel, for model: ProviderModel) {
        thinkingLevels[model.id] = level
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

    func setSearchesTheWeb(_ on: Bool) {
        searchesTheWeb = on
        try? preferenceService.set(PreferenceKey.webSearch, to: on)
    }

    /// Web search for a chat with the model: DeepSeek's Search and Fetch API, with the model's own key.
    func webTools(for model: ProviderModel) -> DeepSeekWebTools? {
        guard searchesTheWeb, let provider = provider(for: model), !provider.apiKey.isEmpty else { return nil }
        if let url = UserDefaults.standard.string(forKey: AppDelegate.LaunchOption.webToolsURL), !url.isEmpty {
            return DeepSeekWebTools(apiKey: provider.apiKey, baseURL: url)
        }
        return isDeepSeek(model) ? DeepSeekWebTools(apiKey: provider.apiKey) : nil
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

    // MARK: Commands

    /// dsh, when this build bundles it.
    let commandRuntime = CommandRuntime.bundled()

    /// How dsh starts for the current model, or why it can't. dsh talks to DeepSeek only,
    /// so it takes the key of the DeepSeek provider; another model there stays on dsh's default.
    func commandOptions() -> Result<CommandAgentOptions, CommandUnavailable> {
        guard commandRuntime != nil else { return .failure(.notBundled) }
        let override = UserDefaults.standard.string(forKey: AppDelegate.LaunchOption.agentBaseURL).flatMap { $0.isEmpty ? nil : $0 }
        let model = currentModel
        let modelIsDeepSeek = model.map { isDeepSeek($0) || override != nil } ?? false
        let provider = modelIsDeepSeek ? model.flatMap { self.provider(for: $0) } : providers.first { provider in
            provider.isEnabled && (ProviderEndpoint(baseURL: provider.baseURL)?.isDeepSeek ?? false)
        }
        guard let provider, !provider.apiKey.isEmpty else { return .failure(.noDeepSeekKey) }
        var options = CommandAgentOptions(
            apiKey: provider.apiKey, baseURL: override,
            home: AppStorageLocation.dataDirectory().appendingPathComponent("Agent", isDirectory: true),
            webToolsURL: override.map { $0 + "/tools" }
        )
        if modelIsDeepSeek, let model {
            options.model = model.modelID
            options.effort = Self.commandEffort(requestThinking(for: model))
        }
        return .success(options)
    }

    /// dsh's names for the levels: off, low, high and max.
    private static func commandEffort(_ level: ThinkingLevel) -> String? {
        switch level {
        case .automatic: return nil
        case .off: return "off"
        case .low: return "low"
        case .medium, .high: return "high"
        case .max: return "max"
        }
    }

    /// ~/Documents/Spot Chat, as dsh puts its own under Documents.
    static var standardCommandFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Spot Chat", isDirectory: true)
    }

    func setDefaultCommandFolder(_ folder: URL) {
        defaultCommandFolder = folder
        try? preferenceService.set(PreferenceKey.commandFolder, to: folder.path)
    }

    /// The default folder, made if it isn't there yet.
    func readyDefaultCommandFolder() -> URL {
        try? FileManager.default.createDirectory(at: defaultCommandFolder, withIntermediateDirectories: true)
        return defaultCommandFolder
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
        bringsSelection = (try? preferenceService.value(PreferenceKey.bringSelection, as: Bool.self)) ?? true
        searchesTheWeb = (try? preferenceService.value(PreferenceKey.webSearch, as: Bool.self)) ?? true
        if let path = UserDefaults.standard.string(forKey: AppDelegate.LaunchOption.defaultCommandFolder)
            ?? (try? preferenceService.value(PreferenceKey.commandFolder, as: String.self)), !path.isEmpty {
            defaultCommandFolder = URL(fileURLWithPath: path, isDirectory: true)
        }
        askedForSelectionAccess = (try? preferenceService.value(PreferenceKey.selectionAccessRequested, as: Bool.self)) ?? false
        thinkingLevels = (try? preferenceService.value(PreferenceKey.thinkingLevels, as: [String: ThinkingLevel].self)) ?? [:]
        modelsWithoutEffort = Set((try? preferenceService.value(PreferenceKey.modelsWithoutEffort, as: [String].self)) ?? [])
    }

    /// What the system prompt's placeholders become for a conversation that started at `start`.
    func promptContext(start: Date, modelName: String) -> PromptVariables.Context {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let language = Locale.preferredLanguages.first ?? "en"
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return PromptVariables.Context(
            start: start,
            modelName: modelName,
            userName: NSFullUserName(),
            systemName: "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            languageName: Locale(identifier: "en").localizedString(forIdentifier: language) ?? language,
            architecture: architecture
        )
    }

    func setBringsSelection(_ on: Bool) {
        bringsSelection = on
        try? preferenceService.set(PreferenceKey.bringSelection, to: on)
        // Turning it on asks macOS for access again, since the first request may have been dismissed.
        if on { _ = SelectionReader.hasAccess(prompt: true) }
    }

    func noteAskedForSelectionAccess() {
        guard !askedForSelectionAccess else { return }
        askedForSelectionAccess = true
        try? preferenceService.set(PreferenceKey.selectionAccessRequested, to: true)
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

    func setActivity(_ value: TopicActivity?, for topicID: UUID) {
        guard activity[topicID] != value else { return }
        activity[topicID] = value
    }
}

/// What a conversation is doing.
enum TopicActivity: Equatable {
    /// A reply is being made.
    case working
    /// It waits for the user to allow or decline a command.
    case needsInput
}

enum CommandUnavailable: LocalizedError {
    case notBundled
    case noDeepSeekKey

    var errorDescription: String? {
        switch self {
        case .notBundled: return String(localized: "This build can't run commands.")
        case .noDeepSeekKey: return String(localized: "Running commands needs a DeepSeek API key. Add one in Settings.")
        }
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
