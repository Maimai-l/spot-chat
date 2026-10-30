import AppKit
import XCTest

/// End-to-end checks on a real macOS session, against scripts/mock_openai_server.py.
/// The global shortcut cannot be pressed from a test, so the app is told to open the capsule on launch.
final class SpotChatUITests: XCTestCase {
    static let mockURL = "http://127.0.0.1:8765/v1"
    let dataDirectory = NSTemporaryDirectory() + "SpotChatUITests"

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: Helpers

    func launch(resetState: Bool, provider: Bool = true, language: String = "en", fullWindow: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-SpotChatShowMiniOnLaunch", "YES",
            "-AppleLanguages", "(\(language))",
            "-SpotChatDataDirectory", dataDirectory,
        ]
        if resetState {
            app.launchArguments += ["-SpotChatResetState", "YES"]
        }
        if provider {
            app.launchArguments += ["-SpotChatTestProviderURL", Self.mockURL, "-SpotChatTestProviderKey", "test-key"]
        }
        if fullWindow {
            app.launchArguments += ["-SpotChatShowFullWindowOnLaunch", "YES"]
        }
        app.launch()
        return app
    }

    func composer(in app: XCUIApplication) -> XCUIElement {
        app.textViews["composer"].firstMatch
    }

    func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The reply whose text contains the string, wherever it is in the conversation.
    func reply(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND (value CONTAINS %@ OR label CONTAINS %@)", "message.assistant", text, text
        )).firstMatch
    }

    func elements(_ identifier: String, in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: identifier)
    }

    func text(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    func send(_ message: String, in app: XCUIApplication) {
        let input = composer(in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.click()
        input.typeText(message)
        input.typeKey(.return, modifierFlags: [])
    }

    /// Waits until the reply's text satisfies the predicate, e.g. "SELF == 'Echo: hi'".
    func waitForReply(in app: XCUIApplication, _ format: String, _ argument: String, timeout: TimeInterval = 10) {
        let reply = element("message.assistant", in: app)
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        waitForText(of: reply, format, argument, timeout: timeout)
    }

    /// Polls the element's text (its value, or its label when it has no value) until it matches.
    func waitForText(of element: XCUIElement, _ format: String, _ argument: String, timeout: TimeInterval = 10) {
        let predicate = NSPredicate(format: format, argument)
        let deadline = Date().addingTimeInterval(timeout)
        var current = text(of: element)
        while !predicate.evaluate(with: current), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            current = text(of: element)
        }
        XCTAssertTrue(predicate.evaluate(with: current), "Text was: \(current)")
    }

    /// Clicks the middle of the element, for small buttons XCTest reports as not hittable inside scroll views.
    func tap(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func moveFocusToAnotherApp() {
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
    }

    func lastRequest() throws -> [String: Any] {
        let data = try Data(contentsOf: URL(string: Self.mockURL + "/last-request")!)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    // MARK: Mini window

    func testSendingStreamsTheReplyInTheCard() {
        let app = launch(resetState: true)
        send("hello spot", in: app)

        let question = element("message.user", in: app)
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        XCTAssertEqual(text(of: question), "hello spot")
        waitForReply(in: app, "SELF == %@", "Echo: hello spot")
        XCTAssertEqual(text(of: composer(in: app)), "")
        XCTAssertTrue(app.buttons["New Chat"].exists)
    }

    func testShiftEnterAddsALineInsteadOfSending() {
        let app = launch(resetState: true)
        let input = composer(in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.click()
        input.typeText("line one")
        input.typeKey(.return, modifierFlags: .shift)
        input.typeText("line two")

        XCTAssertFalse(element("message.user", in: app).exists)
        XCTAssertEqual(text(of: input), "line one\nline two")
    }

    func testDraftSurvivesFocusLossAndRelaunch() {
        var app = launch(resetState: true)
        var input = composer(in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.click()
        input.typeText("draft that must survive")

        moveFocusToAnotherApp()
        XCTAssertTrue(input.waitForNonExistence(timeout: 5), "The capsule hides when it loses focus")

        app.terminate()
        app = launch(resetState: false)
        input = composer(in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertEqual(text(of: input), "draft that must survive")
    }

    func testEscapeKeepsTheCapsuleAndTheDraft() {
        let app = launch(resetState: true)
        let input = composer(in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.click()
        input.typeText("keep me")
        input.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(input.exists)
        XCTAssertEqual(text(of: input), "keep me")
    }

    func testCardStaysOnScreenWhenFocusMovesAway() {
        let app = launch(resetState: true)
        send("stay", in: app)
        let question = element("message.user", in: app)
        XCTAssertTrue(question.waitForExistence(timeout: 5))

        moveFocusToAnotherApp()
        sleep(1)
        XCTAssertTrue(question.exists, "The card stays like a sticky note")
    }

    func testCapsuleCanBeDragged() {
        let app = launch(resetState: true)
        let input = composer(in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        let before = input.frame

        // The capsule's left padding, before the + button.
        let plus = element("plusMenu", in: app)
        let start = plus.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: -5, dy: 0))
        let end = start.withOffset(CGVector(dx: 120, dy: 80))
        start.click(forDuration: 0.3, thenDragTo: end)

        let after = input.frame
        XCTAssertGreaterThan(abs(after.minX - before.minX), 60)
        XCTAssertGreaterThan(abs(after.minY - before.minY), 40)
    }

    func testInterfaceIsTranslatedForSimplifiedChinese() {
        let app = launch(resetState: true, language: "zh-Hans")
        send("hi", in: app)

        XCTAssertTrue(app.buttons["新对话"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["关闭"].exists)
    }

    // MARK: Replies

    func testMarkdownCodeBlockCanBeCopied() {
        let app = launch(resetState: true)
        send("markdown", in: app)
        waitForReply(in: app, "SELF CONTAINS %@", "| WAL | concurrent |")

        // The button is inside the reply's web page; its label comes from the app's strings.
        let copy = app.webViews.buttons.matching(NSPredicate(format: "label == %@", "Copy Code")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        NSPasteboard.general.clearContents()
        tap(copy)
        // The page hands the code to the app, which writes the pasteboard a moment later.
        let deadline = Date().addingTimeInterval(3)
        var copied = NSPasteboard.general.string(forType: .string)
        while copied == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            copied = NSPasteboard.general.string(forType: .string)
        }
        XCTAssertEqual(copied?.trimmingCharacters(in: .whitespacesAndNewlines), "PRAGMA journal_mode = WAL;")
    }

    func testEscapeStopsGenerationAndKeepsThePartialReply() {
        let app = launch(resetState: true)
        send("slow", in: app)
        waitForReply(in: app, "SELF CONTAINS %@", "tick 2")
        XCTAssertTrue(element("stop", in: app).exists)

        composer(in: app).typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(element("stop", in: app).waitForNonExistence(timeout: 5))
        let reply = element("message.assistant", in: app)
        let stopped = text(of: reply)
        sleep(1)
        XCTAssertEqual(text(of: reply), stopped, "Nothing more arrives after stopping")
        XCTAssertTrue(stopped.hasPrefix("tick 0"))
        XCTAssertFalse(stopped.contains("tick 59"))
    }

    func testStopButtonStopsGeneration() {
        let app = launch(resetState: true)
        send("slow", in: app)
        waitForReply(in: app, "SELF CONTAINS %@", "tick 1")
        element("stop", in: app).click()
        XCTAssertTrue(element("stop", in: app).waitForNonExistence(timeout: 5))
    }

    func testErrorShowsTheServiceMessageWithRetry() {
        let app = launch(resetState: true)
        send("fail", in: app)

        let error = element("message.error", in: app)
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertEqual(text(of: error), "The server had an error.")
        let retry = element("retry", in: app)
        XCTAssertTrue(retry.exists)
        retry.click()
        XCTAssertTrue(element("message.error", in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(elements("message.error", in: app).count, 1, "Retry replaces the failed reply")
    }

    func testRegenerateReplacesTheReplyAndCopyCopiesIt() {
        let app = launch(resetState: true)
        send("hello", in: app)
        waitForReply(in: app, "SELF == %@", "Echo: hello")

        element("regenerate", in: app).click()
        waitForReply(in: app, "SELF == %@", "Echo: hello")
        XCTAssertEqual(elements("message.assistant", in: app).count, 1)

        NSPasteboard.general.clearContents()
        element("copyReply", in: app).click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Echo: hello")
    }

    func testFollowUpQuestionsKeepTheConversation() throws {
        let app = launch(resetState: true)
        send("first", in: app)
        waitForReply(in: app, "SELF == %@", "Echo: first")
        send("second", in: app)
        let second = elements("message.assistant", in: app).element(boundBy: 1)
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        waitForText(of: second, "SELF == %@", "Echo: second")

        let messages = try lastRequest()["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(messages.count, 3, "The earlier question and answer are sent along")
    }

    // MARK: Models and settings

    func testModelMenuSwitchesTheModel() throws {
        let app = launch(resetState: true)
        let menu = element("modelMenu", in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.click()
        let item = app.menuItems["mock-vision"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()

        XCTAssertTrue(composer(in: app).waitForExistence(timeout: 5), "Picking a model keeps the capsule open")
        send("hi", in: app)
        waitForReply(in: app, "SELF == %@", "Echo: hi")
        XCTAssertEqual(try lastRequest()["model"] as? String, "mock-vision")
    }

    func testWithoutAModelTheReplyExplainsWhatToDo() {
        let app = launch(resetState: true, provider: false)
        XCTAssertTrue(element("addModel", in: app).waitForExistence(timeout: 10))
        send("hi", in: app)
        let error = element("message.error", in: app)
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(text(of: error), "Add a model in Settings to get replies.")
    }

    func testAddingAProviderInSettings() {
        var app = launch(resetState: true, provider: false)
        let addModel = element("addModel", in: app)
        XCTAssertTrue(addModel.waitForExistence(timeout: 10))
        addModel.click()

        let addProvider = element("addProvider", in: app)
        XCTAssertTrue(addProvider.waitForExistence(timeout: 10), "Settings opens")
        XCTAssertTrue(element("providerList", in: app).staticTexts["DeepSeek"].exists, "Built-in providers are listed")
        XCTAssertTrue(element("providerList", in: app).staticTexts["OpenAI"].exists)
        addProvider.click()

        let url = app.textFields["providerURL"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.click()
        url.typeText(Self.mockURL)
        let key = app.secureTextFields["providerKey"]
        key.click()
        key.typeText("test-key")

        element("fetchModels", in: app).click()
        let result = element("fetchResult", in: app)
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertEqual(text(of: result), "2 models added")

        app.terminate()
        app = launch(resetState: false, provider: false)
        let menu = element("modelMenu", in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "The new models are offered")
        send("saved", in: app)
        waitForReply(in: app, "SELF == %@", "Echo: saved")
    }

    // MARK: Attachments

    func pasteIntoComposer(_ app: XCUIApplication) {
        let input = composer(in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.click()
        input.typeKey("v", modifierFlags: .command)
    }

    func testPastingTextWorks() {
        let app = launch(resetState: true)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("pasted words", forType: .string)
        pasteIntoComposer(app)
        XCTAssertEqual(text(of: composer(in: app)), "pasted words")
    }

    func testPastedImageIsSentAsAnImage() throws {
        let app = launch(resetState: true)
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        pasteIntoComposer(app)
        XCTAssertTrue(element("attachment", in: app).waitForExistence(timeout: 5))

        composer(in: app).typeText("what is this")
        composer(in: app).typeKey(.return, modifierFlags: [])
        waitForReply(in: app, "SELF == %@", "I can see 1 image(s).")
        let messages = try lastRequest()["messages"] as? [[String: Any]] ?? []
        let parts = messages.last?["content"] as? [[String: Any]] ?? []
        XCTAssertTrue(parts.contains { $0["type"] as? String == "image_url" })
    }

    func testPastedTextFileIsSentWithItsContents() throws {
        let app = launch(resetState: true)
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notes.txt")
        try "meeting at 3pm".write(to: file, atomically: true, encoding: .utf8)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([file as NSURL])
        pasteIntoComposer(app)
        let tile = element("attachment", in: app)
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        XCTAssertEqual(tile.label, "notes.txt")

        composer(in: app).typeKey(.return, modifierFlags: [])
        waitForReply(in: app, "SELF == %@", "I read notes.txt.")
        let messages = try lastRequest()["messages"] as? [[String: Any]] ?? []
        let content = messages.last?["content"]
        let text = (content as? String) ?? ((content as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? "")
        XCTAssertTrue(text.contains("meeting at 3pm"))
    }

    func testAttachmentsCanBeRemovedAndSurviveRelaunch() throws {
        var app = launch(resetState: true)
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("keep.txt")
        try "keep".write(to: file, atomically: true, encoding: .utf8)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([file as NSURL])
        pasteIntoComposer(app)
        XCTAssertTrue(element("attachment", in: app).waitForExistence(timeout: 5))

        app.terminate()
        app = launch(resetState: false)
        XCTAssertTrue(element("attachment", in: app).waitForExistence(timeout: 10), "Attachments not sent yet are kept")
        tap(element("removeAttachment", in: app))
        XCTAssertTrue(element("attachment", in: app).waitForNonExistence(timeout: 5))
    }

    func testUnsupportedFileIsRefusedWithANotice() throws {
        let app = launch(resetState: true)
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("blob.bin")
        try Data([0xFF, 0xFE, 0x00, 0x81, 0xC3, 0x28]).write(to: file)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([file as NSURL])
        pasteIntoComposer(app)
        let notice = element("composerNotice", in: app)
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(text(of: notice).hasPrefix("blob.bin can't be sent"))
        XCTAssertFalse(element("attachment", in: app).exists)
    }

    func testPlusMenuOffersUploadsAndSharing() {
        let app = launch(resetState: true)
        let plus = element("plusMenu", in: app)
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        plus.click()
        XCTAssertTrue(app.menuItems["Upload Image…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Upload File…"].exists)
        XCTAssertTrue(app.menuItems["Share Window"].exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(composer(in: app).waitForExistence(timeout: 5), "Closing the menu keeps the capsule")
    }

    func testSharingAWindowWithoutPermissionShowsTheGuide() {
        let app = launch(resetState: true)
        let plus = element("plusMenu", in: app)
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        plus.click()
        let share = app.menuItems["Share Window"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        share.click()
        // CI machines have no screen recording permission, so the guide opens.
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertFalse(done.isEnabled, "Done waits for screen recording permission")
        XCTAssertTrue(app.buttons["Open System Settings"].exists)
        app.buttons["Cancel"].click()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
    }

    // MARK: Composer

    func testSendButtonAppearsOnlyWithText() {
        let app = launch(resetState: true)
        let input = composer(in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertFalse(element("send", in: app).exists, "Nothing to send yet")
        input.click()
        input.typeText("via the button")
        let send = element("send", in: app)
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.click()
        waitForReply(in: app, "SELF == %@", "Echo: via the button")
    }

    func testLongTextMovesAboveTheButtons() {
        let app = launch(resetState: true)
        let input = composer(in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        let plus = element("plusMenu", in: app)
        let oneLine = input.frame
        XCTAssertEqual(oneLine.midY, plus.frame.midY, accuracy: 3, "One line sits beside the +")
        input.click()
        input.typeText("first line")
        input.typeKey(.return, modifierFlags: .shift)
        input.typeText("second line")
        input.typeKey(.return, modifierFlags: .shift)
        input.typeText("third line")

        let deadline = Date().addingTimeInterval(5)
        while input.frame.height <= oneLine.height + 20, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertGreaterThan(input.frame.height, oneLine.height + 20, "The text grows")
        XCTAssertLessThan(input.frame.maxY, plus.frame.minY + 2, "The text sits above the buttons")
        XCTAssertEqual(text(of: input), "first line\nsecond line\nthird line")
    }

    func testCardGrowsUpFromTheInputAndClosesBackToIt() {
        let app = launch(resetState: true)
        let input = composer(in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        let capsuleInput = input.frame

        send("grow up", in: app)
        waitForReply(in: app, "SELF == %@", "Echo: grow up")
        let cardInput = composer(in: app).frame
        XCTAssertEqual(cardInput.maxY, capsuleInput.maxY, accuracy: 20, "The input stays where it was")
        XCTAssertLessThan(app.buttons["New Chat"].frame.minY, cardInput.minY - 300, "The card grows upward")

        app.buttons["Close"].click()
        XCTAssertTrue(app.buttons["New Chat"].waitForNonExistence(timeout: 5))
        app.terminate()
        let again = launch(resetState: false)
        let reopened = composer(in: again)
        XCTAssertTrue(reopened.waitForExistence(timeout: 10))
        XCTAssertEqual(reopened.frame.maxY, capsuleInput.maxY, accuracy: 2, "The capsule opens at the same spot")
    }

    func testEditingAQuestionReplacesTheReply() {
        let app = launch(resetState: true)
        send("first question", in: app)
        waitForReply(in: app, "SELF == %@", "Echo: first question")

        let question = element("message.user", in: app)
        question.hover()
        element("editMessage", in: app).click()
        let field = element("editField", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(element("saveEdit", in: app).isEnabled, "Save waits for a change")
        field.typeKey("a", modifierFlags: .command)
        field.typeText("second question")
        element("saveEdit", in: app).click()

        waitForReply(in: app, "SELF == %@", "Echo: second question")
        XCTAssertEqual(elements("message.user", in: app).count, 1)
        XCTAssertEqual(text(of: element("message.user", in: app)), "second question")
    }

    // MARK: Full window

    func testCardExpandsToTheFullWindowAndCollapsesBack() {
        let app = launch(resetState: true)
        send("carry over", in: app)
        waitForReply(in: app, "SELF == %@", "Echo: carry over")

        app.buttons["Expand to Full Window"].click()
        let collapse = element("collapseToMini", in: app)
        XCTAssertTrue(collapse.waitForExistence(timeout: 10), "The full window opens")
        XCTAssertTrue(element("historyItem", in: app).waitForExistence(timeout: 5))
        waitForReply(in: app, "SELF == %@", "Echo: carry over")

        collapse.click()
        XCTAssertTrue(collapse.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["New Chat"].waitForExistence(timeout: 5), "The card shows the same conversation")
        waitForReply(in: app, "SELF == %@", "Echo: carry over")
    }

    func testCapsuleExpandsToTheFullWindowWithTheDraft() {
        let app = launch(resetState: true)
        let input = composer(in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.click()
        input.typeText("half typed")
        app.buttons["Expand to Full Window"].click()

        XCTAssertTrue(element("collapseToMini", in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(text(of: composer(in: app)), "half typed", "The draft comes along")
    }

    func testHistoryIsKeptAndCanBeRenamedAndDeleted() {
        var app = launch(resetState: true)
        send("remember me", in: app)
        waitForReply(in: app, "SELF == %@", "Echo: remember me")
        // The model names the conversation after its first reply.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        app.terminate()

        app = launch(resetState: false, fullWindow: true)
        let item = element("historyItem", in: app)
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        XCTAssertEqual(text(of: item), "Mock title", "Named by the model, not after the first message")
        item.click()
        waitForReply(in: app, "SELF == %@", "Echo: remember me")

        item.rightClick()
        app.menuItems["Rename…"].click()
        let field = element("renameField", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Renamed\n")
        let renamed = element("historyItem", in: app)
        XCTAssertTrue(renamed.waitForExistence(timeout: 5))
        XCTAssertEqual(text(of: renamed), "Renamed")

        renamed.rightClick()
        app.menuItems["Delete…"].click()
        let confirm = app.sheets.buttons.matching(NSPredicate(format: "label == %@", "Delete")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(element("historyItem", in: app).waitForNonExistence(timeout: 5))
    }

    func testFullWindowSendsAndStartsNewChats() {
        let app = launch(resetState: true, fullWindow: true)
        send("from the full window", in: app)
        waitForReply(in: app, "SELF == %@", "Echo: from the full window")
        XCTAssertTrue(element("historyItem", in: app).waitForExistence(timeout: 5))

        element("newChat", in: app).click()
        XCTAssertTrue(element("message.assistant", in: app).waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["What's on your mind?"].exists)
    }

    func testSettingsOpenFromTheFullWindow() {
        let app = launch(resetState: true, fullWindow: true)
        let gear = element("openSettings", in: app)
        XCTAssertTrue(gear.waitForExistence(timeout: 10))
        gear.click()
        XCTAssertTrue(element("addProvider", in: app).waitForExistence(timeout: 5))
    }

    // MARK: Layout

    /// Keeps screenshots of each window state in the test results for reviewing the layout.
    func testLayoutScreenshots() {
        let app = launch(resetState: true)
        XCTAssertTrue(composer(in: app).waitForExistence(timeout: 10))
        attachScreenshot("Capsule")

        send("markdown", in: app)
        waitForReply(in: app, "SELF CONTAINS %@", "| WAL | concurrent |")
        send("markdown", in: app)
        XCTAssertTrue(elements("message.assistant", in: app).element(boundBy: 1).waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        attachScreenshot("Card")

        // The scroll bar shows while scrolling and is gone a moment after.
        // A point in the conversation just above the input, which is always on screen.
        let conversation = composer(in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: -150))
        conversation.scroll(byDeltaX: 0, deltaY: 120)
        // The scroll lands a moment after the call returns.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        attachScreenshot("Scrolling")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        attachScreenshot("After scrolling")

        send("math", in: app)
        XCTAssertTrue(reply(containing: "frac{n(n+1)}{2}$$", in: app).waitForExistence(timeout: 15))
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        attachScreenshot("Math")

        app.buttons["Expand to Full Window"].click()
        XCTAssertTrue(element("collapseToMini", in: app).waitForExistence(timeout: 10))
        // The replies render again at the new width.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        attachScreenshot("Full window")
    }
}
