import XCTest

/// End-to-end checks of the mini window on a real macOS session.
/// The global shortcut cannot be pressed from a test, so the app is told to open the capsule on launch.
final class SpotChatUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(resetState: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-SpotChatShowMiniOnLaunch", "YES"]
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

        // The capsule's left padding: 10pt padding, a 36pt button and a 6pt gap sit left of the input.
        let start = input.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: -48, dy: 0))
        let end = start.withOffset(CGVector(dx: 120, dy: 80))
        start.click(forDuration: 0.3, thenDragTo: end)

        let after = input.frame
        XCTAssertGreaterThan(abs(after.minX - before.minX), 60)
        XCTAssertGreaterThan(abs(after.minY - before.minY), 40)
    }
}
