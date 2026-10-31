import Foundation

struct StorageIndexRecord: Codable {
    var entry: StorageEntry
    var logicalBytes: Int64
    var allocatedBytes: Int64
}

public enum StorageScanner {
    private static func prepareIndexDirectory(_ url: URL) throws {
        var parent = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.pathComponents.dropFirst() {
            parent.appendPathComponent(component, isDirectory: true)
            do {
                let entry = try StorageFileSystem.entry(at: parent)
                guard entry.isDirectory, !entry.isSymlink else { throw StorageError.invalidIndex(parent.path) }
            } catch let error as POSIXError where error.code == .ENOENT {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
                let entry = try StorageFileSystem.entry(at: parent)
                guard entry.isDirectory, !entry.isSymlink else { throw StorageError.invalidIndex(parent.path) }
            }
        }
    }
    /// A bounded metadata scan. The caller owns the explicit, disposable index directory.
    /// Results never contain a retained array of every file; chunks are paged from disk.
    public static func scan(root: URL, indexDirectory: URL, excludedPaths: [String] = [],
                            isCancelled: () -> Bool = { false },
                            progress: (StorageScanProgress) -> Void = { _ in }) throws -> StorageScanResult {
        let manager = FileManager.default, root = root.standardizedFileURL, indexDirectory = indexDirectory.standardizedFileURL
        let rootEntry = try StorageFileSystem.entry(at: root)
        guard root.isFileURL, rootEntry.isDirectory, !rootEntry.isSymlink, !rootEntry.isCloudPlaceholder,
              !StorageFileSystem.hasSymlinkAncestor(root) else { throw StorageError.invalidRoot(root.path) }
        guard (try? root.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) != false else {
            throw StorageError.invalidRoot(L10n.text("首版仅扫描本地磁盘"))
        }
        guard !StorageFileSystem.isInside(path: root.path, root: indexDirectory.path) else { throw StorageError.invalidIndex(indexDirectory.path) }
        try prepareIndexDirectory(indexDirectory)
        if manager.fileExists(atPath: indexDirectory.path) {
            let contents = try manager.contentsOfDirectory(atPath: indexDirectory.path)
            if !contents.isEmpty {
                let markerURL = indexDirectory.appendingPathComponent(".macdaily-session")
                let expected = Data("MacDaily storage session".utf8)
                guard contents == [".macdaily-session"],
                      let marker = try? StorageFileSystem.entry(at: markerURL), marker.isRegularFile, !marker.isSymlink,
                      marker.logicalBytes == expected.count else { throw StorageError.invalidIndex(L10n.text("请使用新的扫描目录")) }
                let file = try FileHandle(forReadingFrom: markerURL); defer { try? file.close() }
                guard try file.read(upToCount: expected.count + 1) == expected,
                      try StorageFileSystem.entry(at: markerURL).metadataSignature == marker.metadataSignature else {
                    throw StorageError.invalidIndex(L10n.text("扫描目录标记无效"))
                }
            }
        } else { try manager.createDirectory(at: indexDirectory, withIntermediateDirectories: true) }
        var coverage = StorageCoverage()
        var directories: [String: StorageItem] = [root.path: StorageItem(entry: rootEntry)]
        var seen = Set<String>(), chunks: [URL] = [], buffer = Data(), bufferedRecords = 0
        var logical: Int64 = 0, allocated: Int64 = 0
        var lastProgress = Date.distantPast
        let encoder = JSONEncoder()
        let exclusions = StorageFileSystem.normalizedRoots(excludedPaths.map { URL(fileURLWithPath: $0) }).map(\.path)
        func flush() throws {
            guard !buffer.isEmpty else { return }
            let url = indexDirectory.appendingPathComponent(String(format: "entries-%06d.jsonl", chunks.count))
            try buffer.write(to: url, options: .withoutOverwriting)
            chunks.append(url); buffer.removeAll(keepingCapacity: true); bufferedRecords = 0
        }
        func write(_ entry: StorageEntry, logical: Int64, allocated: Int64) throws {
            buffer.append(try encoder.encode(StorageIndexRecord(entry: entry, logicalBytes: logical, allocatedBytes: allocated)))
            buffer.append(10); bufferedRecords += 1
            if bufferedRecords >= 2048 { try flush() }
        }
        func addError(_ path: String, _ error: Error) {
            coverage.errors += 1
            if coverage.errorSamples.count < 20 { coverage.errorSamples.append("\(path)：\(error.localizedDescription)") }
        }
        func publish(_ path: String, force: Bool = false) {
            if force || Date().timeIntervalSince(lastProgress) >= 0.15 {
                progress(.init(files: coverage.files, directories: coverage.directories, logicalBytes: logical,
                               allocatedBytes: allocated, currentPath: path)); lastProgress = Date()
            }
        }
        guard let iterator = manager.enumerator(at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { url, error in
            addError(url.path, error); return true
        }) else { throw StorageError.invalidRoot(root.path) }
        var packagePaths = rootEntry.isPackage ? Set([root.path]) : Set<String>()
        func consumeURL(_ url: URL) throws {
            let path = url.standardizedFileURL.path
            if StorageFileSystem.isInside(path: path, root: indexDirectory.path) || exclusions.contains(where: { StorageFileSystem.isInside(path: path, root: $0) }) {
                coverage.skippedExcluded += 1; iterator.skipDescendants(); return
            }
            var entry: StorageEntry
            do { entry = try StorageFileSystem.entry(at: url) }
            catch { addError(path, error); iterator.skipDescendants(); return }
            guard entry.volumeID == rootEntry.volumeID else { coverage.skippedMounts += 1; iterator.skipDescendants(); return }
            if entry.isSymlink { coverage.skippedSymlinks += 1; iterator.skipDescendants(); return }
            var parent = url.deletingLastPathComponent()
            var insidePackage = false
            while StorageFileSystem.isInside(path: parent.path, root: root.path) {
                if packagePaths.contains(parent.path) { insidePackage = true; break }
                if parent.path == root.path { break }; parent.deleteLastPathComponent()
            }
            entry.isInsidePackage = insidePackage
            if entry.isDirectory {
                coverage.directories += 1
                directories[path] = StorageItem(entry: entry)
                if entry.isPackage { packagePaths.insert(path) }
                if entry.isCloudPlaceholder { coverage.skippedCloudFiles += 1; iterator.skipDescendants() }
                publish(path); return
            }
            guard entry.isRegularFile else { coverage.skippedExcluded += 1; return }
            coverage.files += 1
            if entry.isCloudPlaceholder { coverage.skippedCloudFiles += 1 }
            let fileAllocated = entry.linkCount <= 1 || seen.insert(entry.identity).inserted ? entry.allocatedBytes : 0
            // Logical size is per directory entry; hard links share allocation.
            logical += entry.logicalBytes; allocated += fileAllocated
            var ancestor = url.deletingLastPathComponent()
            while StorageFileSystem.isInside(path: ancestor.path, root: root.path) {
                if var item = directories[ancestor.path] {
                    item.logicalBytes += entry.logicalBytes; item.allocatedBytes += fileAllocated
                    directories[ancestor.path] = item
                }
                if ancestor.path == root.path { break }; ancestor.deleteLastPathComponent()
            }
            try write(entry, logical: entry.logicalBytes, allocated: fileAllocated)
            publish(path)
        }
        while let url = iterator.nextObject() as? URL {
            if isCancelled() { coverage.cancelled = true; break }
            try autoreleasepool { try consumeURL(url) }
        }
        try flush()
        coverage.completed = !coverage.cancelled
        publish(root.path, force: true)
        return .init(rootURL: root, indexDirectory: indexDirectory, root: directories[root.path] ?? StorageItem(entry: rootEntry),
                     directories: directories, totalLogicalBytes: logical, totalAllocatedBytes: allocated,
                     coverage: coverage, finishedAt: Date(), indexFiles: chunks)
    }
}

