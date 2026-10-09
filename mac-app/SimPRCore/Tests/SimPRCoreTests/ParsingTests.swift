import Foundation
import Testing
@testable import SimPRCore

@Suite("simpr:// URL parsing")
struct RunRequestTests {
    // Same query string the redirect page forwards (see web/test/params.test.mjs).
    static let link = "simpr://run?v=1&repo=octo%2Fsample&pr=42&sha=0123456789abcdef0123456789abcdef01234567&run=555&artifact=1001"
        + "&name=simpr-pr-42-0123456789abcdef.zip&app=Sample+App&bundle=dev.simpr.SampleApp&folder=Sample-App-PR42-0123456"
        + "&appfile=SampleApp.app&minos=17.0&arch=arm64%2Cx86_64&key=0123456789abcdef&size=1234567"

    @Test func parsesAFullLink() throws {
        let r = try RunRequest.parse(URL(string: Self.link)!)
        #expect(r.repo.fullName == "octo/sample")
        #expect(r.pr == 42)
        #expect(r.sha == Fixture.sha)
        #expect(r.runID == 555)
        #expect(r.artifactID == 1001)
        #expect(r.artifactName == "simpr-pr-42-0123456789abcdef.zip")
        #expect(r.appName == "Sample App")
        #expect(r.bundleID == "dev.simpr.SampleApp")
        #expect(r.appBundleName == "SampleApp.app")
        #expect(r.minimumOSVersion == OSVersion("17.0"))
        #expect(r.architectures == [.arm64, .x86_64])
        #expect(r.contentKey == "0123456789abcdef")
        #expect(r.sizeBytes == 1_234_567)
        #expect(r.shortSHA == "0123456")
    }

    @Test func roundTrips() throws {
        var r = try RunRequest.parse(URL(string: Self.link)!)
        #expect(try RunRequest.parse(r.url) == r)
        r.appName = "C++ & Friends 100%"
        #expect(try RunRequest.parse(r.url).appName == "C++ & Friends 100%")
    }

    @Test func decodesFormEncodingLikeTheRedirectPage() throws {
        let r = try RunRequest.parse(URL(string: Self.link.replacingOccurrences(of: "app=Sample+App", with: "app=A%2BB+C"))!)
        #expect(r.appName == "A+B C")
    }

    @Test func parsesTheMinimalLink() throws {
        let r = try RunRequest.parse(URL(string: "simpr://run?repo=a/b&pr=1&sha=\(Fixture.sha)&run=2&artifact=3")!)
        #expect(r.bundleID == nil)
        #expect(r.architectures.isEmpty)
    }

    @Test func rejectsOtherSchemesAndActions() {
        #expect(throws: RunRequestError.notSimPRLink) { try RunRequest.parse(URL(string: "https://run?repo=a/b")!) }
        #expect(throws: RunRequestError.unsupportedAction("delete")) { try RunRequest.parse(URL(string: "simpr://delete?repo=a/b")!) }
        #expect(throws: RunRequestError.unsupportedVersion("2")) { try RunRequest.parse(URL(string: "simpr://run?v=2")!) }
    }

    @Test(arguments: ["repo", "pr", "sha", "run", "artifact"])
    func requiresCoreFields(_ field: String) throws {
        var c = URLComponents(string: Self.link)!
        c.queryItems = c.queryItems!.filter { $0.name != field }
        #expect(throws: RunRequestError.missing(field)) { try RunRequest.parse(c.url!) }
    }

