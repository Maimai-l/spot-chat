import AppKit
import Combine
import SwiftUI
import SpotCore

/// Owns the mini window: feeds events to `MiniWindowState` and performs the effects it returns.
@MainActor
final class MiniWindowController: ObservableObject {
    static let width: CGFloat = 480

    @Published private(set) var mode: MiniWindowMode = .hidden
    @Published private(set) var scrollRequest = 0

    let app: AppModel
    let session: ChatSession
    let composer: ComposerModel
    let inputActions: InputActions
    /// Opens the full window, carrying the conversation shown in the card.
    var openFullWindow: (UUID?) -> Void = { _ in }
    var closeFullWindow: () -> Void = {}
    var openSettings: () -> Void = {}

    private var state: MiniWindowState
    private let placementStore: PlacementStore
    private var retentionTimer: DispatchWorkItem?
    private var observers: Set<AnyCancellable> = []
    private var resignObserver: NSObjectProtocol?
    /// While a file picker, the permission guide or a menu is open the capsule must not hide.
    private var suppressFocusLoss = 0
    private lazy var panel: MiniPanel = makePanel()

    init(app: AppModel, composer: ComposerModel, inputActions: InputActions, placementStore: PlacementStore? = nil) {
        self.app = app
        self.composer = composer
        self.inputActions = inputActions
        self.session = ChatSession(app: app)
        self.placementStore = placementStore ?? PlacementStore()
        self.state = MiniWindowState(retentionPolicy: app.retentionPolicy)

        session.$isGenerating
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] generating in
                self?.handle(generating ? .generationStarted : .generationFinished)
            }
            .store(in: &observers)
        session.$messages
            .sink { [weak self] _ in self?.scrollRequest += 1 }
            .store(in: &observers)
        app.$retentionPolicy
            .sink { [weak self] policy in self?.state.retentionPolicy = policy }
            .store(in: &observers)
        app.$historyRevision
            .dropFirst()
            .sink { [weak self] _ in self?.historyDidChange() }
            .store(in: &observers)
        // The capsule grows a row for attachments, the sharing tag and notices.
        Publishers.Merge3(
            composer.$attachments.map { _ in () },
            composer.$sharedWindow.map { _ in () },
            composer.$notice.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.composerDidResize() }
        .store(in: &observers)
    }

    var cardHeight: CGFloat { CGFloat(app.cardHeight) }

    var capsuleHeight: CGFloat { ComposerLayout.height(for: composer) }

    lazy var composerActions: ComposerActions = inputActions.makeActions(
        submit: { [weak self] in self?.submit() },
        escape: { [weak self] in self?.handle(.escape) },
        openSettings: { [weak self] in self?.openSettings() },
        presenting: { [weak self] work in self?.withFocusLossSuppressed(work) },
        menuWillOpen: { [weak self] in self?.suppressFocusLoss += 1 },
        menuDidClose: { [weak self] in self?.suppressFocusLoss -= 1 }
    )

    /// The capsule also offers expanding to the full window; the card has that button in its header.
    var capsuleActions: ComposerActions {
        var actions = composerActions
        actions.expand = { [weak self] in self?.handle(.expandToFullWindow) }
        return actions
    }

    func handle(_ event: MiniWindowEvent) {
        let effects = state.handle(event, isKey: panel.isKeyWindow)
        mode = state.mode
        for effect in effects {
            perform(effect)
        }
    }

    func submit() {
        handle(.send(text: composer.draft, hasAttachments: composer.hasExtras, newConversationID: UUID()))
    }

    func panelWasDragged() {
        placementStore.save(topLeft: WindowPlacement.topLeft(of: panel.frame), screen: panel.screen)
    }

    /// Runs work that shows another window without the capsule hiding meanwhile.
    /// The work calls the completion when that window is gone.
    func withFocusLossSuppressed(_ work: (@escaping () -> Void) -> Void) {
        suppressFocusLoss += 1
        work { [weak self] in
            guard let self else { return }
            self.suppressFocusLoss -= 1
            if self.mode != .hidden {
                self.panel.makeKeyAndOrderFront(nil)
                self.composer.requestFocus()
            }
        }
    }

    // MARK: Effects

    private func perform(_ effect: MiniWindowEffect) {
        switch effect {
        case .showCapsule:
            present(height: capsuleHeight)
        case .showCard:
            if session.topicID != state.conversationID {
                session.load(state.conversationID)
            }
            present(height: cardHeight)
        case .scrollToBottom:
            scrollRequest += 1
        case .focusInput:
            composer.requestFocus()
        case .bringToFront:
            if NSApp.isHidden { NSApp.unhideWithoutActivation() }
            panel.orderFrontRegardless()
            panel.makeKey()
        case .hide:
            panel.orderOut(nil)
            returnFocusToPreviousApp()
        case let .appendUserMessage(text, conversationID):
            inputActions.send(text: text, to: session, newTopicID: conversationID)
        case .clearDraft:
            composer.draft = ""
        case let .scheduleRetentionExpiry(token, interval):
            scheduleRetentionExpiry(token: token, after: interval)
        case .cancelRetentionExpiry:
            retentionTimer?.cancel()
            retentionTimer = nil
        case let .endConversation(id):
            if session.topicID == id {
                session.load(nil)
            }
        case let .openFullWindow(conversationID):
            if conversationID != nil, session.topicID == conversationID {
                session.load(nil)
            }
            openFullWindow(conversationID)
        case .closeFullWindow:
            closeFullWindow()
        case .stopGeneration:
            session.stop()
        }
    }

    /// When Spot Chat became active (for a file picker, say), hiding the capsule hands focus back.
    private func returnFocusToPreviousApp() {
        let otherWindowsOpen = NSApp.windows.contains { $0 !== panel && $0.isVisible && $0.canBecomeMain }
        if NSApp.isActive, !otherWindowsOpen {
            NSApp.hide(nil)
        }
    }

    private func composerDidResize() {
        guard mode == .capsule, panel.isVisible, abs(panel.frame.height - capsuleHeight) > 0.5 else { return }
        present(height: capsuleHeight)
    }

    private func historyDidChange() {
        // A conversation deleted from history must not come back in the card.
        guard let id = state.conversationID, !app.topics.contains(where: { $0.id == id }) else { return }
        if mode == .card {
            handle(.newConversation)
        } else {
            session.load(nil)
        }
    }

    private func present(height: CGFloat) {
        if NSApp.isHidden {
            NSApp.unhideWithoutActivation()
        }
        if panel.isVisible {
            let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
            let target = height > panel.frame.height
                ? WindowPlacement.expandedFrame(from: panel.frame, toHeight: height, visibleFrame: visible)
                : WindowPlacement.collapsedFrame(from: panel.frame, toHeight: height)
            panel.setFrame(target, display: true, animate: true)
        } else {
            let screen = Self.screenUnderMouse()
            let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let frame = WindowPlacement.initialFrame(
                size: CGSize(width: Self.width, height: height),
                savedTopLeft: placementStore.savedTopLeft(for: screen),
                visibleFrame: visible
            )
            panel.setFrame(frame, display: false)
        }
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.panel.invalidateShadow()
        }
    }

    private static func screenUnderMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
    }

    private func scheduleRetentionExpiry(token: Int, after interval: TimeInterval) {
        retentionTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.handle(.retentionExpired(token: token))
            }
        }
        retentionTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: item)
    }

    // MARK: Window

    private func makePanel() -> MiniPanel {
        let panel = MiniPanel.make(width: Self.width, height: ComposerLayout.baseHeight)
        let hosting = NSHostingView(rootView: MiniRootView(controller: self, session: session, app: app, composer: composer))
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.onEscape = { [weak self] in
            self?.handle(.escape)
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.suppressFocusLoss == 0 else { return }
                self.handle(.resignedKey)
            }
        }
        return panel
    }
}
