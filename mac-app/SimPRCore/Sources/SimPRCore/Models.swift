import Foundation

/// A GitHub repository, `owner/name`. Validated on creation.
public struct RepoID: Hashable, Sendable, Codable, CustomStringConvertible, Comparable {
    public let owner: String
    public let name: String

    public init?(_ fullName: String) {
        let parts = fullName.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let owner = String(parts[0])
        let name = String(parts[1])
        guard Validation.isOwner(owner), Validation.isRepoName(name) else { return nil }
        self.owner = owner
        self.name = name
    }

    public var fullName: String { "\(owner)/\(name)" }
    public var description: String { fullName }
    public var webURL: URL { URL(string: "https://github.com/\(fullName)")! }

    public func pullURL(_ number: Int) -> URL {
        URL(string: "https://github.com/\(fullName)/pull/\(number)")!
    }

    public static func < (lhs: RepoID, rhs: RepoID) -> Bool {
        lhs.fullName.lowercased() < rhs.fullName.lowercased()
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let repo = RepoID(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid repository \(raw)"))
        }
        self = repo
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(fullName)
    }
}

public enum Architecture: String, Codable, Sendable, CaseIterable {
    case arm64
    case x86_64

    public var displayName: String {
        switch self {
        case .arm64: "Apple silicon (arm64)"
        case .x86_64: "Intel (x86_64)"
        }
    }
}

/// A dotted numeric OS version such as `17.0` or `17.0.1`.
public struct OSVersion: Comparable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var values: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber), let n = Int(part) else { return nil }
            values.append(n)
        }
        components = values
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    private func padded(_ count: Int) -> [Int] {
        components + Array(repeating: 0, count: max(0, count - components.count))
    }

    public static func < (lhs: OSVersion, rhs: OSVersion) -> Bool {
        let n = max(lhs.components.count, rhs.components.count)
        return lhs.padded(n).lexicographicallyPrecedes(rhs.padded(n))
    }

    public static func == (lhs: OSVersion, rhs: OSVersion) -> Bool {
        let n = max(lhs.components.count, rhs.components.count)
        return lhs.padded(n) == rhs.padded(n)
    }

    public func hash(into hasher: inout Hasher) {
        var c = components
        while c.count > 1, c.last == 0 { c.removeLast() }
        hasher.combine(c)
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let v = OSVersion(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid version \(raw)"))
        }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// Shared validation rules. They match the action (manifest.mjs) and the redirect page (params.mjs).
public enum Validation {
    public static func isOwner(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$"#, options: .regularExpression) != nil
    }

    public static func isRepoName(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9._-]{1,100}$"#, options: .regularExpression) != nil && !s.hasPrefix(".")
    }

    public static func isFullSHA(_ s: String) -> Bool {
        s.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil
    }

    public static func isBundleID(_ s: String) -> Bool {
        s.count <= 255 && s.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil
    }

    public static func isContentKey(_ s: String) -> Bool {
        s.range(of: #"^[0-9a-f]{8,64}$"#, options: .regularExpression) != nil
    }

    /// A single path component that can't escape its directory.
    public static func isSafeFolderName(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9._-]{1,200}$"#, options: .regularExpression) != nil && !s.allSatisfy { $0 == "." }
    }

    public static func isAppBundleName(_ s: String) -> Bool {
        s.hasSuffix(".app") && s.count > 4 && s.count <= 200
            && !s.contains("/") && !s.contains("\\") && !s.contains("\0") && !s.contains("..")
    }

    public static func isArtifactName(_ s: String) -> Bool {
        s.range(of: #"^simpr-pr-\d+-[0-9a-f]{8,64}\.zip$"#, options: .regularExpression) != nil
    }
}
