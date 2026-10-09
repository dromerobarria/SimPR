import Foundation

public struct ProcessResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { status == 0 }
}

public struct ProcessError: Error, LocalizedError, Sendable {
    public var command: String
    public var result: ProcessResult

    public var errorDescription: String? {
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(command) failed (exit \(result.status))" + (detail.isEmpty ? "." : ": \(detail)")
    }
}

/// Runs external tools. Arguments are always passed as an array, never through a
/// shell, so no user-controlled string is ever interpreted as shell syntax.
public protocol ProcessRunning: Sendable {
    func run(_ executable: URL, _ arguments: [String], environment: [String: String]?) async throws -> ProcessResult
}

extension ProcessRunning {
    public func run(_ executable: URL, _ arguments: [String]) async throws -> ProcessResult {
        try await run(executable, arguments, environment: nil)
    }

    /// Runs and throws `ProcessError` on a non-zero exit.
    public func check(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil) async throws -> ProcessResult {
        let result = try await run(executable, arguments, environment: environment)
        guard result.succeeded else {
            throw ProcessError(command: ([executable.lastPathComponent] + arguments.prefix(2)).joined(separator: " "), result: result)
        }
        return result
    }
}

public struct ProcessRunner: ProcessRunning {
    public init() {}

    public func run(_ executable: URL, _ arguments: [String], environment: [String: String]?) async throws -> ProcessResult {
        try await Task.detached(priority: .userInitiated) {
            try Self.runBlocking(executable, arguments, environment: environment)
        }.value
    }

    static func runBlocking(_ executable: URL, _ arguments: [String], environment: [String: String]?) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // Drain both pipes concurrently so a chatty tool can't fill one and deadlock.
        let group = DispatchGroup()
        nonisolated(unsafe) var outData = Data()
        nonisolated(unsafe) var errData = Data()
        group.enter()
        DispatchQueue.global().async {
            outData = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.wait()
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}

public enum Tools {
    public static let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
    public static let open = URL(fileURLWithPath: "/usr/bin/open")
    public static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
    public static let xcodeSelect = URL(fileURLWithPath: "/usr/bin/xcode-select")

    /// The GitHub CLI, if installed. Apps launched from Finder don't inherit the shell PATH.
    public static func gh(fileManager: FileManager = .default) -> URL? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .map(URL.init(fileURLWithPath:))
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}
