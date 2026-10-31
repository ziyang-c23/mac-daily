import Foundation
import CryptoKit
import Darwin

public enum CleanupKind: String, Sendable { case manual, duplicate, cache }
public struct CleanupSelection: Equatable, Sendable, Identifiable {
    public var entry: StorageEntry
    public var reason: String
    public var kind: CleanupKind
    public var retainedEntries: [StorageEntry]
    public var cacheRuleID: String?
    public var id: String { entry.path }
    public init(entry: StorageEntry, reason: String, kind: CleanupKind = .manual,
                retainedEntries: [StorageEntry] = [], cacheRuleID: String? = nil) {
        self.entry = entry; self.reason = reason; self.kind = kind
        self.retainedEntries = retainedEntries; self.cacheRuleID = cacheRuleID
    }
}
public struct CleanupPreviewItem: Sendable, Identifiable {
    public let selection: CleanupSelection
    public let allocatedBytes: Int64
    public let logicalBytes: Int64
    public var id: String { selection.id }
    public var entry: StorageEntry { selection.entry }
    public var reason: String { selection.reason }
    public var bytes: Int64 { allocatedBytes }
    let manifest: StorageManifest
}
public struct CleanupPreview: Sendable {
    public let items: [CleanupPreviewItem]
    public let issues: [String]
    public let createdAt: Date
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.allocatedBytes } }
}
public enum CleanupStatus: String, Sendable { case moved, skipped, failed }
public struct CleanupResult: Sendable, Identifiable {
    public let path: String
    public let status: CleanupStatus
    public let message: String
    public let movedBytes: Int64
    public let trashURL: URL?
    public var id: String { path }
}
public enum StorageCleanupError: LocalizedError {
    case refused(String)
    public var errorDescription: String? { if case let .refused(message) = self { return message }; return nil }
}

/// Snapshot of every directory member. Only a digest and counts are retained in memory.
struct StorageManifest: Equatable, Sendable {
    let digest: String
    let logicalBytes: Int64
    let allocatedBytes: Int64
    let count: Int
    static func capture(root: StorageEntry, allowPackages: Bool = false, isCancelled: () -> Bool) throws -> Self {
        var hasher = SHA256(), logical: Int64 = 0, allocated: Int64 = 0, count = 0
        var identities = Set<String>()
        func visit(_ entry: StorageEntry) throws {
            if isCancelled() { throw CancellationError() }
            guard !entry.isCloudPlaceholder else { throw StorageCleanupError.refused(L10n.text("目录包含云端占位文件，请在原应用管理")) }
            guard entry.volumeID == root.volumeID else { throw StorageCleanupError.refused(L10n.text("目录跨越了其他磁盘")) }
            if entry.isPackage && !allowPackages { throw StorageCleanupError.refused(L10n.text("目录包含应用或资料库包，请在原应用管理")) }
            count += 1
            hasher.update(data: Data((entry.path + "\0" + entry.metadataSignature + "\0").utf8))
            if entry.isSymlink { return } // Include the link, never its target.
            guard entry.isDirectory || entry.isRegularFile else { throw StorageCleanupError.refused(L10n.text("目录包含特殊文件，仅提供定位")) }
            if entry.isDirectory {
                let children = try FileManager.default.contentsOfDirectory(at: entry.url, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
                for url in children { try visit(StorageFileSystem.entry(at: url)) }
            } else {
                logical += entry.logicalBytes
                if identities.insert(entry.identity).inserted { allocated += entry.allocatedBytes }
            }
            let fresh = try StorageFileSystem.entry(at: entry.url)
            guard fresh.metadataSignature == entry.metadataSignature else { throw StorageCleanupError.refused(L10n.text("文件在检查时发生变化，请重新预览")) }
        }
        try visit(root)
        return Self(digest: hasher.finalize().map { String(format: "%02x", $0) }.joined(), logicalBytes: logical, allocatedBytes: allocated, count: count)
    }
}

public enum StorageSafetyPolicy {
    /// The startup Data mount and /Users expose the same user files. Normalize only
    /// this process user's actual home alias; no other /System path is admitted.
    public static func normalizedUserEntry(_ entry: StorageEntry) -> StorageEntry {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let alias = "/System/Volumes/Data" + home
        guard StorageFileSystem.isInside(path: entry.path, root: alias) else { return entry }
        let userPath = home + entry.path.dropFirst(alias.count)
        guard let current = try? StorageFileSystem.entry(at: URL(fileURLWithPath: userPath)),
              current.identity == entry.identity, current.volumeID == entry.volumeID,
              current.metadataSignature == entry.metadataSignature else { return entry }
        return current
    }

