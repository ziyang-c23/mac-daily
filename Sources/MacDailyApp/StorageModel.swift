import AppKit
import Combine
import Foundation
import MacDailyCore
import Quartz

/// Shared cancellation survives Task.detached boundaries; no timer is installed while idle.
private final class StorageCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

enum StoragePane: String, CaseIterable, Identifiable {
    case overview = "概览", large = "大文件", duplicates = "重复文件", caches = "缓存整理"
    var id: String { rawValue }
}

@MainActor
final class StorageModel: ObservableObject {
    @Published var pane: StoragePane = .overview
    @Published private(set) var volumes: [StorageVolume] = []
    @Published var selectedVolumeID = ""
    @Published private(set) var selectedRoot: URL?
    @Published private(set) var result: StorageScanResult?
    @Published private(set) var directory: URL?
    @Published private(set) var rows: [StorageItem] = []
    @Published private(set) var mapRows: [StorageItem] = []
    @Published private(set) var rowCount = 0
    @Published var selectedPath: String?
    @Published var search = ""
    @Published var fileExtension = ""
    @Published var modifiedFilter = 0
    @Published var sort: StorageSort = .sizeDescending
    @Published private(set) var pageIndex = 0
    @Published private(set) var querying = false
    @Published private(set) var busy = false
    @Published private(set) var status = L10n.text("选择磁盘或文件夹，点击扫描后查看占用。")
    @Published private(set) var progressText = ""
    @Published var error: String?
    @Published private(set) var duplicateRoots: [URL] = []
    @Published private(set) var duplicateGroups: [DuplicateGroup] = []
    @Published var duplicateKeepers: [String: String] = [:]
    @Published private(set) var duplicateIssues: [String] = []
    @Published private(set) var cacheCandidates: [StorageCacheCandidate] = []
    @Published private(set) var cacheRules: [StorageCacheRule] = []
    @Published private(set) var pending: [CleanupSelection] = []
    @Published private(set) var preview: CleanupPreview?
    @Published private(set) var cleanupResults: [CleanupResult] = []
    @Published var showingReview = false
    @Published var settings = StorageSettings()
    private var task: Task<Void, Never>?
    private var queryTask: Task<Void, Never>?
    private var cancellation: StorageCancellation?
    private var generation = 0
    private var queryGeneration = 0
    private var sessions = Set<URL>()
    private var prepared = false
    private var explicitlyAllowedRoots: [URL] = []
    let pageSize = 100

    var selectedVolume: StorageVolume? { volumes.first { $0.id == selectedVolumeID } }
    var selectedItem: StorageItem? { rows.first { $0.path == selectedPath } }
    var pendingCount: Int { pending.count }
    var hasNextPage: Bool { (pageIndex + 1) * pageSize < rowCount }
    var sessionBase: URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["MACDAILY_STORAGE_TMP"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        if let path = environment["MACDAILY_DATA_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("StorageSessions", isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacDaily/StorageSessions", isDirectory: true)
    }

    func prepare(settings: StorageSettings) {
        self.settings = settings
        guard !prepared else { return }
        prepared = true
        let manager = FileManager.default
        duplicateRoots = [manager.urls(for: .documentDirectory, in: .userDomainMask).first,
                          manager.urls(for: .downloadsDirectory, in: .userDomainMask).first].compactMap { $0 }
        refreshVolumes()
    }

    func refreshVolumes() {
        Task { [weak self] in
            let catalog = await Task.detached(priority: .utility) { StorageVolume.catalog() }.value
            guard let self else { return }
            self.volumes = catalog
            if self.selectedRoot == nil, let first = catalog.first {
                self.selectedVolumeID = first.id
                self.selectedRoot = first.rootURL
            }
        }
    }

    func selectVolume(_ id: String) {
        guard let volume = volumes.first(where: { $0.id == id }) else { return }
        clearResults()
        selectedVolumeID = id; selectedRoot = volume.rootURL
        if volume.capacityURL.path != "/" { explicitlyAllowedRoots = StorageFileSystem.normalizedRoots(explicitlyAllowedRoots + [volume.rootURL]) }
        status = L10n.text("已选择%@，点击扫描。", String(describing: volume.name))
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择要分析的文件夹")
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectFolder(url)
    }

