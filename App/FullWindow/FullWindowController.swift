import AppKit
import Combine
import SwiftUI
import SpotCore

/// The full window: conversation history on the left, the selected conversation on the right.
@MainActor
final class FullWindowController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var scrollRequest = 0
    @Published var renamingTopic: UUID?
    @Published var renameText = ""
    @Published var topicToDelete: TopicSummary?

    let app: AppModel
    let session: ChatSession
    let composer: ComposerModel
    let inputActions: InputActions
    /// "Collapse to Mini Window", carrying the conversation shown.
    var onCollapse: (UUID?) -> Void = { _ in }
    /// The user closed the window.
    var onClose: () -> Void = {}
    var openSettings: () -> Void = {}

    private var window: NSWindow?
    private var observers: Set<AnyCancellable> = []

    init(app: AppModel, composer: ComposerModel, inputActions: InputActions) {
        self.app = app
        self.composer = composer
        self.inputActions = inputActions
        self.session = ChatSession(app: app)
        super.init()
        session.$messages
            .sink { [weak self] _ in self?.scrollRequest += 1 }
            .store(in: &observers)
        app.$historyRevision
            .dropFirst()
            .sink { [weak self] _ in self?.historyDidChange() }
            .store(in: &observers)
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    /// Opens the window. A conversation passed in is shown; without one, the window keeps what it shows.
    func show(topicID: UUID?) {
        let wasVisible = isVisible
        if window == nil {
            window = makeWindow()
        }
        if topicID != nil || !wasVisible {
            session.load(topicID)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        composer.requestFocus()
    }

    /// Closes the window without telling the mini window, which asked for it.
    func close() {
        session.stop()
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    func collapse() {
        let topicID = session.topicID
        session.stop()
        onCollapse(topicID)
    }

    func submit() {
        guard !session.isGenerating, composer.hasContent else { return }
        let text = composer.draft
        composer.draft = ""
        inputActions.send(text: text, to: session, newTopicID: UUID())
        composer.requestFocus()
    }

    func newChat() {
        session.load(nil)
        composer.requestFocus()
    }

    func select(_ topicID: UUID?) {
        guard let topicID, topicID != session.topicID else { return }
        session.load(topicID)
    }

    func beginRename(_ topic: TopicSummary) {
        renameText = topic.name
        renamingTopic = topic.id
    }

    func commitRename() {
        if let id = renamingTopic {
            app.renameTopic(id, to: renameText)
        }
        renamingTopic = nil
    }

    func delete(_ topic: TopicSummary) {
        app.deleteTopic(topic.id)
    }

    private func historyDidChange() {
        if let id = session.topicID, !app.topics.contains(where: { $0.id == id }) {
            session.load(nil)
        }
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        session.stop()
        NSApp.setActivationPolicy(.accessory)
        onClose()
    }

    private func makeWindow() -> NSWindow {
        let actions = inputActions.makeActions(
            submit: { [weak self] in self?.submit() },
            escape: { [weak self] in self?.session.stop() },
            openSettings: { [weak self] in self?.openSettings() },
            presenting: { work in work {} }
        )
        let view = FullWindowView(controller: self, session: session, app: app, composer: composer, actions: actions)
        let hosting = NSHostingController(rootView: view)
        hosting.sceneBridgingOptions = [.toolbars]

        let window = EditingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = String(localized: "Spot Chat")
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setAccessibilityIdentifier("fullWindow")
        window.setContentSize(NSSize(width: 1040, height: 720))
        window.center()
        window.setFrameAutosaveName("FullWindow")
        return window
    }
}
