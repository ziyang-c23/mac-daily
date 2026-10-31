import Foundation
import CryptoKit
import Darwin

public struct DuplicateProgress: Sendable {
    public var stage: String
    public var filesExamined: Int
    public var bytesRead: Int64
    public init(stage: String, filesExamined: Int, bytesRead: Int64) { self.stage = stage; self.filesExamined = filesExamined; self.bytesRead = bytesRead }
}
public struct DuplicateGroup: Equatable, Sendable, Identifiable {
    public var id: String
    public var members: [StorageEntry]
    public var preferredKeepPath: String
    public init(id: String, members: [StorageEntry], preferredKeepPath: String) { self.id = id; self.members = members; self.preferredKeepPath = preferredKeepPath }
    public var potentialBytes: Int64 { members.filter { $0.path != preferredKeepPath }.reduce(0) { $0 + $1.allocatedBytes } }
}
public struct DuplicateScanResult: Sendable {
    public var groups: [DuplicateGroup]
    public var skippedCount: Int
    public var issues: [String]
    public var completed: Bool
    public init(groups: [DuplicateGroup], skippedCount: Int, issues: [String], completed: Bool) {
        self.groups = groups; self.skippedCount = skippedCount; self.issues = issues; self.completed = completed
    }
}

/// Content comparisons are explicitly requested and never run as part of a size scan.
public enum DuplicateFinder {
    private static let bufferSize = 256 * 1024
    private static let maximumBucketRecords = 100_000
    public static func find(roots: [URL], excludedPaths: [String] = [], preferredKeepPaths: [String] = [], scratchDirectory: URL,
                            isCancelled: () -> Bool = { false }, progress: (DuplicateProgress) -> Void = { _ in }) throws -> DuplicateScanResult {
        let manager = FileManager.default
        let temporary = scratchDirectory.appendingPathComponent("duplicates-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) } // Only this newly created transient index.
        var handles: [Int: FileHandle] = [:], identities = Set<String>(), skipped = 0, files = 0, bytesRead: Int64 = 0, issues: [String] = []
        defer { for handle in handles.values { try? handle.close() } }
        let encoder = JSONEncoder()
        func issue(_ message: String) { if issues.count < 100 { issues.append(message) } }
        func cancelled() throws { if isCancelled() { throw CancellationError() } }
        func eligible(_ entry: StorageEntry) -> Bool {
            !entry.isSymlink && !entry.isCloudPlaceholder && !entry.isPackage && !entry.isInsidePackage
                && !StorageFileSystem.isInside(path: entry.path, root: temporary.path)
                && !StorageSafetyPolicy.isProtected(entry.path, forDuplicate: true)
                && !excludedPaths.contains(where: { StorageFileSystem.isInside(path: entry.path, root: $0) })
                && !["/System", "/Library", "/Applications", "/private", "/usr", "/bin", "/sbin", "/dev"].contains(where: { StorageFileSystem.isInside(path: entry.path, root: $0) })
        }
        func visit(_ entry: StorageEntry, volumeID: String) throws {
            try cancelled()
            guard entry.volumeID == volumeID, eligible(entry) else { skipped += 1; return }
            if entry.isDirectory {
                // Environment roots are recognized by markers too, regardless of their directory name.
                if manager.fileExists(atPath: entry.url.appendingPathComponent("pyvenv.cfg").path)
                    || manager.fileExists(atPath: entry.url.appendingPathComponent("conda-meta").path) { skipped += 1; return }
                do {
                    for child in try manager.contentsOfDirectory(at: entry.url, includingPropertiesForKeys: nil) {
                        try cancelled()
                        do { try visit(StorageFileSystem.entry(at: child), volumeID: volumeID) }
                        catch is CancellationError { throw CancellationError() }
                        catch { skipped += 1; issue("\(child.path)：\(error.localizedDescription)") }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { skipped += 1; issue("\(entry.path)：\(error.localizedDescription)") }
            } else if entry.isRegularFile, entry.logicalBytes > 0 {
                guard identities.insert(entry.identity).inserted else { skipped += 1; return }
                let bucket = Int(UInt64(entry.logicalBytes) % 64)
                let handle: FileHandle
                if let existing = handles[bucket] { handle = existing }
                else {
                    let url = temporary.appendingPathComponent("\(bucket).jsonl")
                    guard manager.createFile(atPath: url.path, contents: nil) else { throw StorageError.unavailable(L10n.text("无法创建重复比较临时索引")) }
                    handle = try FileHandle(forWritingTo: url); handles[bucket] = handle
                }
                var line = try encoder.encode(entry); line.append(10); try handle.write(contentsOf: line)
                files += 1
                if files.isMultiple(of: 256) { progress(.init(stage: L10n.text("检查文件大小"), filesExamined: files, bytesRead: bytesRead)) }
            } else { skipped += 1 }
        }
        for url in StorageFileSystem.normalizedRoots(roots) {
            try cancelled()
            do {
                let entry = StorageSafetyPolicy.normalizedUserEntry(try StorageFileSystem.entry(at: url))
                guard entry.isDirectory, !StorageFileSystem.hasSymlinkAncestor(entry.url) else { skipped += 1; issue(L10n.text("%@：不是可比较的本地目录", String(describing: url.path))); continue }
                try visit(entry, volumeID: entry.volumeID)
            } catch is CancellationError { throw CancellationError() }
            catch { skipped += 1; issue("\(url.path)：\(error.localizedDescription)") }
        }
        for handle in handles.values { try handle.close() }; handles.removeAll()
        progress(.init(stage: L10n.text("按大小筛选"), filesExamined: files, bytesRead: bytesRead))
        var groups: [DuplicateGroup] = []
        for bucket in 0..<64 {
            try cancelled()
            let url = temporary.appendingPathComponent("\(bucket).jsonl")
            guard manager.fileExists(atPath: url.path) else { continue }
            var bySize: [Int64: [StorageEntry]] = [:], records = 0
            try forEachEntry(in: url) { entry in
                try cancelled()
                records += 1
                guard records <= maximumBucketRecords else { throw StorageError.unavailable(L10n.text("同一批次候选过多，请缩小重复文件比较范围")) }
                bySize[entry.logicalBytes, default: []].append(entry)
            }
            for members in bySize.values where members.count > 1 {
                try cancelled()
                var bySample: [String: [StorageEntry]] = [:]
                for entry in members {
                    do {
                        let hash = try digest(entry, sampleOnly: true, isCancelled: isCancelled, bytesRead: &bytesRead)
                        bySample[hash, default: []].append(entry)
                    } catch is CancellationError { throw CancellationError() }
                    catch { skipped += 1; issue("\(entry.path)：\(error.localizedDescription)") }
                }
                progress(.init(stage: L10n.text("分段筛选"), filesExamined: files, bytesRead: bytesRead))
                for sampled in bySample.values where sampled.count > 1 {
                    var byFull: [String: [StorageEntry]] = [:]
                    for entry in sampled {
                        do {
                            let hash = try digest(entry, sampleOnly: false, isCancelled: isCancelled, bytesRead: &bytesRead)
                            byFull[hash, default: []].append(entry)
                        } catch is CancellationError { throw CancellationError() }
                        catch { skipped += 1; issue("\(entry.path)：\(error.localizedDescription)") }
                    }
                    progress(.init(stage: L10n.text("完整内容核验"), filesExamined: files, bytesRead: bytesRead))
                    for (hash, hashed) in byFull where hashed.count > 1 {
                        var pending = hashed.sorted { $0.path < $1.path }
                        while let reference = pending.first {
                            pending.removeFirst()
                            var equal = [reference], different: [StorageEntry] = []
                            for entry in pending {
                                do {
                                    if try contentsEqual(reference, entry, isCancelled: isCancelled) { equal.append(entry); bytesRead += entry.logicalBytes * 2 }
                                    else { different.append(entry) }
                                } catch is CancellationError { throw CancellationError() }
                                catch { skipped += 1; issue("\(entry.path)：\(error.localizedDescription)") }
                            }
                            pending = different
                            guard equal.count > 1 else { continue }
                            equal.sort { left, right in
                                let a = preferredKeepPaths.contains { StorageFileSystem.isInside(path: left.path, root: $0) }
                                let b = preferredKeepPaths.contains { StorageFileSystem.isInside(path: right.path, root: $0) }
                                return a == b ? left.path < right.path : a
                            }
                            groups.append(.init(id: hash + ":" + reference.identity, members: equal, preferredKeepPath: equal[0].path))
                        }
                    }
                }
            }
        }
        progress(.init(stage: L10n.text("比较完成"), filesExamined: files, bytesRead: bytesRead))
        return .init(groups: groups.sorted { $0.potentialBytes > $1.potentialBytes }, skippedCount: skipped, issues: issues, completed: true)
    }

    private static func forEachEntry(in url: URL, _ body: (StorageEntry) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var pending = Data(); let decoder = JSONDecoder()
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            pending.append(data)
            while let newline = pending.firstIndex(of: 10) {
                let line = pending[..<newline]
                if !line.isEmpty { try body(decoder.decode(StorageEntry.self, from: Data(line))) }
                pending.removeSubrange(...newline)
            }
            guard pending.count < 4 * 1024 * 1024 else { throw StorageError.invalidIndex(L10n.text("重复文件索引记录过长")) }
        }
        if !pending.isEmpty { try body(decoder.decode(StorageEntry.self, from: pending)) }
    }
    private static func openStable(_ entry: StorageEntry) throws -> FileHandle {
        guard entry.isRegularFile, !entry.isDirectory, !entry.isSymlink, !entry.isCloudPlaceholder,
              !StorageSafetyPolicy.isCloudLocation(entry.path), !StorageFileSystem.hasSymlinkAncestor(entry.url),
              try StorageFileSystem.entry(at: entry.url).metadataSignature == entry.metadataSignature else {
            throw StorageCleanupError.refused(L10n.text("文件发生变化或不能在本地安全读取"))
        }
        let descriptor = open(entry.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              "\(info.st_dev):\(info.st_ino)" == entry.identity, info.st_size == entry.logicalBytes,
              UInt32(info.st_flags) & 0x40000000 == 0 else {
            close(descriptor); throw StorageCleanupError.refused(L10n.text("文件已被替换或不在本地"))
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    private static func ensureUnchanged(_ entry: StorageEntry) throws {
        guard try StorageFileSystem.entry(at: entry.url).metadataSignature == entry.metadataSignature else {
            throw StorageCleanupError.refused(L10n.text("读取期间文件发生变化，请重新比较"))
        }
    }
    private static func digest(_ entry: StorageEntry, sampleOnly: Bool, isCancelled: () -> Bool, bytesRead: inout Int64) throws -> String {
        let handle = try openStable(entry); defer { try? handle.close() }
        var hasher = SHA256()
        if sampleOnly && entry.logicalBytes > 128 * 1024 {
            for offset in [UInt64(0), UInt64(entry.logicalBytes - 64 * 1024)] {
                if isCancelled() { throw CancellationError() }
                try handle.seek(toOffset: offset)
                let data = try handle.read(upToCount: 64 * 1024) ?? Data()
                guard data.count == 64 * 1024 else { throw StorageCleanupError.refused(L10n.text("文件长度已变化")) }
                hasher.update(data: data); bytesRead += Int64(data.count)
            }
        } else {
            while let data = try handle.read(upToCount: bufferSize), !data.isEmpty {
                if isCancelled() { throw CancellationError() }
                hasher.update(data: data); bytesRead += Int64(data.count)
            }
        }
        try ensureUnchanged(entry)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func contentsEqual(_ lhs: StorageEntry, _ rhs: StorageEntry, isCancelled: () -> Bool = { false }) throws -> Bool {
        guard lhs.logicalBytes == rhs.logicalBytes, lhs.identity != rhs.identity else { return false }
        let left = try openStable(lhs), right = try openStable(rhs)
        defer { try? left.close(); try? right.close() }
        var equal = true
        while true {
            if isCancelled() { throw CancellationError() }
            let a = try left.read(upToCount: bufferSize) ?? Data(), b = try right.read(upToCount: bufferSize) ?? Data()
            if a != b { equal = false; break }
            if a.isEmpty { break }
        }
        try ensureUnchanged(lhs); try ensureUnchanged(rhs)
        return equal
    }
}
