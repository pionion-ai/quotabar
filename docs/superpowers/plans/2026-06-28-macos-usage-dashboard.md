# claude-usage-dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS menu bar app that shows live Claude Code subscription usage as circular gauges, with a `H:MM:SS` countdown to reopening when a limit is reached.

**Architecture:** A SwiftPM executable targeting macOS 13+. Three isolated responsibilities: `UsageClient` (Keychain token + `/oauth/usage` fetch + decode, behind a `UsageProviding` protocol), `UsageModel` (pure value types and derivations — state, color, countdown), and the SwiftUI layer (`DashboardApp` MenuBarExtra + timers, `GaugesView` popover). Only pure logic is unit-tested; network/Keychain sit behind the protocol.

**Tech Stack:** Swift 5.9+, SwiftUI (`MenuBarExtra`, `Gauge`), `URLSession`, `UNUserNotificationCenter`, `Process` (for `/usr/bin/security`), SwiftPM + XCTest.

## Global Constraints

- **Platform:** macOS 13 (Ventura) minimum — required for `MenuBarExtra` and `Gauge`. Set `platforms: [.macOS(.v13)]` in `Package.swift`.
- **Self-contained:** no Python dependency; no third-party packages. Standard library + system frameworks only.
- **Location:** all files under `claude-usage/dashboard/` inside the existing `claude-usage` git repo. Run all `git` and `swift` commands from that directory.
- **Endpoint:** `GET https://api.anthropic.com/api/oauth/usage` with headers `Authorization: Bearer <token>` and `anthropic-beta: oauth-2025-04-20`.
- **Keychain:** read token via `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`, then JSON path `claudeAiOauth.accessToken`.
- **Windows (key → label), display order:** `five_hour`→"5-hour session", `seven_day`→"7-day (all models)", `seven_day_opus`→"7-day (Opus)", `seven_day_sonnet`→"7-day (Sonnet)". Unknown/absent windows are skipped, not fatal.
- **Color buckets** (% used): `<75` green, `75..<90` amber, `>=90` red; a reached window is always red.
- **Commit cadence:** commit at the end of every task. End commit messages with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

### Task 1: Package scaffold + build

**Files:**
- Create: `dashboard/Package.swift`
- Create: `dashboard/Sources/Dashboard/Placeholder.swift`
- Create: `dashboard/Tests/DashboardTests/SmokeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: a buildable SwiftPM package with an executable target `Dashboard` and a test target `DashboardTests`. Establishes that `swift build` and `swift test` work before any real code lands.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Dashboard",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Dashboard", path: "Sources/Dashboard"),
        .testTarget(
            name: "DashboardTests",
            dependencies: ["Dashboard"],
            path: "Tests/DashboardTests"
        ),
    ]
)
```

- [ ] **Step 2: Add a temporary placeholder so the target compiles**

`Sources/Dashboard/Placeholder.swift`:

```swift
// Temporary placeholder; removed in Task 6 when DashboardApp.swift lands.
enum Placeholder { static let ready = true }
```

- [ ] **Step 3: Write the smoke test**

`Tests/DashboardTests/SmokeTests.swift`:

```swift
import XCTest
@testable import Dashboard

final class SmokeTests: XCTestCase {
    func testPackageBuilds() {
        XCTAssertTrue(Placeholder.ready)
    }
}
```

- [ ] **Step 4: Run the test, expect PASS**

Run: `cd dashboard && swift test`
Expected: builds and `testPackageBuilds` passes.

- [ ] **Step 5: Commit**

```bash
cd dashboard
git add Package.swift Sources Tests
git commit -m "chore(dashboard): scaffold SwiftPM package

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: UsageWindow + state/color/remaining

**Files:**
- Create: `dashboard/Sources/Dashboard/UsageModel.swift`
- Test: `dashboard/Tests/DashboardTests/UsageModelTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct UsageWindow { let key: String; let label: String; let usedPercent: Double; let resetsAt: Date }`
  - `enum WindowState: Equatable { case ok(remaining: Double); case reached(reopensAt: Date) }`
  - `enum GaugeColor { case green, amber, red }`
  - `extension UsageWindow { var state: WindowState; var remainingPercent: Double; func color() -> GaugeColor }`

- [ ] **Step 1: Write the failing test**

`Tests/DashboardTests/UsageModelTests.swift`:

```swift
import XCTest
@testable import Dashboard

final class UsageModelTests: XCTestCase {
    private func window(used: Double, resetsIn seconds: TimeInterval = 3600) -> UsageWindow {
        UsageWindow(key: "five_hour", label: "5-hour session",
                    usedPercent: used, resetsAt: Date().addingTimeInterval(seconds))
    }

    func testRemainingPercentClamps() {
        XCTAssertEqual(window(used: 8).remainingPercent, 92, accuracy: 0.001)
        XCTAssertEqual(window(used: 130).remainingPercent, 0, accuracy: 0.001)
        XCTAssertEqual(window(used: -5).remainingPercent, 100, accuracy: 0.001)
    }

    func testStateOkBelow100() {
        if case .ok(let remaining) = window(used: 40).state {
            XCTAssertEqual(remaining, 60, accuracy: 0.001)
        } else { XCTFail("expected .ok") }
    }

    func testStateReachedAt100() {
        if case .reached = window(used: 100).state {} else { XCTFail("expected .reached") }
        if case .reached = window(used: 99.9).state { XCTFail("99.9 should be .ok") }
    }

