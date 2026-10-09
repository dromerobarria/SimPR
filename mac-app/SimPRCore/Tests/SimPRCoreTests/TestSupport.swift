import Foundation
@testable import SimPRCore

enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    static let sha = "0123456789abcdef0123456789abcdef01234567"
    static let repo = RepoID("octo/sample")!

    static func manifest(sha: String = sha, minOS: String = "17.0", archs: [Architecture] = [.arm64, .x86_64]) throws -> BuildManifest {
        var m = try BuildManifest.decode(data("simpr.json"))
        m.commitSha = sha
        m.minimumOSVersion = OSVersion(minOS)!
        m.architectures = archs
        return m
    }

    static func request(sha: String = sha) -> RunRequest {
        RunRequest(repo: repo, pr: 42, sha: sha, runID: 555, artifactID: 1001,
                   artifactName: "simpr-pr-42-0123456789abcdef.zip", appName: "Sample App",
                   bundleID: "dev.simpr.SampleApp", folderName: "Sample-App-PR42-0123456",
                   appBundleName: "SampleApp.app", minimumOSVersion: OSVersion("17.0"),
                   architectures: [.arm64, .x86_64], contentKey: "0123456789abcdef")
    }

    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SimPRTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A folder like the one inside a build zip: Folder/SampleApp.app + Folder/simpr.json.
    static func extractedBuild(_ manifest: BuildManifest, in dir: URL, appBytes: Int = 1000) throws -> URL {
        let folder = dir.appendingPathComponent(manifest.folderName, isDirectory: true)
        let app = folder.appendingPathComponent(manifest.appBundleName, isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data(repeating: 7, count: appBytes).write(to: app.appendingPathComponent("SampleApp"))
        try manifest.encoded().write(to: folder.appendingPathComponent("simpr.json"))
        return folder
    }

    static func record(_ sha: String, downloaded: TimeInterval, size: Int64, pinned: Bool = false,
                       pr: Int? = 1, state: PRState = .open, repo: RepoID = repo) -> BuildRecord {
        BuildRecord(repo: repo, prNumber: pr, prTitle: "PR \(pr ?? 0)", branch: "feature/x", commitSHA: sha,
                    commitMessage: "Commit \(sha.prefix(4))", author: "octocat",
                    buildDate: Date(timeIntervalSince1970: downloaded), downloadDate: Date(timeIntervalSince1970: downloaded),
                    lastRunDate: nil, sizeBytes: size, minimumOSVersion: OSVersion("17.0")!, architectures: [.arm64],
                    prState: state, prStateCheckedAt: nil, pinned: pinned, bundleID: "dev.simpr.SampleApp",
                    appName: "Sample", appBundleName: "SampleApp.app", version: "1.0", buildNumber: "1",
                    contentKey: "0123456789abcdef", artifactID: nil, runID: nil)
    }

    static func sha(_ c: Character) -> String { String(repeating: c, count: 40) }
}

/// Records simulator calls; never runs anything.
final class FakeSimulator: SimulatorControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var runtimeList: [SimRuntime]
    var deviceList: [SimDevice]

    init(runtimes: [SimRuntime], devices: [SimDevice]) {
        runtimeList = runtimes
        deviceList = devices
    }

    var calls: [String] { lock.withLock { _calls } }
    private func record(_ s: String) { lock.withLock { _calls.append(s) } }

    func runtimes() async throws -> [SimRuntime] { runtimeList }
    func devices() async throws -> [SimDevice] { deviceList }
    func boot(_ udid: String) async throws { record("boot \(udid)") }
    func openSimulatorApp(focusing udid: String) async throws { record("open \(udid)") }
    func uninstall(_ udid: String, bundleID: String) async throws { record("uninstall \(udid) \(bundleID)") }
    func install(_ udid: String, app: URL) async throws { record("install \(udid) \(app.lastPathComponent)") }
    func launch(_ udid: String, bundleID: String) async throws { record("launch \(udid) \(bundleID)") }

    static func standard() throws -> FakeSimulator {
        FakeSimulator(runtimes: try SimctlParser.runtimes(Fixture.data("runtimes.json")),
                      devices: try SimctlParser.devices(Fixture.data("devices.json")))
    }
}

/// Serves a prepared zip, or fails every call when `zip` is nil.
final class FakeGitHub: ArtifactFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var zip: URL?
    var artifactExpired = false

    init(zip: URL?) { self.zip = zip }
    var calls: [String] { lock.withLock { _calls } }
    private func record(_ s: String) { lock.withLock { _calls.append(s) } }

    struct Offline: Error {}

    func artifact(_ repo: RepoID, id: Int64) async throws -> ArtifactInfo {
        record("artifact \(id)")
        guard zip != nil else { throw Offline() }
        return ArtifactInfo(id: id, name: "simpr-pr-42-0123456789abcdef.zip", sizeInBytes: 1000, expired: artifactExpired,
                            expiresAt: nil, workflowRun: .init(id: 555, headSha: Fixture.sha, headBranch: "feature/x"))
    }

    func downloadArtifact(_ repo: RepoID, id: Int64, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        record("download \(id)")
        guard let zip else { throw Offline() }
        try FileManager.default.copyItem(at: zip, to: destination)
        progress(1)
    }

    func pullRequest(_ repo: RepoID, number: Int) async throws -> PullRequestInfo {
        record("pull \(number)")
        return PullRequestInfo(number: number, title: "Add onboarding", state: "open", mergedAt: nil,
                               head: .init(ref: "feature/onboarding", sha: Fixture.sha), user: .init(login: "octocat"))
    }

    func commit(_ repo: RepoID, sha: String) async throws -> CommitInfo {
        record("commit \(sha.prefix(7))")
        return CommitInfo(sha: sha, commit: .init(message: "Add onboarding\n\nDetails", author: .init(name: "Octo Cat")), author: .init(login: "octocat"))
    }
}
