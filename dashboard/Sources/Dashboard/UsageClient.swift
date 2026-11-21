import Foundation
import Security

enum FetchError: Error, Equatable {
    case notLoggedIn
    case authExpired
    case rateLimited
    case network(String)
    case decode
    /// The service is permanently unavailable to this account (e.g. a retired
    /// free tier). The provider is hidden and never polled again.
    case unsupported(String)
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

    /// Real wiring: Keychain token, network via URLSession. The direct build
    /// reads via `security` (its Keychain approval predates this split, so
    /// existing users aren't re-prompted); the sandboxed App Store build can't
    /// run that tool and asks Security.framework directly.
    static func live() -> UsageClient {
        UsageClient(tokenReader: Flavor.isAppStore ? Self.readKeychainItemToken : Self.readKeychainToken,
                    transport: { try await URLSession.shared.data(for: $0) })
    }

    static let keychainService = "Claude Code-credentials"

    /// The access token inside the JSON blob the Claude CLI stores. Anything
    /// else (API-key logins, garbage) means there's no usable OAuth session.
    static func token(fromCredentials data: Data) throws -> String {
        struct Creds: Decodable { struct OAuth: Decodable { let accessToken: String }
                                  let claudeAiOauth: OAuth }
        guard let creds = try? JSONDecoder().decode(Creds.self, from: data) else {
            throw FetchError.notLoggedIn
        }
        return creds.claudeAiOauth.accessToken
    }

    /// Every Keychain failure — no item, the user clicked Deny, no UI
    /// allowed — is something a fresh `claude` login fixes.
    static func keychainError(for status: OSStatus) -> FetchError { .notLoggedIn }

    /// Sandbox-safe read of the Claude CLI's item. The token is never logged.
    static func readKeychainItemToken() throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            throw keychainError(for: status)
        }
        return try token(fromCredentials: data)
    }

    static func readKeychainToken() throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw FetchError.notLoggedIn }
        return try token(fromCredentials: out)
    }
}
