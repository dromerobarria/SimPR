import SimPRCore
import SwiftUI

struct MenuContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var preferences = model.preferences

        if let run = model.runState {
            Text("\(run.title): \(statusText(run.phase))")
            Button("Cancel Run") { model.cancelRun() }
            Divider()
        }

        Section("Recent Builds") {
            if model.recent.isEmpty {
                Text("No builds yet. Click “Run in iOS Simulator” on a pull request.")
            }
            ForEach(model.recent) { record in
                let label = "\(record.appName) · \(record.repo.name)\(record.prNumber.map { " #\($0)" } ?? "") · \(record.shortSHA)"
                Menu(label) {
                    Button("Run again") { model.run(record) }
                    Menu("Run on…") {
                        let compatible = Compatibility.compatibleTargets(model.targets, minimumOS: record.minimumOSVersion, architectures: record.architectures)
                        if compatible.isEmpty { Text("No compatible simulators") }
                        ForEach(compatible) { target in
                            Button(target.displayName) { model.run(record, deviceUDID: target.device.udid) }
                        }
                    }
                } primaryAction: {
                    model.run(record)
                }
            }
        }

        Button("Open Library…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: WindowID.library)
        }
        .keyboardShortcut("l")

        Divider()

        Menu("Simulator: \(model.preferredTarget?.displayName ?? "Ask each time")") {
            Picker("Simulator", selection: $preferences.preferredDeviceUDID) {
                Text("Ask each time").tag(String?.none)
                ForEach(model.targets) { target in
                    Text(target.displayName).tag(Optional(target.device.udid))
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Refresh Simulators") { Task { await model.refreshSimulators() } }
        }

        if model.xcodes.count > 1 {
            Menu("Xcode: \(model.activeXcode?.displayName ?? "xcode-select")") {
                Picker("Xcode", selection: Binding(
                    get: { preferences.developerDir },
                    set: { dir in Task { await model.selectXcode(dir) } }
                )) {
                    Text("Automatic (\(XcodeLocator.sorted(model.xcodes).first?.displayName ?? "xcode-select"))").tag("")
                    ForEach(model.xcodes, id: \.developerDir) { xcode in
                        Text(xcode.displayName + (xcode.isBeta ? " — beta" : "")).tag(xcode.developerDir)
                    }
                }
                .pickerStyle(.inline)
            }
        }

        Toggle("Reset App Data Before Launch", isOn: $preferences.resetAppData)

        Divider()

        switch model.auth.state {
        case .signedIn(let login, let source, _):
            Text("Signed in as \(login)\(source == .gitHubCLI ? " (GitHub CLI)" : "")")
            Button("Sign Out") { model.auth.signOut() }
        default:
            SettingsLink { Text("Sign in with GitHub…") }
        }

        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit SimPR") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func statusText(_ phase: RunState.Phase) -> String {
        switch phase {
        case .working(let stage): stage.label
        case .chooseDevice: "Choose a simulator"
        case .failed: "Failed"
        case .finished(let message): message
        }
    }
}
