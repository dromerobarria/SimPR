import Foundation
import Observation
import SimPRCore

/// User settings, stored in UserDefaults.
@MainActor
@Observable
final class Preferences {
    private let defaults: UserDefaults

    private enum Key {
        static let preferredDevice = "preferredDeviceUDID"
        static let resetAppData = "resetAppDataBeforeLaunch"
        static let allowlist = "trustedRepositories"
        static let libraryLimitGB = "libraryLimitGB"
        static let developerDir = "developerDir"
        static let useGitHubCLI = "useGitHubCLIToken"
        static let notify = "notifyWhenDone"
    }

    var preferredDeviceUDID: String? {
        didSet { defaults.set(preferredDeviceUDID, forKey: Key.preferredDevice) }
    }

    var resetAppData: Bool {
        didSet { defaults.set(resetAppData, forKey: Key.resetAppData) }
    }

    var allowlist: RepoAllowlist {
        didSet { defaults.set(allowlist.sorted, forKey: Key.allowlist) }
    }

    /// Library size limit in GB (default 5).
    var libraryLimitGB: Double {
        didSet { defaults.set(libraryLimitGB, forKey: Key.libraryLimitGB) }
    }

    /// DEVELOPER_DIR override. Empty uses xcode-select, or the newest Xcode in /Applications
    /// when xcode-select points at the Command Line Tools.
    var developerDir: String {
        didSet { defaults.set(developerDir, forKey: Key.developerDir) }
    }

    /// Fall back to `gh auth token` when not signed in with SimPR.
    var useGitHubCLI: Bool {
        didSet { defaults.set(useGitHubCLI, forKey: Key.useGitHubCLI) }
    }

    var notifyWhenDone: Bool {
        didSet { defaults.set(notifyWhenDone, forKey: Key.notify) }
    }

    var libraryLimitBytes: Int64 { Int64(libraryLimitGB * 1_000_000_000) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.libraryLimitGB: 5.0, Key.useGitHubCLI: true, Key.notify: true])
        preferredDeviceUDID = defaults.string(forKey: Key.preferredDevice)
        resetAppData = defaults.bool(forKey: Key.resetAppData)
        allowlist = RepoAllowlist(defaults.stringArray(forKey: Key.allowlist) ?? [])
        libraryLimitGB = max(0.5, defaults.double(forKey: Key.libraryLimitGB))
        developerDir = defaults.string(forKey: Key.developerDir) ?? ""
        useGitHubCLI = defaults.bool(forKey: Key.useGitHubCLI)
        notifyWhenDone = defaults.bool(forKey: Key.notify)
    }
}
