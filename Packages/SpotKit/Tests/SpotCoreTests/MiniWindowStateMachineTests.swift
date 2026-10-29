import Foundation
import Testing
@testable import SpotCore

/// One test per cell of the "状态转换" table, plus the rules around it.
@Suite struct MiniWindowStateMachineTests {
    let conversation = UUID()

    func capsuleState(policy: RetentionPolicy = .default) -> MiniWindowState {
        var state = MiniWindowState(retentionPolicy: policy)
        _ = state.handle(.toggleShortcut, isKey: false)
        return state
    }

    func cardState(policy: RetentionPolicy = .default) -> MiniWindowState {
        var state = capsuleState(policy: policy)
        _ = state.handle(.send(text: "你好", newConversationID: conversation), isKey: true)
        return state
    }

    func closedCardState(policy: RetentionPolicy = .default) -> MiniWindowState {
        var state = cardState(policy: policy)
        _ = state.handle(.closeCard, isKey: true)
        return state
    }

    // MARK: Option+Space

    @Test func shortcutWhenHiddenWithoutRecoverableConversationShowsCapsule() {
        var state = MiniWindowState()
        let effects = state.handle(.toggleShortcut, isKey: false)
        #expect(state.mode == .capsule)
        #expect(effects == [.showCapsule, .focusInput])
    }

    @Test func shortcutWhenHiddenWithRecoverableConversationShowsCard() {
        var state = closedCardState()
        let effects = state.handle(.toggleShortcut, isKey: false)
        #expect(state.mode == .card)
        #expect(state.conversationID == conversation)
        #expect(effects == [.cancelRetentionExpiry, .showCard, .scrollToBottom, .focusInput])
    }

    @Test func shortcutWhenCapsuleHasFocusHidesIt() {
        var state = capsuleState()
        let effects = state.handle(.toggleShortcut, isKey: true)
        #expect(state.mode == .hidden)
        #expect(effects == [.hide])
        #expect(!effects.contains(.clearDraft))
    }

    @Test func shortcutWhenCapsuleLacksFocusFocusesIt() {
        var state = capsuleState()
        let effects = state.handle(.toggleShortcut, isKey: false)
        #expect(state.mode == .capsule)
        #expect(effects == [.bringToFront, .focusInput])
    }

    @Test func shortcutWhenCardLacksFocusBringsItToFront() {
        var state = cardState()
        let effects = state.handle(.toggleShortcut, isKey: false)
        #expect(state.mode == .card)
        #expect(effects == [.bringToFront, .focusInput])
    }

    @Test func shortcutWhenCardHasFocusDoesNothing() {
        var state = cardState()
        let effects = state.handle(.toggleShortcut, isKey: true)
        #expect(state.mode == .card)
        #expect(effects.isEmpty)
    }

    @Test func menuOpenNeverHidesTheCapsule() {
        var state = capsuleState()
        let effects = state.handle(.openRequested, isKey: true)
        #expect(state.mode == .capsule)
        #expect(effects.isEmpty)
    }

    // MARK: Focus loss

    @Test func capsuleHidesOnFocusLossAndKeepsDraft() {
        var state = capsuleState()
        let effects = state.handle(.resignedKey, isKey: false)
        #expect(state.mode == .hidden)
        #expect(effects == [.hide])
    }

    @Test func cardStaysOnFocusLoss() {
        var state = cardState()
        let effects = state.handle(.resignedKey, isKey: false)
        #expect(state.mode == .card)
        #expect(effects.isEmpty)
    }

    // MARK: Enter

    @Test func sendFromCapsuleExpandsToCardImmediately() {
        var state = capsuleState()
        let effects = state.handle(.send(text: "你好", newConversationID: conversation), isKey: true)
        #expect(state.mode == .card)
        #expect(state.conversationID == conversation)
        #expect(effects.first == .showCard)
        #expect(effects.contains(.appendUserMessage(text: "你好", conversationID: conversation)))
        #expect(effects.contains(.clearDraft))
    }

    @Test func sendFromCardAppendsToTheSameConversation() {
        var state = cardState()
        let effects = state.handle(.send(text: "再问一个", newConversationID: UUID()), isKey: true)
        #expect(state.conversationID == conversation)
        #expect(effects == [.appendUserMessage(text: "再问一个", conversationID: conversation), .clearDraft, .scrollToBottom])
    }

    @Test func blankTextIsNotSent() {
        var state = capsuleState()
        let effects = state.handle(.send(text: "  \n ", newConversationID: conversation), isKey: true)
        #expect(state.mode == .capsule)
        #expect(effects.isEmpty)
    }

    @Test func attachmentsAloneCanBeSent() {
        var state = capsuleState()
        let effects = state.handle(.send(text: "", hasAttachments: true, newConversationID: conversation), isKey: true)
        #expect(state.mode == .card)
        #expect(effects.contains(.appendUserMessage(text: "", conversationID: conversation)))
    }

