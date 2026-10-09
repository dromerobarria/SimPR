import Foundation
import Security

/// Scopes requested in the device flow.
///
/// GitHub OAuth apps have no read-only scope for Actions artifacts: downloading an
/// artifact from a private repository needs `repo`. Public repositories need a
/// token too, but no scope.
public enum AuthScope: String, Sendable, CaseIterable {
    case publicOnly = ""
    case includePrivate = "repo"
}

public struct DeviceCode: Decodable, Equatable, Sendable {
    public var deviceCode: String
    public var userCode: String
    public var verificationURI: URL
    public var expiresIn: Int
    public var interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

public enum DeviceFlowError: Error, LocalizedError, Equatable {
    case notConfigured
    case disabled
    case expired
    case denied
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "This copy of SimPR has no GitHub OAuth client ID. Use the GitHub CLI sign-in, or set SimPRGitHubClientID (see docs/mac-app.md)."
        case .disabled: "Device sign-in is disabled for this GitHub OAuth app. Enable “Device Flow” in its settings."
        case .expired: "The sign-in code expired. Start again."
        case .denied: "Sign-in was cancelled on GitHub."
        case .failed(let m): "Sign-in failed: \(m)"
        }
    }
}

/// GitHub OAuth device flow. Needs only the client ID, no secret.
public struct DeviceFlow: Sendable {
    public let clientID: String
    let session: URLSession
    let baseURL: URL

    public init(clientID: String, session: URLSession = .shared, baseURL: URL = URL(string: "https://github.com")!) {
        self.clientID = clientID
        self.session = session
        self.baseURL = baseURL
    }

    private func post(_ path: String, _ form: [String: String]) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents()
        c.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((c.percentEncodedQuery ?? "").utf8)
        let (data, _) = try await session.data(for: request)
        return data
    }

    public func start(scope: AuthScope) async throws -> DeviceCode {
        guard !clientID.isEmpty else { throw DeviceFlowError.notConfigured }
        let data = try await post("login/device/code", ["client_id": clientID, "scope": scope.rawValue])
        if let error = try? JSONDecoder().decode(OAuthError.self, from: data) {
            throw error.error == "device_flow_disabled" ? DeviceFlowError.disabled : DeviceFlowError.failed(error.errorDescription ?? error.error)
        }
        return try JSONDecoder().decode(DeviceCode.self, from: data)
    }

    /// Polls until the user approves, honoring `interval` and `slow_down`.
    public func waitForToken(_ code: DeviceCode, sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async throws -> String {
        var interval = max(code.interval, 1)
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        while Date() < deadline {
            try await sleep(.seconds(interval))
            let data = try await post("login/oauth/access_token", [
                "client_id": clientID,
                "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            switch try Self.pollResult(data) {
            case .token(let token): return token
            case .pending: continue
            case .slowDown(let newInterval): interval = newInterval ?? interval + 5
            }
        }
        throw DeviceFlowError.expired
    }

    enum PollResult: Equatable {
        case token(String)
        case pending
        case slowDown(Int?)
    }

    struct OAuthError: Decodable {
        var error: String
        var errorDescription: String?
        var interval: Int?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
            case interval
        }
    }

    static func pollResult(_ data: Data) throws -> PollResult {
        struct TokenResponse: Decodable { var access_token: String }
        if let token = try? JSONDecoder().decode(TokenResponse.self, from: data) { return .token(token.access_token) }
        let error = try JSONDecoder().decode(OAuthError.self, from: data)
        switch error.error {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown(error.interval)
        case "expired_token": throw DeviceFlowError.expired
        case "access_denied": throw DeviceFlowError.denied
        case "device_flow_disabled": throw DeviceFlowError.disabled
        default: throw DeviceFlowError.failed(error.errorDescription ?? error.error)
        }
    }
}

/// Stores the GitHub token in the login Keychain.
public struct KeychainTokenStore: Sendable {
    let service: String
    let account: String

    public init(service: String = "dev.simpr.SimPR", account: String = "github") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func save(_ token: String) -> Bool {
        delete()
        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    public func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// Reads the GitHub CLI's token (`gh auth token`), if gh is installed and signed in.
public struct GitHubCLITokenSource: Sendable {
    let runner: any ProcessRunning

    public init(runner: any ProcessRunning = ProcessRunner()) {
        self.runner = runner
    }

    public var isInstalled: Bool { Tools.gh() != nil }

    public func token() async -> String? {
        guard let gh = Tools.gh() else { return nil }
        guard let result = try? await runner.run(gh, ["auth", "token", "--hostname", "github.com"]), result.succeeded else { return nil }
        let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
