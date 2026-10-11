import XCTest

final class WezCryptSecureStudioUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// On a fresh install the app is not linked to a vault and must show the
    /// pairing screen without contacting the server.
    @MainActor
    func testFreshInstallShowsPairingScreen() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["WezCrypt Secure Studio"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["generatePairingCode"].exists)
        XCTAssertTrue(app.staticTexts["Link this iPhone"].exists)
    }
}