    func testColorBuckets() {
        XCTAssertEqual(window(used: 74).color(), .green)
        XCTAssertEqual(window(used: 75).color(), .amber)
        XCTAssertEqual(window(used: 89).color(), .amber)
        XCTAssertEqual(window(used: 90).color(), .red)
        XCTAssertEqual(window(used: 100).color(), .red)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd dashboard && swift test --filter UsageModelTests`
Expected: FAIL — `UsageWindow` / `WindowState` undefined.

- [ ] **Step 3: Write the implementation**

`Sources/Dashboard/UsageModel.swift`:

```swift
import Foundation

struct UsageWindow: Equatable {
    let key: String
    let label: String
    let usedPercent: Double
    let resetsAt: Date
}

enum WindowState: Equatable {
    case ok(remaining: Double)
    case reached(reopensAt: Date)
}

enum GaugeColor { case green, amber, red }

extension UsageWindow {
    var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }

    var state: WindowState {
        usedPercent >= 100 ? .reached(reopensAt: resetsAt) : .ok(remaining: remainingPercent)
    }

    func color() -> GaugeColor {
        switch usedPercent {
        case ..<75: return .green
        case ..<90: return .amber
        default: return .red
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd dashboard && swift test --filter UsageModelTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd dashboard
git add Sources/Dashboard/UsageModel.swift Tests/DashboardTests/UsageModelTests.swift
git commit -m "feat(dashboard): UsageWindow model with state and color

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Countdown formatting

**Files:**
- Modify: `dashboard/Sources/Dashboard/UsageModel.swift`
- Test: `dashboard/Tests/DashboardTests/CountdownTests.swift`

**Interfaces:**
- Consumes: `UsageWindow`, `WindowState` from Task 2.
- Produces: `extension UsageWindow { func countdown(now: Date) -> String }` — returns `H:MM:SS` (zero-padded minutes/seconds, hours unpadded) when the window is `.reached`, the loose `"4h 53m"` form when `.ok`, and `"now"` when `resetsAt` is at/in the past.

- [ ] **Step 1: Write the failing test**

`Tests/DashboardTests/CountdownTests.swift`:

```swift
import XCTest
@testable import Dashboard

final class CountdownTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func window(used: Double, resetsIn s: TimeInterval) -> UsageWindow {
        UsageWindow(key: "k", label: "l", usedPercent: used,
                    resetsAt: now.addingTimeInterval(s))
    }

    func testLooseFormatWhenOk() {
        // 4h 53m = 17580s
        XCTAssertEqual(window(used: 8, resetsIn: 4 * 3600 + 53 * 60).countdown(now: now), "4h 53m")
        XCTAssertEqual(window(used: 8, resetsIn: 3 * 86400 + 2 * 3600).countdown(now: now), "3d 2h")
        XCTAssertEqual(window(used: 8, resetsIn: 40).countdown(now: now), "0m")
    }

    func testPreciseFormatWhenReached() {
        // reached (used >= 100) → H:MM:SS, here 1h 11m 48s
        XCTAssertEqual(window(used: 100, resetsIn: 3600 + 11 * 60 + 48).countdown(now: now), "1:11:48")
        XCTAssertEqual(window(used: 100, resetsIn: 9).countdown(now: now), "0:00:09")
    }

    func testNowWhenPast() {
        XCTAssertEqual(window(used: 100, resetsIn: -5).countdown(now: now), "now")
        XCTAssertEqual(window(used: 8, resetsIn: 0).countdown(now: now), "now")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd dashboard && swift test --filter CountdownTests`
Expected: FAIL — `countdown(now:)` undefined.

- [ ] **Step 3: Add the implementation to `UsageModel.swift`**

Append to the `extension UsageWindow` block:

```swift
func countdown(now: Date) -> String {
    let total = Int(resetsAt.timeIntervalSince(now))
    if total <= 0 { return "now" }

    if case .reached = state {
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return String(format: "%d:%02d:%02d", h, m, s)
    }

    let days = total / 86400
    let hours = (total % 86400) / 3600
    let minutes = (total % 3600) / 60
    var parts: [String] = []
    if days > 0 { parts.append("\(days)d") }
    if hours > 0 { parts.append("\(hours)h") }
    if minutes > 0 || parts.isEmpty { parts.append("\(minutes)m") }
    return parts.joined(separator: " ")
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd dashboard && swift test --filter CountdownTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd dashboard
git add Sources/Dashboard/UsageModel.swift Tests/DashboardTests/CountdownTests.swift
git commit -m "feat(dashboard): dual-mode reset countdown formatting

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Decode the /oauth/usage payload

**Files:**
- Create: `dashboard/Sources/Dashboard/UsageDecoder.swift`
- Test: `dashboard/Tests/DashboardTests/UsageDecoderTests.swift`

**Interfaces:**
- Consumes: `UsageWindow` from Task 2.
- Produces: `enum UsageDecoder { static func windows(from data: Data) throws -> [UsageWindow] }` — parses the raw usage JSON into the known windows in display order, skipping any window block that is absent or missing `utilization`. `resets_at` is ISO-8601; a block missing it is skipped.

- [ ] **Step 1: Write the failing test**

`Tests/DashboardTests/UsageDecoderTests.swift`:

```swift
import XCTest
@testable import Dashboard

final class UsageDecoderTests: XCTestCase {
    private let sample = """
    {
      "five_hour":        {"utilization": 8.0,  "resets_at": "2026-06-28T18:00:00+00:00"},
      "seven_day":        {"utilization": 8.0,  "resets_at": "2026-07-01T00:00:00+00:00"},
      "seven_day_sonnet": {"utilization": 2.0,  "resets_at": "2026-07-01T00:00:00+00:00"},
      "extra_usage":      {"is_enabled": false}
    }
    """.data(using: .utf8)!

    func testParsesKnownWindowsInOrder() throws {
        let windows = try UsageDecoder.windows(from: sample)
        XCTAssertEqual(windows.map(\.key), ["five_hour", "seven_day", "seven_day_sonnet"])
        XCTAssertEqual(windows[0].label, "5-hour session")
        XCTAssertEqual(windows[0].usedPercent, 8.0, accuracy: 0.001)
    }

    func testSkipsAbsentAndIncompleteWindows() throws {
        let data = """
        {"five_hour": {"resets_at": "2026-06-28T18:00:00+00:00"},
         "seven_day": {"utilization": 5.0, "resets_at": "2026-07-01T00:00:00+00:00"}}
        """.data(using: .utf8)!
        let windows = try UsageDecoder.windows(from: data)
        XCTAssertEqual(windows.map(\.key), ["seven_day"])  // five_hour lacks utilization
    }

    func testThrowsOnGarbage() {
        XCTAssertThrowsError(try UsageDecoder.windows(from: Data("not json".utf8)))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd dashboard && swift test --filter UsageDecoderTests`
Expected: FAIL — `UsageDecoder` undefined.

- [ ] **Step 3: Write the implementation**

`Sources/Dashboard/UsageDecoder.swift`:

```swift
import Foundation

enum UsageDecoder {
    // key → label, in display order.
    static let knownWindows: [(key: String, label: String)] = [
        ("five_hour", "5-hour session"),
        ("seven_day", "7-day (all models)"),
        ("seven_day_opus", "7-day (Opus)"),
        ("seven_day_sonnet", "7-day (Sonnet)"),
    ]

    private struct Block: Decodable {
        let utilization: Double?
        let resets_at: String?
    }

    static func windows(from data: Data) throws -> [UsageWindow] {
        let blocks = try JSONDecoder().decode([String: Block].self, from: data)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        return knownWindows.compactMap { known in
            guard let block = blocks[known.key],
                  let util = block.utilization,
                  let iso = block.resets_at,
                  let date = formatter.date(from: iso)
            else { return nil }
            return UsageWindow(key: known.key, label: known.label,
                               usedPercent: util, resetsAt: date)
        }
    }
}
```

Note: `[String: Block]` decoding tolerates non-window keys like `extra_usage` whose shape differs, because `Block`'s fields are all optional.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd dashboard && swift test --filter UsageDecoderTests`
Expected: PASS. (If `extra_usage` decoding ever fails, it's because a field is non-optional — keep all `Block` fields optional.)

- [ ] **Step 5: Commit**

```bash
cd dashboard
git add Sources/Dashboard/UsageDecoder.swift Tests/DashboardTests/UsageDecoderTests.swift
git commit -m "feat(dashboard): decode /oauth/usage into windows

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Alert transition logic

**Files:**
- Create: `dashboard/Sources/Dashboard/AlertEngine.swift`
- Test: `dashboard/Tests/DashboardTests/AlertEngineTests.swift`

**Interfaces:**
- Consumes: `UsageWindow`, `WindowState` from Task 2.
- Produces:
  - `enum AlertEvent: Equatable { case approaching(label: String, countdown: String); case reached(label: String, countdown: String) }`
  - `struct AlertEngine { var threshold: Double?; mutating func evaluate(_ windows: [UsageWindow], now: Date) -> [AlertEvent] }` — fires `.reached` once when a window first hits 100%, `.approaching` once when it first crosses `threshold` (if set) while still `< 100`. De-duplicated by remembering each window's last emitted level; no event while it stays in the same band; resets when the window drops back (after a reset).

- [ ] **Step 1: Write the failing test**

`Tests/DashboardTests/AlertEngineTests.swift`:

```swift
import XCTest
@testable import Dashboard

final class AlertEngineTests: XCTestCase {
    private let now = Date()
    private func win(_ used: Double) -> UsageWindow {
        UsageWindow(key: "five_hour", label: "5-hour session",
                    usedPercent: used, resetsAt: now.addingTimeInterval(3600))
    }

    func testFiresApproachingOnceOnCrossing() {
        var engine = AlertEngine(threshold: 85)
        XCTAssertTrue(engine.evaluate([win(80)], now: now).isEmpty)
        let events = engine.evaluate([win(86)], now: now)
        XCTAssertEqual(events.count, 1)
        if case .approaching(let label, _) = events[0] {
            XCTAssertEqual(label, "5-hour session")
        } else { XCTFail("expected .approaching") }
        // staying over the threshold emits nothing further
        XCTAssertTrue(engine.evaluate([win(88)], now: now).isEmpty)
    }

    func testFiresReachedOnceAt100() {
        var engine = AlertEngine(threshold: 85)
        _ = engine.evaluate([win(86)], now: now)            // approaching consumed
        let events = engine.evaluate([win(100)], now: now)
        XCTAssertEqual(events.count, 1)
        if case .reached = events[0] {} else { XCTFail("expected .reached") }
        XCTAssertTrue(engine.evaluate([win(100)], now: now).isEmpty)
    }

    func testResetsAfterWindowReopens() {
        var engine = AlertEngine(threshold: 85)
        _ = engine.evaluate([win(100)], now: now)
        // window reopened (low usage) — no event, but state cleared
        XCTAssertTrue(engine.evaluate([win(5)], now: now).isEmpty)
        // crossing again fires again
        XCTAssertEqual(engine.evaluate([win(90)], now: now).count, 1)
    }

    func testNoApproachingWhenThresholdNil() {
        var engine = AlertEngine(threshold: nil)
        XCTAssertTrue(engine.evaluate([win(95)], now: now).isEmpty)
        // reached still fires even with no threshold
        XCTAssertEqual(engine.evaluate([win(100)], now: now).count, 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd dashboard && swift test --filter AlertEngineTests`
Expected: FAIL — `AlertEngine` undefined.

- [ ] **Step 3: Write the implementation**

`Sources/Dashboard/AlertEngine.swift`:

```swift
import Foundation

enum AlertEvent: Equatable {
    case approaching(label: String, countdown: String)
    case reached(label: String, countdown: String)
}

struct AlertEngine {
    var threshold: Double?

    // Highest band each window has alerted at: 0 none, 1 approaching, 2 reached.
    private enum Level: Int { case none, approaching, reached }
    private var lastLevel: [String: Level] = [:]

    private func band(for w: UsageWindow) -> Level {
        if w.usedPercent >= 100 { return .reached }
        if let t = threshold, w.usedPercent >= t { return .approaching }
        return .none
    }

    mutating func evaluate(_ windows: [UsageWindow], now: Date) -> [AlertEvent] {
        var events: [AlertEvent] = []
        for w in windows {
            let current = band(for: w)
            let previous = lastLevel[w.key] ?? .none
            if current.rawValue > previous.rawValue {
                switch current {
                case .approaching:
                    events.append(.approaching(label: w.label, countdown: w.countdown(now: now)))
                case .reached:
                    events.append(.reached(label: w.label, countdown: w.countdown(now: now)))
                case .none:
                    break
                }
            }
            lastLevel[w.key] = current
        }
        return events
    }
}
```

Note: only an *increase* in band emits, so a window sitting at 88% (approaching) that jumps to 100% emits `.reached` once; dropping back to `.none` after reopening rearms it.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd dashboard && swift test --filter AlertEngineTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd dashboard
git add Sources/Dashboard/AlertEngine.swift Tests/DashboardTests/AlertEngineTests.swift
git commit -m "feat(dashboard): transition-based alert engine

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: UsageClient (Keychain + network) behind a protocol

**Files:**
- Create: `dashboard/Sources/Dashboard/UsageClient.swift`
- Test: `dashboard/Tests/DashboardTests/UsageClientTests.swift`

**Interfaces:**
- Consumes: `UsageWindow` (Task 2), `UsageDecoder` (Task 4).
- Produces:
  - `enum FetchError: Error, Equatable { case notLoggedIn, authExpired, network(String), decode }`
  - `protocol UsageProviding { func fetch() async throws -> [UsageWindow] }`
  - `struct UsageClient: UsageProviding` with injectable seams: `init(tokenReader: @escaping () throws -> String, transport: @escaping (URLRequest) async throws -> (Data, URLResponse))`. A convenience `static func live() -> UsageClient` wires the real `security` reader + `URLSession`.

- [ ] **Step 1: Write the failing test**

`Tests/DashboardTests/UsageClientTests.swift`:

```swift
import XCTest
@testable import Dashboard

final class UsageClientTests: XCTestCase {
    private let okJSON = """
    {"five_hour": {"utilization": 8.0, "resets_at": "2026-06-28T18:00:00+00:00"}}
    """.data(using: .utf8)!

    private func response(_ code: Int) -> URLResponse {
        HTTPURLResponse(url: URL(string: "https://api.anthropic.com")!,
                        statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    func testFetchReturnsWindowsOn200() async throws {
        let client = UsageClient(tokenReader: { "tok" },
                                 transport: { _ in (self.okJSON, self.response(200)) })
        let windows = try await client.fetch()
        XCTAssertEqual(windows.map(\.key), ["five_hour"])
    }

    func testSendsBearerAndBetaHeaders() async throws {
        let client = UsageClient(tokenReader: { "secret-token" }) { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
            XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
            return (self.okJSON, self.response(200))
        }
        _ = try await client.fetch()
    }

    func testMaps401ToAuthExpired() async {
        let client = UsageClient(tokenReader: { "tok" },
                                 transport: { _ in (Data(), self.response(401)) })
        await assert(client, throws: .authExpired)
    }

    func testTokenReaderFailureIsNotLoggedIn() async {
        struct Boom: Error {}
        let client = UsageClient(tokenReader: { throw Boom() },
                                 transport: { _ in (self.okJSON, self.response(200)) })
        await assert(client, throws: .notLoggedIn)
    }

    private func assert(_ client: UsageClient, throws expected: FetchError,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await client.fetch(); XCTFail("expected throw", file: file, line: line) }
        catch let e as FetchError { XCTAssertEqual(e, expected, file: file, line: line) }
        catch { XCTFail("wrong error \(error)", file: file, line: line) }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd dashboard && swift test --filter UsageClientTests`
Expected: FAIL — `UsageClient` / `FetchError` undefined.

- [ ] **Step 3: Write the implementation**

`Sources/Dashboard/UsageClient.swift`:

```swift
import Foundation

enum FetchError: Error, Equatable {
    case notLoggedIn
    case authExpired
    case network(String)
    case decode
}

protocol UsageProviding {
    func fetch() async throws -> [UsageWindow]
}

struct UsageClient: UsageProviding {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    let tokenReader: () throws -> String
    let transport: (URLRequest) async throws -> (Data, URLResponse)

    init(tokenReader: @escaping () throws -> String,
         transport: @escaping (URLRequest) async throws -> (Data, URLResponse)) {
        self.tokenReader = tokenReader
        self.transport = transport
    }

    func fetch() async throws -> [UsageWindow] {
        let token: String
        do { token = try tokenReader() } catch { throw FetchError.notLoggedIn }

        var req = URLRequest(url: Self.endpoint)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let data: Data, response: URLResponse
        do { (data, response) = try await transport(req) }
        catch { throw FetchError.network(error.localizedDescription) }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 { throw FetchError.authExpired }
            guard (200..<300).contains(http.statusCode) else {
                throw FetchError.network("HTTP \(http.statusCode)")
            }
        }

        do { return try UsageDecoder.windows(from: data) }
        catch { throw FetchError.decode }
    }

    /// Real wiring: Keychain token via `security`, network via URLSession.
    static func live() -> UsageClient {
        UsageClient(tokenReader: Self.readKeychainToken,
                    transport: { try await URLSession.shared.data(for: $0) })
    }

    static func readKeychainToken() throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw FetchError.notLoggedIn }

        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        struct Creds: Decodable { struct OAuth: Decodable { let accessToken: String }
                                  let claudeAiOauth: OAuth }
        guard let creds = try? JSONDecoder().decode(Creds.self, from: out) else {
            throw FetchError.notLoggedIn
        }
        return creds.claudeAiOauth.accessToken
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd dashboard && swift test --filter UsageClientTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd dashboard
git add Sources/Dashboard/UsageClient.swift Tests/DashboardTests/UsageClientTests.swift
git commit -m "feat(dashboard): UsageClient with injectable token+transport seams

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: App store (observable state + timers + notifications)

**Files:**
- Create: `dashboard/Sources/Dashboard/UsageStore.swift`
- Test: `dashboard/Tests/DashboardTests/UsageStoreTests.swift`

**Interfaces:**
- Consumes: `UsageProviding` (Task 6), `UsageWindow` (Task 2), `AlertEngine`/`AlertEvent` (Task 5).
- Produces:
  - `enum LoadState: Equatable { case loading; case loaded([UsageWindow]); case failed(FetchError) }`
  - `@MainActor final class UsageStore: ObservableObject` with `@Published var loadState`, `@Published var lastChecked: Date?`, a `var onAlerts: ([AlertEvent]) -> Void` hook, an injected `now: () -> Date` clock, and `func refresh() async`. `refresh()` calls the provider, updates `loadState`/`lastChecked`, and on success runs the alert engine and invokes `onAlerts` with any events.
  - Menu-bar summary helpers (pure, testable): `var menuBarTitle: String` and `var menuBarColor: GaugeColor` derived from current windows (reached → soonest `⛔ H:MM:SS`; else `◔ N%` for the lowest remaining; loading/error → glyph).

- [ ] **Step 1: Write the failing test**

`Tests/DashboardTests/UsageStoreTests.swift`:

```swift
import XCTest
@testable import Dashboard

@MainActor
final class UsageStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private struct FakeProvider: UsageProviding {
        let result: Result<[UsageWindow], FetchError>
        func fetch() async throws -> [UsageWindow] { try result.get() }
    }
    private func win(_ key: String, _ label: String, used: Double, resetsIn s: TimeInterval) -> UsageWindow {
        UsageWindow(key: key, label: label, usedPercent: used, resetsAt: now.addingTimeInterval(s))
    }

    func testRefreshSetsLoaded() async {
        let store = UsageStore(provider: FakeProvider(result: .success([win("five_hour", "5-hour session", used: 8, resetsIn: 3600)])),
                               threshold: nil, now: { self.now })
        await store.refresh()
        XCTAssertEqual(store.loadState, .loaded([win("five_hour", "5-hour session", used: 8, resetsIn: 3600)]))
        XCTAssertEqual(store.lastChecked, now)
    }

    func testRefreshSetsFailed() async {
        let store = UsageStore(provider: FakeProvider(result: .failure(.authExpired)), threshold: nil, now: { self.now })
        await store.refresh()
        XCTAssertEqual(store.loadState, .failed(.authExpired))
    }

    func testAlertsFireThroughHook() async {
        var captured: [AlertEvent] = []
        let store = UsageStore(provider: FakeProvider(result: .success([win("five_hour", "5-hour session", used: 100, resetsIn: 3600)])),
                               threshold: 85, now: { self.now })
        store.onAlerts = { captured.append(contentsOf: $0) }
        await store.refresh()
        XCTAssertEqual(captured.count, 1)
        if case .reached = captured[0] {} else { XCTFail("expected .reached") }
    }

    func testMenuBarTitlePrefersSoonestReached() async {
        let store = UsageStore(provider: FakeProvider(result: .success([
            win("five_hour", "5-hour session", used: 100, resetsIn: 7200),   // reopens later
            win("seven_day", "7-day (all models)", used: 100, resetsIn: 600) // reopens sooner
        ])), threshold: nil, now: { self.now })
        await store.refresh()
        XCTAssertEqual(store.menuBarTitle, "⛔ 0:10:00")
        XCTAssertEqual(store.menuBarColor, .red)
    }

    func testMenuBarTitleShowsLowestRemainingWhenOk() async {
        let store = UsageStore(provider: FakeProvider(result: .success([
            win("five_hour", "5-hour session", used: 8, resetsIn: 3600),     // 92% left
            win("seven_day", "7-day (all models)", used: 40, resetsIn: 3600) // 60% left
        ])), threshold: nil, now: { self.now })
        await store.refresh()
        XCTAssertEqual(store.menuBarTitle, "◔ 60%")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd dashboard && swift test --filter UsageStoreTests`
Expected: FAIL — `UsageStore` undefined.

- [ ] **Step 3: Write the implementation**

`Sources/Dashboard/UsageStore.swift`:

```swift
import Foundation
import Combine

enum LoadState: Equatable {
    case loading
    case loaded([UsageWindow])
    case failed(FetchError)
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var loadState: LoadState = .loading
    @Published private(set) var lastChecked: Date?

    var onAlerts: ([AlertEvent]) -> Void = { _ in }

    private let provider: UsageProviding
    private let now: () -> Date
    private var alertEngine: AlertEngine

    init(provider: UsageProviding, threshold: Double?, now: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.now = now
        self.alertEngine = AlertEngine(threshold: threshold)
    }

    func setThreshold(_ value: Double?) { alertEngine.threshold = value }

    func refresh() async {
        do {
            let windows = try await provider.fetch()
            loadState = .loaded(windows)
            lastChecked = now()
            let events = alertEngine.evaluate(windows, now: now())
            if !events.isEmpty { onAlerts(events) }
        } catch let error as FetchError {
            loadState = .failed(error)
        } catch {
            loadState = .failed(.network(error.localizedDescription))
        }
    }

    private var windows: [UsageWindow] {
        if case .loaded(let w) = loadState { return w }
        return []
    }

    var menuBarColor: GaugeColor {
        switch loadState {
        case .loading, .failed: return .amber
        case .loaded:
            let reached = windows.filter { $0.usedPercent >= 100 }
            if !reached.isEmpty { return .red }
            return windows.map { $0.color() }.contains(.red) ? .red
                : windows.map { $0.color() }.contains(.amber) ? .amber : .green
        }
    }

    var menuBarTitle: String {
        switch loadState {
        case .loading: return "…"
        case .failed: return "⚠"
        case .loaded:
            let reached = windows.filter { $0.usedPercent >= 100 }
            if let soonest = reached.min(by: { $0.resetsAt < $1.resetsAt }) {
                return "⛔ \(soonest.countdown(now: now()))"
            }
            guard let lowest = windows.min(by: { $0.remainingPercent < $1.remainingPercent }) else {
                return "◔ —"
            }
            return "◔ \(Int(lowest.remainingPercent.rounded()))%"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd dashboard && swift test --filter UsageStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd dashboard
git add Sources/Dashboard/UsageStore.swift Tests/DashboardTests/UsageStoreTests.swift
git commit -m "feat(dashboard): observable UsageStore with menu-bar summary

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Notifications + threshold persistence

**Files:**
- Create: `dashboard/Sources/Dashboard/Notifier.swift`
- Create: `dashboard/Sources/Dashboard/Settings.swift`
- Test: `dashboard/Tests/DashboardTests/SettingsTests.swift`

**Interfaces:**
- Consumes: `AlertEvent` (Task 5).
- Produces:
  - `enum Notifier { static func post(_ events: [AlertEvent]); static func requestAuthorization() }` — maps each `AlertEvent` to a `UNMutableNotificationContent` (title "Claude Code Usage", body e.g. "5-hour limit reached · available in 1:11:48") and delivers immediately. Pure-logic helper `static func body(for: AlertEvent) -> (title: String, body: String)` is what we test.
  - `struct Settings { var threshold: Double?; static func load(_ d: UserDefaults) -> Settings; func save(_ d: UserDefaults) }` — persists the threshold; `nil` means alerts off.

- [ ] **Step 1: Write the failing test**

`Tests/DashboardTests/SettingsTests.swift`:

```swift
import XCTest
@testable import Dashboard

final class SettingsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        return d
    }

    func testRoundTripThreshold() {
        let d = defaults()
        Settings(threshold: 85).save(d)
        XCTAssertEqual(Settings.load(d).threshold, 85)
    }

    func testNilThresholdMeansOff() {
        let d = defaults()
        Settings(threshold: nil).save(d)
        XCTAssertNil(Settings.load(d).threshold)
    }

    func testNotificationBodyForReached() {
        let (title, body) = Notifier.body(for: .reached(label: "5-hour session", countdown: "1:11:48"))
        XCTAssertEqual(title, "Claude Code Usage")
        XCTAssertEqual(body, "5-hour session limit reached · available in 1:11:48")
    }

    func testNotificationBodyForApproaching() {
        let (_, body) = Notifier.body(for: .approaching(label: "7-day (all models)", countdown: "1h 12m"))
        XCTAssertEqual(body, "7-day (all models) at threshold · resets in 1h 12m")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd dashboard && swift test --filter SettingsTests`
Expected: FAIL — `Settings` / `Notifier` undefined.

- [ ] **Step 3: Write the implementations**

`Sources/Dashboard/Settings.swift`:

```swift
import Foundation

struct Settings {
    var threshold: Double?   // nil = alerts off

    private static let key = "alertThresholdPercent"  // store -1 for "off"

    static func load(_ defaults: UserDefaults = .standard) -> Settings {
        guard defaults.object(forKey: key) != nil else { return Settings(threshold: nil) }
        let v = defaults.double(forKey: key)
        return Settings(threshold: v >= 0 ? v : nil)
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(threshold ?? -1, forKey: Self.key)
    }
}
```

`Sources/Dashboard/Notifier.swift`:

```swift
import Foundation
import UserNotifications

enum Notifier {
    static func body(for event: AlertEvent) -> (title: String, body: String) {
        let title = "Claude Code Usage"
        switch event {
        case .reached(let label, let countdown):
            return (title, "\(label) limit reached · available in \(countdown)")
        case .approaching(let label, let countdown):
            return (title, "\(label) at threshold · resets in \(countdown)")
        }
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ events: [AlertEvent]) {
        let center = UNUserNotificationCenter.current()
        for event in events {
            let (title, body) = body(for: event)
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content, trigger: nil)
            center.add(request)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd dashboard && swift test --filter SettingsTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd dashboard
git add Sources/Dashboard/Notifier.swift Sources/Dashboard/Settings.swift Tests/DashboardTests/SettingsTests.swift
git commit -m "feat(dashboard): notifications + threshold persistence

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: SwiftUI views (popover)

**Files:**
- Create: `dashboard/Sources/Dashboard/GaugesView.swift`

**Interfaces:**
- Consumes: `UsageStore` (Task 7), `UsageWindow`/`GaugeColor`/`WindowState` (Task 2).
- Produces: `struct GaugesView: View` taking `@ObservedObject var store: UsageStore` and a `now: Date` (driven by the 1s tick from Task 10) plus threshold-edit bindings. No new testable logic — this is presentation only, so there is no XCTest step; verification is the manual smoke test at the end.

- [ ] **Step 1: Write the view**

`Sources/Dashboard/GaugesView.swift`:

```swift
import SwiftUI

private func swiftUIColor(_ c: GaugeColor) -> Color {
    switch c { case .green: return .green; case .amber: return .orange; case .red: return .red }
}

struct GaugesView: View {
    @ObservedObject var store: UsageStore
    let now: Date
    @Binding var thresholdEnabled: Bool
    @Binding var thresholdValue: Double
    var onThresholdChange: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Code Usage").font(.headline)

            switch store.loadState {
            case .loading:
                ProgressView().frame(maxWidth: .infinity)
            case .failed(let error):
                errorView(error)
            case .loaded(let windows):
                content(windows)
            }

            Divider()
            thresholdControl
            Button("Quit", action: onQuit)
        }
        .padding(16)
        .frame(width: 300)
    }

    @ViewBuilder private func content(_ windows: [UsageWindow]) -> some View {
        let reached = windows.filter { if case .reached = $0.state { return true }; return false }
        let healthy = windows.filter { if case .ok = $0.state { return true }; return false }

        ForEach(reached, id: \.key) { w in
            VStack(alignment: .leading, spacing: 4) {
                Label("\(w.label) limit reached", systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red).font(.subheadline.bold())
                Text("available in \(w.countdown(now: now))")
                    .font(.system(.title, design: .monospaced))
            }
        }
        if !healthy.isEmpty {
            HStack(spacing: 16) {
                ForEach(healthy, id: \.key) { w in gauge(w) }
            }
        }
        if let checked = store.lastChecked {
            Text("checked \(checked.formatted(date: .omitted, time: .standard))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func gauge(_ w: UsageWindow) -> some View {
        VStack(spacing: 4) {
            Gauge(value: w.remainingPercent, in: 0...100) {
                EmptyView()
            } currentValueLabel: {
                Text("\(Int(w.remainingPercent.rounded()))%")
            }
            .gaugeStyle(.accessoryCircular)
            .tint(swiftUIColor(w.color()))
            Text(w.label).font(.caption2).multilineTextAlignment(.center)
            Text(w.countdown(now: now)).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 72)
    }

    private func errorView(_ error: FetchError) -> some View {
        let message: String
        switch error {
        case .authExpired: message = "Token expired — run `claude` once to refresh."
        case .notLoggedIn: message = "Not logged in to Claude Code."
        case .network(let m): message = "Network error: \(m)"
        case .decode: message = "Couldn't read the usage response."
        }
        return Label(message, systemImage: "wifi.exclamationmark")
            .font(.callout).foregroundStyle(.secondary)
    }

    private var thresholdControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Alert me at threshold", isOn: $thresholdEnabled)
                .onChange(of: thresholdEnabled) { _ in onThresholdChange() }
            if thresholdEnabled {
                HStack {
                    Text("\(Int(thresholdValue))% used")
                    Slider(value: $thresholdValue, in: 50...99, step: 1)
                        .onChange(of: thresholdValue) { _ in onThresholdChange() }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd dashboard && swift build`
Expected: builds with no errors. (Views are exercised in the Task 11 smoke test.)

- [ ] **Step 3: Commit**

```bash
cd dashboard
git add Sources/Dashboard/GaugesView.swift
git commit -m "feat(dashboard): popover gauges + limit-reached countdown view

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: App entry point (MenuBarExtra + timers)

**Files:**
- Create: `dashboard/Sources/Dashboard/DashboardApp.swift`
- Delete: `dashboard/Sources/Dashboard/Placeholder.swift`

**Interfaces:**
- Consumes: everything above — `UsageStore.live` wiring via `UsageClient.live()`, `GaugesView`, `Notifier`, `Settings`.
- Produces: the `@main` app. No unit tests (UI/wiring); verified by the Task 11 smoke test.

- [ ] **Step 1: Delete the placeholder**

```bash
cd dashboard && git rm Sources/Dashboard/Placeholder.swift
```

- [ ] **Step 2: Write the app entry point**

`Sources/Dashboard/DashboardApp.swift`:

```swift
import SwiftUI

@main
struct DashboardApp: App {
    @StateObject private var store: UsageStore
    @State private var thresholdEnabled: Bool
    @State private var thresholdValue: Double
    @State private var now = Date()

    private let refreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private let tickTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init() {
        let settings = Settings.load()
        let store = UsageStore(provider: UsageClient.live(), threshold: settings.threshold)
        store.onAlerts = { Notifier.post($0) }
        _store = StateObject(wrappedValue: store)
        _thresholdEnabled = State(initialValue: settings.threshold != nil)
        _thresholdValue = State(initialValue: settings.threshold ?? 85)
    }

    var body: some Scene {
        MenuBarExtra {
            GaugesView(
                store: store,
                now: now,
                thresholdEnabled: $thresholdEnabled,
                thresholdValue: $thresholdValue,
                onThresholdChange: applyThreshold,
                onQuit: { NSApplication.shared.terminate(nil) }
            )
            .onReceive(refreshTimer) { _ in Task { await store.refresh() } }
            .onReceive(tickTimer) { now = $0 }
            .task {
                Notifier.requestAuthorization()
                await store.refresh()
            }
        } label: {
            Text(store.menuBarTitle)
        }
        .menuBarExtraStyle(.window)
    }

    private func applyThreshold() {
        let value: Double? = thresholdEnabled ? thresholdValue : nil
        store.setThreshold(value)
        Settings(threshold: value).save()
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `cd dashboard && swift build`
Expected: builds with no errors.

- [ ] **Step 4: Commit**

```bash
cd dashboard
git add Sources/Dashboard/DashboardApp.swift
git rm --cached Sources/Dashboard/Placeholder.swift 2>/dev/null || true
git commit -m "feat(dashboard): MenuBarExtra app entry with refresh + tick timers

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: Bundle build script + Info.plist + README

**Files:**
- Create: `dashboard/Resources/Info.plist`
- Create: `dashboard/build-app.sh`
- Create: `dashboard/README.md`

**Interfaces:**
- Consumes: the built `Dashboard` binary.
- Produces: `Dashboard.app` — a menu-bar-only (`LSUIElement`) ad-hoc-signed bundle. Final manual smoke test confirms the whole app runs.

- [ ] **Step 1: Write the Info.plist**

`Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Claude Usage</string>
    <key>CFBundleExecutable</key><string>Dashboard</string>
    <key>CFBundleIdentifier</key><string>com.claudeusage.dashboard</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
```

- [ ] **Step 2: Write the build script**

`build-app.sh`:

```bash
#!/usr/bin/env bash
# Build Dashboard.app — a menu-bar-only macOS app bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP="Dashboard.app"
CONTENTS="$APP/Contents"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Dashboard"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/Dashboard"
cp Resources/Info.plist "$CONTENTS/Info.plist"

# Ad-hoc sign so UNUserNotificationCenter works.
codesign --force --sign - "$APP"

echo "Built $APP — run with: open $APP"
```

- [ ] **Step 3: Make it executable and build the bundle**

Run:
```bash
cd dashboard && chmod +x build-app.sh && ./build-app.sh
```
Expected: prints "Built Dashboard.app". (If `codesign` fails in the environment, the bundle still exists; note it in the README.)

- [ ] **Step 4: Manual smoke test**

Run: `cd dashboard && open Dashboard.app`
Expected: a menu bar item appears showing `◔ N%` (or `…` briefly while loading); clicking it opens the popover with circular gauges and reset countdowns; no Dock icon appears. Quit from the popover's Quit button.

If you are not logged in, expect the popover to show "Not logged in" / "Token expired" — that is the correct error state, not a failure of this task.

- [ ] **Step 5: Write the README**

`README.md`:

```markdown
# claude-usage-dashboard

A native macOS menu bar app showing live Claude Code subscription usage as
circular gauges, with a countdown to reopening when a limit is reached. A
self-contained companion to the `claude-usage` CLI tool (no Python needed).

## Requirements
- macOS 13 (Ventura) or later
- A logged-in Claude Code session (the token is read from the Keychain)
- Swift toolchain (Xcode or Command Line Tools) to build

## Build & run
```bash
swift build           # compile
swift run             # run from the terminal (dev)
./build-app.sh        # produce Dashboard.app (menu-bar-only, ad-hoc signed)
open Dashboard.app    # launch the bundled app
```

## What it shows
- A circular gauge per usage window (5-hour, 7-day, per-model) showing **% left**,
  colored green → amber → red as it fills.
- The menu bar title shows the lowest remaining % (`◔ 92%`), or — when a limit is
  reached — a live `⛔ H:MM:SS` countdown to the soonest reopening.
- Optional notifications when a window crosses your threshold or hits its limit
  (set the threshold in the popover; off by default).

## How it works
Reads the OAuth token via `security find-generic-password -s "Claude Code-credentials"`,
calls `GET /api/oauth/usage`, and renders the windows. It polls every 60s; the
countdown ticks locally every second. Only reads — never writes credentials.

## Tests
```bash
swift test            # pure-logic unit tests (model, decoder, alerts, store)
```
Network and Keychain access sit behind a protocol and are not unit-tested.
```

- [ ] **Step 6: Run the full test suite once more**

Run: `cd dashboard && swift test`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
cd dashboard
git add Resources/Info.plist build-app.sh README.md
git commit -m "feat(dashboard): app bundle build script, Info.plist, README

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Notes for the implementer

- **Build artifacts:** add `.build/` and `Dashboard.app/` to a `.gitignore` in `dashboard/` if they aren't already ignored by the repo root. Do this in Task 1's commit if convenient.
- **`onChange` deprecation:** on macOS 14+ the two-parameter `onChange(of:)` is preferred, but the single-trailing-closure form used here compiles with a deprecation warning on 14+ and works on 13. Leave as-is unless you are targeting 14+ only.
- **Async on MainActor:** `UsageStore` is `@MainActor`; `refresh()` is called from SwiftUI `.task`/`.onReceive`, which already hop to the main actor. Keep the `await` calls as written.
- **Never log the token.** `readKeychainToken()` must not print or persist the token anywhere; it only flows into the `Authorization` header.
