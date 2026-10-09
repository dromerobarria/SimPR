import Foundation
import Testing
@testable import SimPRCore

@Suite("simctl JSON parsing")
struct SimctlParserTests {
    @Test func parsesRuntimes() throws {
        let runtimes = try SimctlParser.runtimes(Fixture.data("runtimes.json"))
        #expect(runtimes.count == 5)
        let ios265 = try #require(runtimes.first { $0.identifier == "com.apple.CoreSimulator.SimRuntime.iOS-26-5" })
        #expect(ios265.osVersion == OSVersion("26.5"))
        #expect(ios265.isIOS)
        #expect(ios265.supportedArchitectures == ["arm64"])
        #expect(runtimes.first { $0.platform == "watchOS" }?.isIOS == false)
    }

    @Test func parsesDevicesAndRememberTheirRuntime() throws {
        let devices = try SimctlParser.devices(Fixture.data("devices.json"))
        let booted = try #require(devices.first { $0.isBooted })
        #expect(booted.name == "iPhone 17 Pro")
        #expect(booted.runtimeIdentifier == "com.apple.CoreSimulator.SimRuntime.iOS-26-5")
        #expect(booted.isIPhone)
        #expect(devices.contains { !$0.isAvailable })
    }

    @Test func buildsIOSTargetsNewestFirst() throws {
        let targets = SimctlParser.iOSTargets(
            devices: try SimctlParser.devices(Fixture.data("devices.json")),
            runtimes: try SimctlParser.runtimes(Fixture.data("runtimes.json"))
        )
        #expect(!targets.contains { !$0.device.isAvailable }, "unavailable devices are dropped")
        #expect(!targets.contains { $0.device.name.contains("Watch") }, "non-iOS devices are dropped")
        #expect(!targets.contains { $0.device.udid == "11111111-1111-1111-1111-111111111111" }, "devices without an installed runtime are dropped")
        #expect(targets.first?.runtimeVersion == OSVersion("27.1"))
        let versions = targets.map(\.runtimeVersion)
        #expect(versions == versions.sorted(by: >))
        #expect(targets.first { $0.device.isBooted }?.displayName == "iPhone 17 Pro (iOS 26.5)")
    }

    @Test func toleratesOlderXcodeOutputWithoutPlatform() throws {
        let json = #"{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-16-4","name":"iOS 16.4","version":"16.4","isAvailable":true}]}"#
        let runtimes = try SimctlParser.runtimes(Data(json.utf8))
        #expect(runtimes[0].isIOS)
        #expect(runtimes[0].supportedArchitectures == nil)
    }
}

@Suite("Compatibility checks")
struct CompatibilityTests {
    let runtimes: [SimRuntime]
    let targets: [SimTarget]

    init() throws {
        runtimes = try SimctlParser.runtimes(Fixture.data("runtimes.json"))
        targets = SimctlParser.iOSTargets(devices: try SimctlParser.devices(Fixture.data("devices.json")), runtimes: runtimes)
    }

    @Test func passesWhenARuntimeIsNewEnoughAndTheArchMatches() {
        #expect(Compatibility.check(minimumOS: OSVersion("17.0")!, architectures: [.arm64, .x86_64], host: .arm64, runtimes: runtimes).isEmpty)
        #expect(Compatibility.check(minimumOS: OSVersion("27.1")!, architectures: [.arm64], host: .arm64, runtimes: runtimes).isEmpty)
    }

    @Test func failsWhenNoRuntimeIsNewEnough() {
        let issues = Compatibility.check(minimumOS: OSVersion("28.0")!, architectures: [.arm64], host: .arm64, runtimes: runtimes)
        #expect(issues == [.noRuntime(required: OSVersion("28.0")!, newestInstalled: OSVersion("27.1"))])
        #expect(issues[0].errorDescription!.contains("iOS 28.0 or later"))
        #expect(issues[0].errorDescription!.contains("Xcode › Settings › Components"))
    }

    @Test func failsWithNoRuntimesAtAll() {
        let issues = Compatibility.check(minimumOS: OSVersion("17.0")!, architectures: [.arm64], host: .arm64, runtimes: [])
        #expect(issues == [.noRuntime(required: OSVersion("17.0")!, newestInstalled: nil)])
    }

    @Test func failsWhenTheBuildLacksTheHostArchitecture() {
        let onIntel = Compatibility.check(minimumOS: OSVersion("17.0")!, architectures: [.arm64], host: .x86_64, runtimes: runtimes)
        #expect(onIntel.contains(.architecture(build: [.arm64], host: .x86_64)))
        let onAppleSilicon = Compatibility.check(minimumOS: OSVersion("17.0")!, architectures: [.x86_64], host: .arm64, runtimes: runtimes)
        #expect(onAppleSilicon.contains(.architecture(build: [.x86_64], host: .arm64)))
        #expect(onAppleSilicon.first!.errorDescription!.contains("universal"))
    }

    @Test func reportsEveryProblemAtOnce() {
        let issues = Compatibility.check(minimumOS: OSVersion("99")!, architectures: [.x86_64], host: .arm64, runtimes: runtimes)
        #expect(issues.count == 2)
    }

    @Test func checksTheChosenDevice() throws {
        let old = try #require(targets.first { $0.runtimeVersion == OSVersion("26.5") })
        #expect(Compatibility.check(target: old, minimumOS: OSVersion("27.0")!, architectures: [.arm64], host: .arm64)
            == .deviceTooOld(device: old.device.name, version: OSVersion("26.5")!, required: OSVersion("27.0")!))
        #expect(Compatibility.check(target: old, minimumOS: OSVersion("17.0")!, architectures: [.arm64], host: .arm64) == nil)
    }

    @Test func checksTheRuntimeArchitecture() throws {
        // iOS 26+ runtimes only run arm64 apps.
        let target = try #require(targets.first)
        let issue = Compatibility.check(target: target, minimumOS: OSVersion("17.0")!, architectures: [.x86_64], host: .x86_64)
        #expect(issue == .runtimeArchitecture(device: target.device.name, build: [.x86_64], runtime: ["arm64"]))
    }

    @Test func picksDevices() throws {
        let compatible = Compatibility.compatibleTargets(targets, minimumOS: OSVersion("17.0")!, architectures: [.arm64], host: .arm64)
        #expect(compatible.count == targets.count)
        #expect(Compatibility.suggestedTarget(compatible)?.device.isBooted == true, "booted iPhone first")
        let preferred = try #require(compatible.last)
        #expect(Compatibility.automaticTarget(compatible, preferredUDID: preferred.device.udid) == preferred)
        #expect(Compatibility.automaticTarget(compatible, preferredUDID: nil) == nil)
        #expect(Compatibility.automaticTarget(compatible, preferredUDID: "gone") == nil)

        let onlyNew = Compatibility.compatibleTargets(targets, minimumOS: OSVersion("27.0")!, architectures: [.arm64], host: .arm64)
        #expect(onlyNew.allSatisfy { $0.runtimeVersion >= OSVersion("27.0")! })
        #expect(Compatibility.suggestedTarget(onlyNew)?.device.isIPhone == true)
    }
}
