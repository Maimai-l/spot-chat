import Foundation
import Testing
@testable import SpotCore

@Suite struct ChatRequestBuilderTests {
    let imageURL = URL(fileURLWithPath: "/tmp/photo.png")
    let fileURL = URL(fileURLWithPath: "/tmp/notes.txt")

    func load(_ attachment: Attachment) -> AttachmentContent {
        attachment.kind == .image ? .image(data: Data([1, 2, 3]), mimeType: "image/png") : .text("file body")
    }

    @Test func keepsConversationOrderAndSkipsFailedOrEmptyReplies() {
        let history = [
            ChatMessage(role: .user, text: "first"),
            ChatMessage(role: .assistant, text: "answer"),
            ChatMessage(role: .user, text: "second"),
            ChatMessage(role: .assistant, text: "", status: .error, errorMessage: "boom"),
            ChatMessage(role: .user, text: "third"),
            ChatMessage(role: .assistant, text: "", status: .pending),
        ]
        let messages = ChatRequestBuilder.messages(from: history, loadAttachment: load)
        #expect(messages == [
            ChatRequestMessage(role: .user, parts: [.text("first")]),
            ChatRequestMessage(role: .assistant, parts: [.text("answer")]),
            ChatRequestMessage(role: .user, parts: [.text("second")]),
            ChatRequestMessage(role: .user, parts: [.text("third")]),
        ])
    }

    @Test func stoppedReplyIsKept() {
        let history = [
            ChatMessage(role: .user, text: "q"),
            ChatMessage(role: .assistant, text: "partial", status: .paused),
        ]
        let messages = ChatRequestBuilder.messages(from: history, loadAttachment: load)
        #expect(messages.last == ChatRequestMessage(role: .assistant, parts: [.text("partial")]))
    }

    @Test func attachmentsBecomeImageAndTextParts() {
        let image = Attachment(name: "photo", ext: "png", size: 3, fileURL: imageURL)
        let file = Attachment(name: "notes", ext: "txt", size: 9, fileURL: fileURL)
        let history = [ChatMessage(role: .user, text: "look", attachments: [image, file])]
        let messages = ChatRequestBuilder.messages(from: history, loadAttachment: load)
        #expect(messages == [ChatRequestMessage(role: .user, parts: [
            .text("look"),
            .image(data: Data([1, 2, 3]), mimeType: "image/png"),
            .text("[File: notes.txt]\n```\nfile body\n```"),
        ])])
    }

    @Test func attachmentWithoutTextIsSent() {
        let image = Attachment(name: "photo", ext: "png", size: 3, fileURL: imageURL)
        let messages = ChatRequestBuilder.messages(from: [ChatMessage(role: .user, text: "", attachments: [image])], loadAttachment: load)
        #expect(messages.count == 1)
        #expect(messages[0].parts == [.image(data: Data([1, 2, 3]), mimeType: "image/png")])
    }

    @Test func imageKindComesFromTheExtension() {
        #expect(Attachment(name: "a", ext: "JPG", size: 0, fileURL: imageURL).kind == .image)
        #expect(Attachment(name: "a", ext: "pdf", size: 0, fileURL: imageURL).kind == .file)
        #expect(Attachment(name: "Makefile", ext: nil, size: 0, fileURL: imageURL).kind == .file)
    }

    @Test func fileNamesSplitAtTheLastDot() {
        #expect(Attachment.split(fileName: "report.final.pdf") == ("report.final", "pdf"))
        #expect(Attachment.split(fileName: "Makefile") == ("Makefile", nil))
    }

    @Test func echoRepliesWithTheLastUserText() async throws {
        let request = ChatRequest(model: "m", messages: [
            ChatRequestMessage(role: .user, parts: [.text("one")]),
            ChatRequestMessage(role: .assistant, parts: [.text("one")]),
            ChatRequestMessage(role: .user, parts: [.text("two")]),
        ])
        var reply = ""
        for try await chunk in EchoResponder().reply(to: request) {
            reply += chunk
        }
        #expect(reply == "two")
    }
}

@Suite struct ProviderEndpointTests {
    @Test func parsesAFullBaseURL() {
        let endpoint = ProviderEndpoint(baseURL: "https://api.openai.com/v1")
        #expect(endpoint == ProviderEndpoint(scheme: "https", host: "api.openai.com", port: 443, basePath: "/v1"))
    }

