import Foundation

enum FetchError: Error, Equatable {
    case notLoggedIn
    case authExpired
    case rateLimited
    case network(String)
    case decode
}

protocol UsageProviding {
    func fetch() async throws -> [UsageWindow]
}

struct UsageClient: UsageProviding {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    // The /oauth/usage endpoint gates the generous rate-limit bucket on a
    // `claude-code/<version>` User-Agent. Without it, requests land in an
    // aggressively throttled bucket and get persistent 429s (retry-after:0).
    // Only the `claude-code/` prefix + a version token matters; see TESTING.md.
    static let userAgent = "claude-code/2.1.195"

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
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw FetchError.notLoggedIn }

        struct Creds: Decodable { struct OAuth: Decodable { let accessToken: String }
                                  let claudeAiOauth: OAuth }
        guard let creds = try? JSONDecoder().decode(Creds.self, from: out) else {
            throw FetchError.notLoggedIn
        }
        return creds.claudeAiOauth.accessToken
    }
}
