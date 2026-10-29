import XCTest

/// End-to-end checks of the mini window on a real macOS session.
/// The global shortcut cannot be pressed from a test, so the app is told to open the capsule on launch.
final class SpotChatUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(resetState: Bool, language: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-SpotChatShowMiniOnLaunch", "YES", "-AppleLanguages", "(\(language))"]
        if resetState {
            app.launchArguments += ["-SpotChatResetState", "YES"]
        }
        app.launch()
        return app
    }

    private func composer(in app: XCUIApplication) -> XCUIElement {
        app.textViews["composer"].firstMatch
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func text(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    private func moveFocusToAnotherApp() {
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
    }

    func testSendingShowsTheMessageAndTheEchoInTheCard() {
        let app = launch(resetState: true)
        let input = composer(in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.click()
        input.typeText("hello spot")
        input.typeKey(.return, modifierFlags: [])

        let question = element("message.user", in: app)
        let reply = element("message.assistant", in: app)
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        XCTAssertEqual(text(of: question), "hello spot")
        XCTAssertEqual(text(of: reply), "hello spot")
        XCTAssertEqual(text(of: composer(in: app)), "")
        XCTAssertTrue(app.buttons["New Chat"].exists)
    }

    func testInterfaceIsTranslatedForSimplifiedChinese() {
        let app = launch(resetState: true, language: "zh-Hans")
        let input = composer(in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.click()
        input.typeText("hi")
        input.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(app.buttons["新对话"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["关闭"].exists)
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
        let input = composer(in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.click()
        input.typeText("stay")
        input.typeKey(.return, modifierFlags: [])
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
}
