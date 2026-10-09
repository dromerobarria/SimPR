import Foundation

/// Unzips a downloaded build and finds its simpr.json.
public struct BuildExtractor: Sendable {
    let runner: any ProcessRunning

    public init(runner: any ProcessRunning = ProcessRunner()) {
        self.runner = runner
    }

    public struct Extracted: Sendable {
        /// Folder holding the .app and simpr.json.
        public var folder: URL
        public var manifest: BuildManifest
    }

    public func extract(zip: URL, into workDir: URL) async throws -> Extracted {
        let out = workDir.appendingPathComponent("unzipped", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // ditto keeps symlinks and permissions (the executable bit matters).
        _ = try await runner.check(Tools.ditto, ["-x", "-k", zip.path, out.path])

        // Tolerate a wrapping zip layer (artifact downloaded as a zip of our zip).
        let entries = try FileManager.default.contentsOfDirectory(atPath: out.path).filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }
        if entries.count == 1, entries[0].hasSuffix(".zip") {
            return try await extract(zip: out.appendingPathComponent(entries[0]), into: workDir.appendingPathComponent("inner", isDirectory: true))
        }
        return try Self.locate(in: out)
    }

    static func locate(in dir: URL) throws -> Extracted {
        let fm = FileManager.default
        var candidates = [dir]
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !name.hasSuffix(".app") && !name.hasPrefix(".") {
            var isDir: ObjCBool = false
            let url = dir.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { candidates.append(url) }
        }
        for folder in candidates {
            let manifestURL = folder.appendingPathComponent("simpr.json")
            guard fm.fileExists(atPath: manifestURL.path) else { continue }
            let manifest = try BuildManifest.decode(try Data(contentsOf: manifestURL))
            let app = folder.appendingPathComponent(manifest.appBundleName, isDirectory: true)
            let attributes = try? fm.attributesOfItem(atPath: app.path)
            guard attributes?[.type] as? FileAttributeType == .typeDirectory else {
                throw LibraryError.appMissing(manifest.appBundleName)
            }
            return Extracted(folder: folder, manifest: manifest)
        }
        throw ManifestError.notFound
    }
}

public enum RunStage: Equatable, Sendable {
    case checkingBuild
    case downloading(Double?)
    case extracting
    case checkingCompatibility
    case booting(String)
    case installing(String)
    case launching(String)
    case done(String)

    public var label: String {
        switch self {
        case .checkingBuild: "Checking build…"
        case .downloading(let p): p.map { "Downloading… \(Int($0 * 100))%" } ?? "Downloading…"
        case .extracting: "Unpacking…"
        case .checkingCompatibility: "Checking compatibility…"
        case .booting(let d): "Booting \(d)…"
        case .installing(let d): "Installing on \(d)…"
        case .launching(let d): "Launching on \(d)…"
        case .done(let d): "Running on \(d)"
        }
    }
}

public struct RunOptions: Sendable, Equatable {
    /// Simulator to use. Nil uses the preferred one or asks.
    public var deviceUDID: String?
    public var preferredUDID: String?
    /// Uninstall first, so the app starts with no data.
    public var resetAppData: Bool

    public init(deviceUDID: String? = nil, preferredUDID: String? = nil, resetAppData: Bool = false) {
        self.deviceUDID = deviceUDID
        self.preferredUDID = preferredUDID
        self.resetAppData = resetAppData
    }
}

public enum RunError: Error, LocalizedError, Equatable {
    case incompatible([CompatibilityIssue])
    /// No simulator was chosen yet: show a picker.
    case needsDevice(record: BuildRecord, candidates: [SimTarget], suggested: SimTarget?)
    case deviceUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .incompatible(let issues): issues.compactMap(\.errorDescription).joined(separator: "\n\n")
        case .needsDevice: "Choose a simulator."
        case .deviceUnavailable(let udid): "The simulator \(udid) isn't available anymore. Pick another one."
        }
    }
}

public struct RunOutcome: Equatable, Sendable {
    public var record: BuildRecord
    public var target: SimTarget
    public var usedCache: Bool
}

/// The whole "run this build" flow. UI-free so it can be tested with fakes.
public struct RunPipeline: Sendable {
    public let library: BuildLibrary
    public let github: any ArtifactFetching
    public let simulator: any SimulatorControlling
    public let extractor: BuildExtractor
    public let host: Architecture
    public let libraryLimitBytes: @Sendable () -> Int64

    public init(library: BuildLibrary, github: any ArtifactFetching, simulator: any SimulatorControlling,
                extractor: BuildExtractor = BuildExtractor(), host: Architecture = HostInfo.architecture,
                libraryLimitBytes: @escaping @Sendable () -> Int64 = { 5_000_000_000 }) {
        self.library = library
        self.github = github
        self.simulator = simulator
        self.extractor = extractor
        self.host = host
        self.libraryLimitBytes = libraryLimitBytes
    }

