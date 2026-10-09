import AppKit
import Foundation
import Observation
import SimPRCore
import UserNotifications

/// What the run panel shows.
struct RunState: Equatable {
    enum Phase: Equatable {
        case working(RunStage)
        case chooseDevice(record: BuildRecord, candidates: [SimTarget], suggested: SimTarget?)
        case failed(String)
        case finished(String)
    }

    var title: String
    var subtitle: String
    var phase: Phase
    /// Link to re-run the workflow, for expired builds.
    var rebuildURL: URL?
}

@MainActor
@Observable
final class AppModel {
    let preferences: Preferences
    let auth: AuthModel
    let library: BuildLibrary

    private(set) var records: [BuildRecord] = []
    private(set) var recent: [BuildRecord] = []
    private(set) var totalSize: Int64 = 0
    private(set) var targets: [SimTarget] = []
    private(set) var xcodes: [XcodeLocator.Xcode] = XcodeLocator.installedXcodes()
    /// The Xcode actually in use (the preference, or the automatic choice).
    private(set) var activeDeveloperDir: String?
    private(set) var simulatorError: String?
    var runState: RunState?

    private var runTask: Task<Void, Never>?
    private var lastPRRefresh: Date?

    init(preferences: Preferences = Preferences(), library: BuildLibrary = BuildLibrary()) {
        self.preferences = preferences
        self.library = library
        auth = AuthModel(preferences: preferences)
        Task {
            await reloadLibrary()
            await refreshSimulators()
            await auth.refresh()
        }
    }

    // MARK: Dependencies

    private func simulator() async -> Simctl {
        Simctl(developerDir: await XcodeLocator.developerDir(preferred: preferences.developerDir))
    }

    private func pipeline() async -> RunPipeline {
        let limit = preferences.libraryLimitBytes
        return RunPipeline(library: library, github: GitHubClient(tokens: auth.tokens), simulator: await simulator(),
                           libraryLimitBytes: { limit })
    }

    // MARK: Library

    func reloadLibrary() async {
        records = await library.all()
        recent = await library.recent(5)
        totalSize = await library.totalSize()
    }

    var activeXcode: XcodeLocator.Xcode? {
        xcodes.first { $0.developerDir == activeDeveloperDir }
    }

    /// Switches Xcode (empty means automatic) and reloads its simulators.
    func selectXcode(_ developerDir: String) async {
        preferences.developerDir = developerDir
        await refreshSimulators()
    }

    func refreshSimulators() async {
        xcodes = XcodeLocator.installedXcodes()
        activeDeveloperDir = await XcodeLocator.developerDir(preferred: preferences.developerDir)
        let sim = await simulator()
        do {
            targets = SimctlParser.iOSTargets(devices: try await sim.devices(), runtimes: try await sim.runtimes())
            simulatorError = targets.isEmpty ? SimulatorError.noDevices.errorDescription : nil
        } catch {
            targets = []
            simulatorError = error.localizedDescription
        }
    }

    var preferredTarget: SimTarget? {
        targets.first { $0.device.udid == preferences.preferredDeviceUDID }
    }

    /// Refreshes PR titles and states (merged/closed) at most once an hour. Best effort.
    func refreshPRStates(force: Bool = false) async {
        if !force, let last = lastPRRefresh, Date().timeIntervalSince(last) < 3600 { return }
        guard auth.isSignedIn else { return }
        lastPRRefresh = Date()
        let github = GitHubClient(tokens: auth.tokens)
        let pulls = Set(records.filter { $0.prState == .open || $0.prState == .unknown }
            .compactMap { r in r.prNumber.map { PullKey(repo: r.repo, number: $0) } })
        for key in pulls {
            guard let pull = try? await github.pullRequest(key.repo, number: key.number) else { continue }
            try? await library.updatePR(repo: key.repo, number: key.number, title: pull.title, state: pull.prState)
        }
        await reloadLibrary()
    }

    private struct PullKey: Hashable {
        var repo: RepoID
        var number: Int
    }

    func setPinned(_ record: BuildRecord, _ pinned: Bool) {
        Task {
            try? await library.setPinned(record.id, pinned)
            await reloadLibrary()
        }
    }

    func delete(_ record: BuildRecord) {
        Task {
            try? await library.delete(record.id)
            await reloadLibrary()
        }
    }

    func deleteMergedAndClosed() {
        Task {
            await refreshPRStates(force: true)
            _ = try? await library.deleteMergedAndClosed()
            await reloadLibrary()
        }
    }

    func deleteAllUnpinned() {
        Task {
            _ = try? await library.deleteAllUnpinned()
            await reloadLibrary()
        }
    }

    func enforceLibraryLimit() {
        Task {
            _ = try? await library.evict(limitBytes: preferences.libraryLimitBytes)
            await reloadLibrary()
        }
    }

    func reveal(_ record: BuildRecord) {
        Task {
            guard let app = try? await library.appURL(for: record) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([app])
        }
    }

    func openPR(_ record: BuildRecord) {
        if let url = record.pullURL { NSWorkspace.shared.open(url) }
    }