    func selectFolder(_ url: URL) {
        guard url.isFileURL else { return }
        let keys = try? url.resourceValues(forKeys: [.isDirectoryKey, .volumeIsLocalKey, .isSymbolicLinkKey])
        guard keys?.isDirectory == true, keys?.volumeIsLocal != false, keys?.isSymbolicLink != true else {
            error = L10n.text("请选择本地磁盘上的普通文件夹。"); return
        }
        clearResults(); selectedRoot = url.standardizedFileURL; selectedVolumeID = ""
        explicitlyAllowedRoots = StorageFileSystem.normalizedRoots(explicitlyAllowedRoots + [url.standardizedFileURL])
        status = L10n.text("已选择文件夹，点击扫描。")
    }

    func startScan() {
        guard !busy, let root = selectedRoot else { return }
        let session = allocateSession(), token = begin(L10n.text("正在扫描文件元数据…"))
        let excluded = scanExclusions
        task = Task { [weak self] in
            do {
                let value = try await Task.detached(priority: .utility) {
                    try Self.createSession(session)
                    return try StorageScanner.scan(root: root, indexDirectory: session, excludedPaths: excluded,
                        isCancelled: { token.cancelled }, progress: { update in
                            Task { @MainActor [weak self] in
                                guard let self, self.cancellation === token else { return }
                                self.progressText = L10n.text("%@ 个文件 · %@ 个目录 · %@", String(describing: update.files.formatted()), String(describing: update.directories.formatted()), String(describing: Self.bytes(update.allocatedBytes)))
                            }
                        })
                }.value
                guard let self, self.cancellation === token else { Self.disposeSession(session); return }
                if let old = self.result?.indexDirectory { self.releaseSession(old) }
                self.result = value; self.directory = value.rootURL
                self.status = value.coverage.cancelled ? L10n.text("扫描已取消，显示已完成的部分。") : L10n.text("扫描完成；文件占用为估算值。")
                self.finish(token); self.reloadRows(resetPage: true)
            } catch {
                Self.disposeSession(session)
                guard let self, self.cancellation === token else { return }
                self.status = token.cancelled ? L10n.text("扫描已取消。") : L10n.text("扫描未完成。")
                if !token.cancelled { self.error = error.localizedDescription }
                self.finish(token)
            }
        }
    }

