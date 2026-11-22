import XCTest
@testable import Dashboard

final class FlavorTests: XCTestCase {
    func testAppStoreFlavorHasOnlyClaudeAndCodex() {
        XCTAssertEqual(Flavor.providerIDs(appStore: true), ["claude", "codex"])
    }

    func testDirectFlavorHasAllProviders() {
        XCTAssertEqual(Flavor.providerIDs(appStore: false), ["claude", "codex", "gemini", "cursor"])
    }

    /// The App Store build must not point users at GitHub.
    func testProjectLinkOnlyOutsideTheAppStore() {
        XCTAssertNil(Flavor.projectLink(appStore: true))
        XCTAssertEqual(Flavor.projectLink(appStore: false)?.absoluteString, "https://github.com/pionion-ai/quotabar")
    }
}
