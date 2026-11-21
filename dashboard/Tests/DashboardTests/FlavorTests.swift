import XCTest
@testable import Dashboard

final class FlavorTests: XCTestCase {
    func testAppStoreFlavorHasOnlyClaudeAndCodex() {
        XCTAssertEqual(Flavor.providerIDs(appStore: true), ["claude", "codex"])
    }

    func testDirectFlavorHasAllProviders() {
        XCTAssertEqual(Flavor.providerIDs(appStore: false), ["claude", "codex", "gemini", "cursor"])
    }
}
