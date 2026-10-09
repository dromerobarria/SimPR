import AppKit
import Foundation
import Observation
import SimPRCore

/// Supplies the GitHub token: the Keychain first, then (optionally) the GitHub CLI.
final class TokenProvider: TokenProviding, @unchecked Sendable {
    let keychain: KeychainTokenStore
    private let lock = NSLock()
    private var _allowGitHubCLI = true

    init(keychain: KeychainTokenStore) {
        self.keychain = keychain
    }

    var allowGitHubCLI: Bool {
        get { lock.withLock { _allowGitHubCLI } }
        set { lock.withLock { _allowGitHubCLI = newValue } }
    }

    func token() async -> String? {
        if let token = keychain.read() { return token }
        guard allowGitHubCLI else { return nil }
        return await GitHubCLITokenSource().token()
    }
}

@MainActor
@Observable
final class AuthModel {
    enum Source: Equatable {
        case simpr
        case gitHubCLI
    }

    enum State: Equatable {
        case unknown
        case signedOut
        case signedIn(login: String, source: Source, privateRepos: Bool)
        case waitingForCode
        case enterCode(DeviceCode)
        case failed(String)
    }

    private(set) var state: State = .unknown
    let tokens: TokenProvider
    private let preferences: Preferences
    private var flowTask: Task<Void, Never>?

    /// From Info.plist (`SimPRGitHubClientID`), set at build time. Empty disables the device flow.
    let clientID: String = (Bundle.main.object(forInfoDictionaryKey: "SimPRGitHubClientID") as? String)?
        .trimmingCharacters(in: .whitespaces) ?? ""

    var canUseDeviceFlow: Bool { !clientID.isEmpty && !clientID.hasPrefix("$(") }
    var gitHubCLIInstalled: Bool { Tools.gh() != nil }

    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    init(preferences: Preferences) {
        self.preferences = preferences
        tokens = TokenProvider(keychain: KeychainTokenStore(service: Bundle.main.bundleIdentifier ?? "dev.danielromero.SimPR"))
        tokens.allowGitHubCLI = preferences.useGitHubCLI
    }

    func refresh() async {
        tokens.allowGitHubCLI = preferences.useGitHubCLI
        let source: Source = tokens.keychain.read() != nil ? .simpr : .gitHubCLI
        guard await tokens.token() != nil else {
            state = .signedOut
            return
        }
        do {
            let viewer = try await GitHubClient(tokens: tokens).viewer()
            state = .signedIn(login: viewer.login, source: source, privateRepos: viewer.canReadPrivateRepos)
        } catch GitHubError.unauthorized {
            if source == .simpr { tokens.keychain.delete() }
            state = .failed(GitHubError.unauthorized.errorDescription ?? "Sign in again.")
        } catch {
            // Offline: keep the token, assume it still works.
            state = .signedIn(login: "GitHub", source: source, privateRepos: true)
        }
    }

    func signIn(scope: AuthScope) {
        flowTask?.cancel()
        state = .waitingForCode
        flowTask = Task {
            let flow = DeviceFlow(clientID: clientID)
            do {
                let code = try await flow.start(scope: scope)
                state = .enterCode(code)
                let token = try await flow.waitForToken(code)
                tokens.keychain.save(token)
                await refresh()
            } catch is CancellationError {
                return
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func copyCodeAndOpenGitHub(_ code: DeviceCode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code.userCode, forType: .string)
        NSWorkspace.shared.open(code.verificationURI)
    }

    func cancelSignIn() {
        flowTask?.cancel()
        flowTask = nil
        Task { await refresh() }
    }

    func useGitHubCLI() {
        preferences.useGitHubCLI = true
        Task { await refresh() }
    }

    func signOut() {
        flowTask?.cancel()
        tokens.keychain.delete()
        // Signing out also stops borrowing the GitHub CLI's token.
        preferences.useGitHubCLI = false
        tokens.allowGitHubCLI = false
        state = .signedOut
    }
}
