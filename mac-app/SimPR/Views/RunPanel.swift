import AppKit
import Observation
import SimPRCore
import SwiftUI

/// A small floating panel that shows run progress, the simulator picker, and errors.
/// A panel (rather than a SwiftUI window) can be shown from a URL event without a view in scope.
@MainActor
final class RunPanelController {
    private let model: AppModel
    private var panel: NSPanel?

    init(model: AppModel) {
        self.model = model
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = model.runState
        } onChange: {
            Task { @MainActor [weak self] in
                self?.update()
                self?.observe()
            }
        }
    }

    private func update() {
        if model.runState == nil {
            panel?.orderOut(nil)
            return
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible {
            panel.center()
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "SimPR"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RunStatusView().environment(model))
        host.sizingOptions = [.preferredContentSize]
        panel.contentView = host
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let state = self.model.runState else { return }
                // Closing the panel while working leaves the run going; otherwise it dismisses.
                if case .working = state.phase { return }
                self.model.runState = nil
            }
        }
        return panel
    }
}

struct RunStatusView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let run = model.runState {
                header(run)
                switch run.phase {
                case .working(let stage):
                    working(stage)
                case .chooseDevice(let record, let candidates, let suggested):
                    picker(record: record, candidates: candidates, suggested: suggested)
                case .failed(let message):
                    failed(message, rebuildURL: run.rebuildURL)
                case .finished(let message):
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    HStack {
                        Spacer()
                        Button("Done") { model.runState = nil }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(20)
        .padding(.top, 8)
        .frame(width: 420, alignment: .leading)
    }

    private func header(_ run: RunState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(run.title).font(.headline).lineLimit(1)
            Text(run.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    private func working(_ stage: RunStage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .downloading(let fraction?) = stage {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Text(stage.label).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.cancelRun() }
            }
        }
    }

    private func picker(record: BuildRecord, candidates: [SimTarget], suggested: SimTarget?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.xcodes.count > 1 {
                Picker("Xcode", selection: Binding(
                    get: { model.activeDeveloperDir ?? "" },
                    set: { dir in
                        selection = nil
                        model.switchXcodeAndRetry(dir)
                    }
                )) {
                    if model.activeDeveloperDir == nil { Text("Selected with xcode-select").tag("") }
                    ForEach(model.xcodes, id: \.developerDir) { xcode in
                        Text(xcode.displayName + (xcode.isBeta ? " — beta" : "")).tag(xcode.developerDir)
                    }
                }
            }
            Picker("Simulator", selection: Binding(get: { selection ?? suggested?.id }, set: { selection = $0 })) {
                ForEach(candidates) { target in
                    Text(target.displayName + (target.device.isBooted ? " — booted" : "")).tag(Optional(target.id))
                }
            }
            Toggle("Use this simulator next time (don't ask again)", isOn: $remember)
            HStack {
                Spacer()
                Button("Cancel") { model.cancelRun() }
                Button("Run") {
                    let id = selection ?? suggested?.id
                    if let target = candidates.first(where: { $0.id == id }) {
                        model.choose(target, for: record, remember: remember)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failed(_ message: String, rebuildURL: URL?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack {
                Button("Copy Error") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                }
                if let rebuildURL {
                    Button("Open Workflow Run") { NSWorkspace.shared.open(rebuildURL) }
                }
                Spacer()
                Button("Close") { model.runState = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