    @Test(arguments: [
        ("repo", "octo"), ("repo", "octo/sample/x"), ("repo", "-octo/sample"), ("repo", "octo/.."), ("repo", "octo/a b"),
        ("pr", "0"), ("pr", "-3"), ("pr", "1e3"), ("pr", "007"),
        ("sha", "0123456"), ("sha", String(repeating: "G", count: 40)),
        ("run", "x"), ("artifact", "99999999999999999999"),
        ("name", "simpr-pr-7-0123456789abcdef.zip"), ("name", "evil.zip"),
        ("bundle", "nodots"), ("bundle", "a.b;c"),
        ("folder", ".."), ("folder", "a/b"),
        ("appfile", "../x.app"), ("appfile", "a/b.app"), ("appfile", "App"),
        ("minos", "17.x"), ("arch", "armv7"), ("arch", "arm64,ppc"),
        ("key", "XYZ"), ("app", "bad\u{0007}name"),
    ])
    func rejectsInvalidValues(_ field: String, _ value: String) throws {
        var c = URLComponents(string: Self.link)!
        c.queryItems = c.queryItems!.map { $0.name == field ? URLQueryItem(name: field, value: value) : $0 }
        #expect(throws: RunRequestError.invalid(field)) { try RunRequest.parse(c.url!) }
    }

    @Test func ignoresUnknownAndDuplicateFields() throws {
        let r = try RunRequest.parse(URL(string: Self.link + "&evil=1&repo=mallory/x")!)
        #expect(r.repo.fullName == "octo/sample")
    }
}

@Suite("simpr.json decoding")
struct ManifestTests {
    @Test func decodesTheActionsManifest() throws {
        let m = try BuildManifest.decode(Fixture.data("simpr.json"))
        #expect(m.bundleId == "dev.simpr.SampleApp")
        #expect(m.appName == "Sample App")
        #expect(m.minimumOSVersion == OSVersion("17"))
        #expect(m.architectures == [.x86_64, .arm64])
        #expect(m.repository.fullName == "octo/sample")
        #expect(m.prNumber == 42)
        #expect(m.xcodeVersion == "26.6")
        #expect(m.appSizeBytes == 2_500_000)
        #expect(m.buildDate == Date(timeIntervalSince1970: 1_791_549_296.789))
    }

    @Test func roundTrips() throws {
        let m = try BuildManifest.decode(Fixture.data("simpr.json"))
        #expect(try BuildManifest.decode(m.encoded()) == m)
    }

    @Test func toleratesMissingOptionalFieldsAndExtraFields() throws {
        var json = try JSONSerialization.jsonObject(with: Fixture.data("simpr.json")) as! [String: Any]
        for key in ["version", "buildNumber", "xcodeVersion", "xcodeBuild", "sdkVersion", "appSizeBytes", "prNumber"] { json[key] = nil }
        json["futureField"] = ["x": 1]
        json["buildDate"] = "2026-10-09T12:34:56Z"
        let m = try BuildManifest.decode(JSONSerialization.data(withJSONObject: json))
        #expect(m.version == nil)
    }

