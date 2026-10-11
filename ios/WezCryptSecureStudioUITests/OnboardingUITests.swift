import XCTest

final class OnboardingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testWelcomeScreenOnFreshInstall() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"]
        app.launch()
        XCTAssertTrue(app.buttons["getStarted"].waitForExistence(timeout: 15))
        app.buttons["getStarted"].tap()
        XCTAssertTrue(app.textFields["serverURL"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["saveConfiguration"].exists)
    }

    /// Drives the real setup screens against the CI backend and expects the
    /// connection test to pass every step (upload, download, decrypt, delete).
    @MainActor
    func testServerSetupAndConnectionTestAgainstRealServer() throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["WZC_TEST_SERVER"], let user = env["WZC_TEST_USER"], let password = env["WZC_TEST_PASSWORD"] else {
            throw XCTSkip("Backend not configured — UI integration test NOT EXECUTED")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestReset"]
        app.launch()
        if app.buttons["getStarted"].waitForExistence(timeout: 15) { app.buttons["getStarted"].tap() }
        let url = app.textFields["serverURL"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let existing = (url.value as? String) ?? ""
        url.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count + 5))
        url.typeText(server)
        let username = app.textFields["username"]
        username.tap()
        username.typeText(user)
        let pass = app.secureTextFields["password"]
        pass.tap()
        pass.typeText(password)
        app.buttons["saveConfiguration"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["connectionSuccessful"].waitForExistence(timeout: 90), "connection test did not report success")
    }
}
