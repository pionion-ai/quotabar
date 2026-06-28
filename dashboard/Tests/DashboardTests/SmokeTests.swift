import XCTest
@testable import Dashboard

final class SmokeTests: XCTestCase {
    func testPackageBuilds() {
        XCTAssertTrue(Placeholder.ready)
    }
}
