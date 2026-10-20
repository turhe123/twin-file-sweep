import SwiftUI
import AppKit

/// Which copy in each group is kept when extras are auto-selected.
enum KeepRule: String, CaseIterable, Identifiable {
    case oldest, newest, shortestPath, firstFolder
    var id: String { rawValue }
    var title: String {
        switch self {
        case .oldest: "Keep oldest"
        case .newest: "Keep newest"
        case .shortestPath: "Keep shortest path"
        case .firstFolder: "Keep first folder added"
        }
    }
}

/// Owns folders, scan state, results and selection; enforces the keep-one safety rule.
@MainActor
final class ScanModel: ObservableObject {
    @Published var folders: [URL] = [] { didSet { saveFolders() } }
    @Published private(set) var groups: [DuplicateGroup] = []
    @Published private(set) var selected: Set<URL> = []
    @Published private(set) var warnings: [String] = []
    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false
    @Published private(set) var phase: ScanPhase = .sizing
    @Published private(set) var progress: Double = 0
    @Published var notice: String?

    private var scanTask: Task<Void, Never>?
    private var scanID = UUID()
    private static let foldersKey = "folders"

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.foldersKey) ?? []
        folders = paths.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func saveFolders() {
        UserDefaults.standard.set(folders.map(\.path), forKey: Self.foldersKey)
    }

    // MARK: Folders

    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func add(_ urls: [URL]) {
        var packageNames: [String] = []
        for url in urls.map({ $0.standardizedFileURL }) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
                  !folders.contains(url) else { continue }
            let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
            if isPackage || ["app", "photoslibrary"].contains(url.pathExtension.lowercased()) {
                packageNames.append(url.lastPathComponent)
            }
            folders.append(url)
        }
        if !packageNames.isEmpty {
            notice = "\(packageNames.joined(separator: ", ")) is an app bundle or library package. "
                + "Removing files from inside it can break the app or library, so review results carefully."
        }
    }

    func remove(_ url: URL) { folders.removeAll { $0 == url } }

    // MARK: Scanning

    func scan(minSizeKB: Int, includeHidden: Bool, includePackages: Bool, rule: KeepRule) {
        guard !folders.isEmpty, !isScanning else { return }
        groups = []; selected = []; warnings = []
        isScanning = true; progress = 0; phase = .sizing
        let options = ScanOptions(roots: folders, minSize: Int64(max(0, minSizeKB)) * 1024,
                                  includeHidden: includeHidden, includePackages: includePackages)
        let id = UUID()
        scanID = id
        scanTask = Task {
            do {
                let output = try await DuplicateScanner.scan(options) { [self] phase, fraction in
                    Task { @MainActor in
                        guard self.isScanning, self.scanID == id else { return }
                        self.phase = phase
                        self.progress = fraction
                    }
                }
                guard scanID == id, !Task.isCancelled else { return }
                groups = output.groups
                warnings = output.warnings
                hasScanned = true
                applyRule(rule)
                isScanning = false
            } catch {
                guard scanID == id else { return }
                isScanning = false
            }
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        scanID = UUID()
        isScanning = false
    }

    // MARK: Selection

    /// Selects every file except the keeper chosen by `rule`.
    func applyRule(_ rule: KeepRule) {
        var newSelection = Set<URL>()
        for group in groups {
            guard let keep = keeper(in: group, rule: rule) else { continue }
            for file in group.files where file.url != keep.url { newSelection.insert(file.url) }
        }
        selected = newSelection
    }

    private func keeper(in group: DuplicateGroup, rule: KeepRule) -> FileItem? {
        let files = group.files
        switch rule {
        case .oldest: return files.min { $0.modified < $1.modified }
        case .newest: return files.max { $0.modified < $1.modified }
        case .shortestPath:
            return files.min { ($0.url.path.count, $0.url.path) < ($1.url.path.count, $1.url.path) }
        case .firstFolder:
            return files.min { ($0.rootIndex, $0.url.path) < ($1.rootIndex, $1.url.path) }
        }
    }

    func isSelected(_ file: FileItem) -> Bool { selected.contains(file.url) }

    /// Toggles a file, refusing to select the last unselected copy of a group.
    func setSelected(_ file: FileItem, in group: DuplicateGroup, _ value: Bool) {
        if value {
            let remaining = group.files.filter { !selected.contains($0.url) && $0.url != file.url }
            guard !remaining.isEmpty else { NSSound.beep(); return }
            selected.insert(file.url)
        } else {
            selected.remove(file.url)
        }
    }

    /// True only when something is selected and every group keeps at least one copy.
    var canTrash: Bool {
        !selected.isEmpty && !isScanning
            && groups.allSatisfy { group in group.files.contains { !selected.contains($0.url) } }
    }

    var reclaimableBytes: Int64 {
        groups.reduce(0) { sum, group in
            sum + group.files.filter { selected.contains($0.url) }.reduce(0) { $0 + $1.size }
        }
    }

    func skip(_ group: DuplicateGroup) {
        for file in group.files { selected.remove(file.url) }
        groups.removeAll { $0.id == group.id }
    }

    func reveal(_ file: FileItem) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    /// Moves selected files to the Trash; failures become warnings.
    func trashSelected() {
        guard canTrash else { return }
        var trashed = Set<URL>()
        for url in selected {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                trashed.insert(url)
            } catch {
                warnings.append("\(url.path): \(error.localizedDescription)")
            }
        }
        selected.subtract(trashed)
        groups = groups.compactMap { group in
            var group = group
            group.files.removeAll { trashed.contains($0.url) }
            return group.files.count > 1 ? group : nil
        }
        let valid = Set(groups.flatMap { $0.files.map(\.url) })
        selected.formIntersection(valid)
    }
}
