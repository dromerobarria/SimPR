import Foundation
import Testing
@testable import SimPRCore

@Suite("Build library")
struct LibraryTests {
    @Test func storesBuildsUnderOwnerRepoSha() async throws {
        let root = Fixture.tempDir()
        let library = BuildLibrary(root: root)
        let manifest = try Fixture.manifest()
        let folder = try Fixture.extractedBuild(manifest, in: Fixture.tempDir())
        try "junk".write(to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

        let record = try await library.add(extractedFolder: folder, manifest: manifest,
                                           details: BuildDetails(prTitle: "Add onboarding", branch: "feature/onboarding", prState: .open))
        let dir = root.appendingPathComponent("Builds/octo/sample/\(Fixture.sha)")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("SampleApp.app/SampleApp").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("simpr.json").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("README.txt").path))
        #expect(try await library.appURL(for: record) == dir.appendingPathComponent("SampleApp.app", isDirectory: true))
        #expect(record.prNumber == 42)
        #expect(record.prTitle == "Add onboarding")
        #expect(record.sizeBytes > 0)
        #expect(await library.record(repo: Fixture.repo, sha: Fixture.sha) == record)
    }

    @Test func persistsTheIndex() async throws {
        let root = Fixture.tempDir()
        let manifest = try Fixture.manifest()
        let added = try await BuildLibrary(root: root).add(extractedFolder: try Fixture.extractedBuild(manifest, in: Fixture.tempDir()),
                                                         manifest: manifest, details: BuildDetails())
        try await BuildLibrary(root: root).setPinned(added.id, true)
        let reloaded = BuildLibrary(root: root)
        #expect(await reloaded.all().count == 1)
        #expect(await reloaded.record(added.id)?.pinned == true)
    }

    @Test func reAddingACommitKeepsPinAndReplacesFiles() async throws {
        let library = BuildLibrary(root: Fixture.tempDir())
        let manifest = try Fixture.manifest()
        let first = try await library.add(extractedFolder: try Fixture.extractedBuild(manifest, in: Fixture.tempDir()), manifest: manifest, details: BuildDetails())
        try await library.setPinned(first.id, true)
        let second = try await library.add(extractedFolder: try Fixture.extractedBuild(manifest, in: Fixture.tempDir(), appBytes: 50_000),
                                           manifest: manifest, details: BuildDetails())
        #expect(second.pinned)
        #expect(second.sizeBytes > first.sizeBytes)
        #expect(await library.all().count == 1)
    }

    @Test func deletesFilesAndEmptyFolders() async throws {
        let root = Fixture.tempDir()
        let library = BuildLibrary(root: root)
        let manifest = try Fixture.manifest()
        let r = try await library.add(extractedFolder: try Fixture.extractedBuild(manifest, in: Fixture.tempDir()), manifest: manifest, details: BuildDetails())
        try await library.delete(r.id)
        #expect(await library.all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Builds/octo").path))
    }

    @Test func refusesMissingApps() async throws {
        let library = BuildLibrary(root: Fixture.tempDir())
        var manifest = try Fixture.manifest()
        let folder = try Fixture.extractedBuild(manifest, in: Fixture.tempDir())
        manifest.appBundleName = "Other.app"
        await #expect(throws: LibraryError.appMissing("Other.app")) {
            try await library.add(extractedFolder: folder, manifest: manifest, details: BuildDetails())
        }
    }

    @Test func bulkDeletesRespectPins() async throws {
        let library = BuildLibrary(root: Fixture.tempDir())
        var ids: [String: String] = [:]
        for (c, state, pinned) in [("a", PRState.merged, false), ("b", .closed, false), ("c", .open, false), ("d", .merged, true)] as [(Character, PRState, Bool)] {
            let m = try Fixture.manifest(sha: Fixture.sha(c))
            let r = try await library.add(extractedFolder: try Fixture.extractedBuild(m, in: Fixture.tempDir()), manifest: m, details: BuildDetails(prState: state))
            if pinned { try await library.setPinned(r.id, true) }
            ids[String(c)] = r.id
        }
        let removed = try await library.deleteMergedAndClosed()
        #expect(Set(removed.map(\.id)) == [ids["a"]!, ids["b"]!])
        let removedAll = try await library.deleteAllUnpinned()
        #expect(removedAll.map(\.id) == [ids["c"]!])
        #expect(await library.all().map(\.id) == [ids["d"]!])
    }

    @Test func updatesPRStateForAllItsBuilds() async throws {
        let library = BuildLibrary(root: Fixture.tempDir())
        for c in ["a", "b"] as [Character] {
            let m = try Fixture.manifest(sha: Fixture.sha(c))
            try await library.add(extractedFolder: try Fixture.extractedBuild(m, in: Fixture.tempDir()), manifest: m, details: BuildDetails(prState: .open))
        }
        try await library.updatePR(repo: Fixture.repo, number: 42, title: "Renamed", state: .merged)
        #expect(await library.all().allSatisfy { $0.prState == .merged && $0.prTitle == "Renamed" })
    }

    @Test func evictsThroughTheActor() async throws {
        let library = BuildLibrary(root: Fixture.tempDir())
        for c in ["a", "b", "c"] as [Character] {
            let m = try Fixture.manifest(sha: Fixture.sha(c))
            try await library.add(extractedFolder: try Fixture.extractedBuild(m, in: Fixture.tempDir(), appBytes: 100_000), manifest: m, details: BuildDetails())
            try await Task.sleep(for: .milliseconds(5))
        }
        let size = await library.all().first!.sizeBytes
        let evicted = try await library.evict(limitBytes: size * 2)
        #expect(evicted.map(\.commitSHA) == [Fixture.sha("a")], "oldest download goes first")
        #expect(await library.all().count == 2)
    }
}

