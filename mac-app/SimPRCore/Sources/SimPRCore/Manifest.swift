import Foundation

/// `simpr.json`, written by the action next to the .app inside every build zip.
/// Schema: action/src/lib/manifest.mjs.
public struct BuildManifest: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public var schemaVersion: Int
    public var bundleId: String
    public var appName: String
    public var appBundleName: String
    public var folderName: String
    public var version: String?
    public var buildNumber: String?
    public var minimumOSVersion: OSVersion
    public var architectures: [Architecture]
    public var xcodeVersion: String?
    public var xcodeBuild: String?
    public var sdkVersion: String?
    public var configuration: String?
    public var scheme: String?
    public var repository: RepoID
    public var prNumber: Int?
    public var commitSha: String
    public var contentKey: String
    public var buildDate: Date
    public var appSizeBytes: Int64?

    public static func decode(_ data: Data) throws -> BuildManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601.parse(raw) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid date \(raw)"))
        }
        let manifest = try decoder.decode(BuildManifest.self, from: data)
        try manifest.validate()
        return manifest
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601.format(date))
        }
        return try encoder.encode(self)
    }

    public func validate() throws(ManifestError) {
        guard schemaVersion == Self.supportedSchemaVersion else { throw .unsupportedSchema(schemaVersion) }
        guard Validation.isBundleID(bundleId) else { throw .invalid("bundleId") }
        guard Validation.isAppBundleName(appBundleName) else { throw .invalid("appBundleName") }
        guard Validation.isSafeFolderName(folderName) else { throw .invalid("folderName") }
        guard Validation.isFullSHA(commitSha) else { throw .invalid("commitSha") }
        guard Validation.isContentKey(contentKey) else { throw .invalid("contentKey") }
        guard !architectures.isEmpty else { throw .invalid("architectures") }
        guard !appName.isEmpty, appName.count <= 200 else { throw .invalid("appName") }
        if let prNumber, prNumber <= 0 { throw .invalid("prNumber") }
    }

    /// Checks that a downloaded build is the one the link asked for.
    public func verify(matches request: RunRequest) throws(ManifestError) {
        guard repository == request.repo else { throw .mismatch("repository") }
        guard commitSha == request.sha else { throw .mismatch("commit") }
        if let pr = prNumber, pr != request.pr { throw .mismatch("pull request") }
        if let bundle = request.bundleID, bundle != bundleId { throw .mismatch("bundle identifier") }
        if let key = request.contentKey, key != contentKey { throw .mismatch("content key") }
    }
}

public enum ManifestError: Error, Equatable, LocalizedError {
    case notFound
    case unsupportedSchema(Int)
    case invalid(String)
    case mismatch(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: "The download doesn't contain a SimPR build (simpr.json is missing)."
        case .unsupportedSchema(let v): "This build was made by a newer SimPR action (manifest version \(v)). Update the SimPR app."
        case .invalid(let f): "The build's simpr.json has an invalid “\(f)”."
        case .mismatch(let f): "The downloaded build doesn't match the link (different \(f)). Refusing to install it."
        }
    }
}

enum ISO8601 {
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let lock = NSLock()

    static func parse(_ s: String) -> Date? {
        lock.withLock { withFraction.date(from: s) ?? plain.date(from: s) }
    }

    static func format(_ d: Date) -> String {
        lock.withLock { withFraction.string(from: d) }
    }
}
