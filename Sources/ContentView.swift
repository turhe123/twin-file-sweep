import SwiftUI
import AppKit

/// Main window: folder sidebar, results list and footer with the trash action.
struct ContentView: View {
    @EnvironmentObject private var model: ScanModel
    @AppStorage("minSizeKB") private var minSizeKB = 100
    @AppStorage("includeHidden") private var includeHidden = false
    @AppStorage("includePackages") private var includePackages = false
    @AppStorage("keepRule") private var rule: KeepRule = .oldest
    @State private var confirmTrash = false
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 240, ideal: 260)
        } detail: {
            VStack(spacing: 0) {
                mainArea.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                footer
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .onChange(of: rule) { _, newRule in model.applyRule(newRule) }
        .alert("Package folder added", isPresented: Binding(
            get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
        .confirmationDialog("Move \(model.selected.count) files to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { model.trashSelected() }
        } message: {
            Text("\(bytes(model.reclaimableBytes)) will be freed once you empty the Trash. You can restore files from the Trash at any time.")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List {
            Section {
                ForEach(model.folders, id: \.self) { url in
                    HStack {
                        Label(url.lastPathComponent, systemImage: "folder")
                        Spacer()
                        Button { model.remove(url) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove folder")
                    }
                    .help(url.path)
                    .contextMenu { Button("Remove") { model.remove(url) } }
                }
                if model.folders.isEmpty {
                    Text("No folders yet").foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Folders")
                    Spacer()
                    Button { model.chooseFolders() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("Add folder (⌘O)")
                }
            }
            Section("Options") {
                Stepper(value: $minSizeKB, in: 0...10_000_000, step: 100) {
                    Text("Min size: \(minSizeKB) KB")
                }
                Toggle("Include hidden files", isOn: $includeHidden)
                Toggle("Include packages", isOn: $includePackages)
                Picker("Auto-select", selection: $rule) {
                    ForEach(KeepRule.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .disabled(model.isScanning)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button {
                    model.scan(minSizeKB: minSizeKB, includeHidden: includeHidden,
                               includePackages: includePackages, rule: rule)
                } label: { Label("Scan", systemImage: "magnifyingglass").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.folders.isEmpty || model.isScanning)
                Button("Support / Donate ❤️") { Support.open() }
                    .buttonStyle(.link)
            }
            .padding()
        }
    }

    // MARK: Main area

    @ViewBuilder private var mainArea: some View {
        if model.isScanning {
            VStack(spacing: 16) {
                ProgressView(value: model.progress) { Text("\(model.phase.rawValue)…") }
                    .frame(maxWidth: 380)
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
            }
        } else if !model.hasScanned {
            dropZone
        } else if model.groups.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 54)).foregroundStyle(.green)
                Text("No duplicates found").font(.title2.bold())
                Text("Your folders are nice and tidy. 🎉").foregroundStyle(.secondary)
                if !model.warnings.isEmpty {
                    List { warningsSection }.frame(maxHeight: 200)
                }
            }
            .padding()
        } else {
            List {
                ForEach(model.groups) { group in GroupView(group: group) }
                warningsSection
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 48))
            Text("Drop folders to look for duplicates").font(.title3)
            Button("Choose Folders…") { model.chooseFolders() }
        }
        .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
            .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5)))
        .padding(32)
    }

    @ViewBuilder private var warningsSection: some View {
        if !model.warnings.isEmpty {
            Section {
                DisclosureGroup("Warnings (\(model.warnings.count) unreadable files)") {
                    ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(model.groups.count) groups").monospacedDigit()
            Text("·").foregroundStyle(.secondary)
            Text("\(model.selected.count) selected, \(bytes(model.reclaimableBytes)) reclaimable").monospacedDigit()
            Spacer()
            Button(role: .destructive) { confirmTrash = true } label: {
                Label("Move Selected to Trash", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(!model.canTrash)
        }
        .padding(12)
    }
}

/// One duplicate group with a disclosure triangle and a checkbox per file.
struct GroupView: View {
    @EnvironmentObject private var model: ScanModel
    let group: DuplicateGroup
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(group.files) { file in
                FileRow(file: file, isOn: Binding(
                    get: { model.isSelected(file) },
                    set: { model.setSelected(file, in: group, $0) }))
            }
        } label: {
            HStack {
                Text(group.files.first?.url.lastPathComponent ?? "Group").bold().lineLimit(1)
                Text("\(group.files.count) copies × \(bytes(group.fileSize))").foregroundStyle(.secondary)
                Spacer()
                Button("Skip Group") { model.skip(group) }.buttonStyle(.borderless)
            }
        }
    }
}

/// A single file: checkbox, icon, name, folder, date, size and Reveal in Finder.
struct FileRow: View {
    @EnvironmentObject private var model: ScanModel
    let file: FileItem
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.checkbox)
                .help(isOn ? "Will be moved to Trash" : "Will be kept")
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent).lineLimit(1)
                Text(file.url.deletingLastPathComponent().path)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if !isOn { Text("Keep").font(.caption.bold()).foregroundStyle(.green) }
            Text(file.modified, format: .dateTime.year().month().day().hour().minute())
                .font(.caption).foregroundStyle(.secondary)
            Text(bytes(file.size)).font(.caption).monospacedDigit().frame(width: 70, alignment: .trailing)
            Button { model.reveal(file) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Reveal in Finder")
        }
        .opacity(isOn ? 0.75 : 1)
    }
}

/// Formats a byte count the way Finder does.
func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}
