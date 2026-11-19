import AppKit
import Combine
import Logging
import SwiftUI
import SpotCore

/// Owns the mini window: feeds events to `MiniWindowState` and performs the effects it returns.
@MainActor
final class MiniWindowController: ObservableObject {
    /// As wide as Gemini's.
    static let width: CGFloat = 400

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
    /// Where the input bar's bottom-left corner sits; the window grows up from here.
    private var inputCorner = CGPoint.zero
    /// The app the user was in when the mini window took the keyboard, to give it back to.
    private var appBeforeShowing: NSRunningApplication?
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
        // A new message or another conversation scrolls to the end; a reply growing doesn't, so a reader
        // who scrolled up while it streams stays where they are.
        session.$messages
            .map { messages in messages.map(\.id) }
            .removeDuplicates()
            .sink { [weak self] _ in self?.scrollRequest += 1 }
            .store(in: &observers)
        app.$retentionPolicy
            .sink { [weak self] policy in self?.state.retentionPolicy = policy }
            .store(in: &observers)
        app.$historyRevision
            .dropFirst()
            .sink { [weak self] _ in self?.historyDidChange() }
            .store(in: &observers)
        // The capsule grows a row for attachments, the sharing tag, notices and the strips at its top.
        Publishers.MergeMany(
            composer.$attachments.map { _ in () }.eraseToAnyPublisher(),
            composer.$sharedWindow.map { _ in () }.eraseToAnyPublisher(),
            composer.$notice.map { _ in () }.eraseToAnyPublisher(),
            composer.$selection.map { _ in () }.eraseToAnyPublisher(),
            composer.$selectionOpen.map { _ in () }.eraseToAnyPublisher(),
            composer.$asksForAccessibility.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.composerDidResize() }
        .store(in: &observers)
    }

    var cardHeight: CGFloat { CGFloat(app.cardHeight) }

    var capsuleHeight: CGFloat { ComposerLayout.height(for: composer, textHeight: composerTextHeight) }

    /// The height of text that moved above the input's buttons, or 0.
    private(set) var composerTextHeight: CGFloat = 0

    func composerTextHeightChanged(_ height: CGFloat) {
        guard abs(height - composerTextHeight) > 0.5 else { return }
        composerTextHeight = height
        composerDidResize()
    }

    lazy var composerActions: ComposerActions = inputActions.makeActions(
        session: session,
        submit: { [weak self] in self?.submit() },
        escape: { [weak self] in
            // Esc answers a pending approval first: no.
            if self?.session.pendingApproval != nil {
                self?.session.answerApproval(.deny)
            } else {
                self?.handle(.escape)
            }
        },
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

    /// Opens the mini window with the selected text in a strip at the top of the input, replacing one brought
    /// before. Without any text it just opens.
    func ask(about selection: String?) {
        if let text = selection?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            composer.selection = text
            composer.asksForAccessibility = false
            SpotLog.window.info("Brought the selected text", metadata: ["characters": "\(text.count)"])
        }
        handle(.openRequested)
        composer.requestFocus()
    }

    func handle(_ event: MiniWindowEvent) {
        let effects = state.handle(event, isKey: panel.isKeyWindow)
        SpotLog.window.debug("Mini window", metadata: [
            "event": "\(event)", "mode": "\(state.mode)", "effects": "\(effects)",
        ])
        mode = state.mode
        for effect in effects {
            perform(effect)
        }
    }

    func submit() {
        handle(.send(text: composer.messageText, hasAttachments: composer.hasExtras, newConversationID: UUID()))
    }

    func panelWasDragged() {
        inputCorner = WindowPlacement.bottomLeft(of: panel.frame)
        placementStore.save(bottomLeft: inputCorner, screen: panel.screen)
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
            if let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                appBeforeShowing = front
            }
            if NSApp.isHidden { NSApp.unhideWithoutActivation() }
            panel.orderFrontRegardless()
            panel.makeKey()
        case .hide:
            panel.orderOut(nil)
            // When the full window takes over, Spot Chat keeps focus. Hiding the app here would race the
            // full window's activation and leave it behind other apps, half drawn.
            if !state.isFullWindowOpen {
                returnFocusToPreviousApp()
            }
        case let .appendUserMessage(text, conversationID):
            inputActions.send(text: text, to: session, newTopicID: conversationID)
        case .clearDraft:
            composer.clearSent()
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

    /// Gives the keyboard back to the app the user was in. The panel takes the keyboard without making Spot
    /// Chat the active app, and ordering it out didn't give it back: keys kept coming to Spot Chat, which had
    /// no window for them, so every key beeped and flashed the screen until Spot Chat quit. Hiding the app
    /// lets go of the keyboard, as it did already when Spot Chat had become active (for a file picker, say);
    /// with Settings or another window still open, the app the user was in is asked to take it back instead.
    private func returnFocusToPreviousApp() {
        let otherWindowsOpen = NSApp.windows.contains { $0 !== panel && $0.isVisible && $0.canBecomeMain }
        let wasActive = NSApp.isActive
        let previous = appBeforeShowing
        appBeforeShowing = nil
        if !otherWindowsOpen {
            NSApp.hide(nil)
        } else if let previous, !previous.isTerminated {
            if wasActive { NSApp.yieldActivation(to: previous) }
            previous.activate()
        }
        SpotLog.window.info("Gave the keyboard back", metadata: [
            "to": "\(previous?.localizedName ?? "nothing")", "wasActive": "\(wasActive)",
            "hidden": "\(!otherWindowsOpen)", "keyWindow": "\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none")",
        ])
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

    /// Places the window by the input bar's bottom-left corner, so the card grows up from the input and
    /// shrinks back to it. The size changes in one step: animating a window frame around SwiftUI content
    /// stutters, so the content fades instead.
    private func present(height: CGFloat) {
        if NSApp.isHidden {
            NSApp.unhideWithoutActivation()
        }
        let screen = panel.isVisible ? (panel.screen ?? NSScreen.main) : Self.screenUnderMouse()
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        if !panel.isVisible {
            inputCorner = placementStore.savedBottomLeft(for: screen)
                ?? WindowPlacement.defaultBottomLeft(width: Self.width, visibleFrame: visible)
        }
        let frame = WindowPlacement.frame(
            bottomLeft: inputCorner,
            size: CGSize(width: Self.width, height: height),
            visibleFrame: visible
        )
        panel.setFrame(frame, display: true, animate: false)
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
