import SimPRCore
import SwiftUI
import UniformTypeIdentifiers

/// Every build the user has downloaded, grouped by repository and pull request.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var importing = false
    @State private var confirmDeleteAll = false

    private var groups: [LibraryGroup] {
        LibraryGroup.group(model.records.filter { $0.matches(query) })
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.records.isEmpty {
                ContentUnavailableView {
                    Label("No Builds Yet", systemImage: "iphone")
                } description: {
                    Text("Click “Run in iOS Simulator” on a pull request. Every build you run is kept here, even after GitHub deletes it.")
                } actions: {
                    Button("Import Build Zip…") { importing = true }
                }
            } else if groups.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.pulls) { pull in
                                PullSection(repo: group.repo, pull: pull)
                            }
                        } header: {
                            Label(group.repo.fullName, systemImage: "shippingbox")
                                .font(.headline)
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
            }
            Divider()
            footer
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Repo, #PR, branch or SHA")
        .toolbar {
            ToolbarItem {
                Button { importing = true } label: { Label("Import Build Zip", systemImage: "square.and.arrow.down") }
                    .help("Import a build zip downloaded from GitHub")
            }
            ToolbarItem {
                Button { Task { await model.refreshPRStates(force: true) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh pull request titles and states")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { result in
            if case .success(let url) = result { model.importBuild(from: url) }
        }
        .confirmationDialog("Delete all unpinned builds?", isPresented: $confirmDeleteAll) {
            Button("Delete Unpinned Builds", role: .destructive) { model.deleteAllUnpinned() }
        } message: {
            Text("Pinned builds are kept. Deleted builds can be downloaded again only while GitHub still has them.")
        }
        .task {
            await model.reloadLibrary()
            await model.refreshSimulators()
            await model.refreshPRStates()
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(model.records.count) builds · \(ByteCountFormatter.string(fromByteCount: model.totalSize, countStyle: .file)) of \(Int(model.preferences.libraryLimitGB)) GB")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Delete Builds from Merged/Closed PRs") { model.deleteMergedAndClosed() }
            Button("Delete All Unpinned…") { confirmDeleteAll = true }
            Button { model.revealLibraryFolder() } label: { Image(systemName: "folder") }
                .help("Show the library in Finder")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .disabled(model.records.isEmpty)
    }
}

private struct PullSection: View {
    let repo: RepoID
    let pull: LibraryGroup.PullGroup
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(pull.builds) { record in
                BuildRow(record: record, isLatest: record.id == pull.builds.first?.id)
            }
        } label: {
            HStack(spacing: 8) {
                Text(pull.number.map { "#\($0)" } ?? "No PR").font(.body.monospacedDigit().weight(.semibold))
                Text(pull.title ?? "Untitled pull request").lineLimit(1)
                StateBadge(state: pull.state)
                Spacer()
                Text("\(pull.builds.count) build\(pull.builds.count == 1 ? "" : "s")").foregroundStyle(.secondary).font(.caption)
            }
        }
    }
}

private struct BuildRow: View {
    @Environment(AppModel.self) private var model
    let record: BuildRecord
    let isLatest: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.shortSHA).font(.body.monospaced())
                    Text(record.commitTitle ?? record.appName).lineLimit(1)
                    if record.pinned { Image(systemName: "pin.fill").foregroundStyle(.orange).help("Pinned") }
                    if isLatest { Text("latest").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule()) }
                }
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Run") { model.run(record) }
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 3)
        .contextMenu { actions }
    }

    private var details: String {
        var parts: [String] = []
        if let branch = record.branch { parts.append(branch) }
        if let author = record.author { parts.append(author) }
        parts.append("built \(record.buildDate.formatted(date: .abbreviated, time: .shortened))")
        parts.append("iOS \(record.minimumOSVersion)+")
        parts.append(ByteCountFormatter.string(fromByteCount: record.sizeBytes, countStyle: .file))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var actions: some View {
        Button("Run") { model.run(record) }
        Menu("Run on…") {
            let compatible = Compatibility.compatibleTargets(model.targets, minimumOS: record.minimumOSVersion, architectures: record.architectures)
            if compatible.isEmpty { Text("No compatible simulators") }
            ForEach(compatible) { target in
                Button(target.displayName) { model.run(record, deviceUDID: target.device.udid) }
            }
        }
        Divider()
        Button(record.pinned ? "Unpin" : "Pin") { model.setPinned(record, !record.pinned) }
        Button("Reveal in Finder") { model.reveal(record) }
        if record.pullURL != nil {
            Button("Open PR on GitHub") { model.openPR(record) }
        }
        Button("Copy Commit SHA") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(record.commitSHA, forType: .string)
        }
        Divider()
        Button("Delete", role: .destructive) { model.delete(record) }
    }
}

private struct StateBadge: View {
    let state: PRState

    var body: some View {
        switch state {
        case .open: badge("Open", .green)
        case .merged: badge("Merged", .purple)
        case .closed: badge("Closed", .red)
        case .unknown: EmptyView()
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}
