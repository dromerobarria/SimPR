import Foundation

public enum PRState: String, Codable, Sendable {
    case open, closed, merged, unknown
}

/// One build stored on disk, plus what SimPR knows about where it came from.
public struct BuildRecord: Codable, Equatable, Sendable, Identifiable, Hashable {
    /// `owner/repo/sha`: one stored build per commit.
    public var id: String { "\(repo.fullName)/\(commitSHA)" }

    public var repo: RepoID
    public var prNumber: Int?
    public var prTitle: String?
    public var branch: String?
    public var commitSHA: String
    public var commitMessage: String?
    public var author: String?
    public var buildDate: Date
    public var downloadDate: Date
    public var lastRunDate: Date?
    public var sizeBytes: Int64
    public var minimumOSVersion: OSVersion
    public var architectures: [Architecture]
    public var prState: PRState
    public var prStateCheckedAt: Date?
    public var pinned: Bool
    public var bundleID: String
    public var appName: String
    public var appBundleName: String
    public var version: String?
    public var buildNumber: String?
    public var contentKey: String
    public var artifactID: Int64?
    public var runID: Int64?

    public var shortSHA: String { String(commitSHA.prefix(7)) }
    public var commitTitle: String? { commitMessage?.split(separator: "\n", maxSplits: 1).first.map(String.init) }
    public var pullURL: URL? { prNumber.map { repo.pullURL($0) } }
}

public enum LibraryError: Error, LocalizedError, Equatable {
    case unsafePath
    case appMissing(String)
    case notFound

    public var errorDescription: String? {
        switch self {
        case .unsafePath: "Refusing to use a path outside the SimPR library."
        case .appMissing(let name): "\(name) is missing from the stored build. Delete it and download it again."
        case .notFound: "That build isn't in the library anymore."
        }
    }
}

/// Picks builds to delete when the library is over its size limit:
/// unpinned builds, oldest download first. Pinned and protected builds are never picked.
public enum EvictionPolicy {
    public static func select(_ records: [BuildRecord], limitBytes: Int64, protecting protected: Set<String> = []) -> [BuildRecord] {
        var total = records.reduce(Int64(0)) { $0 + $1.sizeBytes }
        guard total > limitBytes else { return [] }
        var evicted: [BuildRecord] = []
        for record in records.sorted(by: { $0.downloadDate < $1.downloadDate }) {
            guard total > limitBytes else { break }
            if record.pinned || protected.contains(record.id) { continue }
            evicted.append(record)
            total -= record.sizeBytes
        }
        return evicted
    }
}

/// Library grouping for the UI: repo → PR → builds (newest first).
public struct LibraryGroup: Identifiable, Equatable, Sendable {
    public struct PullGroup: Identifiable, Equatable, Sendable {
        public var number: Int?
        public var title: String?
        public var state: PRState
        public var builds: [BuildRecord]
        public var id: String { number.map(String.init) ?? "no-pr" }
    }

    public var repo: RepoID
    public var pulls: [PullGroup]
    public var id: String { repo.fullName }

    public static func group(_ records: [BuildRecord]) -> [LibraryGroup] {
        Dictionary(grouping: records, by: \.repo)
            .map { repo, builds in
                let pulls = Dictionary(grouping: builds, by: \.prNumber).map { number, builds in
                    let sorted = builds.sorted { $0.buildDate > $1.buildDate }
                    return PullGroup(number: number, title: sorted.first?.prTitle, state: sorted.first?.prState ?? .unknown, builds: sorted)
                }
                .sorted { ($0.builds.first?.buildDate ?? .distantPast) > ($1.builds.first?.buildDate ?? .distantPast) }
                return LibraryGroup(repo: repo, pulls: pulls)
            }
            .sorted { $0.repo < $1.repo }
    }
}

