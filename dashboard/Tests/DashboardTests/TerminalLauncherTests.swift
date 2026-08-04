import XCTest
@testable import Dashboard

final class TerminalLauncherTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("launcher-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testWritesAnExecutableScriptAndOpensIt() throws {
        var opened: [URL] = []
        let launcher = TerminalLauncher(baseDirectory: tempDir, open: { opened.append($0) })

        launcher.launch(command: "codex login", providerID: "codex")

        XCTAssertEqual(opened.count, 1)
        let url = try XCTUnwrap(opened.first)
        XCTAssertEqual(url.lastPathComponent, "relogin-codex.command")

        let script = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"), "script was: \(script)")
        XCTAssertTrue(script.contains("exec codex login"), "script was: \(script)")

        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o755)
    }

    func testCreatesTheBaseDirectoryOnDemand() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path))
        let launcher = TerminalLauncher(baseDirectory: tempDir, open: { _ in })
        launcher.launch(command: "claude", providerID: "claude")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path))
    }

    // Fixed per-provider filename: repeat clicks overwrite rather than litter.
    func testRepeatLaunchesReuseTheSamePath() throws {
        var opened: [URL] = []
        let launcher = TerminalLauncher(baseDirectory: tempDir, open: { opened.append($0) })
        launcher.launch(command: "claude", providerID: "claude")
        launcher.launch(command: "claude", providerID: "claude")
        XCTAssertEqual(opened.count, 2)
        XCTAssertEqual(opened[0], opened[1])
        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(contents, ["relogin-claude.command"])
    }

    // A launch failure is swallowed: the popover keeps its existing error text.
    func testUnwritableDirectoryDoesNotOpenAnythingOrCrash() {
        var opened: [URL] = []
        let unwritable = URL(fileURLWithPath: "/System/nope-\(UUID().uuidString)")
        let launcher = TerminalLauncher(baseDirectory: unwritable, open: { opened.append($0) })
        launcher.launch(command: "claude", providerID: "claude")
        XCTAssertTrue(opened.isEmpty)
    }

    func testLiveLauncherPointsAtTheAppCacheDirectory() {
        XCTAssertTrue(TerminalLauncher.live.baseDirectory.path
            .hasSuffix("Caches/ai.pionion.quotabar"))
    }
}
