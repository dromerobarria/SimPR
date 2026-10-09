import Foundation
import Testing
@testable import SimPRCore

@Suite("Run pipeline")
struct PipelineTests {
    /// Zips a fake build the way the action does (folder kept at the root).
    static func makeZip(_ manifest: BuildManifest) async throws -> URL {
        let dir = Fixture.tempDir()
        let folder = try Fixture.extractedBuild(manifest, in: dir)
        let zip = dir.appendingPathComponent("build.zip")
        _ = try await ProcessRunner().check(Tools.ditto, ["-c", "-k", "--keepParent", folder.path, zip.path])
        return zip
    }

    final class Stages: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [RunStage] = []
        var all: [RunStage] { lock.withLock { _all } }
        func add(_ s: RunStage) { lock.withLock { _all.append(s) } }
    }

    func bootedUDID(_ sim: FakeSimulator) -> String {
        sim.deviceList.first { $0.isBooted }!.udid
    }

    @Test func downloadsInstallsAndLaunches() async throws {
        let sim = try FakeSimulator.standard()
        let github = FakeGitHub(zip: try await Self.makeZip(try Fixture.manifest()))
        let library = BuildLibrary(root: Fixture.tempDir())
        let pipeline = RunPipeline(library: library, github: github, simulator: sim, host: .arm64)
        let udid = bootedUDID(sim)
        let stages = Stages()

        let outcome = try await pipeline.run(Fixture.request(), options: RunOptions(preferredUDID: udid)) { stages.add($0) }

        #expect(!outcome.usedCache)
        #expect(outcome.target.device.udid == udid)
        #expect(sim.calls == ["open \(udid)", "install \(udid) SampleApp.app", "launch \(udid) dev.simpr.SampleApp"])
        #expect(outcome.record.prTitle == "Add onboarding")
        #expect(outcome.record.branch == "feature/onboarding")
        #expect(outcome.record.commitMessage?.hasPrefix("Add onboarding") == true)
        #expect(outcome.record.lastRunDate != nil)
        #expect(stages.all.contains(.extracting))
        #expect(stages.all.last == .done(outcome.target.device.name))
        #expect(await library.all().count == 1)
    }

    @Test func runningAStoredBuildNeverTouchesTheNetwork() async throws {
        let sim = try FakeSimulator.standard()
        let library = BuildLibrary(root: Fixture.tempDir())
        let online = FakeGitHub(zip: try await Self.makeZip(try Fixture.manifest()))
        let udid = bootedUDID(sim)
        _ = try await RunPipeline(library: library, github: online, simulator: sim, host: .arm64)
            .run(Fixture.request(), options: RunOptions(preferredUDID: udid)) { _ in }

        let offline = FakeGitHub(zip: nil)
        let pipeline = RunPipeline(library: library, github: offline, simulator: sim, host: .arm64)
        let again = try await pipeline.run(Fixture.request(), options: RunOptions(preferredUDID: udid)) { _ in }
        #expect(again.usedCache)

        let stored = try #require(await library.all().first)
        _ = try await pipeline.runStored(stored, options: RunOptions(deviceUDID: udid)) { _ in }
        #expect(offline.calls.isEmpty, "no GitHub calls for stored builds")
    }

    @Test func bootsShutdownSimulatorsAndResetsData() async throws {
        let sim = try FakeSimulator.standard()
        let library = BuildLibrary(root: Fixture.tempDir())
        let pipeline = RunPipeline(library: library, github: FakeGitHub(zip: try await Self.makeZip(try Fixture.manifest())), simulator: sim, host: .arm64)
        let shutdown = sim.deviceList.first { !$0.isBooted && $0.isAvailable && $0.runtimeIdentifier.contains("iOS-27-0") }!

        _ = try await pipeline.run(Fixture.request(), options: RunOptions(deviceUDID: shutdown.udid, resetAppData: true)) { _ in }
        #expect(sim.calls == [
            "boot \(shutdown.udid)",
            "open \(shutdown.udid)",
            "uninstall \(shutdown.udid) dev.simpr.SampleApp",
            "install \(shutdown.udid) SampleApp.app",
            "launch \(shutdown.udid) dev.simpr.SampleApp",
        ])
    }

    @Test func asksForADeviceWhenNoneIsPreferred() async throws {
        let sim = try FakeSimulator.standard()
        let library = BuildLibrary(root: Fixture.tempDir())
        let pipeline = RunPipeline(library: library, github: FakeGitHub(zip: try await Self.makeZip(try Fixture.manifest())), simulator: sim, host: .arm64)
        do {
            _ = try await pipeline.run(Fixture.request(), options: RunOptions()) { _ in }
            Issue.record("expected needsDevice")
        } catch RunError.needsDevice(let record, let candidates, let suggested) {
            #expect(!candidates.isEmpty)
            #expect(suggested?.device.isBooted == true)
            #expect(record.commitSHA == Fixture.sha, "the build is already in the library")
        }
        #expect(sim.calls.isEmpty)
    }

    @Test func failsFastOnIncompatibleLinksBeforeDownloading() async throws {
        let sim = try FakeSimulator.standard()
        let github = FakeGitHub(zip: try await Self.makeZip(try Fixture.manifest()))
        let pipeline = RunPipeline(library: BuildLibrary(root: Fixture.tempDir()), github: github, simulator: sim, host: .arm64)
        var request = Fixture.request()
        request.minimumOSVersion = OSVersion("30.0")
        await #expect(throws: RunError.self) { _ = try await pipeline.run(request, options: RunOptions()) { _ in } }
        #expect(github.calls.isEmpty)
    }

    @Test func refusesABuildThatDoesNotMatchTheLink() async throws {
        let sim = try FakeSimulator.standard()
        let zip = try await Self.makeZip(try Fixture.manifest(sha: Fixture.sha("e")))
        let library = BuildLibrary(root: Fixture.tempDir())
        let pipeline = RunPipeline(library: library, github: FakeGitHub(zip: zip), simulator: sim, host: .arm64)
        await #expect(throws: ManifestError.mismatch("commit")) {
            _ = try await pipeline.run(Fixture.request(), options: RunOptions(preferredUDID: bootedUDID(sim))) { _ in }
        }
        #expect(await library.all().isEmpty)
        #expect(sim.calls.isEmpty)
    }

    @Test func explainsExpiredBuilds() async throws {
        let github = FakeGitHub(zip: try await Self.makeZip(try Fixture.manifest()))
        github.artifactExpired = true
        let pipeline = RunPipeline(library: BuildLibrary(root: Fixture.tempDir()), github: github, simulator: try FakeSimulator.standard(), host: .arm64)
        await #expect(throws: GitHubError.expired(repo: "octo/sample", runID: 555)) {
            _ = try await pipeline.run(Fixture.request(), options: RunOptions()) { _ in }
        }
        #expect(GitHubError.expired(repo: "octo/sample", runID: 555).errorDescription!.contains("Re-run the workflow"))
    }

    @Test func evictsOldBuildsButKeepsTheNewOne() async throws {
        let sim = try FakeSimulator.standard()
        let library = BuildLibrary(root: Fixture.tempDir())
        let old = try Fixture.manifest(sha: Fixture.sha("a"))
        try await library.add(extractedFolder: try Fixture.extractedBuild(old, in: Fixture.tempDir(), appBytes: 100_000), manifest: old, details: BuildDetails())
        let pipeline = RunPipeline(library: library, github: FakeGitHub(zip: try await Self.makeZip(try Fixture.manifest())),
                                   simulator: sim, host: .arm64, libraryLimitBytes: { 1 })
        _ = try await pipeline.run(Fixture.request(), options: RunOptions(preferredUDID: bootedUDID(sim))) { _ in }
        #expect(await library.all().map(\.commitSHA) == [Fixture.sha])
    }

    @Test func extractorUnwrapsADoubleZip() async throws {
        let inner = try await Self.makeZip(try Fixture.manifest())
        let outerDir = Fixture.tempDir()
        let outer = outerDir.appendingPathComponent("outer.zip")
        _ = try await ProcessRunner().check(Tools.ditto, ["-c", "-k", inner.path, outer.path])
        let extracted = try await BuildExtractor().extract(zip: outer, into: Fixture.tempDir())
        #expect(extracted.manifest.commitSha == Fixture.sha)
        #expect(extracted.folder.lastPathComponent == "Sample-App-PR42-0123456")
    }

    @Test func extractorRejectsZipsWithoutAManifest() async throws {
        let dir = Fixture.tempDir()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Thing/X.app"), withIntermediateDirectories: true)
        let zip = Fixture.tempDir().appendingPathComponent("x.zip")
        _ = try await ProcessRunner().check(Tools.ditto, ["-c", "-k", "--keepParent", dir.appendingPathComponent("Thing").path, zip.path])
        await #expect(throws: ManifestError.notFound) { _ = try await BuildExtractor().extract(zip: zip, into: Fixture.tempDir()) }
    }
}
