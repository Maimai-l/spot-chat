import Foundation
import Testing
import SpotCore
@testable import SpotData

struct TestStore {
    let database: AppDatabase
    let directory: URL
    let topics: TopicService
    let messages: MessageService
    let files: FileEntryService
    let providers: ProviderService
    let models: ModelService
    let preferences: PreferenceService

    init() throws {
        database = try AppDatabase.inMemory()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SpotDataTests-\(UUID().uuidString)")
        files = FileEntryService(database: database, directory: directory)
        topics = TopicService(database: database)
        messages = MessageService(database: database, files: files)
        providers = ProviderService(database: database)
        models = ModelService(database: database)
        preferences = PreferenceService(database: database)
    }
}

@Suite struct TopicServiceTests {
    @Test func listsMostRecentlyActiveFirst() throws {
        let store = try TestStore()
        let old = try store.topics.create(name: "old", at: Date(timeIntervalSince1970: 100))
        let new = try store.topics.create(name: "new", at: Date(timeIntervalSince1970: 200))
        #expect(try store.topics.list().map(\.id) == [new.id, old.id])

        try store.topics.touch(old.id, at: Date(timeIntervalSince1970: 300))
        #expect(try store.topics.list().map(\.id) == [old.id, new.id])
    }

    @Test func automaticNameNeverReplacesAManualOne() throws {
        let store = try TestStore()
        let topic = try store.topics.create()
        try store.topics.setAutomaticName(topic.id, to: "auto")
        #expect(try store.topics.get(topic.id)?.name == "auto")
        try store.topics.rename(topic.id, to: "mine")
        try store.topics.setAutomaticName(topic.id, to: "auto again")
        #expect(try store.topics.get(topic.id)?.name == "mine")
    }

    @Test func deletingATopicDeletesItsMessages() throws {
        let store = try TestStore()
        let topic = try store.topics.create()
        try store.messages.append(ChatMessage(role: .user, text: "hi"), to: topic.id)
        try store.topics.delete(topic.id)
        #expect(try store.topics.get(topic.id) == nil)
        #expect(try store.messages.list(topicID: topic.id).isEmpty)
    }
}

@Suite struct MessageServiceTests {
    @Test func messagesRoundTripInOrder() throws {
        let store = try TestStore()
        let topic = try store.topics.create()
        let question = ChatMessage(role: .user, text: "问题", createdAt: Date(timeIntervalSince1970: 10))
        let answer = ChatMessage(role: .assistant, text: "回答", status: .pending, modelID: nil, createdAt: Date(timeIntervalSince1970: 10))
        try store.messages.append(question, to: topic.id)
        try store.messages.append(answer, to: topic.id)

        let listed = try store.messages.list(topicID: topic.id)
        #expect(listed.map(\.id) == [question.id, answer.id])
        #expect(listed[0].text == "问题")
        #expect(listed[1].status == .pending)
    }