    public static func isCloudLocation(_ path: String) -> Bool {
        let p = path.lowercased()
        return p.contains("/library/cloudstorage/") || p.hasSuffix("/library/cloudstorage")
            || p.contains("/library/mobile documents/") || p.hasSuffix("/library/mobile documents")
            || p.contains("/.icloud")
    }
    public static func isProtected(_ path: String, forDuplicate: Bool = false) -> Bool {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents.map { $0.lowercased() }
        if isCloudLocation(path) { return true }
        let always: Set<String> = [".git", ".hg", ".svn", ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".trash", ".trashes", "keychains"]
        if parts.contains(where: always.contains) { return true }
        if parts.contains(where: { $0.hasSuffix(".app") || $0.hasSuffix(".photoslibrary") || $0.hasSuffix(".photolibrary") || $0.hasSuffix(".musiclibrary") || $0.hasSuffix(".pvm") || $0.hasSuffix(".vmwarevm") }) { return true }
        let protected: Set<String> = [".venv", "venv", "envs", "conda-meta", "data", "datasets", "models", "checkpoints"]
        if parts.contains(where: protected.contains) { return true }
        if ["safetensors", "ckpt", "pth", "pt"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) { return true }
        if path.hasSuffix("/Library") { return true }
        if parts.contains("caches") || parts.contains(".cache") || parts.contains("deriveddata") || parts.contains(".npm") || parts.contains(".pnpm-store")
            || path.contains("/Library/Logs/") || path.hasSuffix("/Library/Logs") {
            return true // Cache cleanup must pass its rule and busy-process checks.
        }
        let lowerPath = path.lowercased()
        if ["/library/application support", "/library/containers", "/library/group containers"].contains(where: { lowerPath.hasSuffix($0) || lowerPath.contains($0 + "/") }) { return true }
        if forDuplicate {
            if path.hasSuffix("/Library") { return true }
        if parts.contains("caches") || parts.contains(".cache") || parts.contains("node_modules") || parts.contains(".npm") || parts.contains(".build") { return true }
        }
        return false
    }
}

/// No code path permanently deletes a selected item. A failed Trash operation remains a failure.
public struct CleanupService {
    public typealias Trasher = (URL) throws -> URL?
    private let allowedRoots: [URL]
    private let cacheRules: [StorageCacheRule]
    private let busyProcessNames: () -> [String]
    private let trasher: Trasher
    public init(allowedRoots: [URL], cacheRules: [StorageCacheRule] = [], busyProcessNames: @escaping () -> [String] = { [] },
                trasher: @escaping Trasher = { url in
                    var result: NSURL?
                    try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                    return result as URL?
                }) {
        self.allowedRoots = StorageFileSystem.normalizedRoots(allowedRoots)
        self.cacheRules = cacheRules; self.busyProcessNames = busyProcessNames; self.trasher = trasher
    }
    private func cacheRule(_ selection: CleanupSelection) throws -> StorageCacheRule? {
        guard selection.kind == .cache else { return nil }
        guard let id = selection.cacheRuleID, let rule = cacheRules.first(where: { $0.id == id }), rule.canClean,
              StorageFileSystem.isInside(path: selection.entry.path, root: rule.rootPath),
              (rule.minimumAgeDays != nil || selection.entry.path == rule.rootPath) else {
            throw StorageCleanupError.refused(L10n.text("该项目不属于可清理的内置缓存规则"))
        }
        if rule.isBusy(processNames: busyProcessNames()) { throw StorageCleanupError.refused(L10n.text("相关应用或工具正在运行，请退出后重新预览")) }
        if let days = rule.minimumAgeDays {
            guard !selection.entry.isDirectory, selection.entry.modifiedAt < Date().addingTimeInterval(-Double(days) * 86400),
                  ["log", "txt", "json", "gz", "crash", "ips"].contains(selection.entry.url.pathExtension.lowercased()) else {
                throw StorageCleanupError.refused(L10n.text("日志尚未超过保留期限或类型不适用"))
            }
        }
        return rule
    }
    private func validate(_ selection: CleanupSelection, selectedPaths: Set<String>, isCancelled: () -> Bool) throws -> StorageEntry {
        if isCancelled() { throw CancellationError() }
        let path = selection.entry.path, url = selection.entry.url
        guard url.standardizedFileURL.path == path, path != "/", !StorageFileSystem.hasSymlinkAncestor(url),
              allowedRoots.contains(where: { StorageFileSystem.isInside(path: path, root: $0.path) && path != $0.path }),
              !["/System", "/Applications", "/Library", "/usr", "/bin", "/sbin", "/private", "/dev", "/Volumes"].contains(where: { StorageFileSystem.isInside(path: path, root: $0) && !$0.hasPrefix("/Volumes") }) else {
            throw StorageCleanupError.refused(L10n.text("路径不属于允许整理的个人目录，或经过符号链接"))
        }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == geteuid() else { throw StorageCleanupError.refused(L10n.text("文件不属于当前用户或已经不可访问")) }
        let current = try StorageFileSystem.entry(at: url)
        guard current.isDirectory || current.isRegularFile else { throw StorageCleanupError.refused(L10n.text("特殊文件只能定位，不能整理")) }
        guard !current.isSymlink, !current.isCloudPlaceholder,
              current.identity == selection.entry.identity, current.volumeID == selection.entry.volumeID,
              current.metadataSignature == selection.entry.metadataSignature else {
            throw StorageCleanupError.refused(L10n.text("文件已变化、被替换或不在本地，请重新扫描"))
        }
        let rule = try cacheRule(selection)
        if selection.kind != .cache && StorageSafetyPolicy.isProtected(path) {
            throw StorageCleanupError.refused(L10n.text("受保护的应用、资料库、环境或研究文件，仅提供定位"))
        }
        if rule == nil {
            guard !current.isPackage, !selection.entry.isInsidePackage else { throw StorageCleanupError.refused(L10n.text("应用或资料库包不能从此处处理")) }
            var ancestor = current.url.deletingLastPathComponent()
            while ancestor.path != "/" {
                if (try? StorageFileSystem.entry(at: ancestor).isPackage) == true {
                    throw StorageCleanupError.refused(L10n.text("文件位于应用或资料库包内，请在原应用管理"))
                }
                ancestor.deleteLastPathComponent()
            }
        }
        if selection.kind == .duplicate {
            guard !current.isDirectory else { throw StorageCleanupError.refused(L10n.text("重复文件处理不接受目录")) }
            let keepers = selection.retainedEntries.filter { !selectedPaths.contains($0.path) && $0.path != path }
            var validKeeper = false
            for keeper in keepers {
                guard !StorageFileSystem.hasSymlinkAncestor(keeper.url),
                      let fresh = try? StorageFileSystem.entry(at: keeper.url), !fresh.isSymlink, !fresh.isCloudPlaceholder,
                      fresh.metadataSignature == keeper.metadataSignature, fresh.identity != current.identity else { continue }
                do {
                    if try DuplicateFinder.contentsEqual(current, fresh, isCancelled: isCancelled) { validKeeper = true; break }
                } catch is CancellationError { throw CancellationError() }
                catch { continue }
            }
            guard validKeeper else { throw StorageCleanupError.refused(L10n.text("没有仍然有效且保留的相同副本，请重新比较")) }
        }
        return current
    }
    public func preview(_ selections: [CleanupSelection], isCancelled: () -> Bool = { false }) throws -> CleanupPreview {
        let normalized = selections.map { original in
            var value = original
            value.entry = StorageSafetyPolicy.normalizedUserEntry(value.entry)
            value.retainedEntries = value.retainedEntries.map(StorageSafetyPolicy.normalizedUserEntry)
            return value
        }
        let sorted = Dictionary(normalized.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.entry.path < $1.entry.path }
        var selected: [CleanupSelection] = [], issues: [String] = []
        for item in sorted {
            if selected.contains(where: { $0.entry.isDirectory && StorageFileSystem.isInside(path: item.entry.path, root: $0.entry.path) }) {
                issues.append(L10n.text("%@：已包含在所选父目录中", String(describing: item.entry.name))); continue
            }
            selected.append(item)
        }
        let paths = Set(selected.map(\.id))
        var items: [CleanupPreviewItem] = []
        for selection in selected {
            if isCancelled() { throw CancellationError() }
            do {
                let current = try validate(selection, selectedPaths: paths, isCancelled: isCancelled)
                let manifest = try StorageManifest.capture(root: current, allowPackages: selection.kind == .cache, isCancelled: isCancelled)
                // Manual directory selections must not smuggle a protected descendant into the batch.
                if selection.kind != .cache && current.isDirectory { try validateDescendants(current.url, isCancelled: isCancelled) }
                items.append(.init(selection: selection, allocatedBytes: manifest.allocatedBytes, logicalBytes: manifest.logicalBytes, manifest: manifest))
            } catch is CancellationError { throw CancellationError() }
            catch { issues.append("\(selection.entry.path)：\(error.localizedDescription)") }
        }
        return .init(items: items, issues: issues, createdAt: Date())
    }
    private func validateDescendants(_ root: URL, isCancelled: () -> Bool) throws {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { throw StorageCleanupError.refused(L10n.text("无法检查目录内容")) }
        for case let url as URL in walker {
            if isCancelled() { throw CancellationError() }
            let entry = try StorageFileSystem.entry(at: url)
            if StorageSafetyPolicy.isProtected(entry.path) { throw StorageCleanupError.refused(L10n.text("目录包含受保护的内容，请单独选择普通文件")) }
            if entry.isSymlink { walker.skipDescendants() }
        }
    }
    public func execute(_ preview: CleanupPreview, isCancelled: () -> Bool = { false }) -> [CleanupResult] {
        let paths = Set(preview.items.map(\.id))
        return preview.items.map { item in
            if isCancelled() { return .init(path: item.id, status: .skipped, message: L10n.text("已取消，未处理"), movedBytes: 0, trashURL: nil) }
            do {
                let current = try validate(item.selection, selectedPaths: paths, isCancelled: isCancelled)
                let manifest = try StorageManifest.capture(root: current, allowPackages: item.selection.kind == .cache, isCancelled: isCancelled)
                guard manifest == item.manifest else { throw StorageCleanupError.refused(L10n.text("预览后目录或文件内容发生变化，请重新预览")) }
                if item.selection.kind != .cache && current.isDirectory { try validateDescendants(current.url, isCancelled: isCancelled) }
                // A final identity/parent check immediately precedes the system Trash call.
                _ = try validate(item.selection, selectedPaths: paths, isCancelled: isCancelled)
                if isCancelled() { throw CancellationError() }
                let trashURL = try trasher(current.url)
                return .init(path: item.id, status: .moved, message: L10n.text("已移入废纸篓；不代表磁盘空间已释放"), movedBytes: item.allocatedBytes, trashURL: trashURL)
            } catch is CancellationError { return .init(path: item.id, status: .skipped, message: L10n.text("已取消，未处理"), movedBytes: 0, trashURL: nil) }
            catch let error as StorageCleanupError { return .init(path: item.id, status: .skipped, message: error.localizedDescription, movedBytes: 0, trashURL: nil) }
            catch { return .init(path: item.id, status: .failed, message: error.localizedDescription, movedBytes: 0, trashURL: nil) }
        }
    }
}
