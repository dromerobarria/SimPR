import SimPRCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AccountSettings().tabItem { Label("GitHub", systemImage: "person.crop.circle") }
            LibrarySettings().tabItem { Label("Library", systemImage: "books.vertical") }
            TrustSettings().tabItem { Label("Trusted Repos", systemImage: "checkmark.shield") }
        }
        .frame(width: 520)
        .padding(20)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Picker("Preferred simulator", selection: $preferences.preferredDeviceUDID) {
                Text("Ask each time").tag(String?.none)
                ForEach(model.targets) { Text($0.displayName).tag(Optional($0.device.udid)) }
            }
            if let error = model.simulatorError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Toggle("Reset app data before launch (uninstall first)", isOn: $preferences.resetAppData)
            Toggle("Notify when a build is running", isOn: $preferences.notifyWhenDone)
            Picker("Xcode", selection: $preferences.developerDir) {
                Text("Selected with xcode-select").tag("")
                ForEach(XcodeLocator.installedXcodes(), id: \.developerDir) { xcode in
                    Text(xcode.displayName + (xcode.isBeta ? " — beta" : "")).tag(xcode.developerDir)
                }
            }
            .onChange(of: preferences.developerDir) { Task { await model.refreshSimulators() } }
        }
        .formStyle(.grouped)
        .task { await model.refreshSimulators() }
    }
}

private struct AccountSettings: View {
    @Environment(AppModel.self) private var model
    @State private var includePrivate = true

    var body: some View {
        let auth = model.auth
        Form {
            switch auth.state {
            case .unknown:
                ProgressView()
            case .signedIn(let login, let source, let privateRepos):
                LabeledContent("Signed in as", value: login)
                LabeledContent("Using", value: source == .simpr ? "SimPR sign-in (Keychain)" : "GitHub CLI token")
                if !privateRepos {
                    Text("This sign-in can only download builds from public repositories.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Sign Out") { auth.signOut() }
            case .waitingForCode:
                ProgressView("Contacting GitHub…")
            case .enterCode(let code):
                VStack(alignment: .leading, spacing: 10) {
                    Text("Enter this code on GitHub:")
                    Text(code.userCode).font(.system(size: 28, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Button("Copy Code and Open GitHub") { auth.copyCodeAndOpenGitHub(code) }
                            .keyboardShortcut(.defaultAction)
                        Button("Cancel") { auth.cancelSignIn() }
                    }
                    Text("Waiting for you to approve SimPR…").font(.caption).foregroundStyle(.secondary)
                }
            case .signedOut, .failed:
                if case .failed(let message) = auth.state {
                    Text(message).foregroundStyle(.red)
                }
                Text("GitHub requires signing in to download build artifacts, even from public repositories.")
                    .font(.callout)
                if auth.canUseDeviceFlow {
                    Toggle("Include private repositories (requests the “repo” scope)", isOn: $includePrivate)
                    Button("Sign in with GitHub") { auth.signIn(scope: includePrivate ? .includePrivate : .publicOnly) }
                } else {
                    Text("This build of SimPR has no OAuth client ID, so “Sign in with GitHub” is unavailable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if auth.gitHubCLIInstalled {
                    Button("Use GitHub CLI Sign-in (gh auth token)") { auth.useGitHubCLI() }
                } else {
                    Text("Or install the GitHub CLI and run “gh auth login”.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { if auth.state == .unknown { await auth.refresh() } }
    }
}

private struct LibrarySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            LabeledContent("Using", value: ByteCountFormatter.string(fromByteCount: model.totalSize, countStyle: .file) + " in \(model.records.count) builds")
            Stepper(value: $preferences.libraryLimitGB, in: 1...200, step: 1) {
                Text("Size limit: \(Int(preferences.libraryLimitGB)) GB")
            }
            .onChange(of: preferences.libraryLimitGB) { model.enforceLibraryLimit() }
            Text("When the library is over the limit, the oldest unpinned builds are deleted. Pinned builds are never deleted automatically.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Delete Builds from Merged/Closed PRs") { model.deleteMergedAndClosed() }
                Button("Delete All Unpinned") { model.deleteAllUnpinned() }
            }
            Button("Show Library in Finder") { model.revealLibraryFolder() }
        }
        .formStyle(.grouped)
    }
}

private struct TrustSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Text("Builds from these repositories run without asking first.").font(.callout)
            if preferences.allowlist.sorted.isEmpty {
                Text("None yet. Choose “Always allow” when SimPR asks.").foregroundStyle(.secondary)
            }
            ForEach(preferences.allowlist.sorted, id: \.self) { repo in
                HStack {
                    Text(repo)
                    Spacer()
                    Button("Remove") { preferences.allowlist.remove(repo) }
                }
            }
        }
        .formStyle(.grouped)
    }
}
