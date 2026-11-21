import Foundation

struct CodexUsageClient: UsageProviding {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    // The Codex usage bucket expects a `codex_cli_rs/<version>` User-Agent;
    // requests with a different UA are not served from the Codex usage endpoint.
    static let userAgent = "codex_cli_rs/0.136.0"

    let authReader: () throws -> (token: String, accountId: String)
    let transport: (URLRequest) async throws -> (Data, URLResponse)

    init(authReader: @escaping () throws -> (token: String, accountId: String),
         transport: @escaping (URLRequest) async throws -> (Data, URLResponse)) {
        self.authReader = authReader
        self.transport = transport
    }

    func fetch() async throws -> [UsageWindow] {
        let auth: (token: String, accountId: String)
        do { auth = try authReader() } catch { throw FetchError.notLoggedIn }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        req.setValue(auth.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data, response: URLResponse
        do { (data, response) = try await transport(req) }
        catch { throw FetchError.network(error.localizedDescription) }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 { throw FetchError.authExpired }
            if http.statusCode == 429 { throw FetchError.rateLimited }
            guard (200..<300).contains(http.statusCode) else {
                throw FetchError.network("HTTP \(http.statusCode)")
            }
        }

        do { return try CodexUsageDecoder.windows(from: data) }
        catch { throw FetchError.decode }
    }

    /// Real wiring: auth from `~/.codex/auth.json`, network via URLSession.
    static func live() -> CodexUsageClient {
        CodexUsageClient(authReader: Self.readAuth,
                         transport: { try await URLSession.shared.data(for: $0) })
    }

    static func authPath(home: String = realHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".codex/auth.json")
    }

    /// The user's actual home. Under the App Sandbox NSHomeDirectory() is the
    /// app's container, but the read-only `/.codex/auth.json` entitlement exception is
    /// relative to the real home.
    static func realHomeDirectory() -> String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    static func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: authPath())
    }

    static func readAuth() throws -> (token: String, accountId: String) {
        let data = try Data(contentsOf: URL(fileURLWithPath: authPath()))

        struct Auth: Decodable {
            struct Tokens: Decodable {
                let access_token: String
                let account_id: String
            }
            let tokens: Tokens
        }
        // The token is never logged.
        guard let auth = try? JSONDecoder().decode(Auth.self, from: data) else {
            throw FetchError.notLoggedIn
        }
        return (auth.tokens.access_token, auth.tokens.account_id)
    }
}