    @Test func cannotSendWhileGeneratingAndDraftIsKept() {
        var state = cardState()
        _ = state.handle(.generationStarted, isKey: true)
        let effects = state.handle(.send(text: "下一条", newConversationID: UUID()), isKey: true)
        #expect(effects.isEmpty)
    }

    @Test func clearDraftOnlyHappensOnSend() {
        let events: [MiniWindowEvent] = [
            .toggleShortcut, .resignedKey, .toggleShortcut, .toggleShortcut, .escape, .openRequested,
            .closeCard, .newConversation, .expandToFullWindow, .retentionExpired(token: 1),
        ]
        var state = MiniWindowState()
        for event in events {
            let effects = state.handle(event, isKey: true)
            #expect(!effects.contains(.clearDraft), "\(event) must not clear the draft")
        }
    }

    // MARK: ×

    @Test func closingCardHidesAndStartsRetention() {
        var state = cardState(policy: .minutes(10))
        let effects = state.handle(.closeCard, isKey: true)
        #expect(state.mode == .hidden)
        #expect(state.isRecoverable)
        #expect(effects == [.hide, .scheduleRetentionExpiry(token: 1, after: 600)])
    }

    @Test func closingCardWithClearImmediatelyEndsConversation() {
        var state = cardState(policy: .clearImmediately)
        let effects = state.handle(.closeCard, isKey: true)
        #expect(!state.isRecoverable)
        #expect(state.conversationID == nil)
        #expect(effects == [.hide, .endConversation(conversation)])
        _ = state.handle(.toggleShortcut, isKey: false)
        #expect(state.mode == .capsule)
    }

    @Test func retentionExpiryEndsConversation() {
        var state = closedCardState()
        let effects = state.handle(.retentionExpired(token: state.retentionToken), isKey: false)
        #expect(effects == [.endConversation(conversation)])
        _ = state.handle(.toggleShortcut, isKey: false)
        #expect(state.mode == .capsule)
    }

    @Test func staleRetentionTimerIsIgnored() {
        var state = closedCardState()
        let staleToken = state.retentionToken
        _ = state.handle(.toggleShortcut, isKey: false)
        _ = state.handle(.closeCard, isKey: true)
        let effects = state.handle(.retentionExpired(token: staleToken), isKey: false)
        #expect(effects.isEmpty)
        #expect(state.isRecoverable)
    }

    // MARK: 新对话

    @Test func newConversationCollapsesToCapsule() {
        var state = cardState()
        let effects = state.handle(.newConversation, isKey: true)
        #expect(state.mode == .capsule)
        #expect(state.conversationID == nil)
        #expect(effects == [.endConversation(conversation), .showCapsule, .focusInput])
    }

    @Test func newConversationStopsGenerationFirst() {
        var state = cardState()
        _ = state.handle(.generationStarted, isKey: true)
        let effects = state.handle(.newConversation, isKey: true)
        #expect(effects.first == .stopGeneration)
    }

    // MARK: 展开为完整窗口 / 收回小窗

    @Test func expandFromCapsuleOpensEmptyFullWindow() {
        var state = capsuleState()
        let effects = state.handle(.expandToFullWindow, isKey: true)
        #expect(state.mode == .hidden)
        #expect(state.isFullWindowOpen)
        #expect(effects == [.hide, .openFullWindow(conversationID: nil)])
    }

    @Test func expandFromCardMovesConversationToFullWindow() {
        var state = cardState()
        let effects = state.handle(.expandToFullWindow, isKey: true)
        #expect(state.mode == .hidden)
        #expect(state.conversationID == nil)
        #expect(effects == [.hide, .openFullWindow(conversationID: conversation)])
    }

    @Test func collapseFullWindowShowsSameConversationInCard() {
        var state = cardState()
        _ = state.handle(.expandToFullWindow, isKey: true)
        let effects = state.handle(.collapseFullWindow(conversationID: conversation), isKey: false)
        #expect(state.mode == .card)
        #expect(state.conversationID == conversation)
        #expect(!state.isFullWindowOpen)
        #expect(effects == [.closeFullWindow, .showCard, .scrollToBottom, .focusInput])
    }

    @Test func collapseEmptyFullWindowShowsCapsule() {
        var state = MiniWindowState()
        _ = state.handle(.fullWindowShortcut, isKey: false)
        let effects = state.handle(.collapseFullWindow(conversationID: nil), isKey: false)
        #expect(state.mode == .capsule)
        #expect(effects == [.closeFullWindow, .showCapsule, .focusInput])
    }

    // MARK: Esc

    @Test func escapeStopsGenerationInCard() {
        var state = cardState()
        _ = state.handle(.generationStarted, isKey: true)
        #expect(state.handle(.escape, isKey: true) == [.stopGeneration])
    }

    @Test func escapeDoesNothingOtherwise() {
        var capsule = capsuleState()
        #expect(capsule.handle(.escape, isKey: true).isEmpty)
        #expect(capsule.mode == .capsule)
        var card = cardState()
        #expect(card.handle(.escape, isKey: true).isEmpty)
        #expect(card.mode == .card)
    }
}