    /// Values are JSON fragments.
    @Test(arguments: [
        ("schemaVersion", "2"), ("bundleId", #""no dots""#), ("commitSha", #""abc""#),
        ("architectures", #"["armv7"]"#), ("architectures", "[]"), ("folderName", #""../x""#),
        ("appBundleName", #""x/y.app""#), ("minimumOSVersion", #""seventeen""#), ("repository", #""nope""#),
        ("contentKey", #""XYZ""#), ("buildDate", #""yesterday""#),
    ])
    func rejectsInvalidManifests(_ key: String, _ fragment: String) throws {
        var json = try JSONSerialization.jsonObject(with: Fixture.data("simpr.json")) as! [String: Any]
        json[key] = try JSONSerialization.jsonObject(with: Data(fragment.utf8), options: .fragmentsAllowed)
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: (any Error).self) { try BuildManifest.decode(data) }
    }

    @Test func verifiesTheBuildMatchesTheLink() throws {
        let m = try Fixture.manifest()
        try m.verify(matches: Fixture.request())
        var other = Fixture.request()
        other.sha = Fixture.sha("f")
        #expect(throws: ManifestError.mismatch("commit")) { try m.verify(matches: other) }
        other = Fixture.request()
        other.bundleID = "com.evil.app"
        #expect(throws: ManifestError.mismatch("bundle identifier")) { try m.verify(matches: other) }
        other = Fixture.request()
        other.repo = RepoID("mallory/sample")!
        #expect(throws: ManifestError.mismatch("repository")) { try m.verify(matches: other) }
    }
}

@Suite("Versions")
struct OSVersionTests {
    @Test func compares() {
        #expect(OSVersion("17.0")! == OSVersion("17")!)
        #expect(OSVersion("17.0.1")! > OSVersion("17")!)
        #expect(OSVersion("9.3")! < OSVersion("17.0")!)
        #expect(OSVersion("26.5")! >= OSVersion("26.5.0")!)
        #expect(Set([OSVersion("17")!, OSVersion("17.0")!]).count == 1)
    }

    @Test(arguments: ["", "17.", ".1", "17.0.0.0", "x", "17.0-beta", "١٧"])
    func rejectsMalformed(_ s: String) {
        #expect(OSVersion(s) == nil)
    }
}

@Suite("Device flow")
struct DeviceFlowTests {
    @Test func parsesPollResponses() throws {
        #expect(try DeviceFlow.pollResult(Data(#"{"access_token":"gho_x","token_type":"bearer","scope":"repo"}"#.utf8)) == .token("gho_x"))
        #expect(try DeviceFlow.pollResult(Data(#"{"error":"authorization_pending"}"#.utf8)) == .pending)
        #expect(try DeviceFlow.pollResult(Data(#"{"error":"slow_down","interval":10}"#.utf8)) == .slowDown(10))
        #expect(throws: DeviceFlowError.expired) { try DeviceFlow.pollResult(Data(#"{"error":"expired_token"}"#.utf8)) }
        #expect(throws: DeviceFlowError.denied) { try DeviceFlow.pollResult(Data(#"{"error":"access_denied"}"#.utf8)) }
        #expect(throws: DeviceFlowError.disabled) { try DeviceFlow.pollResult(Data(#"{"error":"device_flow_disabled"}"#.utf8)) }
    }

    @Test func decodesDeviceCode() throws {
        let json = #"{"device_code":"3584d83530557fdd1f46af8289938c8ef79f9dc5","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#
        let code = try JSONDecoder().decode(DeviceCode.self, from: Data(json.utf8))
        #expect(code.userCode == "WDJB-MJHT")
        #expect(code.interval == 5)
    }

    @Test func refusesToStartWithoutAClientID() async {
        await #expect(throws: DeviceFlowError.notConfigured) { _ = try await DeviceFlow(clientID: "").start(scope: .publicOnly) }
    }
}

@Suite("Process wrapper")
struct ProcessRunnerTests {
    @Test func passesArgumentsLiterally() async throws {
        let tricky = ["$(whoami)", "a b", "; rm -rf /", "'\"", "*"]
        let result = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/printf"), ["%s\\n"] + tricky)
        #expect(result.succeeded)
        #expect(result.stdout == tricky.joined(separator: "\n") + "\n")
    }

    @Test func capturesStderrAndStatus() async throws {
        let result = try await ProcessRunner().run(URL(fileURLWithPath: "/bin/ls"), ["/definitely/not/here"])
        #expect(!result.succeeded)
        #expect(result.stderr.contains("No such file"))
        await #expect(throws: ProcessError.self) { _ = try await ProcessRunner().check(URL(fileURLWithPath: "/bin/ls"), ["/definitely/not/here"]) }
    }

    @Test func handlesLargeOutputOnBothPipes() async throws {
        let script = "for i in $(seq 1 20000); do echo out$i; echo err$i 1>&2; done"
        let result = try await ProcessRunner().run(URL(fileURLWithPath: "/bin/sh"), ["-c", script])
        #expect(result.stdout.split(separator: "\n").count == 20000)
        #expect(result.stderr.split(separator: "\n").count == 20000)
    }
}
