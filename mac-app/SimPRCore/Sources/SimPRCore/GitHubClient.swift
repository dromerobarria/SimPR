import Foundation

public struct ArtifactInfo: Decodable, Equatable, Sendable {
    public struct WorkflowRun: Decodable, Equatable, Sendable {
        public var id: Int64?
        public var headSha: String?
        public var headBranch: String?

        enum CodingKeys: String, CodingKey {
            case id
            case headSha = "head_sha"
            case headBranch = "head_branch"
        }
    }

    public var id: Int64
    public var name: String
    public var sizeInBytes: Int64
    public var expired: Bool
    public var expiresAt: Date?
    public var workflowRun: WorkflowRun?

    enum CodingKeys: String, CodingKey {
        case id, name, expired
        case sizeInBytes = "size_in_bytes"
        case expiresAt = "expires_at"
        case workflowRun = "workflow_run"
    }
}

public struct PullRequestInfo: Decodable, Equatable, Sendable {
    public struct Ref: Decodable, Equatable, Sendable {
        public var ref: String
        public var sha: String
    }

    public struct User: Decodable, Equatable, Sendable {
        public var login: String
    }

    public var number: Int
    public var title: String
    public var state: String
    public var mergedAt: Date?
    public var head: Ref
    public var user: User?

    enum CodingKeys: String, CodingKey {
        case number, title, state, head, user
        case mergedAt = "merged_at"
    }

    public var prState: PRState {
        if mergedAt != nil { return .merged }
        return state == "open" ? .open : .closed
    }
}

public struct CommitInfo: Decodable, Equatable, Sendable {
    public struct Inner: Decodable, Equatable, Sendable {
        public struct Person: Decodable, Equatable, Sendable {
            public var name: String?
        }

        public var message: String
        public var author: Person?
    }

    public struct User: Decodable, Equatable, Sendable {
        public var login: String
    }

    public var sha: String
    public var commit: Inner
    public var author: User?
}

public enum GitHubError: Error, LocalizedError, Equatable {
    case notSignedIn
    case unauthorized
    case notFound(repo: String)
    case forbidden(String)
    case expired(repo: String, runID: Int64)
    case rateLimited(resetAt: Date?)
    case http(Int, String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            "Sign in to GitHub to download builds. GitHub requires it even for public repositories."
        case .unauthorized:
            "Your GitHub sign-in expired or was revoked. Sign in again."
        case .notFound(let repo):
            "The build or repository wasn't found. If \(repo) is private, sign in with access to private repositories, "
                + "and if it belongs to an organization, make sure the organization allows SimPR (or use the GitHub CLI sign-in)."
        case .forbidden(let message):
            "GitHub denied access: \(message)"
        case .expired(let repo, let runID):
            "This build has expired on GitHub. Re-run the workflow to rebuild it: https://github.com/\(repo)/actions/runs/\(runID)"
        case .rateLimited(let reset):
            "GitHub's API rate limit was reached." + (reset.map { " Try again after \($0.formatted(date: .omitted, time: .shortened))." } ?? "")
        case .http(let status, let message):
            "GitHub returned an error (\(status)): \(message)"
        case .network(let message):
            "Couldn't reach GitHub: \(message)"
        }
    }
}

public protocol TokenProviding: Sendable {
    func token() async -> String?
}

/// Network access used by the run pipeline. Real implementation: `GitHubClient`.
public protocol ArtifactFetching: Sendable {
    func artifact(_ repo: RepoID, id: Int64) async throws -> ArtifactInfo
    func downloadArtifact(_ repo: RepoID, id: Int64, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws
    func pullRequest(_ repo: RepoID, number: Int) async throws -> PullRequestInfo
    func commit(_ repo: RepoID, sha: String) async throws -> CommitInfo
}

public final class GitHubClient: ArtifactFetching, Sendable {
    public let apiURL: URL
    let tokens: any TokenProviding
    let session: URLSession

