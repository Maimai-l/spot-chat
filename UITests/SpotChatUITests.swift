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

    func launch(resetState: Bool, provider: Bool = true, language: String = "en") -> XCUIApplication {
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
        app.launch()
        return app
    }

    func composer(in app: XCUIApplication) -> XCUIElement {
        app.textViews["composer"].firstMatch
    }

    func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
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

    /// Waits until the reply's text satisfies the predicate, e.g. "value == 'Echo: hi'".
    func waitForReply(in app: XCUIApplication, _ format: String, _ argument: String, timeout: TimeInterval = 10) {
        let reply = element("message.assistant", in: app)
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argument), object: reply)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, "Reply was: \(text(of: reply))")
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
        waitForReply(in: app, "value == %@", "Echo: hello spot")
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

        // The capsule's 20pt left padding, outside the input.
        let start = input.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: -8, dy: 0))
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
        waitForReply(in: app, "value CONTAINS %@", "| WAL | concurrent |")

        let copy = element("copyCode", in: app)
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        NSPasteboard.general.clearContents()
        copy.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), "PRAGMA journal_mode = WAL;")
    }

    func testEscapeStopsGenerationAndKeepsThePartialReply() {
        let app = launch(resetState: true)
        send("slow", in: app)
        waitForReply(in: app, "value CONTAINS %@", "tick 2")
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
        waitForReply(in: app, "value CONTAINS %@", "tick 1")
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
        XCTAssertEqual(elements("message.assistant", in: app).count, 1, "Retry replaces the failed reply")
    }

    func testRegenerateReplacesTheReplyAndCopyCopiesIt() {
        let app = launch(resetState: true)
        send("hello", in: app)
        waitForReply(in: app, "value == %@", "Echo: hello")

        element("regenerate", in: app).click()
        waitForReply(in: app, "value == %@", "Echo: hello")
        XCTAssertEqual(elements("message.assistant", in: app).count, 1)

        NSPasteboard.general.clearContents()
        element("copyReply", in: app).click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Echo: hello")
    }

    func testFollowUpQuestionsKeepTheConversation() throws {
        let app = launch(resetState: true)
        send("first", in: app)
        waitForReply(in: app, "value == %@", "Echo: first")
        send("second", in: app)
        let second = elements("message.assistant", in: app).element(boundBy: 1)
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Echo: second"), object: second)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)

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
        waitForReply(in: app, "value == %@", "Echo: hi")
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
        waitForReply(in: app, "value == %@", "Echo: saved")
    }
}
