import Foundation

/// A parsed and validated `simpr://run?...` link.
public struct RunRequest: Equatable, Sendable {
    public var repo: RepoID
    public var pr: Int
    public var sha: String
    public var runID: Int64
    public var artifactID: Int64
    public var artifactName: String?
    public var appName: String?
    public var bundleID: String?
    public var folderName: String?
    public var appBundleName: String?
    public var minimumOSVersion: OSVersion?
    public var architectures: [Architecture]
    public var contentKey: String?
    public var sizeBytes: Int64?

    public var shortSHA: String { String(sha.prefix(7)) }

    public init(
        repo: RepoID, pr: Int, sha: String, runID: Int64, artifactID: Int64,
        artifactName: String? = nil, appName: String? = nil, bundleID: String? = nil,
        folderName: String? = nil, appBundleName: String? = nil, minimumOSVersion: OSVersion? = nil,
        architectures: [Architecture] = [], contentKey: String? = nil, sizeBytes: Int64? = nil
    ) {
        self.repo = repo
        self.pr = pr
        self.sha = sha
        self.runID = runID
        self.artifactID = artifactID
        self.artifactName = artifactName
        self.appName = appName
        self.bundleID = bundleID
        self.folderName = folderName
        self.appBundleName = appBundleName
        self.minimumOSVersion = minimumOSVersion
        self.architectures = architectures
        self.contentKey = contentKey
        self.sizeBytes = sizeBytes
    }
}

public enum RunRequestError: Error, Equatable, LocalizedError {
    case notSimPRLink
    case unsupportedAction(String)
    case unsupportedVersion(String)
    case missing(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .notSimPRLink: "This isn't a SimPR link."
        case .unsupportedAction(let a): "SimPR doesn't know how to “\(a)”. Update SimPR and try again."
        case .unsupportedVersion(let v): "This link needs a newer SimPR (link version \(v)). Update SimPR and try again."
        case .missing(let f): "The link is missing “\(f)”. Open it again from the pull request comment."
        case .invalid(let f): "The link has an invalid “\(f)”. Open it again from the pull request comment."
        }
    }
}

extension RunRequest {
    public static let scheme = "simpr"

    /// Parses `simpr://run?repo=…&pr=…&sha=…&run=…&artifact=…`.
    /// Every field is validated; unknown fields are ignored.
    public static func parse(_ url: URL) throws(RunRequestError) -> RunRequest {
        guard url.scheme?.lowercased() == scheme else { throw .notSimPRLink }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw .notSimPRLink }
        let action = (components.host ?? "").lowercased()
        guard action == "run" else { throw .unsupportedAction(action) }

        // Form decoding, like the page's URLSearchParams: "+" is a space and a literal plus is %2B.
        func formDecode(_ s: String) -> String? {
            s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        }
        var query: [String: String] = [:]
        for item in components.percentEncodedQueryItems ?? [] {
            guard let name = formDecode(item.name), query[name] == nil else { continue }
            guard let value = formDecode(item.value ?? "") else { throw .invalid(name) }
            query[name] = value
        }
        func value(_ name: String) -> String? {
            guard let v = query[name], !v.isEmpty else { return nil }
            return v
        }
        func required(_ name: String) throws(RunRequestError) -> String {
            guard let v = value(name) else { throw .missing(name) }
            return v
        }
        func positiveInt(_ name: String, _ raw: String) throws(RunRequestError) -> Int64 {
            guard raw.count <= 16, raw.allSatisfy({ $0.isASCII && $0.isNumber }), !raw.hasPrefix("0"),
                  let n = Int64(raw), n > 0 else { throw .invalid(name) }
            return n
        }

        if let v = value("v"), v != "1" { throw .unsupportedVersion(v) }

        guard let repo = RepoID(try required("repo")) else { throw .invalid("repo") }
        let pr = Int(try positiveInt("pr", try required("pr")))
        let sha = try required("sha")
        guard Validation.isFullSHA(sha) else { throw .invalid("sha") }
        let runID = try positiveInt("run", try required("run"))
        let artifactID = try positiveInt("artifact", try required("artifact"))

        var request = RunRequest(repo: repo, pr: pr, sha: sha, runID: runID, artifactID: artifactID)

        if let name = value("name") {
            guard Validation.isArtifactName(name), name.hasPrefix("simpr-pr-\(pr)-") else { throw .invalid("name") }
            request.artifactName = name
        }
        if let app = value("app") {
            guard app.count <= 100, !app.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw .invalid("app")
            }
            request.appName = app
        }
        if let bundle = value("bundle") {
            guard Validation.isBundleID(bundle) else { throw .invalid("bundle") }
            request.bundleID = bundle
        }
        if let folder = value("folder") {
            guard Validation.isSafeFolderName(folder) else { throw .invalid("folder") }
            request.folderName = folder
        }
        if let appFile = value("appfile") {
            guard Validation.isAppBundleName(appFile) else { throw .invalid("appfile") }
            request.appBundleName = appFile
        }
        if let minOS = value("minos") {
            guard let v = OSVersion(minOS) else { throw .invalid("minos") }
            request.minimumOSVersion = v
        }
        if let arch = value("arch") {
            var archs: [Architecture] = []
            for part in arch.split(separator: ",", omittingEmptySubsequences: false) {
                guard let a = Architecture(rawValue: String(part)) else { throw .invalid("arch") }
                if !archs.contains(a) { archs.append(a) }
            }
            request.architectures = archs
        }
        if let key = value("key") {
            guard Validation.isContentKey(key) else { throw .invalid("key") }
            request.contentKey = key
        }
        if let size = value("size") {
            request.sizeBytes = try positiveInt("size", size)
        }
        return request
    }

    /// The `simpr://` URL for this request (used for "copy link" and tests).
    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = "run"
        var items: [URLQueryItem] = [
            .init(name: "v", value: "1"),
            .init(name: "repo", value: repo.fullName),
            .init(name: "pr", value: String(pr)),
            .init(name: "sha", value: sha),
            .init(name: "run", value: String(runID)),
            .init(name: "artifact", value: String(artifactID)),
        ]
        if let artifactName { items.append(.init(name: "name", value: artifactName)) }
        if let appName { items.append(.init(name: "app", value: appName)) }
        if let bundleID { items.append(.init(name: "bundle", value: bundleID)) }
        if let folderName { items.append(.init(name: "folder", value: folderName)) }
        if let appBundleName { items.append(.init(name: "appfile", value: appBundleName)) }
        if let minimumOSVersion { items.append(.init(name: "minos", value: minimumOSVersion.description)) }
        if !architectures.isEmpty { items.append(.init(name: "arch", value: architectures.map(\.rawValue).joined(separator: ","))) }
        if let contentKey { items.append(.init(name: "key", value: contentKey)) }
        if let sizeBytes { items.append(.init(name: "size", value: String(sizeBytes))) }
        c.queryItems = items
        // URLComponents leaves "+" alone; encode it so form decoding reads it back as a plus.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }
}