    public init(tokens: any TokenProviding, apiURL: URL = URL(string: "https://api.github.com")!, session: URLSession = .shared) {
        self.tokens = tokens
        self.apiURL = apiURL
        self.session = session
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func request(_ path: String, accept: String = "application/vnd.github+json") async throws -> URLRequest {
        guard let token = await tokens.token() else { throw GitHubError.notSignedIn }
        var request = URLRequest(url: apiURL.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("SimPR-macOS", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func error(for response: HTTPURLResponse, data: Data, repo: RepoID, runID: Int64? = nil) -> GitHubError {
        let message = (try? JSONDecoder().decode([String: String].self, from: data))?["message"]
            ?? String(decoding: data.prefix(300), as: UTF8.self)
        switch response.statusCode {
        case 401: return .unauthorized
        case 404: return .notFound(repo: repo.fullName)
        case 410: return .expired(repo: repo.fullName, runID: runID ?? 0)
        case 403, 429:
            if response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" || response.statusCode == 429 {
                let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
                return .rateLimited(resetAt: reset)
            }
            return .forbidden(message)
        default: return .http(response.statusCode, message)
        }
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String, repo: RepoID) async throws -> T {
        let req = try await request(path)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw GitHubError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw GitHubError.network("Invalid response") }
        guard (200..<300).contains(http.statusCode) else { throw Self.error(for: http, data: data, repo: repo) }
        return try Self.decoder.decode(T.self, from: data)
    }

    private func repoPath(_ repo: RepoID) -> String { "repos/\(repo.owner)/\(repo.name)" }

    public func artifact(_ repo: RepoID, id: Int64) async throws -> ArtifactInfo {
        try await get(ArtifactInfo.self, "\(repoPath(repo))/actions/artifacts/\(id)", repo: repo)
    }

    public func pullRequest(_ repo: RepoID, number: Int) async throws -> PullRequestInfo {
        try await get(PullRequestInfo.self, "\(repoPath(repo))/pulls/\(number)", repo: repo)
    }

    public func commit(_ repo: RepoID, sha: String) async throws -> CommitInfo {
        try await get(CommitInfo.self, "\(repoPath(repo))/commits/\(sha)", repo: repo)
    }

    /// Downloads the artifact. GitHub answers with a redirect to a short-lived signed URL;
    /// the token is stripped before following it so it never leaves api.github.com.
    public func downloadArtifact(_ repo: RepoID, id: Int64, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let req = try await request("\(repoPath(repo))/actions/artifacts/\(id)/zip")
        try await Downloader(apiHost: apiURL.host ?? "api.github.com").download(req, to: destination, repo: repo, progress: progress)
    }
}

/// URLSession download with progress that drops `Authorization` on cross-host redirects.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let apiHost: String
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var destination: URL?
    private var repo: RepoID?
    private var progress: (@Sendable (Double) -> Void)?
    private var moveError: Error?
    private var failedResponse: (HTTPURLResponse, Data)?

    init(apiHost: String) {
        self.apiHost = apiHost
    }

    func download(_ request: URLRequest, to destination: URL, repo: RepoID, progress: @escaping @Sendable (Double) -> Void) async throws {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    self.continuation = c
                    self.destination = destination
                    self.repo = repo
                    self.progress = progress
                }
                session.downloadTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request
        if request.url?.host != apiHost {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        lock.withLock { progress }?(min(1, fraction))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let (destination, http) = lock.withLock { (self.destination, downloadTask.response as? HTTPURLResponse) }
        if let http, !(200..<300).contains(http.statusCode) {
            let data = (try? Data(contentsOf: location)) ?? Data()
            lock.withLock { failedResponse = (http, data) }
            return
        }
        do {
            guard let destination else { return }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.withLock { moveError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (c, repo, failed, moveError) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, RepoID?, (HTTPURLResponse, Data)?, Error?) in
            let c = continuation
            continuation = nil
            return (c, self.repo, failedResponse, self.moveError)
        }
        guard let c else { return }
        if let error {
            c.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : GitHubError.network(error.localizedDescription))
        } else if let (response, data) = failed, let repo {
            c.resume(throwing: GitHubClient.error(for: response, data: data, repo: repo))
        } else if let moveError {
            c.resume(throwing: moveError)
        } else {
            c.resume()
        }
    }
}
