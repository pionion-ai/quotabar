import Foundation

struct GeminiUsageClient: UsageProviding {
    // Public installed-app OAuth client credentials shipped with the open-source
    // gemini CLI. They are not secret (they live in the OSS repo) and are safe
    // to embed for the refresh-token grant.
    static let clientID = "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com"
    static let clientSecret = "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"

    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let quotaEndpoint = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
    static let loadCodeAssistEndpoint = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!

    let credsReader: () throws -> (refreshToken: String, project: String)
    let transport: (URLRequest) async throws -> (Data, URLResponse)

    init(credsReader: @escaping () throws -> (refreshToken: String, project: String),
         transport: @escaping (URLRequest) async throws -> (Data, URLResponse)) {
        self.credsReader = credsReader
        self.transport = transport
    }

    private struct TokenResponse: Decodable { let access_token: String? }

    func fetch() async throws -> [UsageWindow] {
        let creds: (refreshToken: String, project: String)
        do { creds = try credsReader() } catch { throw FetchError.notLoggedIn }

        // 1. Refresh the short-lived access token in-memory (never written back).
        let accessToken = try await refresh(refreshToken: creds.refreshToken)

        // 2. Quota is per Code Assist project. Without one configured, ask the
        //    server which project this account uses — as the gemini CLI does.
        let project = creds.project.isEmpty
            ? try await loadCodeAssistProject(accessToken: accessToken)
            : creds.project

        // 3. Fetch the quota buckets with the freshly minted bearer.
        let quotaData = try await retrieveQuota(accessToken: accessToken, project: project)

        do { return try GeminiUsageDecoder.windows(from: quotaData) }
        catch { throw FetchError.decode }
    }

    private func refresh(refreshToken: String) async throws -> String {
        var req = URLRequest(url: Self.tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=refresh_token"
            + "&refresh_token=\(form(refreshToken))"
            + "&client_id=\(form(Self.clientID))"
            + "&client_secret=\(form(Self.clientSecret))"
        req.httpBody = body.data(using: .utf8)

        let data: Data, response: URLResponse
        do { (data, response) = try await transport(req) }
        catch { throw FetchError.network(error.localizedDescription) }

        // A non-2xx response or a missing access_token means the refresh token is
        // invalid/expired — the user must re-run `gemini`. Tokens are never logged.
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw FetchError.notLoggedIn
        }
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data).access_token,
              !token.isEmpty else {
            throw FetchError.notLoggedIn
        }
        return token
    }

    /// `cloudaicompanionProject` arrives as a plain id, or as `{"id": ...}`.
    private struct LoadCodeAssistResponse: Decodable {
        struct IneligibleTier: Decodable { let reasonCode: String?; let reasonMessage: String? }
        let project: String?
        let ineligibleTiers: [IneligibleTier]?
        private enum CodingKeys: String, CodingKey { case cloudaicompanionProject, ineligibleTiers }
        private struct ProjectObject: Decodable { let id: String? }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            project = (try? c.decode(String.self, forKey: .cloudaicompanionProject))
                ?? (try? c.decode(ProjectObject.self, forKey: .cloudaicompanionProject))?.id
            ineligibleTiers = try? c.decode([IneligibleTier].self, forKey: .ineligibleTiers)
        }
    }

    /// Returns "" when the account has no Code Assist project yet; quota is
    /// then requested without one.
    private func loadCodeAssistProject(accessToken: String) async throws -> String {
        let data = try await post(Self.loadCodeAssistEndpoint, accessToken: accessToken, body: [
            "metadata": ["ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"],
        ])
        let decoded = try? JSONDecoder().decode(LoadCodeAssistResponse.self, from: data)
        // Google retired the gemini CLI for "Code Assist for individuals"
        // (2026): the account's tier is reported ineligible for this client.
        if let retired = decoded?.ineligibleTiers?.first(where: { $0.reasonCode == "UNSUPPORTED_CLIENT" }) {
            throw FetchError.unsupported(retired.reasonMessage ?? "This client is no longer supported.")
        }
        return decoded?.project ?? ""
    }

    private func retrieveQuota(accessToken: String, project: String) async throws -> Data {
        try await post(Self.quotaEndpoint, accessToken: accessToken,
                       body: project.isEmpty ? [:] : ["project": project])
    }

    private func post(_ url: URL, accessToken: String, body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data, response: URLResponse
        do { (data, response) = try await transport(req) }
        catch { throw FetchError.network(error.localizedDescription) }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 { throw FetchError.authExpired }
            if http.statusCode == 429 { throw FetchError.rateLimited }
            // 403 = not entitled (e.g. "no valid license"): permanent, stop polling.
            if http.statusCode == 403 {
                throw FetchError.unsupported(Self.describe(status: 403, call: url, body: data))
            }
            guard (200..<300).contains(http.statusCode) else {
                throw FetchError.network(Self.describe(status: http.statusCode, call: url, body: data))
            }
        }
        return data
    }

    private struct GoogleError: Decodable {
        struct Detail: Decodable { let message: String? }
        let error: Detail?
    }

    /// "HTTP 403 (retrieveUserQuota): <Google's message>" — Google's error
    /// messages name the project/API at fault and carry no credentials.
    static func describe(status: Int, call url: URL, body: Data) -> String {
        let call = url.lastPathComponent.components(separatedBy: ":").last ?? url.lastPathComponent
        let base = "HTTP \(status) (\(call))"
        guard let message = (try? JSONDecoder().decode(GoogleError.self, from: body))?.error?.message,
              !message.isEmpty else { return base }
        return "\(base): \(message.prefix(200))"
    }

    private func form(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: - Live wiring

    /// Real wiring: creds from `~/.gemini`, network via URLSession.
    static func live() -> GeminiUsageClient {
        GeminiUsageClient(credsReader: Self.readCreds,
                          transport: { try await URLSession.shared.data(for: $0) })
    }

    static func credsPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".gemini/oauth_creds.json")
    }

    static func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: credsPath())
    }

    static func readCreds() throws -> (refreshToken: String, project: String) {
        let credsData = try Data(contentsOf: URL(fileURLWithPath: credsPath()))
        // The refresh token is never logged. Refresh is in-memory only — we do
        // not write back to oauth_creds.json.
        struct Creds: Decodable { let refresh_token: String? }
        guard let rt = try? JSONDecoder().decode(Creds.self, from: credsData).refresh_token,
              !rt.isEmpty else {
            throw FetchError.notLoggedIn
        }

        return (rt, configuredProject(env: ProcessInfo.processInfo.environment))
    }

    /// An explicitly configured Cloud project, from the env vars the gemini CLI
    /// honours; "" means "ask loadCodeAssist". (`~/.gemini/projects.json` is not
    /// a source: it maps local folders to short names, not Cloud project ids.)
    static func configuredProject(env: [String: String]) -> String {
        env["GOOGLE_CLOUD_PROJECT"].flatMap { $0.isEmpty ? nil : $0 }
            ?? env["GOOGLE_CLOUD_PROJECT_ID"] ?? ""
    }
}
