import Foundation
import Testing
@testable import SpotCore

@Suite struct DraftStorageTests {
    func makeDefaults() -> UserDefaults {
        let name = "SpotCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func draftSurvivesANewStorageInstance() {
        let defaults = makeDefaults()
        UserDefaultsDraftStorage(defaults: defaults).saveDraft("还没发出去的话\n第二行")
        #expect(UserDefaultsDraftStorage(defaults: defaults).loadDraft() == "还没发出去的话\n第二行")
    }

    @Test func emptyDraftClearsStoredValue() {
        let defaults = makeDefaults()
        let storage = UserDefaultsDraftStorage(defaults: defaults)
        storage.saveDraft("草稿")
        storage.saveDraft("")
        #expect(storage.loadDraft() == "")
        #expect(defaults.object(forKey: UserDefaultsDraftStorage.defaultKey) == nil)
    }
}

@Suite struct EchoResponderTests {
    @Test func repliesWithLastUserMessage() async throws {
        let messages = [
            ChatMessage(role: .user, text: "第一条"),
            ChatMessage(role: .assistant, text: "第一条"),
            ChatMessage(role: .user, text: "第二条"),
        ]
        var reply = ""
        for try await chunk in EchoResponder().reply(to: messages) {
            reply += chunk
        }
        #expect(reply == "第二条")
    }
}
