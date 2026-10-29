import AppKit
import SwiftUI
import SpotCore

/// Owns the mini window: feeds events to `MiniWindowState` and performs the effects it returns.
@MainActor
final class MiniWindowController: ObservableObject {
    static let width: CGFloat = 480
    static let capsuleHeight: CGFloat = 56
    static let cardHeight: CGFloat = 560

    @Published private(set) var mode: MiniWindowMode = .hidden
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isGenerating = false
    @Published private(set) var focusRequest = 0
    @Published private(set) var scrollRequest = 0
    /// What the user has typed but not sent. Saved on every change.
    @Published var draft: String {
        didSet {
            if draft != oldValue { draftStorage.saveDraft(draft) }
        }
    }

    /// Nil until a provider is set up in stage 2.
    let modelName: String? = nil

    private var state: MiniWindowState
    private let draftStorage: DraftStorage
    private let placementStore: PlacementStore
    private let responder: ChatResponder
    private var conversations: [UUID: Conversation] = [:]
    private var retentionTimer: DispatchWorkItem?
    private var generationTask: Task<Void, Never>?
    private var resignObserver: NSObjectProtocol?
    private lazy var panel: MiniPanel = makePanel()

    init(
        draftStorage: DraftStorage,
        placementStore: PlacementStore? = nil,
        responder: ChatResponder = EchoResponder(),
        retentionPolicy: RetentionPolicy = .default
    ) {
        self.draftStorage = draftStorage
        self.placementStore = placementStore ?? PlacementStore()
        self.responder = responder
        self.state = MiniWindowState(retentionPolicy: retentionPolicy)
        self.draft = draftStorage.loadDraft()
    }

    func handle(_ event: MiniWindowEvent) {
        let effects = state.handle(event, isKey: panel.isKeyWindow)
        mode = state.mode
        isGenerating = state.isGenerating
        syncMessages()
        for effect in effects {
            perform(effect)
        }
    }

    func submit() {
        handle(.send(text: draft, newConversationID: UUID()))
    }

    func panelWasDragged() {
        placementStore.save(topLeft: WindowPlacement.topLeft(of: panel.frame), screen: panel.screen)
    }

    // MARK: Effects

    private func perform(_ effect: MiniWindowEffect) {
        switch effect {
        case .showCapsule:
            present(height: Self.capsuleHeight)
        case .showCard:
            present(height: Self.cardHeight)
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
            appendUserMessage(text, to: conversationID)
        case .clearDraft:
            draft = ""
        case let .scheduleRetentionExpiry(token, interval):
            scheduleRetentionExpiry(token: token, after: interval)
        case .cancelRetentionExpiry:
            retentionTimer?.cancel()
            retentionTimer = nil
        case .endConversation:
            // Stage 2 keeps ended conversations in history.
            syncMessages()
        case .openFullWindow, .closeFullWindow:
            // Stage 6.
            break
        case .stopGeneration:
            generationTask?.cancel()
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

    // MARK: Conversation

    private func syncMessages() {
        let current = state.conversationID.flatMap { conversations[$0]?.messages } ?? []
        if current != messages {
            messages = current
        }
    }

    private func appendUserMessage(_ text: String, to conversationID: UUID) {
        var conversation = conversations[conversationID] ?? Conversation(id: conversationID)
        conversation.messages.append(ChatMessage(role: .user, text: text))
        let history = conversation.messages
        let reply = ChatMessage(role: .assistant, text: "")
        conversation.messages.append(reply)
        conversations[conversationID] = conversation
        syncMessages()
        startGeneration(history: history, conversationID: conversationID, replyID: reply.id)
    }

    private func startGeneration(history: [ChatMessage], conversationID: UUID, replyID: UUID) {
        handle(.generationStarted)
        let stream = responder.reply(to: history)
        generationTask = Task { [weak self] in
            do {
                for try await chunk in stream {
                    if Task.isCancelled { break }
                    self?.appendChunk(chunk, conversationID: conversationID, replyID: replyID)
                }
            } catch {
                // Stage 2 shows request errors in place of the reply.
            }
            self?.handle(.generationFinished)
        }
    }

    private func appendChunk(_ chunk: String, conversationID: UUID, replyID: UUID) {
        guard var conversation = conversations[conversationID],
              let index = conversation.messages.firstIndex(where: { $0.id == replyID })
        else { return }
        conversation.messages[index].text += chunk
        conversations[conversationID] = conversation
        syncMessages()
    }

    // MARK: Window

    private func makePanel() -> MiniPanel {
        let panel = MiniPanel.make(width: Self.width, height: Self.capsuleHeight)
        let hosting = NSHostingView(rootView: MiniRootView(controller: self))
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
                self?.handle(.resignedKey)
            }
        }
        return panel
    }
}
