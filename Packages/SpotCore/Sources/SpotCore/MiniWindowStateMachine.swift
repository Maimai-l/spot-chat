import Foundation

/// What the mini window shows. The full window is tracked separately because it is its own window.
public enum MiniWindowMode: Equatable, Sendable {
    case hidden
    case capsule
    case card
}

/// How long a closed card stays recoverable.
public enum RetentionPolicy: Equatable, Sendable {
    case clearImmediately
    case minutes(Int)

    public static let `default` = RetentionPolicy.minutes(10)

    var interval: TimeInterval? {
        switch self {
        case .clearImmediately:
            return nil
        case .minutes(let minutes):
            return minutes > 0 ? TimeInterval(minutes * 60) : nil
        }
    }
}

public enum MiniWindowEvent: Equatable, Sendable {
    /// The global shortcut (Option+Space by default).
    case toggleShortcut
    /// "打开小窗" from the menu bar icon. Same as the shortcut, but never hides.
    case openRequested
    /// The mini window lost keyboard focus.
    case resignedKey
    /// Enter in the input. `newConversationID` is used only when no conversation exists yet.
    case send(text: String, newConversationID: UUID)
    case closeCard
    case newConversation
    case expandToFullWindow
    /// The full window shortcut (Option+Shift+Space by default).
    case fullWindowShortcut
    /// "收回小窗" in the full window, carrying the conversation it shows.
    case collapseFullWindow(conversationID: UUID?)
    case fullWindowClosed
    case escape
    case generationStarted
    case generationFinished
    case retentionExpired(token: Int)
}

public enum MiniWindowEffect: Equatable, Sendable {
    case showCapsule
    case showCard
    case scrollToBottom
    case focusInput
    case bringToFront
    case hide
    case appendUserMessage(text: String, conversationID: UUID)
    case clearDraft
    case scheduleRetentionExpiry(token: Int, after: TimeInterval)
    case cancelRetentionExpiry
    /// The mini window lets go of this conversation. It stays in history.
    case endConversation(UUID)
    case openFullWindow(conversationID: UUID?)
    case closeFullWindow
    case stopGeneration
}

/// The mini window's state transitions, as specified in the "状态转换" table.
/// Pure logic: the app feeds it events and performs the effects it returns.
public struct MiniWindowState: Equatable, Sendable {
    public private(set) var mode: MiniWindowMode = .hidden
    /// The conversation shown in the card, or kept while recoverable.
    public private(set) var conversationID: UUID?
    /// True while a closed card can be brought back by the shortcut.
    public private(set) var isRecoverable = false
    public private(set) var isGenerating = false
    public private(set) var isFullWindowOpen = false
    public private(set) var retentionToken = 0
    public var retentionPolicy: RetentionPolicy

    public init(retentionPolicy: RetentionPolicy = .default) {
        self.retentionPolicy = retentionPolicy
    }

    /// Applies an event. `isKey` is whether the mini window currently has keyboard focus.
    public mutating func handle(_ event: MiniWindowEvent, isKey: Bool) -> [MiniWindowEffect] {
        switch event {
        case .toggleShortcut:
            return handleShortcut(isKey: isKey, mayHide: true)

        case .openRequested:
            return handleShortcut(isKey: isKey, mayHide: false)

        case .resignedKey:
            guard mode == .capsule else { return [] }
            mode = .hidden
            return [.hide]

        case let .send(text, newConversationID):
            return handleSend(text: text, newConversationID: newConversationID)

        case .closeCard:
            guard mode == .card else { return [] }
            mode = .hidden
            var effects: [MiniWindowEffect] = [.hide]
            guard let id = conversationID else { return effects }
            if let interval = retentionPolicy.interval {
                isRecoverable = true
                retentionToken += 1
                effects.append(.scheduleRetentionExpiry(token: retentionToken, after: interval))
            } else {
                effects.append(.endConversation(id))
                conversationID = nil
            }
            return effects

        case .newConversation:
            guard mode == .card else { return [] }
            var effects: [MiniWindowEffect] = []
            if isGenerating {
                effects.append(.stopGeneration)
            }
            if let id = conversationID {
                effects.append(.endConversation(id))
            }
            conversationID = nil
            isRecoverable = false
            mode = .capsule
            effects += [.showCapsule, .focusInput]
            return effects

        case .expandToFullWindow:
            return openFullWindowFromMini()

        case .fullWindowShortcut:
            if mode == .hidden {
                isFullWindowOpen = true
                return [.openFullWindow(conversationID: nil)]
            }
            return openFullWindowFromMini()

        case let .collapseFullWindow(fullWindowConversation):
            guard isFullWindowOpen else { return [] }
            isFullWindowOpen = false
            var effects: [MiniWindowEffect] = [.closeFullWindow]
            if isRecoverable {
                effects.append(.cancelRetentionExpiry)
                isRecoverable = false
            }
            if let previous = conversationID, previous != fullWindowConversation {
                effects.append(.endConversation(previous))
            }
            if let id = fullWindowConversation {
                conversationID = id
                mode = .card
                effects += [.showCard, .scrollToBottom, .focusInput]
            } else {
                conversationID = nil
                mode = .capsule
                effects += [.showCapsule, .focusInput]
            }
            return effects

        case .fullWindowClosed:
            isFullWindowOpen = false
            return []

        case .escape:
            guard mode == .card, isGenerating else { return [] }
            return [.stopGeneration]

        case .generationStarted:
            isGenerating = true
            return []

        case .generationFinished:
            isGenerating = false
            return []

        case let .retentionExpired(token):
            guard mode == .hidden, isRecoverable, token == retentionToken, let id = conversationID else {
                return []
            }
            isRecoverable = false
            conversationID = nil
            return [.endConversation(id)]
        }
    }

    private mutating func handleShortcut(isKey: Bool, mayHide: Bool) -> [MiniWindowEffect] {
        switch mode {
        case .hidden:
            if isRecoverable, conversationID != nil {
                isRecoverable = false
                mode = .card
                return [.cancelRetentionExpiry, .showCard, .scrollToBottom, .focusInput]
            }
            mode = .capsule
            return [.showCapsule, .focusInput]
        case .capsule:
            if isKey {
                guard mayHide else { return [] }
                mode = .hidden
                return [.hide]
            }
            return [.bringToFront, .focusInput]
        case .card:
            return isKey ? [] : [.bringToFront, .focusInput]
        }
    }

    private mutating func handleSend(text: String, newConversationID: UUID) -> [MiniWindowEffect] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        switch mode {
        case .hidden:
            return []
        case .capsule:
            let id = conversationID ?? newConversationID
            conversationID = id
            mode = .card
            return [.showCard, .appendUserMessage(text: text, conversationID: id), .clearDraft, .scrollToBottom, .focusInput]
        case .card:
            guard !isGenerating, let id = conversationID else { return [] }
            return [.appendUserMessage(text: text, conversationID: id), .clearDraft, .scrollToBottom]
        }
    }

    private mutating func openFullWindowFromMini() -> [MiniWindowEffect] {
        switch mode {
        case .hidden:
            return []
        case .capsule:
            mode = .hidden
            isFullWindowOpen = true
            return [.hide, .openFullWindow(conversationID: nil)]
        case .card:
            let id = conversationID
            mode = .hidden
            conversationID = nil
            isRecoverable = false
            isFullWindowOpen = true
            return [.hide, .openFullWindow(conversationID: id)]
        }
    }
}
