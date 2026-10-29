import AppKit
import Combine
import SwiftUI
import SpotCore

/// Owns the mini window: feeds events to `MiniWindowState` and performs the effects it returns.
@MainActor
final class MiniWindowController: ObservableObject {
    static let width: CGFloat = 480
    static let capsuleHeight: CGFloat = 56

    @Published private(set) var mode: MiniWindowMode = .hidden
    @Published private(set) var focusRequest = 0
    @Published private(set) var scrollRequest = 0
    /// What the user has typed but not sent. Saved on every change.
    @Published var draft: String {
        didSet {
            if draft != oldValue { draftStorage.saveDraft(draft) }
        }
    }
    @Published var pendingAttachments: [Attachment] = []

    let app: AppModel
    let session: ChatSession
    /// Opens the full window, carrying the conversation shown in the card.
    var openFullWindow: (UUID?) -> Void = { _ in }
    var closeFullWindow: () -> Void = {}
    var openSettings: () -> Void = {}

    private var state: MiniWindowState
    private let draftStorage: DraftStorage
    private let placementStore: PlacementStore
    private var retentionTimer: DispatchWorkItem?
    private var observers: Set<AnyCancellable> = []
    private var resignObserver: NSObjectProtocol?
    /// While a file picker or menu is open the capsule must not hide.
    private var suppressFocusLoss = 0
    private lazy var panel: MiniPanel = makePanel()

    init(app: AppModel, draftStorage: DraftStorage, placementStore: PlacementStore? = nil) {
        self.app = app
        self.session = ChatSession(app: app)
        self.draftStorage = draftStorage
        self.placementStore = placementStore ?? PlacementStore()
        self.state = MiniWindowState(retentionPolicy: app.retentionPolicy)
        self.draft = draftStorage.loadDraft()

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
    }

    var cardHeight: CGFloat { CGFloat(app.cardHeight) }

    func handle(_ event: MiniWindowEvent) {
        let effects = state.handle(event, isKey: panel.isKeyWindow)
        mode = state.mode
        for effect in effects {
            perform(effect)
        }
    }

    func submit() {
        handle(.send(text: draft, hasAttachments: !pendingAttachments.isEmpty, newConversationID: UUID()))
    }

    func panelWasDragged() {
        placementStore.save(topLeft: WindowPlacement.topLeft(of: panel.frame), screen: panel.screen)
    }

    /// Runs work that shows another window (a file picker, an alert) without the capsule hiding meanwhile.
    /// The work calls the completion when that window is gone.
    func withFocusLossSuppressed(_ work: (@escaping () -> Void) -> Void) {
        suppressFocusLoss += 1
        work { [weak self] in
            guard let self else { return }
            self.suppressFocusLoss -= 1
            self.panel.makeKeyAndOrderFront(nil)
            self.focusRequest += 1
        }
    }

    // MARK: Effects

    private func perform(_ effect: MiniWindowEffect) {
        switch effect {
        case .showCapsule:
            present(height: Self.capsuleHeight)
        case .showCard:
            if session.topicID != state.conversationID {
                session.load(state.conversationID)
            }
            present(height: cardHeight)
        case .scrollToBottom:
            scrollRequest += 1
        case .focusInput:
            focusRequest += 1
        case .bringToFront:
            panel.orderFrontRegardless()
            panel.makeKey()
        case .hide:
            panel.orderOut(nil)
        case let .appendUserMessage(text, conversationID):
            let attachments = pendingAttachments
            pendingAttachments = []
            session.send(text: text, attachments: attachments, newTopicID: conversationID)
        case .clearDraft:
            draft = ""
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
        let panel = MiniPanel.make(width: Self.width, height: Self.capsuleHeight)
        let hosting = NSHostingView(rootView: MiniRootView(controller: self, session: session, app: app))
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