    @Test func messagesChainToTheirParent() throws {
        let store = try TestStore()
        let topic = try store.topics.create()
        let first = ChatMessage(role: .user, text: "1")
        let second = ChatMessage(role: .assistant, text: "2")
        try store.messages.append(first, to: topic.id)
        try store.messages.append(second, to: topic.id)
        let parent = try store.database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT parentId FROM message WHERE id = ?", arguments: [second.id.uuidString])
        }
        #expect(parent == first.id.uuidString)
    }

    @Test func updateSavesTextStatusAndError() throws {
        let store = try TestStore()
        let topic = try store.topics.create()
        var reply = ChatMessage(role: .assistant, text: "", status: .pending)
        try store.messages.append(reply, to: topic.id)
        reply.text = "partial"
        reply.status = .error
        reply.errorMessage = "Incorrect API key provided."
        try store.messages.update(reply)

        let saved = try store.messages.list(topicID: topic.id)[0]
        #expect(saved.text == "partial")
        #expect(saved.status == .error)
        #expect(saved.errorMessage == "Incorrect API key provided.")
    }

    @Test func assistantPresetsAreStoredAndLinkedToConversations() throws {
        let store = try TestStore()
        let assistants = AssistantService(database: store.database)
        let writer = try assistants.create(name: " Writer ", prompt: "Write plainly.", thinking: .low)
        #expect(writer.name == "Writer")
        #expect(throws: DataError.emptyName) { try assistants.create(name: "  ") }

        var edited = writer
        edited.prompt = "Write briefly."
        try assistants.update(edited)
        #expect(try assistants.get(writer.id)?.prompt == "Write briefly.")
        #expect(try assistants.get(writer.id)?.thinking == .low)

        let topic = try store.topics.create()
        try store.topics.setAssistant(writer.id, for: topic.id)
        #expect(try store.topics.assistantID(of: topic.id) == writer.id)
        try assistants.delete(writer.id)
        #expect(try assistants.list().isEmpty)
        #expect(try store.topics.assistantID(of: topic.id) == nil, "The conversation stays, without the preset")
    }

    @Test func searchFindsConversationsByTheirMessages() throws {
        let store = try TestStore()
        let circles = try store.topics.create(name: "Circles")
        let lunch = try store.topics.create(name: "Lunch")
        try store.messages.append(ChatMessage(role: .user, text: "What is the Area of a circle?"), to: circles.id)
        try store.messages.append(ChatMessage(role: .assistant, text: "午饭吃面条"), to: lunch.id)

        #expect(try store.messages.topicIDs(containing: "area") == [circles.id])
        #expect(try store.messages.topicIDs(containing: "面条") == [lunch.id])
        #expect(try store.messages.topicIDs(containing: "  ").isEmpty)
        #expect(try store.messages.topicIDs(containing: "100%").isEmpty)
    }

    @Test func thinkingIsKeptWithTheReply() throws {
        let store = try TestStore()
        let topic = try store.topics.create()
        var reply = ChatMessage(role: .assistant, text: "", status: .pending)
        try store.messages.append(reply, to: topic.id)
        #expect(try store.messages.list(topicID: topic.id)[0].reasoning == "")

        reply.text = "Four."
        reply.reasoning = "Two plus two is four."
        reply.reasoningDuration = 3.5
        reply.status = .success
        try store.messages.update(reply)

        let saved = try store.messages.list(topicID: topic.id)[0]
        #expect(saved.reasoning == "Two plus two is four.")
        #expect(saved.reasoningDuration == 3.5)
    }

    @Test func attachmentsAreCopiedAndLinked() throws {
        let store = try TestStore()
        let topic = try store.topics.create()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("source-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: source)
        let attachment = try store.files.importFile(at: source)
        try FileManager.default.removeItem(at: source)

        try store.messages.append(ChatMessage(role: .user, text: "see file", attachments: [attachment]), to: topic.id)
        let saved = try store.messages.list(topicID: topic.id)[0]
        #expect(saved.attachments.count == 1)
        #expect(saved.attachments[0].displayName == source.lastPathComponent)
        #expect(try Data(contentsOf: saved.attachments[0].fileURL) == Data("hello".utf8))
    }

    @Test func appendingMarksTheTopicActive() throws {
        let store = try TestStore()
        let topic = try store.topics.create(at: Date(timeIntervalSince1970: 100))
        try store.messages.append(ChatMessage(role: .user, text: "hi", createdAt: Date(timeIntervalSince1970: 500)), to: topic.id)
        #expect(try store.topics.get(topic.id)?.lastActivityAt == Date(timeIntervalSince1970: 500))
    }
}

@Suite struct ProviderServiceTests {
    @Test func providersKeepTheirOrderModelsAndKey() throws {
        let store = try TestStore()
        let openAI = try store.providers.create(name: "OpenAI", baseURL: "https://api.openai.com/v1", apiKey: "sk-1")
        let local = try store.providers.create(name: "Ollama", baseURL: "http://localhost:11434/v1", apiKey: "")
        try store.models.add(modelID: "gpt-4.1", to: openAI.id)
        try store.models.add(modelID: "o4-mini", to: openAI.id)

        let listed = try store.providers.list()
        #expect(listed.map(\.name) == ["OpenAI", "Ollama"])
        #expect(listed[0].apiKey == "sk-1")
        #expect(listed[0].baseURL == "https://api.openai.com/v1")
        #expect(listed[0].models.map(\.modelID) == ["gpt-4.1", "o4-mini"])
        #expect(listed[1].id == local.id)
        #expect(listed[1].models.isEmpty)
    }

    @Test func updateChangesNameURLAndKey() throws {
        let store = try TestStore()
        var provider = try store.providers.create(name: "A", baseURL: "https://a.example/v1", apiKey: "k1")
        provider.name = "B"
        provider.baseURL = "https://b.example/v1"
        provider.apiKey = "k2"
        try store.providers.update(provider)
        let saved = try store.providers.list()[0]
        #expect(saved.name == "B")
        #expect(saved.baseURL == "https://b.example/v1")
        #expect(saved.apiKey == "k2")
    }

    @Test func mergeAddsOnlyNewModels() throws {
        let store = try TestStore()
        let provider = try store.providers.create(name: "A", baseURL: "https://a.example/v1", apiKey: "")
        try store.models.add(modelID: "m1", to: provider.id)
        let added = try store.models.merge(modelIDs: ["m1", "m2", "m3"], into: provider.id)
        #expect(added == 2)
        #expect(try store.providers.list()[0].models.map(\.modelID) == ["m1", "m2", "m3"])
    }

