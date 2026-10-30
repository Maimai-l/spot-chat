import AppKit
import KeyboardShortcuts
import SpotCore
import SpotData

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Launch arguments used by the UI tests.
    enum LaunchOption {
        static let showMiniWindow = "SpotChatShowMiniOnLaunch"
        static let showFullWindow = "SpotChatShowFullWindowOnLaunch"
        static let resetState = "SpotChatResetState"
        /// Keeps the database and attachments in this folder instead of Application Support.
        static let dataDirectory = "SpotChatDataDirectory"
        /// Adds a provider with this base URL when there is none.
        static let testProviderURL = "SpotChatTestProviderURL"
        static let testProviderKey = "SpotChatTestProviderKey"
    }

    private(set) lazy var app = makeAppModel()
    private(set) lazy var composer = ComposerModel(app: app, draftStorage: UserDefaultsDraftStorage())
    private lazy var shareService = WindowShareService()
    private lazy var permissionGuide = PermissionGuideController()
    private(set) lazy var miniController = makeMiniController()
    private(set) lazy var fullWindow = makeFullWindow()
    private(set) lazy var settings = SettingsWindowController(app: app)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: LaunchOption.resetState) {
            UserDefaultsDraftStorage().saveDraft("")
            defaults.removeObject(forKey: "SpotChat.pendingAttachments")
            PlacementStore().reset()
            try? FileManager.default.removeItem(at: AppStorageLocation.dataDirectory())
        }
        if let url = defaults.string(forKey: LaunchOption.testProviderURL), !app.providers.contains(where: { $0.baseURL == url }) {
            seedTestProvider(baseURL: url, apiKey: defaults.string(forKey: LaunchOption.testProviderKey) ?? "")
        }

        KeyboardShortcuts.onKeyDown(for: .toggleMiniWindow) { [weak self] in
            self?.miniController.handle(.toggleShortcut)
        }
        KeyboardShortcuts.onKeyDown(for: .openFullWindow) { [weak self] in
            self?.openFullWindow()
        }

        if defaults.bool(forKey: LaunchOption.showFullWindow) {
            openFullWindow()
        } else if defaults.bool(forKey: LaunchOption.showMiniWindow) {
            miniController.handle(.openRequested)
        }
    }

    func showSettings() {
        settings.show()
    }

    func openFullWindow() {
        miniController.handle(.fullWindowShortcut)
    }

    private func makeAppModel() -> AppModel {
        let database: AppDatabase
        do {
            database = try AppDatabase.onDisk(at: AppStorageLocation.databaseURL)
        } catch {
            NSLog("Spot Chat could not open its database: \(error)")
            // Keeps the app usable; nothing is saved this session.
            database = try! AppDatabase.inMemory()
        }
        return AppModel(database: database, filesDirectory: AppStorageLocation.filesDirectory)
    }

    private func makeInputActions() -> InputActions {
        InputActions(composer: composer, app: app, share: shareService, guide: permissionGuide)
    }

    private func makeMiniController() -> MiniWindowController {
        let controller = MiniWindowController(app: app, composer: composer, inputActions: makeInputActions())
        controller.openSettings = { [weak self] in self?.showSettings() }
        controller.openFullWindow = { [weak self] topicID in self?.fullWindow.show(topicID: topicID) }
        controller.closeFullWindow = { [weak self] in self?.fullWindow.close() }
        return controller
    }

    private func makeFullWindow() -> FullWindowController {
        let controller = FullWindowController(app: app, composer: composer, inputActions: makeInputActions())
        controller.onCollapse = { [weak self] topicID in
            self?.miniController.handle(.collapseFullWindow(conversationID: topicID))
        }
        controller.onClose = { [weak self] in
            self?.miniController.handle(.fullWindowClosed)
        }
        controller.openSettings = { [weak self] in self?.showSettings() }
        return controller
    }

    private func seedTestProvider(baseURL: String, apiKey: String) {
        guard let provider = app.addProvider(name: "Mock", baseURL: baseURL, apiKey: apiKey) else { return }
        app.addModel("mock-fast", to: provider.id)
        app.addModel("mock-vision", to: provider.id)
    }
}
