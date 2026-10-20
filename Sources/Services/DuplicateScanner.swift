import Foundation
import CryptoKit

/// A regular file found during enumeration.
struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let size: Int64
    let modified: Date
    /// Index of the scanned root folder this file was found under.
    let rootIndex: Int
    var id: URL { url }
}

/// A set of files with byte-identical content.
struct DuplicateGroup: Identifiable, Sendable {
    let id = UUID()
    var files: [FileItem]
    var fileSize: Int64 { files.first?.size ?? 0 }
}

/// Scan pipeline phases shown in the progress UI.
enum ScanPhase: String, Sendable {
    case sizing = "Sizing", sampling = "Sampling", hashing = "Hashing"
}

/// User-chosen scan parameters.
struct ScanOptions: Sendable {
    var roots: [URL]
    var minSize: Int64
    var includeHidden: Bool
    var includePackages: Bool
}

/// Result of a completed scan.
struct ScanOutput: Sendable {
    var groups: [DuplicateGroup]
    var warnings: [String]
}

/// Finds exact duplicates: groups by size, then a head+tail sample hash, then a full streaming SHA-256.
enum DuplicateScanner {
    private static let chunkSize = 1 << 20
    private static let sampleSize = 64 * 1024

    static func scan(_ options: ScanOptions,
                     progress: @escaping @Sendable (ScanPhase, Double) -> Void) async throws -> ScanOutput {
        progress(.sizing, 0)
        var (files, warnings) = try enumerate(options)
        let sameSize = Dictionary(grouping: files, by: \.size).values.filter { $0.count > 1 }.flatMap { $0 }
        files = []

        let (sampled, sampleWarnings) = try await hashAll(sameSize, phase: .sampling, full: false, progress: progress)
        warnings += sampleWarnings
        let candidates = regroup(sampled).flatMap { $0 }

        let (hashed, hashWarnings) = try await hashAll(candidates, phase: .hashing, full: true, progress: progress)
        warnings += hashWarnings
        let groups = regroup(hashed)
            .map { files in DuplicateGroup(files: files.sorted { $0.url.path < $1.url.path }) }
            .sorted { (a: DuplicateGroup, b: DuplicateGroup) -> Bool in wasted(a) > wasted(b) }
        return ScanOutput(groups: groups, warnings: warnings)
    }

    private static func wasted(_ group: DuplicateGroup) -> Int64 {
        group.fileSize * Int64(group.files.count - 1)
    }

    /// Groups (file, digest) pairs by size+digest, keeping only groups with 2+ members.
    private static func regroup(_ pairs: [(FileItem, String)]) -> [[FileItem]] {
        Dictionary(grouping: pairs, by: { "\($0.0.size):\($0.1)" })
            .values.filter { $0.count > 1 }.map { $0.map(\.0) }
    }

    /// Walks every root, skipping links, aliases, empty files and hard-link twins.
    private static func enumerate(_ options: ScanOptions) throws -> ([FileItem], [String]) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey,
                                      .fileSizeKey, .contentModificationDateKey]
        var enumOptions: FileManager.DirectoryEnumerationOptions = []
        if !options.includeHidden { enumOptions.insert(.skipsHiddenFiles) }
        if !options.includePackages { enumOptions.insert(.skipsPackageDescendants) }

        struct Inode: Hashable { let dev: Int32; let ino: UInt64 }
        final class Box { var warnings: [String] = [] }
        let box = Box()
        var seen = Set<Inode>()
        var files: [FileItem] = []
        var visited = 0

        for (index, root) in options.roots.enumerated() {
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: enumOptions,
                errorHandler: { url, error in
                    box.warnings.append("\(url.path): \(error.localizedDescription)")
                    return true
                }) else {
                box.warnings.append("\(root.path): could not be read")
                continue
            }
            while let url = walker.nextObject() as? URL {
                visited += 1
                if visited % 256 == 0 { try Task.checkCancellation() }
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isSymbolicLink != true, values.isAliasFile != true,
                      values.isRegularFile == true,
                      let size = values.fileSize, size > 0, Int64(size) >= options.minSize else { continue }
                var info = stat()
                guard lstat(url.path, &info) == 0,
                      seen.insert(Inode(dev: info.st_dev, ino: info.st_ino)).inserted else { continue }
                files.append(FileItem(url: url, size: Int64(size),
                                      modified: values.contentModificationDate ?? .distantPast,
                                      rootIndex: index))
            }
        }
        return (files, box.warnings)
    }

    /// Hashes files in parallel with bounded concurrency; changed or vanished files are dropped.
    private static func hashAll(_ items: [FileItem], phase: ScanPhase, full: Bool,
                                progress: @escaping @Sendable (ScanPhase, Double) -> Void)
    async throws -> ([(FileItem, String)], [String]) {
        progress(phase, 0)
        guard !items.isEmpty else { return ([], []) }
        let limit = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
        var results: [(FileItem, String)] = []
        var warnings: [String] = []

        try await withThrowingTaskGroup(of: (FileItem, Result<String?, Error>).self) { group in
            var next = 0
            var done = 0
            while next < min(limit, items.count) {
                let item = items[next]
                group.addTask { (item, Result { try digest(item, full: full) }) }
                next += 1
            }
            while let (item, result) = try await group.next() {
                try Task.checkCancellation()
                done += 1
                if done % 8 == 0 || done == items.count { progress(phase, Double(done) / Double(items.count)) }
                switch result {
                case .success(let hash?): results.append((item, hash))
                case .success(nil): break
                case .failure(let error): warnings.append("\(item.url.path): \(error.localizedDescription)")
                }
                if next < items.count {
                    let item = items[next]
                    group.addTask { (item, Result { try digest(item, full: full) }) }
                    next += 1
                }
            }
        }
        return (results, warnings)
    }

    /// SHA-256 of the whole file (full) or of its first and last 64 KB (sample).
    /// Returns nil when the file vanished or changed since enumeration.
    private static func digest(_ item: FileItem, full: Bool) throws -> String? {
        guard FileManager.default.fileExists(atPath: item.url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: item.url)
        defer { try? handle.close() }
        var hasher = SHA256()
        if full || item.size <= Int64(sampleSize * 2) {
            while true {
                if Task.isCancelled { throw CancellationError() }
                guard let data = try handle.read(upToCount: full ? chunkSize : sampleSize * 2),
                      !data.isEmpty else { break }
                hasher.update(data: data)
            }
        } else {
            if let head = try handle.read(upToCount: sampleSize) { hasher.update(data: head) }
            try handle.seek(toOffset: UInt64(item.size) - UInt64(sampleSize))
            if let tail = try handle.read(upToCount: sampleSize) { hasher.update(data: tail) }
        }
        let now = try? item.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let now, Int64(now.fileSize ?? -1) == item.size,
              (now.contentModificationDate ?? .distantPast) == item.modified else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