@Suite("Eviction policy")
struct EvictionPolicyTests {
    @Test func doesNothingUnderTheLimit() {
        let records = [Fixture.record(Fixture.sha("a"), downloaded: 1, size: 100)]
        #expect(EvictionPolicy.select(records, limitBytes: 100).isEmpty)
    }

    @Test func evictsOldestUnpinnedFirstUntilUnderTheLimit() {
        let records = [
            Fixture.record(Fixture.sha("c"), downloaded: 3, size: 100),
            Fixture.record(Fixture.sha("a"), downloaded: 1, size: 100, pinned: true),
            Fixture.record(Fixture.sha("b"), downloaded: 2, size: 100),
            Fixture.record(Fixture.sha("d"), downloaded: 4, size: 100),
        ]
        let evicted = EvictionPolicy.select(records, limitBytes: 250)
        #expect(evicted.map(\.commitSHA) == [Fixture.sha("b"), Fixture.sha("c")])
    }

    @Test func neverEvictsPinnedOrProtectedBuilds() {
        let records = [
            Fixture.record(Fixture.sha("a"), downloaded: 1, size: 1000, pinned: true),
            Fixture.record(Fixture.sha("b"), downloaded: 2, size: 1000),
        ]
        let protected: Set<String> = [records[1].id]
        #expect(EvictionPolicy.select(records, limitBytes: 10, protecting: protected).isEmpty)
    }
}

@Suite("Library search and grouping")
struct LibraryQueryTests {
    let records = [
        Fixture.record(Fixture.sha("a"), downloaded: 1, size: 1, pr: 12),
        Fixture.record(Fixture.sha("b"), downloaded: 2, size: 1, pr: 12),
        Fixture.record(Fixture.sha("c"), downloaded: 3, size: 1, pr: 7, state: .merged),
        Fixture.record(Fixture.sha("d"), downloaded: 4, size: 1, pr: 3, repo: RepoID("acme/app")!),
    ]

    @Test func searches() {
        #expect(records.filter { $0.matches("#12") }.count == 2)
        #expect(records.filter { $0.matches("12") }.count == 2)
        #expect(records.filter { $0.matches("acme") }.count == 1)
        #expect(records.filter { $0.matches("cccc") }.map(\.prNumber) == [7])
        #expect(records.filter { $0.matches("feature/x") }.count == 4)
        #expect(records.filter { $0.matches("  ") }.count == 4)
        #expect(records.filter { $0.matches("nothing-matches") }.isEmpty)
    }

    @Test func groupsByRepoThenPRNewestFirst() {
        let groups = LibraryGroup.group(records)
        #expect(groups.map(\.repo.fullName) == ["acme/app", "octo/sample"])
        let octo = groups[1]
        #expect(octo.pulls.map(\.number) == [7, 12])
        #expect(octo.pulls[1].builds.map(\.commitSHA) == [Fixture.sha("b"), Fixture.sha("a")])
        #expect(octo.pulls[0].state == .merged)
    }

    @Test func allowlistIsCaseInsensitive() {
        var list = RepoAllowlist(["Octo/Sample"])
        #expect(list.contains(RepoID("octo/sample")!))
        list.add(RepoID("acme/app")!)
        list.remove("OCTO/sample")
        #expect(list.sorted == ["acme/app"])
    }
}