extension BuildRecord {
    /// Matches repo, `#123` or `123` (PR), branch, SHA prefix, title or app name.
    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        if q.hasPrefix("#"), let n = Int(q.dropFirst()) { return prNumber == n }
        if let n = Int(q), prNumber == n { return true }
        let fields = [repo.fullName, branch, commitSHA, prTitle, appName, commitMessage, author].compactMap { $0?.lowercased() }
        return fields.contains { $0.contains(q) } || commitSHA.hasPrefix(q)
    }
}

/// The local build library:
/// `~/Library/Application Support/SimPR/Builds/<owner>/<repo>/<sha>/` holds the .app and simpr.json,
/// and `library.json` indexes them. Running a stored build never touches the network.
public actor BuildLibrary {
    public let root: URL
    private let buildsDir: URL
    private let indexURL: URL
    private var records: [String: BuildRecord] = [:]
    private let fileManager = FileManager.default

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SimPR", isDirectory: true)
    }

    public init(root: URL = BuildLibrary.defaultRoot) {
        self.root = root
        buildsDir = root.appendingPathComponent("Builds", isDirectory: true)
        indexURL = root.appendingPathComponent("library.json")
        if let data = try? Data(contentsOf: indexURL), let list = try? Self.decoder.decode([BuildRecord].self, from: data) {
            records = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Queries

    public func all() -> [BuildRecord] {
        records.values.sorted { $0.downloadDate > $1.downloadDate }
    }

    public func record(_ id: String) -> BuildRecord? { records[id] }

    public func record(repo: RepoID, sha: String) -> BuildRecord? {
        records["\(repo.fullName)/\(sha)"]
    }

    /// Recently run builds, for the menu.
    public func recent(_ limit: Int = 5) -> [BuildRecord] {
        records.values
            .sorted { ($0.lastRunDate ?? $0.downloadDate) > ($1.lastRunDate ?? $1.downloadDate) }
            .prefix(limit)
            .map { $0 }
    }

    public func totalSize() -> Int64 {
        records.values.reduce(0) { $0 + $1.sizeBytes }
    }

    public func directory(for record: BuildRecord) throws -> URL {
        try directory(repo: record.repo, sha: record.commitSHA)
    }

    public func appURL(for record: BuildRecord) throws -> URL {
        let url = try directory(for: record).appendingPathComponent(record.appBundleName, isDirectory: true)
        guard fileManager.fileExists(atPath: url.path) else { throw LibraryError.appMissing(record.appBundleName) }
        return url
    }

    // MARK: Changes

    /// Moves an extracted build (a folder with the .app and simpr.json) into the library.
    @discardableResult
    public func add(extractedFolder: URL, manifest: BuildManifest, details: BuildDetails, now: Date = Date()) throws -> BuildRecord {
        let dir = try directory(repo: manifest.repository, sha: manifest.commitSha)
        let app = extractedFolder.appendingPathComponent(manifest.appBundleName, isDirectory: true)
        guard fileManager.fileExists(atPath: app.path) else { throw LibraryError.appMissing(manifest.appBundleName) }

        try? fileManager.removeItem(at: dir)
        try fileManager.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: extractedFolder, to: dir)
        // Keep exactly the .app and simpr.json.
        for item in (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? [] where item != manifest.appBundleName && item != "simpr.json" {
            try? fileManager.removeItem(at: dir.appendingPathComponent(item))
        }
        try manifest.encoded().write(to: dir.appendingPathComponent("simpr.json"))

        let existing = records["\(manifest.repository.fullName)/\(manifest.commitSha)"]
        let record = BuildRecord(
            repo: manifest.repository,
            prNumber: manifest.prNumber ?? details.prNumber,
            prTitle: details.prTitle,
            branch: details.branch,
            commitSHA: manifest.commitSha,
            commitMessage: details.commitMessage,
            author: details.author,
            buildDate: manifest.buildDate,
            downloadDate: now,
            lastRunDate: existing?.lastRunDate,
            sizeBytes: Self.allocatedSize(of: dir),
            minimumOSVersion: manifest.minimumOSVersion,
            architectures: manifest.architectures,
            prState: details.prState ?? .unknown,
            prStateCheckedAt: details.prState == nil ? nil : now,
            pinned: existing?.pinned ?? false,
            bundleID: manifest.bundleId,
            appName: manifest.appName,
            appBundleName: manifest.appBundleName,
            version: manifest.version,
            buildNumber: manifest.buildNumber,
            contentKey: manifest.contentKey,
            artifactID: details.artifactID,
            runID: details.runID
        )
        records[record.id] = record
        try save()
        return record
    }

    public func markRun(_ id: String, at date: Date = Date()) throws {
        guard var r = records[id] else { throw LibraryError.notFound }
        r.lastRunDate = date
        records[id] = r
        try save()
    }

    public func setPinned(_ id: String, _ pinned: Bool) throws {
        guard var r = records[id] else { throw LibraryError.notFound }
        r.pinned = pinned
        records[id] = r
        try save()
    }

    public func updatePR(repo: RepoID, number: Int, title: String?, state: PRState, at date: Date = Date()) throws {
        var changed = false
        for (id, var r) in records where r.repo == repo && r.prNumber == number {
            r.prState = state
            r.prStateCheckedAt = date
            if let title { r.prTitle = title }
            records[id] = r
            changed = true
        }
        if changed { try save() }
    }

    public func delete(_ id: String) throws {
        guard let r = records[id] else { return }
        let dir = try directory(for: r)
        try? fileManager.removeItem(at: dir)
        // Tidy empty parent folders (repo, then owner).
        for parent in [dir.deletingLastPathComponent(), dir.deletingLastPathComponent().deletingLastPathComponent()] {
            if (try? fileManager.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
                try? fileManager.removeItem(at: parent)
            }
        }
        records[id] = nil
        try save()
    }

    /// Deletes unpinned builds, oldest first, until the library fits. Returns what was deleted.
    @discardableResult
    public func evict(limitBytes: Int64, protecting: Set<String> = []) throws -> [BuildRecord] {
        let doomed = EvictionPolicy.select(Array(records.values), limitBytes: limitBytes, protecting: protecting)
        for r in doomed { try delete(r.id) }
        return doomed
    }

    @discardableResult
    public func deleteMergedAndClosed() throws -> [BuildRecord] {
        let doomed = records.values.filter { ($0.prState == .merged || $0.prState == .closed) && !$0.pinned }
        for r in doomed { try delete(r.id) }
        return doomed
    }

    @discardableResult
    public func deleteAllUnpinned() throws -> [BuildRecord] {
        let doomed = records.values.filter { !$0.pinned }
        for r in doomed { try delete(r.id) }
        return doomed
    }

    // MARK: Internals

    private func directory(repo: RepoID, sha: String) throws -> URL {
        guard Validation.isFullSHA(sha) else { throw LibraryError.unsafePath }
        let dir = buildsDir
            .appendingPathComponent(repo.owner, isDirectory: true)
            .appendingPathComponent(repo.name, isDirectory: true)
            .appendingPathComponent(sha, isDirectory: true)
            .standardizedFileURL
        guard dir.path.hasPrefix(buildsDir.standardizedFileURL.path + "/") else { throw LibraryError.unsafePath }
        return dir
    }

    private func save() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(records.values.sorted { $0.id < $1.id })
        try data.write(to: indexURL, options: .atomic)
    }

    static func allocatedSize(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}

/// Facts about a build that come from GitHub rather than from simpr.json.
public struct BuildDetails: Equatable, Sendable {
    public var prNumber: Int?
    public var prTitle: String?
    public var branch: String?
    public var prState: PRState?
    public var commitMessage: String?
    public var author: String?
    public var artifactID: Int64?
    public var runID: Int64?

    public init(prNumber: Int? = nil, prTitle: String? = nil, branch: String? = nil, prState: PRState? = nil,
                commitMessage: String? = nil, author: String? = nil, artifactID: Int64? = nil, runID: Int64? = nil) {
        self.prNumber = prNumber
        self.prTitle = prTitle
        self.branch = branch
        self.prState = prState
        self.commitMessage = commitMessage
        self.author = author
        self.artifactID = artifactID
        self.runID = runID
    }
}