    func revealLibraryFolder() {
        let dir = library.root.appendingPathComponent("Builds", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    /// Imports a build zip downloaded by hand (the no-app path) into the library.
    func importBuild(from zip: URL) {
        Task {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("SimPR-import-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: work) }
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let extracted = try await BuildExtractor().extract(zip: zip, into: work)
                let record = try await library.add(extractedFolder: extracted.folder, manifest: extracted.manifest,
                                                   details: BuildDetails(prNumber: extracted.manifest.prNumber))
                try await library.evict(limitBytes: preferences.libraryLimitBytes, protecting: [record.id])
                await reloadLibrary()
                Task { await refreshPRStates(force: true) }
            } catch {
                showError(title: "Couldn't import the build", message: error.localizedDescription)
            }
        }
    }

    // MARK: Running

    /// Entry point for simpr:// links.
    func handle(url: URL) {
        let request: RunRequest
        do {
            request = try RunRequest.parse(url)
        } catch {
            showError(title: "Can't open this link", message: error.localizedDescription)
            return
        }
        guard confirmTrust(request.repo) else { return }
        start(title: request.appName ?? request.repo.fullName,
              subtitle: "\(request.repo.fullName) #\(request.pr) · \(request.shortSHA)",
              rebuildURL: URL(string: "https://github.com/\(request.repo.fullName)/actions/runs/\(request.runID)")) { pipeline, options, progress in
            try await pipeline.run(request, options: options, progress: progress)
        }
    }

    func run(_ record: BuildRecord, deviceUDID: String? = nil) {
        start(title: record.appName, subtitle: subtitle(for: record), rebuildURL: nil, deviceUDID: deviceUDID) { pipeline, options, progress in
            try await pipeline.runStored(record, options: options, progress: progress)
        }
    }

    /// Continues after the user picked a simulator in the run panel.
    func choose(_ target: SimTarget, for record: BuildRecord, remember: Bool) {
        if remember { preferences.preferredDeviceUDID = target.device.udid }
        run(record, deviceUDID: target.device.udid)
    }

    func cancelRun() {
        runTask?.cancel()
        runTask = nil
        runState = nil
    }

    private func subtitle(for record: BuildRecord) -> String {
        "\(record.repo.fullName)\(record.prNumber.map { " #\($0)" } ?? "") · \(record.shortSHA)"
    }

    private typealias RunBody = @Sendable (RunPipeline, RunOptions, @escaping @Sendable (RunStage) -> Void) async throws -> RunOutcome
    private var lastRun: (title: String, subtitle: String, rebuildURL: URL?, body: RunBody)?

    /// Re-runs the current build after switching Xcode from the run panel.
    func switchXcodeAndRetry(_ developerDir: String) {
        Task {
            await selectXcode(developerDir)
            guard let last = lastRun else { return }
            start(title: last.title, subtitle: last.subtitle, rebuildURL: last.rebuildURL, last.body)
        }
    }

    private func start(title: String, subtitle: String, rebuildURL: URL?, deviceUDID: String? = nil,
                       _ body: @escaping RunBody) {
        runTask?.cancel()
        lastRun = (title, subtitle, rebuildURL, body)
        runState = RunState(title: title, subtitle: subtitle, phase: .working(.checkingBuild), rebuildURL: rebuildURL)
        let options = RunOptions(deviceUDID: deviceUDID, preferredUDID: preferences.preferredDeviceUDID, resetAppData: preferences.resetAppData)
        runTask = Task {
            let pipeline = await pipeline()
            do {
                let outcome = try await body(pipeline, options) { stage in
                    Task { @MainActor in
                        if case .working = self.runState?.phase { self.runState?.phase = .working(stage) }
                    }
                }
                runState?.phase = .finished("Running on \(outcome.target.displayName)")
                notify(title: "\(outcome.record.appName) is running", body: "\(subtitle) on \(outcome.target.device.name)")
                await reloadLibrary()
                try? await Task.sleep(for: .seconds(4))
                if case .finished = runState?.phase { runState = nil }
            } catch is CancellationError {
                return
            } catch RunError.needsDevice(let record, let candidates, let suggested) {
                await reloadLibrary()
                if candidates.isEmpty {
                    runState?.phase = .failed("No installed simulator can run this build (it needs iOS \(record.minimumOSVersion) or later).")
                } else {
                    runState?.phase = .chooseDevice(record: record, candidates: candidates, suggested: suggested)
                }
            } catch {
                await reloadLibrary()
                let message = error.localizedDescription
                runState?.phase = .failed(message)
                if let github = error as? GitHubError, case .expired = github {} else { runState?.rebuildURL = nil }
                notify(title: "Couldn't run \(title)", body: message)
            }
        }
    }

    // MARK: Trust and alerts

    /// Asks before running builds from a repository the user hasn't trusted yet.
    private func confirmTrust(_ repo: RepoID) -> Bool {
        if preferences.allowlist.contains(repo) { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Run build from \(repo.fullName)?"
        alert.informativeText = "SimPR will download this pull request's simulator build from GitHub and install it in iOS Simulator. "
            + "Only run builds from repositories you trust."
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Always allow builds from \(repo.fullName)"
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if alert.suppressionButton?.state == .on { preferences.allowlist.add(repo) }
        return true
    }

    private func showError(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func notify(title: String, body: String) {
        guard preferences.notifyWhenDone, Bundle.main.bundleIdentifier != nil else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
