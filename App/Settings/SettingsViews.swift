import AppKit
import KeyboardShortcuts
import SwiftUI
import SpotCore

// MARK: Providers

struct ProvidersSettingsView: View {
    @ObservedObject var app: AppModel
    @State private var selection: String?
    @State private var providerToDelete: Provider?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(app.providers) { provider in
                        HStack {
                            Text(provider.name.isEmpty ? String(localized: "Untitled") : provider.name)
                                .lineLimit(1)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { provider.isEnabled },
                                set: { app.setProviderEnabled(provider.id, $0) }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                            .accessibilityLabel(Text("Use \(provider.name)"))
                            .accessibilityIdentifier("providerEnabled")
                        }
                        .tag(provider.id)
                    }
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier("providerList")
                Divider()
                HStack(spacing: 0) {
                    Button(action: addProvider) {
                        Image(systemName: "plus").frame(width: 26, height: 22)
                    }
                    .accessibilityLabel(Text("Add Provider"))
                    .accessibilityIdentifier("addProvider")
                    Button {
                        providerToDelete = app.providers.first { $0.id == selection }
                    } label: {
                        Image(systemName: "minus").frame(width: 26, height: 22)
                    }
                    .disabled(app.providers.first { $0.id == selection }?.isBuiltIn ?? true)
                    .accessibilityLabel(Text("Delete Provider"))
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(width: 200)

            Divider()

            if let provider = app.providers.first(where: { $0.id == selection }) {
                ProviderDetailView(app: app, provider: provider)
                    .id(provider.id)
            } else {
                Group {
                    if app.providers.isEmpty {
                        Button("Add Provider", action: addProvider)
                    } else {
                        Text("Select a provider.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selection == nil {
                selection = app.providers.first?.id
            }
        }
        .confirmationDialog(
            Text("Delete \(providerToDelete?.name ?? "")?"),
            isPresented: Binding(get: { providerToDelete != nil }, set: { if !$0 { providerToDelete = nil } }),
            presenting: providerToDelete
        ) { provider in
            Button("Delete", role: .destructive) {
                app.deleteProvider(provider.id)
                selection = app.providers.first?.id
            }
        } message: { _ in
            Text("Its models are removed too. Conversations stay in history.")
        }
    }

    private func addProvider() {
        if let provider = app.addProvider(name: String(localized: "New Provider"), baseURL: "", apiKey: "") {
            selection = provider.id
        }
    }
}

struct ProviderDetailView: View {
    @ObservedObject var app: AppModel
    let provider: Provider

    @State private var name: String
    @State private var baseURL: String
    @State private var apiKey: String
    @State private var showsKey = false
    @State private var newModel = ""
    @State private var isFetching = false
    @State private var fetchResult: String?

    init(app: AppModel, provider: Provider) {
        self.app = app
        self.provider = provider
        _name = State(initialValue: provider.name)
        _baseURL = State(initialValue: provider.baseURL)
        _apiKey = State(initialValue: provider.apiKey)
    }

    var body: some View {
        Form {
            Section {
                if provider.isBuiltIn {
                    LabeledContent("Name", value: provider.name)
                } else {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("providerName")
                }
                TextField("API Address", text: $baseURL, prompt: Text(verbatim: "https://api.openai.com/v1"))
                    .accessibilityIdentifier("providerURL")
                HStack {
                    Group {
                        if showsKey {
                            TextField("API Key", text: $apiKey)
                        } else {
                            SecureField("API Key", text: $apiKey)
                        }
                    }
                    .accessibilityIdentifier("providerKey")
                    Button {
                        showsKey.toggle()
                    } label: {
                        Image(systemName: showsKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text(showsKey ? "Hide API Key" : "Show API Key"))
                }
            }

            Section("Models") {
                ForEach(provider.models) { model in
                    HStack {
                        Text(model.modelID)
                        Spacer()
                        Button {
                            app.removeModel(model.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Remove \(model.modelID)"))
                    }
                }
                TextField("Add Model", text: $newModel, prompt: Text("Model ID"))
                    .onSubmit(addModel)
                    .accessibilityIdentifier("newModel")
                HStack {
                    Button("Fetch Model List", action: fetchModels)
                        .disabled(isFetching || baseURL.isEmpty)
                        .accessibilityIdentifier("fetchModels")
                    if isFetching {
                        ProgressView().controlSize(.small)
                    }
                    if let fetchResult {
                        Text(fetchResult)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("fetchResult")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: name) { save() }
        .onChange(of: baseURL) { save() }
        .onChange(of: apiKey) { save() }
    }

    private func save() {
        var updated = provider
        updated.name = name
        updated.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        app.updateProvider(updated)
    }

    private func addModel() {
        app.addModel(newModel, to: provider.id)
        newModel = ""
    }

    private func fetchModels() {
        save()
        isFetching = true
        fetchResult = nil
        Task {
            do {
                let added = try await app.fetchModels(for: provider.id)
                fetchResult = String(localized: "\(added) models added")
            } catch {
                fetchResult = ErrorText.describe(error)
            }
            isFetching = false
        }
    }
}

// MARK: General

struct GeneralSettingsView: View {
    @ObservedObject var app: AppModel
    @State private var language = InterfaceLanguage.chosen

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $language) {
                    Text("System Default").tag(InterfaceLanguage.system)
                    // Each language in its own words, as System Settings lists them.
                    Text(verbatim: "English").tag(InterfaceLanguage.english)
                    Text(verbatim: "简体中文").tag(InterfaceLanguage.simplifiedChinese)
                }
                .onChange(of: language) { InterfaceLanguage.choose(language) }
                .accessibilityIdentifier("interfaceLanguage")
                if language != InterfaceLanguage.atLaunch {
                    HStack {
                        Spacer()
                        Button("Restart Spot Chat", action: InterfaceLanguage.relaunch)
                            .accessibilityIdentifier("restartForLanguage")
                    }
                }
            }

            Section {
                Picker("Default Model", selection: Binding(
                    get: { app.currentModel?.id ?? "" },
                    set: { app.setDefaultModel($0) }
                )) {
                    if app.allModels.isEmpty {
                        Text("None").tag("")
                    }
                    ForEach(app.providers.filter { !$0.models.isEmpty }) { provider in
                        Section(provider.name) {
                            ForEach(provider.models) { model in
                                Text(model.modelID).tag(model.id)
                            }
                        }
                    }
                }
                .disabled(app.allModels.isEmpty)
                .accessibilityIdentifier("defaultModel")
                Toggle("Search the Web", isOn: Binding(get: { app.searchesTheWeb }, set: { app.setSearchesTheWeb($0) }))
                    .accessibilityIdentifier("searchTheWeb")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("System Prompt")
                    TextEditor(text: Binding(get: { app.systemPrompt }, set: { app.setSystemPrompt($0) }))
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.never)
                        .padding(6)
                        .frame(minHeight: 80, maxHeight: 140)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                        )
                        .accessibilityIdentifier("systemPrompt")
                }
                // Cherry Studio's placeholders, added at the end; the tooltip shows the placeholder.
                HStack(spacing: 6) {
                    ForEach(Self.promptVariables, id: \.variable) { item in
                        Button(item.label) { app.setSystemPrompt(Self.appending(item.variable.placeholder, to: app.systemPrompt)) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(Text(verbatim: item.variable.placeholder))
                    }
                    Spacer()
                    if app.systemPrompt != AppModel.defaultSystemPrompt {
                        Button("Restore Default") { app.setSystemPrompt(AppModel.defaultSystemPrompt) }
                            .controlSize(.small)
                            .accessibilityIdentifier("restoreSystemPrompt")
                    }
                }
            }

            Section("Run Commands") {
                LabeledContent("Default Folder") {
                    HStack(spacing: 8) {
                        Text(PathTile.shortPath(of: app.defaultCommandFolder))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Change…") {
                            FolderPicker.pick(files: false) { urls in
                                if let folder = urls.first { app.setDefaultCommandFolder(folder) }
                            }
                        }
                        .accessibilityIdentifier("changeCommandFolder")
                    }
                }
                .accessibilityIdentifier("defaultCommandFolder")
            }

            Section("Shortcuts") {
                KeyboardShortcuts.Recorder("Open Mini Window", name: .toggleMiniWindow)
                KeyboardShortcuts.Recorder("Open Full Window", name: .openFullWindow)
                Toggle("Bring Selected Text", isOn: Binding(get: { app.bringsSelection }, set: { app.setBringsSelection($0) }))
                    .accessibilityIdentifier("bringSelection")
            }

            Section("Mini Window") {
                Picker("Keep Conversation After Closing", selection: Binding(
                    get: { app.retentionPolicy },
                    set: { app.setRetentionPolicy($0) }
                )) {
                    ForEach(RetentionPolicy.options, id: \.self) { option in
                        Text(Self.label(for: option)).tag(option)
                    }
                }
                .accessibilityIdentifier("retention")
                // A slider between "Small" and "Large", as System Settings sizes the Dock.
                LabeledContent("Card Height") {
                    Slider(
                        value: Binding(
                            get: { Double(app.cardHeight) },
                            set: { app.setCardHeight(Int(($0 / 20).rounded()) * 20) }
                        ),
                        in: Double(AppModel.cardHeightRange.lowerBound)...Double(AppModel.cardHeightRange.upperBound)
                    ) {
                        Text("Card Height")
                    } minimumValueLabel: {
                        Text("Small")
                    } maximumValueLabel: {
                        Text("Large")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }
                .accessibilityIdentifier("cardHeight")
            }
        }
        .formStyle(.grouped)
    }

    static let promptVariables: [(variable: PromptVariable, label: LocalizedStringKey)] = [
        (.date, "Date"), (.time, "Time"), (.username, "User Name"), (.system, "System"),
        (.language, "Language"), (.modelName, "Model"),
    ]

    static func appending(_ placeholder: String, to prompt: String) -> String {
        guard !prompt.isEmpty else { return placeholder }
        let separator = prompt.hasSuffix(" ") || prompt.hasSuffix("\n") ? "" : " "
        return prompt + separator + placeholder
    }

    static func label(for option: RetentionPolicy) -> String {
        switch option {
        case .clearImmediately:
            return String(localized: "Clear Immediately")
        case let .minutes(minutes):
            return String(localized: "\(minutes) min")
        }
    }
}

/// The language of the interface: the system's, or one chosen in Settings. macOS reads it when the app
/// starts, so a change takes effect after a restart.
enum InterfaceLanguage: String {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    private static let key = "AppleLanguages"

    /// What is chosen in Settings, ignoring a language given on the command line for a test.
    static var chosen: InterfaceLanguage {
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        guard let first = (domain?[key] as? [String])?.first else { return .system }
        return InterfaceLanguage(rawValue: first) ?? .system
    }

    static let atLaunch = chosen

    static func choose(_ language: InterfaceLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: key)
        }
    }

    @MainActor
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
