import Foundation

public enum HostInfo {
    /// The Mac's native architecture (Apple silicon even when running under Rosetta).
    public static var architecture: Architecture {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0, value == 1 { return .arm64 }
        return .x86_64
    }
}

public enum CompatibilityIssue: Equatable, Sendable, LocalizedError {
    /// No installed iOS runtime is new enough.
    case noRuntime(required: OSVersion, newestInstalled: OSVersion?)
    /// The build has no slice for this Mac.
    case architecture(build: [Architecture], host: Architecture)
    /// The chosen device runs an iOS older than the build needs.
    case deviceTooOld(device: String, version: OSVersion, required: OSVersion)
    /// The chosen device's runtime can't run any of the build's architectures.
    case runtimeArchitecture(device: String, build: [Architecture], runtime: [String])

    public var errorDescription: String? {
        switch self {
        case let .noRuntime(required, newest):
            let have = newest.map { "The newest one installed is iOS \($0)." } ?? "No iOS Simulator runtime is installed."
            return "This build needs iOS \(required) or later. \(have) Install a newer runtime in Xcode › Settings › Components."
        case let .architecture(build, host):
            let built = build.map(\.rawValue).joined(separator: " + ")
            return "This build only contains \(built), but this Mac needs \(host.rawValue). Ask the team to build universal "
                + "simulator binaries (the SimPR action does by default) or to add \(host.rawValue) to the archs input."
        case let .deviceTooOld(device, version, required):
            return "\(device) runs iOS \(version), but this build needs iOS \(required) or later. Pick a newer simulator."
        case let .runtimeArchitecture(device, build, runtime):
            return "\(device) only runs \(runtime.joined(separator: " + ")) apps, and this build contains "
                + "\(build.map(\.rawValue).joined(separator: " + ")). Pick another simulator."
        }
    }
}

public enum Compatibility {
    /// Checks a build against this Mac and its installed runtimes. Returns every problem found.
    public static func check(
        minimumOS: OSVersion,
        architectures: [Architecture],
        host: Architecture = HostInfo.architecture,
        runtimes: [SimRuntime]
    ) -> [CompatibilityIssue] {
        var issues: [CompatibilityIssue] = []
        if !architectures.contains(host) {
            issues.append(.architecture(build: architectures, host: host))
        }
        let installed = runtimes.filter { $0.isIOS && $0.isAvailable }.compactMap(\.osVersion)
        if !installed.contains(where: { $0 >= minimumOS }) {
            issues.append(.noRuntime(required: minimumOS, newestInstalled: installed.max()))
        }
        return issues
    }

    /// Checks a specific simulator for a build.
    public static func check(target: SimTarget, minimumOS: OSVersion, architectures: [Architecture], host: Architecture = HostInfo.architecture) -> CompatibilityIssue? {
        if target.runtimeVersion < minimumOS {
            return .deviceTooOld(device: target.device.name, version: target.runtimeVersion, required: minimumOS)
        }
        if let runtimeArchs = target.runtimeArchitectures, !runtimeArchs.isEmpty {
            // The simulator runs the host's slice; the runtime must support it.
            let usable = architectures.filter { $0 == host && runtimeArchs.contains($0.rawValue) }
            if usable.isEmpty && architectures.contains(host) {
                return .runtimeArchitecture(device: target.device.name, build: architectures, runtime: runtimeArchs)
            }
        }
        return nil
    }

    /// Simulators that can run the build, best first.
    public static func compatibleTargets(_ targets: [SimTarget], minimumOS: OSVersion, architectures: [Architecture], host: Architecture = HostInfo.architecture) -> [SimTarget] {
        targets.filter { check(target: $0, minimumOS: minimumOS, architectures: architectures, host: host) == nil }
    }

    /// The simulator to use without asking: the preferred one when it is compatible,
    /// otherwise nil (the app then shows a picker, preselecting `suggested`).
    public static func automaticTarget(_ compatible: [SimTarget], preferredUDID: String?) -> SimTarget? {
        guard let preferredUDID else { return nil }
        return compatible.first { $0.device.udid == preferredUDID }
    }

    /// Default selection for the picker: a booted iPhone, then the newest iPhone, then anything.
    public static func suggestedTarget(_ compatible: [SimTarget]) -> SimTarget? {
        compatible.first { $0.device.isBooted && $0.device.isIPhone }
            ?? compatible.first { $0.device.isBooted }
            ?? compatible.first { $0.device.isIPhone }
            ?? compatible.first
    }
}