    @Test func builtInTemplatesHaveValidEndpoints() {
        #expect(ProviderEndpoint(baseURL: ProviderTemplate.deepSeek.baseURL)
            == ProviderEndpoint(scheme: "https", host: "api.deepseek.com", port: 443, basePath: "/v1"))
        #expect(ProviderEndpoint(baseURL: ProviderTemplate.openAI.baseURL)
            == ProviderEndpoint(scheme: "https", host: "api.openai.com", port: 443, basePath: "/v1"))
        #expect(ProviderTemplate.all.map(\.name) == ["DeepSeek", "OpenAI", "Ollama", "LM Studio"])
        #expect(ProviderEndpoint(baseURL: ProviderTemplate.ollama.baseURL)
            == ProviderEndpoint(scheme: "http", host: "localhost", port: 11434, basePath: "/v1"))
    }

    @Test func parsesALocalServerWithPort() {
        let endpoint = ProviderEndpoint(baseURL: "http://localhost:11434/v1/")
        #expect(endpoint == ProviderEndpoint(scheme: "http", host: "localhost", port: 11434, basePath: "/v1"))
    }

    @Test func addsHTTPSWhenTheSchemeIsMissing() {
        #expect(ProviderEndpoint(baseURL: "api.deepseek.com")?.scheme == "https")
        #expect(ProviderEndpoint(baseURL: "api.deepseek.com")?.basePath == "")
    }

    @Test func dropsAPastedEndpointPath() {
        #expect(ProviderEndpoint(baseURL: "https://example.com/v1/chat/completions")?.basePath == "/v1")
    }

    @Test func rejectsUnusableURLs() {
        #expect(ProviderEndpoint(baseURL: "") == nil)
        #expect(ProviderEndpoint(baseURL: "ftp://example.com") == nil)
        #expect(ProviderEndpoint(baseURL: "https://") == nil)
    }

    @Test func modelIDsCombineProviderAndModel() {
        #expect(ProviderModel(providerID: "p1", modelID: "gpt-4.1").id == "p1::gpt-4.1")
    }
}

extension ProviderEndpoint {
    init(scheme: String, host: String, port: Int, basePath: String) {
        self = ProviderEndpoint(baseURL: "\(scheme)://\(host):\(port)\(basePath)")!
    }
}

@Suite struct TopicNameTests {
    @Test func usesTheFirstNonEmptyLine() {
        #expect(TopicName.make(fromFirstMessage: "\n  SQLite 的 WAL 模式是什么？\n怎么开？") == "SQLite 的 WAL 模式是什么？")
    }

    @Test func shortensLongLines() {
        let name = TopicName.make(fromFirstMessage: String(repeating: "a", count: 60))
        #expect(name.count == TopicName.maxLength + 1)
        #expect(name.hasSuffix("…"))
    }
}

@Suite struct RetentionPolicyTests {
    @Test func storedMinutesRoundTrip() {
        for option in RetentionPolicy.options {
            #expect(RetentionPolicy(storedMinutes: option.storedMinutes) == option)
        }
    }

    @Test func storedValuesAreClampedToThirtyMinutes() {
        #expect(RetentionPolicy(storedMinutes: 90) == .minutes(30))
        #expect(RetentionPolicy(storedMinutes: -3) == .clearImmediately)
    }
}

@Suite struct TopicTitleTests {
    @Test func cleansTheModelsReply() {
        #expect(TopicTitle.clean("\"Python Snake Game\"") == "Python Snake Game")
        #expect(TopicTitle.clean("Title: Friendly Greeting.") == "Friendly Greeting")
        #expect(TopicTitle.clean("「敏感性分析是什么」") == "敏感性分析是什么")
        #expect(TopicTitle.clean("标题：时区换算。") == "时区换算")
        #expect(TopicTitle.clean("**C++ Modulo Operator**\nIt explains…") == "C++ Modulo Operator")
        #expect(TopicTitle.clean("<think>The user greets me.</think>\n\nFriendly Greeting") == "Friendly Greeting")
        #expect(TopicTitle.clean("<think>still thinking") == nil)
        #expect(TopicTitle.clean("  \n ") == nil)
    }

    @Test func longTitlesAreShortened() {
        let title = TopicTitle.clean(String(repeating: "word ", count: 20))
        #expect(title?.count == TopicName.maxLength + 1)
    }

