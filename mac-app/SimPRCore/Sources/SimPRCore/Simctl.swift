import Foundation

public struct SimRuntime: Decodable, Equatable, Sendable, Identifiable {
    public var identifier: String
    public var name: String
    public var version: String
    public var platform: String?
    public var isAvailable: Bool
    public var supportedArchitectures: [String]?

    public var id: String { identifier }
    public var osVersion: OSVersion? { OSVersion(version) }

    /// True for iOS runtimes. Older Xcode versions omit `platform`, so fall back to the identifier.
    public var isIOS: Bool {
        if let platform { return platform == "iOS" }
        return identifier.contains(".SimRuntime.iOS-")
    }

    public init(identifier: String, name: String, version: String, platform: String?, isAvailable: Bool, supportedArchitectures: [String]? = nil) {
        self.identifier = identifier
        self.name = name
        self.version = version
        self.platform = platform
        self.isAvailable = isAvailable
        self.supportedArchitectures = supportedArchitectures
    }
}

public struct SimDevice: Decodable, Equatable, Sendable, Identifiable, Hashable {
    public var udid: String
    public var name: String
    public var state: String
    public var isAvailable: Bool
    public var deviceTypeIdentifier: String?
    /// Filled in from the dictionary key in `simctl list devices`.
    public var runtimeIdentifier: String = ""

    public var id: String { udid }
    public var isBooted: Bool { state == "Booted" }
    public var isIPhone: Bool { deviceTypeIdentifier?.contains("iPhone") ?? name.hasPrefix("iPhone") }
    public var isIPad: Bool { deviceTypeIdentifier?.contains("iPad") ?? name.hasPrefix("iPad") }

    enum CodingKeys: String, CodingKey {
        case udid, name, state, isAvailable, deviceTypeIdentifier
    }

    public init(udid: String, name: String, state: String, isAvailable: Bool, deviceTypeIdentifier: String?, runtimeIdentifier: String) {
        self.udid = udid
        self.name = name
        self.state = state
        self.isAvailable = isAvailable
        self.deviceTypeIdentifier = deviceTypeIdentifier
        self.runtimeIdentifier = runtimeIdentifier
    }
}

/// A device together with its runtime, ready to show in a picker.
public struct SimTarget: Equatable, Sendable, Identifiable, Hashable {
    public var device: SimDevice
    public var runtimeName: String
    public var runtimeVersion: OSVersion
    public var runtimeArchitectures: [String]?

    public var id: String { device.udid }
    public var displayName: String { "\(device.name) (\(runtimeName))" }
}

public enum SimctlParser {
    struct RuntimesEnvelope: Decodable { var runtimes: [SimRuntime] }
    struct DevicesEnvelope: Decodable { var devices: [String: [SimDevice]] }

    public static func runtimes(_ data: Data) throws -> [SimRuntime] {
        try JSONDecoder().decode(RuntimesEnvelope.self, from: data).runtimes
    }

    public static func devices(_ data: Data) throws -> [SimDevice] {
        let envelope = try JSONDecoder().decode(DevicesEnvelope.self, from: data)
        return envelope.devices
            .sorted { $0.key < $1.key }
            .flatMap { key, devices in
                devices.map { d in
                    var d = d
                    d.runtimeIdentifier = key
                    return d
                }
            }
    }

    /// Available iOS devices joined with their (available) runtimes, newest runtime first.
    public static func iOSTargets(devices: [SimDevice], runtimes: [SimRuntime]) -> [SimTarget] {
        let byID = Dictionary(runtimes.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
        return devices.compactMap { device -> SimTarget? in
            guard device.isAvailable, let runtime = byID[device.runtimeIdentifier],
                  runtime.isAvailable, runtime.isIOS, let version = runtime.osVersion else { return nil }
            return SimTarget(device: device, runtimeName: runtime.name, runtimeVersion: version, runtimeArchitectures: runtime.supportedArchitectures)
        }
        .sorted { a, b in
            if a.runtimeVersion != b.runtimeVersion { return a.runtimeVersion > b.runtimeVersion }
            if a.device.isIPhone != b.device.isIPhone { return a.device.isIPhone }
            return a.device.name.localizedStandardCompare(b.device.name) == .orderedAscending
        }
    }
}

/// Everything SimPR does to simulators. Real implementation: `Simctl`.
public protocol SimulatorControlling: Sendable {
    func runtimes() async throws -> [SimRuntime]
    func devices() async throws -> [SimDevice]
    func boot(_ udid: String) async throws
    func openSimulatorApp(focusing udid: String) async throws
    func uninstall(_ udid: String, bundleID: String) async throws
    func install(_ udid: String, app: URL) async throws
    func launch(_ udid: String, bundleID: String) async throws
}

public struct Simctl: SimulatorControlling {
    let runner: any ProcessRunning
    /// DEVELOPER_DIR to use, when xcode-select points at the Command Line Tools.
    let developerDir: String?