    func reloadRows(resetPage: Bool = false) {
        if resetPage { pageIndex = 0 }
        queryGeneration &+= 1
        let expected = queryGeneration
        queryTask?.cancel()
        guard let result else { rows = []; rowCount = 0; querying = false; return }
        guard pane == .overview || pane == .large else { return }
        let dir = pane == .overview ? (directory ?? result.rootURL) : nil
        let date: Date? = (pane != .large || modifiedFilter == 0) ? nil : Calendar.current.date(byAdding: .day, value: -modifiedFilter, to: Date())
        let query = StorageQuery(minimumLogicalBytes: pane == .large ? settings.minimumLargeFileBytes : 0,
            search: search, fileExtension: pane == .large ? fileExtension : "", modifiedBefore: date,
            sort: sort, metric: settings.sizeMetric, offset: pageIndex * pageSize, limit: pageSize)
        querying = true
        queryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
                let pages = try await Task.detached(priority: .utility) {
                    let page = try StorageIndex.query(result: result, directory: dir, query: query)
                    var mapQuery = query; mapQuery.offset = 0; mapQuery.limit = 64; mapQuery.sort = .sizeDescending
                    let map = dir == nil ? [] : try StorageIndex.query(result: result, directory: dir, query: mapQuery).items
                    return (page, map)
                }.value
                let page = pages.0
                guard let self, self.queryGeneration == expected else { return }
                self.rows = page.items; self.mapRows = pages.1; self.rowCount = page.totalCount; self.querying = false
                if !self.rows.contains(where: { $0.path == self.selectedPath }) { self.selectedPath = nil }
            } catch {
                guard let self, self.queryGeneration == expected else { return }
                self.querying = false; self.error = error.localizedDescription
            }
        }
    }

    func changePage(_ offset: Int) {
        pageIndex = max(0, pageIndex + offset); reloadRows()
    }
    func navigate(_ url: URL) {
        guard let result, StorageFileSystem.isInside(path: url.path, root: result.rootURL.path) else { return }
        directory = url; selectedPath = nil; search = ""; reloadRows(resetPage: true)
    }
    func enter(_ item: StorageItem) {
        if item.isDirectory && !item.entry.isPackage { navigate(item.url) }
        else { quickLook(item.entry) }
    }
    var currentDirectoryBytes: Int64 {
        guard let result else { return 0 }
        return (result.directories[directory?.path ?? result.rootURL.path] ?? result.root).bytes(for: settings.sizeMetric)
    }
    var breadcrumbs: [URL] {
        guard let root = result?.rootURL, var current = directory else { return [] }
        var items = [current]
        while current.path != root.path && StorageFileSystem.isInside(path: current.path, root: root.path) {
            current.deleteLastPathComponent(); items.append(current)
        }
        return items.reversed()
    }

    func addDuplicateFolder() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("添加要比较的文件夹"); panel.canChooseFiles = false
        panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { addDuplicateRoots(panel.urls) }
    }
    func addDuplicateRoots(_ urls: [URL]) {
        guard !busy else { return }
        let local = urls.filter { url in
            guard url.isFileURL, let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .volumeIsLocalKey, .isSymbolicLinkKey]) else { return false }
            return values.isDirectory == true && values.volumeIsLocal != false && values.isSymbolicLink != true
        }
        duplicateRoots = StorageFileSystem.normalizedRoots(duplicateRoots + local)
        explicitlyAllowedRoots = StorageFileSystem.normalizedRoots(explicitlyAllowedRoots + local)
    }
    func removeDuplicateRoot(_ url: URL) { duplicateRoots.removeAll { $0 == url } }
    func startDuplicates() {
        guard !busy, !duplicateRoots.isEmpty else { return }
        let roots = duplicateRoots, excluded = scanExclusions, preferred = settings.preferredKeepPaths
        let session = allocateSession(), token = begin(L10n.text("正在比较重复文件…"))
        duplicateGroups = []; duplicateKeepers = [:]; duplicateIssues = []
        task = Task { [weak self] in
            do {
                let found = try await Task.detached(priority: .utility) {
                    try Self.createSession(session)
                    return try DuplicateFinder.find(roots: roots, excludedPaths: excluded, preferredKeepPaths: preferred,
                        scratchDirectory: session, isCancelled: { token.cancelled }, progress: { update in
                            Task { @MainActor [weak self] in
                                guard let self, self.cancellation === token else { return }
                                self.progressText = L10n.text("%@ · %@ 个文件 · 已读取 %@", String(describing: update.stage), String(describing: update.filesExamined.formatted()), String(describing: Self.bytes(update.bytesRead)))
                            }
                        })
                }.value
                Self.disposeSession(session)
                guard let self, self.cancellation === token else { return }
                self.sessions.remove(session)
                self.duplicateGroups = found.groups
                self.duplicateKeepers = Dictionary(uniqueKeysWithValues: found.groups.map { ($0.id, $0.preferredKeepPath) })
                self.duplicateIssues = found.issues
                self.status = found.completed ? L10n.text("比较完成，共 %@ 组完全相同的文件；跳过 %@ 项，尚未选择任何文件。", String(describing: found.groups.count), String(describing: found.skippedCount)) : L10n.text("比较已取消，只显示已核验的结果。")
                self.finish(token)
            } catch {
                Self.disposeSession(session)
                guard let self, self.cancellation === token else { return }
                self.status = token.cancelled ? L10n.text("比较已取消。") : L10n.text("比较未完成。")
                if !token.cancelled { self.error = error.localizedDescription }
                self.finish(token)
            }
        }
    }
    func setKeeper(_ path: String, group: DuplicateGroup) {
        duplicateKeepers[group.id] = path
        pending.removeAll { $0.entry.path == path }
        let retained = group.members.filter { member in !pending.contains { $0.entry.path == member.path } }
        for index in pending.indices where group.members.contains(where: { $0.path == pending[index].entry.path }) {
            pending[index].retainedEntries = retained
        }
        preview = nil
    }
    func toggleDuplicate(_ entry: StorageEntry, group: DuplicateGroup) {
        guard !busy else { return }
        let keeperPath = duplicateKeepers[group.id] ?? group.preferredKeepPath
        guard entry.path != keeperPath else { return }
        if isPending(entry.path) { removePending(entry.path); return }
        let retained = group.members.filter { $0.path == keeperPath }
        addPending(.init(entry: entry, reason: L10n.text("与保留副本内容完全相同"), kind: .duplicate, retainedEntries: retained))
    }

    func startCaches() {
        guard !busy else { return }
        let token = begin(L10n.text("正在检查内置缓存规则…"))
        task = Task { [weak self] in
            do {
                let catalog = try await Task.detached(priority: .utility) {
                    let apps = Self.knownApplications()
                    let rules = CacheRules.catalog(applications: apps)
                    let candidates = try CacheRules.discover(rules: rules, isCancelled: { token.cancelled })
                    return (rules, candidates)
                }.value
                guard let self, self.cancellation === token else { return }
                self.cacheRules = catalog.0
                self.cacheCandidates = catalog.1.filter { candidate in
                    !self.settings.excludedPaths.contains { StorageFileSystem.isInside(path: candidate.entry.path, root: $0) }
                }
                self.status = L10n.text("缓存检查完成；未默认勾选任何项目。")
                self.finish(token)
            } catch {
                guard let self, self.cancellation === token else { return }
                self.status = token.cancelled ? L10n.text("缓存检查已取消。") : L10n.text("缓存检查未完成。")
                if !token.cancelled { self.error = error.localizedDescription }
                self.finish(token)
            }
        }
    }
    func toggleCache(_ candidate: StorageCacheCandidate) {
        guard candidate.canClean, !busy else { return }
        if isPending(candidate.entry.path) { removePending(candidate.entry.path) }
        else { addPending(candidate.selection) }
    }
    func toggleManual(_ item: StorageItem) {
        guard !busy else { return }
        if isPending(item.path) { removePending(item.path) }
        else { addPending(.init(entry: item.entry, reason: L10n.text("手动选择的文件或目录"))) }
    }
    func addPending(_ item: CleanupSelection) {
        var selection = item
        selection.entry = StorageSafetyPolicy.normalizedUserEntry(item.entry)
        selection.retainedEntries = item.retainedEntries.map(StorageSafetyPolicy.normalizedUserEntry)
        guard !pending.contains(where: { $0.id == selection.id }),
              !settings.excludedPaths.contains(where: { StorageFileSystem.isInside(path: selection.id, root: $0) }) else { return }
        pending.append(selection); preview = nil; cleanupResults = []
    }
    func removePending(_ path: String) { pending.removeAll { Self.displayPath($0.id) == Self.displayPath(path) }; preview = nil }
    func isPending(_ path: String) -> Bool { pending.contains { Self.displayPath($0.id) == Self.displayPath(path) } }
    func clearPending() { pending = []; preview = nil; cleanupResults = [] }

    func beginReview() {
        guard !busy, !pending.isEmpty else { return }
        showingReview = true; preview = nil; cleanupResults = []
        let selected = pending, roots = allowedRoots, rules = cacheRules
        let token = begin(L10n.text("正在核对待整理清单…"))
        task = Task { [weak self] in
            do {
                let value = try await Task.detached(priority: .utility) {
                    try CleanupService(allowedRoots: roots, cacheRules: rules, busyProcessNames: Self.processNames)
                        .preview(selected, isCancelled: { token.cancelled })
                }.value
                guard let self, self.cancellation === token else { return }
                self.preview = value; self.status = L10n.text("清单已核对，请确认后移入废纸篓。"); self.finish(token)
            } catch {
                guard let self, self.cancellation === token else { return }
                if !token.cancelled { self.error = error.localizedDescription }
                self.status = L10n.text("预览已停止。"); self.finish(token)
            }
        }
    }
    func executePreview() {
        guard !busy, let preview, !preview.items.isEmpty else { return }
        let roots = allowedRoots, rules = cacheRules
        let token = begin(L10n.text("正在移入废纸篓…"))
        task = Task { [weak self] in
            let outcomes = await Task.detached(priority: .utility) {
                CleanupService(allowedRoots: roots, cacheRules: rules, busyProcessNames: Self.processNames)
                    .execute(preview, isCancelled: { token.cancelled })
            }.value
            guard let self, self.cancellation === token else { return }
            self.cleanupResults = outcomes
            let succeeded = Set(outcomes.filter { $0.status == .moved }.map(\.path))
            self.pending.removeAll { succeeded.contains($0.id) }
            self.preview = nil
            self.status = L10n.text("已移入废纸篓 %@ 项；尚未清空废纸篓，不能视为已释放空间。", String(describing: succeeded.count))
            self.finish(token); self.refreshVolumes()
            // A previous scan is a snapshot; do not silently reuse it after a cleanup.
            if !succeeded.isEmpty { self.invalidateScanAfterCleanup() }
        }
    }

    func closeReview() {
        if busy { cancel() }
        showingReview = false
    }
    func cancel() { cancellation?.cancel(); if busy { status = L10n.text("正在取消，请稍候…") } }
    func clearResults() {
        generation &+= 1; queryGeneration &+= 1; cancellation?.cancel(); cancellation = nil
        task = nil; queryTask?.cancel(); queryTask = nil; busy = false; querying = false
        if let folder = result?.indexDirectory { releaseSession(folder) }
        result = nil; rows = []; mapRows = []; rowCount = 0; selectedPath = nil; directory = nil; pageIndex = 0
    }
    func shutdown() {
        clearResults(); duplicateGroups = []; cacheCandidates = []; clearPending()
        // Running workers own their folders until they observe cancellation and return.
    }
    private func invalidateScanAfterCleanup() {
        if let folder = result?.indexDirectory { releaseSession(folder) }
        result = nil; rows = []; mapRows = []; rowCount = 0; selectedPath = nil; directory = nil
        duplicateGroups = []; duplicateKeepers = [:]; cacheCandidates = []
    }
    func applySettings(_ value: StorageSettings) {
        settings = value
        pending.removeAll { item in value.excludedPaths.contains { StorageFileSystem.isInside(path: Self.displayPath(item.id), root: Self.displayPath($0)) } }
        preview = nil
        reloadRows(resetPage: true)
    }
    private var scanExclusions: [String] {
        let aliases = settings.excludedPaths.flatMap { path -> [String] in
            let logical = Self.displayPath(path)
            return [logical, "/System/Volumes/Data" + logical]
        }
        return Array(Set(aliases + [sessionBase.path, Self.displayPath(sessionBase.path), "/System/Volumes/Data" + sessionBase.path]))
    }
    private var allowedRoots: [URL] {
        StorageFileSystem.normalizedRoots([FileManager.default.homeDirectoryForCurrentUser] + explicitlyAllowedRoots + duplicateRoots)
    }
    private func begin(_ text: String) -> StorageCancellation {
        generation &+= 1
        let token = StorageCancellation(); cancellation = token
        busy = true; status = text; progressText = ""; error = nil
        return token
    }
    private func finish(_ token: StorageCancellation) {
        guard cancellation === token else { return }
        busy = false; cancellation = nil; task = nil; progressText = ""
    }
    private func allocateSession() -> URL {
        let url = sessionBase.appendingPathComponent(UUID().uuidString, isDirectory: true)
        sessions.insert(url); return url
    }
    private func releaseSession(_ url: URL) {
        sessions.remove(url)
        Task.detached(priority: .utility) { Self.disposeSession(url) }
    }
    private nonisolated static func createSession(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("MacDaily storage session".utf8).write(to: url.appendingPathComponent(".macdaily-session"), options: .withoutOverwriting)
    }
    private nonisolated static func disposeSession(_ url: URL) {
        guard UUID(uuidString: url.lastPathComponent) != nil,
              let marker = try? Data(contentsOf: url.appendingPathComponent(".macdaily-session")),
              marker == Data("MacDaily storage session".utf8),
              !StorageFileSystem.hasSymlinkAncestor(url),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { return }
        try? FileManager.default.removeItem(at: url)
    }
    private nonisolated static func knownApplications() -> [StorageKnownApplication] {
        let manager = FileManager.default
        let roots = [URL(fileURLWithPath: "/Applications", isDirectory: true), manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
        var apps: [StorageKnownApplication] = []
        for root in roots {
            guard let urls = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for url in urls where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
                apps.append(.init(bundleIdentifier: id, name: name))
            }
        }
        return apps
    }
    private nonisolated static func processNames() -> [String] {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "comm="]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return ["__PROCESS_CHECK_UNAVAILABLE__"] }
            let names = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            var resolved = names
            var seenBundles = Set<String>()
            for name in names {
                guard let boundary = name.range(of: ".app/Contents/") else { continue }
                let appPath = String(name[..<boundary.lowerBound]) + ".app"
                guard seenBundles.insert(appPath).inserted, let bundle = Bundle(path: appPath) else { continue }
                if let id = bundle.bundleIdentifier { resolved.append(id) }
                if let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String { resolved.append(display) }
                if let display = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String { resolved.append(display) }
            }
            return resolved
        } catch { return ["__PROCESS_CHECK_UNAVAILABLE__"] }
    }
    nonisolated static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, count), countStyle: .decimal)
    }
    nonisolated static func displayPath(_ path: String) -> String {
        let data = "/System/Volumes/Data"
        if path == data { return "/" }
        if path.hasPrefix(data + "/") { return String(path.dropFirst(data.count)) }
        return path
    }
    func reveal(_ entry: StorageEntry) { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
    func copyPath(_ entry: StorageEntry) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Self.displayPath(entry.path), forType: .string)
    }
    func quickLook(_ entry: StorageEntry) {
        guard !entry.isCloudPlaceholder, !entry.isSymlink else { error = L10n.text("云端占位文件或符号链接请在 Finder 中查看。"); return }
        StorageQuickLook.shared.show(entry.url)
    }
    func openDiskPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
    }
    func openTrash() { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)) }
}

@MainActor
private final class StorageQuickLook: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = StorageQuickLook()
    private var url: NSURL?
    func show(_ url: URL) {
        self.url = url as NSURL
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self; panel.reloadData(); panel.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { url }
}