    @Test func requestCarriesTheInstructionAndTheExchange() {
        let request = TopicTitle.request(model: "m", question: "hi, write a python game", answer: "Here is a game")
        #expect(request.model == "m")
        guard case let .text(prompt) = request.messages.first?.parts.first else {
            Issue.record("No text")
            return
        }
        #expect(prompt.hasPrefix(TopicTitle.instruction))
        #expect(prompt.contains("User: hi, write a python game"))
        #expect(prompt.contains("Assistant: Here is a game"))
    }
}

struct ThinkTagSplitterTests {
    func split(_ pieces: [String]) -> (thinking: String, text: String) {
        var splitter = ThinkTagSplitter()
        var chunks = pieces.flatMap { splitter.feed($0) }
        chunks += splitter.finish()
        var thinking = "", text = ""
        for chunk in chunks {
            switch chunk {
            case let .reasoning(part): thinking += part
            case let .text(part): text += part
            case .usage: break
            }
        }
        return (thinking, text)
    }

    @Test func aLeadingThinkBlockIsThinking() {
        let result = split(["<think>Let me see.</think>\n\nFour."])
        #expect(result.thinking == "Let me see.")
        #expect(result.text == "Four.")
    }

    @Test func tagsCutAcrossPiecesStillCount() {
        let result = split(["  <thi", "nk>Let ", "me see.</th", "ink>", "Four", "."])
        #expect(result.thinking == "Let me see.")
        #expect(result.text == "Four.")
    }

    @Test func aReplyWithoutTagsIsLeftAlone() {
        #expect(split(["Hello ", "<think> is a tag"]).text == "Hello <think> is a tag")
        #expect(split(["<", "b>bold</b>"]).text == "<b>bold</b>")
        #expect(split(["<thinking about it"]).text == "<thinking about it")
    }

    @Test func anUnfinishedThinkBlockStaysThinking() {
        let result = split(["<think>Still going"])
        #expect(result.thinking == "Still going")
        #expect(result.text == "")
    }
}

struct ConversationExportTests {
    @Test func followsCherryStudiosLayout() {
        let markdown = ConversationExport.markdown(title: "Circles", messages: [
            ChatMessage(role: .user, text: "Area?"),
            ChatMessage(role: .assistant, text: "Use $\\pi r^2$."),
            ChatMessage(role: .assistant, text: "", status: .error, errorMessage: "Failed"),
        ])
        #expect(markdown == "# Circles\n\n## 🧑‍💻 User\n\nArea?\n\n---\n## 🤖 Assistant\n\nUse $\\pi r^2$.\n")
    }

    @Test func fileNamesLeaveOutReservedCharacters() {
        #expect(ConversationExport.fileName(for: "a/b: c?") == "a b  c.md")
        #expect(ConversationExport.fileName(for: "  ") == "Conversation.md")
    }

    @Test func selectionsAreQuoted() {
        #expect(SelectionQuote.draft(quoting: "  one\n\ntwo \n") == "> one\n>\n> two\n\n")
        #expect(SelectionQuote.draft(quoting: " \n ") == nil)
    }
}

struct PromptVariablesTests {
    let context = PromptVariables.Context(
        start: Date(timeIntervalSince1970: 1_798_000_000), modelName: "deepseek-chat", userName: "Mai",
        systemName: "macOS 15.4", languageName: "English", architecture: "arm64",
        locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!
    )

    @Test func placeholdersAreFilledIn() {
        let prompt = "Today is {{date}} at {{time}}. User {{username}} on {{system}} ({{arch}}), {{language}}, via {{model_name}}."
        let resolved = PromptVariables.resolve(prompt, in: context)
        #expect(!resolved.contains("{{"), "\(resolved)")
        #expect(resolved.contains("User Mai on macOS 15.4 (arm64), English, via deepseek-chat."))
        #expect(resolved.contains("2026"), "\(resolved)")
    }

    @Test func theSameConversationGetsTheSamePrompt() {
        let prompt = "Now: {{datetime}}"
        #expect(PromptVariables.resolve(prompt, in: context) == PromptVariables.resolve(prompt, in: context))
    }

    @Test func promptsWithoutPlaceholdersAreUntouched() {
        #expect(PromptVariables.resolve("You are a helpful assistant.", in: context) == "You are a helpful assistant.")
        #expect(PromptVariables.resolve("Keep {{unknown}} as is", in: context) == "Keep {{unknown}} as is")
    }
}