    public init(runner: any ProcessRunning = ProcessRunner(), developerDir: String? = nil) {
        self.runner = runner
        self.developerDir = developerDir
    }

    private var environment: [String: String]? {
        developerDir.map { ["DEVELOPER_DIR": $0] }
    }

    private func simctl(_ args: [String]) async throws -> ProcessResult {
        let result = try await runner.run(Tools.xcrun, ["simctl"] + args, environment: environment)
        guard result.succeeded else {
            if result.stderr.contains("unable to find utility \"simctl\"") {
                throw SimulatorError.xcodeMissing
            }
            throw ProcessError(command: "simctl \(args.first ?? "")", result: result)
        }
        return result
    }

    public func runtimes() async throws -> [SimRuntime] {
        try SimctlParser.runtimes(Data(try await simctl(["list", "runtimes", "--json"]).stdout.utf8))
    }

    public func devices() async throws -> [SimDevice] {
        try SimctlParser.devices(Data(try await simctl(["list", "devices", "--json"]).stdout.utf8))
    }

    public func boot(_ udid: String) async throws {
        let result = try await runner.run(Tools.xcrun, ["simctl", "boot", udid], environment: environment)
        // 149 / "current state: Booted" means it was already booted: fine.
        if !result.succeeded && !result.stderr.contains("current state: Booted") {
            throw ProcessError(command: "simctl boot", result: result)
        }
        _ = try await simctl(["bootstatus", udid, "-b"])
    }

    public func openSimulatorApp(focusing udid: String) async throws {
        var args = ["-a", "Simulator", "--args", "-CurrentDeviceUDID", udid]
        if let developerDir {
            args = ["-a", URL(fileURLWithPath: developerDir).appendingPathComponent("Applications/Simulator.app").path,
                    "--args", "-CurrentDeviceUDID", udid]
        }
        _ = try await runner.check(Tools.open, args)
    }

    public func uninstall(_ udid: String, bundleID: String) async throws {
        // Not installed yet is fine.
        _ = try await runner.run(Tools.xcrun, ["simctl", "uninstall", udid, bundleID], environment: environment)
    }

    public func install(_ udid: String, app: URL) async throws {
        _ = try await simctl(["install", udid, app.path])
    }

    public func launch(_ udid: String, bundleID: String) async throws {
        _ = try await simctl(["launch", udid, bundleID])
    }
}

public enum SimulatorError: Error, LocalizedError, Equatable {
    case xcodeMissing
    case noDevices

    public var errorDescription: String? {
        switch self {
        case .xcodeMissing:
            "Xcode isn't selected. Install Xcode, then run “sudo xcode-select -s /Applications/Xcode.app” or choose an Xcode in SimPR Settings."
        case .noDevices:
            "No iOS simulators are available. Open Xcode › Settings › Components to install an iOS Simulator runtime."
        }
    }
}

/// Finds installed Xcode apps, for when xcode-select points at the Command Line Tools.
public enum XcodeLocator {
    public static func installedXcodes(fileManager: FileManager = .default) -> [URL] {
        let apps = URL(fileURLWithPath: "/Applications")
        let entries = (try? fileManager.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil)) ?? []
        return entries
            .filter { $0.lastPathComponent.hasPrefix("Xcode") && $0.pathExtension == "app" }
            .filter { fileManager.fileExists(atPath: $0.appendingPathComponent("Contents/Developer/usr/bin/xcodebuild").path) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
    }

    /// The developer dir to pass as DEVELOPER_DIR, or nil when xcode-select already points at an Xcode.
    public static func developerDir(preferred: String?, runner: any ProcessRunning = ProcessRunner()) async -> String? {
        if let preferred, !preferred.isEmpty { return preferred }
        let selected = (try? await runner.run(Tools.xcodeSelect, ["-p"]))?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if selected.contains(".app/Contents/Developer") { return nil }
        return installedXcodes().first?.appendingPathComponent("Contents/Developer").path
    }
}