public enum StorageIndex {
    public static func query(result: StorageScanResult, directory: URL? = nil, query: StorageQuery = .init()) throws -> StoragePage {
        guard query.offset >= 0, (1...1000).contains(query.limit), query.offset <= 10_000_000,
              query.minimumLogicalBytes >= 0 else { throw StorageError.invalidIndex(L10n.text("分页参数无效")) }
        let directoryPath = directory?.standardizedFileURL.path
        if let directoryPath, !StorageFileSystem.isInside(path: directoryPath, root: result.rootURL.path) {
            throw StorageError.invalidIndex(L10n.text("目录不属于此次扫描"))
        }
        let retainedCount = query.offset + query.limit
        var heap = StorageItemHeap(capacity: retainedCount, better: { better($0, than: $1, query: query) })
        var total = 0
        func accept(_ item: StorageItem) {
            guard item.logicalBytes >= query.minimumLogicalBytes,
                  query.search.isEmpty || item.path.localizedCaseInsensitiveContains(query.search),
                  query.fileExtension.isEmpty || item.url.pathExtension.caseInsensitiveCompare(query.fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))) == .orderedSame,
                  query.modifiedBefore == nil || item.entry.modifiedAt < query.modifiedBefore! else { return }
            total += 1; heap.insert(item)
        }
        if let directoryPath {
            for (path, item) in result.directories where path != result.rootURL.path && item.url.deletingLastPathComponent().path == directoryPath {
                accept(item)
            }
        }
        for file in result.indexFiles {
            try records(in: file) { record in
                if let directoryPath {
                    guard record.entry.url.deletingLastPathComponent().path == directoryPath else { return }
                } else if record.entry.isInsidePackage { return }
                accept(StorageItem(entry: record.entry, logicalBytes: record.logicalBytes, allocatedBytes: record.allocatedBytes))
            }
        }
        let sorted = heap.items.sorted { better($0, than: $1, query: query) }
        return StoragePage(items: Array(sorted.dropFirst(query.offset).prefix(query.limit)), totalCount: total)
    }
    private static func better(_ a: StorageItem, than b: StorageItem, query: StorageQuery) -> Bool {
        switch query.sort {
        case .sizeDescending: if a.bytes(for: query.metric) != b.bytes(for: query.metric) { return a.bytes(for: query.metric) > b.bytes(for: query.metric) }
        case .sizeAscending: if a.bytes(for: query.metric) != b.bytes(for: query.metric) { return a.bytes(for: query.metric) < b.bytes(for: query.metric) }
        case .name: if a.name != b.name { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
        case .modifiedNewest: if a.entry.modifiedAt != b.entry.modifiedAt { return a.entry.modifiedAt > b.entry.modifiedAt }
        case .modifiedOldest: if a.entry.modifiedAt != b.entry.modifiedAt { return a.entry.modifiedAt < b.entry.modifiedAt }
        }
        return a.path < b.path
    }
    private static func records(in url: URL, consume: (StorageIndexRecord) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let decoder = JSONDecoder()
        var data = Data()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            data.append(chunk)
            while let newline = data.firstIndex(of: 10) {
                let line = data[..<newline]
                if !line.isEmpty { try consume(decoder.decode(StorageIndexRecord.self, from: line)) }
                data.removeSubrange(...newline)
            }
            guard data.count <= 1_048_576 else { throw StorageError.invalidIndex(L10n.text("索引条目过长")) }
        }
        guard data.isEmpty else { throw StorageError.invalidIndex(L10n.text("扫描索引不完整")) }
    }
}

private struct StorageItemHeap {
    var items: [StorageItem] = []
    let capacity: Int
    let better: (StorageItem, StorageItem) -> Bool
    mutating func insert(_ item: StorageItem) {
        guard capacity > 0 else { return }
        if items.count < capacity {
            items.append(item); var index = items.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard better(items[parent], items[index]) else { break }
                items.swapAt(index, parent); index = parent
            }
        } else if better(item, items[0]) {
            items[0] = item; var index = 0
            while true {
                let left = index * 2 + 1, right = left + 1
                guard left < items.count else { break }
                var worst = left
                if right < items.count, better(items[left], items[right]) { worst = right }
                guard better(items[index], items[worst]) else { break }
                items.swapAt(index, worst); index = worst
            }
        }
    }
}
