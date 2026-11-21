import Foundation
import SQLite3

struct CursorUsageClient: UsageProviding {
    /// Cursor's dashboard RPCs (Connect protocol, JSON) — the same calls the
    /// Cursor app makes for its usage panel.
    static let base = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/")!

    let tokenReader: () throws -> String
    let transport: (URLRequest) async throws -> (Data, URLResponse)
    let now: () -> Date

    init(tokenReader: @escaping () throws -> String,
         transport: @escaping (URLRequest) async throws -> (Data, URLResponse),
         now: @escaping () -> Date = Date.init) {
        self.tokenReader = tokenReader
        self.transport = transport
        self.now = now
    }

    func fetch() async throws -> [UsageWindow] {
        let token: String
        do { token = try tokenReader() } catch { throw FetchError.notLoggedIn }

        let periodData = try await call("GetCurrentPeriodUsage", token: token, body: [:])
        let period: CursorUsageDecoder.Period
        do { period = try CursorUsageDecoder.period(from: periodData) }
        catch { throw FetchError.decode }

        // The per-model breakdown is a nice-to-have: if it fails, still show the quotas.
        let models = try? await call("GetAggregatedUsageEvents", token: token, body: [
            "startDate": String(period.cycleStartMs!),
            "endDate": String(Int64(now().timeIntervalSince1970 * 1000)),
        ])
        // ...but a call cut short by cancellation (popover closed) isn't a
        // failure: don't let it pass as a success that lacks the breakdown.
        try Task.checkCancellation()
        return CursorUsageDecoder.windows(period: period, models: models)
    }

    private func call(_ method: String, token: String, body: [String: String]) async throws -> Data {
        var req = URLRequest(url: Self.base.appendingPathComponent(method))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data, response: URLResponse
        do { (data, response) = try await transport(req) }
        catch { throw FetchError.network(error.localizedDescription) }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw FetchError.authExpired }
            if http.statusCode == 429 { throw FetchError.rateLimited }
            guard (200..<300).contains(http.statusCode) else {
                throw FetchError.network("HTTP \(http.statusCode)")
            }
        }
        return data
    }

    /// Real wiring: token from Cursor's local state DB, network via URLSession.
    static func live() -> CursorUsageClient {
        CursorUsageClient(tokenReader: { try readToken(dbPath: stateDBPath()) },
                          transport: { try await URLSession.shared.data(for: $0) })
    }

    static func stateDBPath() -> String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    static func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: stateDBPath())
    }

    /// Reads the session token the Cursor app stores after sign-in. Opened
    /// read-only and re-read on every fetch, so a re-login is picked up
    /// without restarting. The token is never logged.
    static func readToken(dbPath: String) throws -> String {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw FetchError.notLoggedIn
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)

        var stmt: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw FetchError.notLoggedIn }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(stmt, 0) ?? sqlite3_column_text(stmt, 0).map(UnsafeRawPointer.init)
        else { throw FetchError.notLoggedIn }
        let token = String(decoding: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0))), as: UTF8.self)
        guard !token.isEmpty else { throw FetchError.notLoggedIn }
        return token
    }
}