    /// Runs a build from a link: uses the library when the commit is already stored, otherwise downloads it.
    public func run(_ request: RunRequest, options: RunOptions, progress: @escaping @Sendable (RunStage) -> Void) async throws -> RunOutcome {
        progress(.checkingBuild)
        if let stored = await library.record(repo: request.repo, sha: request.sha),
           request.contentKey == nil || request.contentKey == stored.contentKey,
           (try? await library.appURL(for: stored)) != nil {
            let target = try await install(stored, options: options, progress: progress)
            return RunOutcome(record: await library.record(stored.id) ?? stored, target: target, usedCache: true)
        }

        // Fail fast on what the link already tells us, before downloading anything.
        if let minOS = request.minimumOSVersion, !request.architectures.isEmpty {
            let issues = Compatibility.check(minimumOS: minOS, architectures: request.architectures, host: host, runtimes: try await simulator.runtimes())
            if !issues.isEmpty { throw RunError.incompatible(issues) }
        }

        let record = try await download(request, progress: progress)
        let target = try await install(record, options: options, progress: progress)
        return RunOutcome(record: await library.record(record.id) ?? record, target: target, usedCache: false)
    }

    /// Runs a stored build. Never touches the network.
    public func runStored(_ record: BuildRecord, options: RunOptions, progress: @escaping @Sendable (RunStage) -> Void) async throws -> RunOutcome {
        let target = try await install(record, options: options, progress: progress)
        return RunOutcome(record: await library.record(record.id) ?? record, target: target, usedCache: true)
    }

    func download(_ request: RunRequest, progress: @escaping @Sendable (RunStage) -> Void) async throws -> BuildRecord {
        let artifact: ArtifactInfo
        do {
            artifact = try await github.artifact(request.repo, id: request.artifactID)
        } catch GitHubError.expired {
            throw GitHubError.expired(repo: request.repo.fullName, runID: request.runID)
        }
        if artifact.expired { throw GitHubError.expired(repo: request.repo.fullName, runID: request.runID) }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("SimPR-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        progress(.downloading(nil))
        let zip = work.appendingPathComponent("build.zip")
        do {
            try await github.downloadArtifact(request.repo, id: request.artifactID, to: zip) { fraction in
                progress(.downloading(fraction))
            }
        } catch GitHubError.expired {
            throw GitHubError.expired(repo: request.repo.fullName, runID: request.runID)
        }

        progress(.extracting)
        let extracted = try await extractor.extract(zip: zip, into: work)
        try extracted.manifest.verify(matches: request)

        // Best effort: the build runs even if these lookups fail.
        async let pull = try? github.pullRequest(request.repo, number: request.pr)
        async let commit = try? github.commit(request.repo, sha: request.sha)
        let (p, c) = await (pull, commit)
        let details = BuildDetails(
            prNumber: request.pr,
            prTitle: p?.title,
            branch: p?.head.ref ?? artifact.workflowRun?.headBranch,
            prState: p?.prState,
            commitMessage: c?.commit.message,
            author: c?.author?.login ?? c?.commit.author?.name ?? p?.user?.login,
            artifactID: request.artifactID,
            runID: request.runID
        )
        let record = try await library.add(extractedFolder: extracted.folder, manifest: extracted.manifest, details: details)
        try await library.evict(limitBytes: libraryLimitBytes(), protecting: [record.id])
        return record
    }

    func install(_ record: BuildRecord, options: RunOptions, progress: @escaping @Sendable (RunStage) -> Void) async throws -> SimTarget {
        progress(.checkingCompatibility)
        let app = try await library.appURL(for: record)
        let runtimes = try await simulator.runtimes()
        let issues = Compatibility.check(minimumOS: record.minimumOSVersion, architectures: record.architectures, host: host, runtimes: runtimes)
        if !issues.isEmpty { throw RunError.incompatible(issues) }

        let targets = SimctlParser.iOSTargets(devices: try await simulator.devices(), runtimes: runtimes)
        guard !targets.isEmpty else { throw SimulatorError.noDevices }
        let compatible = Compatibility.compatibleTargets(targets, minimumOS: record.minimumOSVersion, architectures: record.architectures, host: host)

        let target: SimTarget
        if let udid = options.deviceUDID {
            guard let chosen = targets.first(where: { $0.device.udid == udid }) else { throw RunError.deviceUnavailable(udid) }
            if let issue = Compatibility.check(target: chosen, minimumOS: record.minimumOSVersion, architectures: record.architectures, host: host) {
                throw RunError.incompatible([issue])
            }
            target = chosen
        } else if let automatic = Compatibility.automaticTarget(compatible, preferredUDID: options.preferredUDID) {
            target = automatic
        } else {
            throw RunError.needsDevice(record: record, candidates: compatible, suggested: Compatibility.suggestedTarget(compatible))
        }

        let name = target.device.name
        if !target.device.isBooted {
            progress(.booting(name))
            try await simulator.boot(target.device.udid)
        }
        try await simulator.openSimulatorApp(focusing: target.device.udid)
        progress(.installing(name))
        if options.resetAppData {
            try await simulator.uninstall(target.device.udid, bundleID: record.bundleID)
        }
        try await simulator.install(target.device.udid, app: app)
        progress(.launching(name))
        try await simulator.launch(target.device.udid, bundleID: record.bundleID)
        try await library.markRun(record.id)
        progress(.done(name))
        return target
    }
}

/// Repositories the user trusts to run builds from without asking.
public struct RepoAllowlist: Equatable, Sendable {
    public private(set) var repos: Set<String>

    public init(_ repos: [String] = []) {
        self.repos = Set(repos.map { $0.lowercased() })
    }

    public func contains(_ repo: RepoID) -> Bool {
        repos.contains(repo.fullName.lowercased())
    }

    public mutating func add(_ repo: RepoID) {
        repos.insert(repo.fullName.lowercased())
    }

    public mutating func remove(_ fullName: String) {
        repos.remove(fullName.lowercased())
    }

    public var sorted: [String] { repos.sorted() }
}