    @Test func blankModelIDIsRejected() throws {
        let store = try TestStore()
        let provider = try store.providers.create(name: "A", baseURL: "https://a.example/v1", apiKey: "")
        #expect(throws: DataError.invalidModelID) {
            try store.models.add(modelID: "  ", to: provider.id)
        }
    }

    @Test func deletingAProviderDeletesItsModelsAndKeepsMessages() throws {
        let store = try TestStore()
        let provider = try store.providers.create(name: "A", baseURL: "https://a.example/v1", apiKey: "")
        let model = try store.models.add(modelID: "m1", to: provider.id)
        let topic = try store.topics.create()
        try store.messages.append(ChatMessage(role: .assistant, text: "old reply", modelID: model.id), to: topic.id)

        try store.providers.delete(provider.id)
        #expect(try store.providers.list().isEmpty)
        let reply = try store.messages.list(topicID: topic.id)[0]
        #expect(reply.text == "old reply")
        #expect(reply.modelID == nil)
    }
}

@Suite struct BuiltInProviderTests {
    @Test func builtInProvidersAreAddedOnceAndListedFirst() throws {
        let store = try TestStore()
        let own = try store.providers.create(name: "Mine", baseURL: "https://mine.example/v1", apiKey: "k")
        try store.providers.ensureBuiltInProviders()
        try store.providers.ensureBuiltInProviders()
        let listed = try store.providers.list()
        #expect(listed.map(\.id) == ["deepseek", "openai", "ollama", "lmstudio", own.id])
        #expect(listed[0].baseURL == "https://api.deepseek.com/v1")
        #expect(listed[0].isBuiltIn)
        #expect(!listed[4].isBuiltIn)
    }

    @Test func builtInProvidersCanBeTurnedOffButNotDeleted() throws {
        let store = try TestStore()
        try store.providers.ensureBuiltInProviders()
        try store.providers.setEnabled("openai", false)
        #expect(try store.providers.list().first { $0.id == "openai" }?.isEnabled == false)
        #expect(throws: DataError.builtInProvider) {
            try store.providers.delete("openai")
        }
    }

    @Test func emptyCopiesFromAnEarlierAlphaAreReplaced() throws {
        let store = try TestStore()
        _ = try store.providers.create(name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", apiKey: "")
        let keyed = try store.providers.create(name: "OpenAI", baseURL: "https://api.openai.com/v1", apiKey: "sk-1")
        try store.providers.ensureBuiltInProviders()
        let listed = try store.providers.list()
        #expect(listed.map(\.id) == ["deepseek", "openai", "ollama", "lmstudio", keyed.id], "The one with a key stays")
    }
}

@Suite struct PreferenceServiceTests {
    @Test func valuesRoundTripAsJSON() throws {
        let store = try TestStore()
        try store.preferences.set(PreferenceKey.cardHeight, to: 600)
        try store.preferences.set(PreferenceKey.defaultModel, to: "p::m")
        #expect(try store.preferences.value(PreferenceKey.cardHeight, as: Int.self) == 600)
        #expect(try store.preferences.value(PreferenceKey.defaultModel, as: String.self) == "p::m")

        try store.preferences.set(PreferenceKey.cardHeight, to: 640)
        #expect(try store.preferences.value(PreferenceKey.cardHeight, as: Int.self) == 640)

        try store.preferences.remove(PreferenceKey.cardHeight)
        #expect(try store.preferences.value(PreferenceKey.cardHeight, as: Int.self) == nil)
    }
}

@Suite struct FileEntryServiceTests {
    @Test func pendingAttachmentsCanBeLookedUpAgain() throws {
        let store = try TestStore()
        let first = try store.files.importData(Data([1]), fileName: "a.png")
        let second = try store.files.importData(Data("x".utf8), fileName: "notes.txt")
        let missing = UUID()
        let found = try store.files.attachments(withIDs: [second.id, missing, first.id])
        #expect(found.map(\.id) == [second.id, first.id])
        #expect(found[0].displayName == "notes.txt")
        #expect(found[1].kind == .image)
    }

    @Test func attachmentsWhoseFileIsGoneAreSkipped() throws {
        let store = try TestStore()
        let attachment = try store.files.importData(Data([1]), fileName: "a.png")
        try FileManager.default.removeItem(at: attachment.fileURL)
        #expect(try store.files.attachments(withIDs: [attachment.id]).isEmpty)
    }
}
