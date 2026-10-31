import Foundation

public struct StorageKnownApplication: Equatable, Sendable {
    public var bundleIdentifier: String
    public var name: String
    public init(bundleIdentifier: String, name: String) { self.bundleIdentifier = bundleIdentifier; self.name = name }
}
public enum StorageCacheKind: String, Codable, CaseIterable, Sendable {
    case application, oldLogs, developer, inspectionOnly
    public var title: String {
        switch self { case .application: L10n.text("应用缓存"); case .oldLogs: L10n.text("旧日志"); case .developer: L10n.text("开发缓存"); case .inspectionOnly: L10n.text("仅分析") }
    }
}
public struct StorageCacheRule: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var rootPath: String
    public var kind: StorageCacheKind
    public var reason: String
    public var canClean: Bool
    public var minimumAgeDays: Int?
    public var busyProcessHints: [String]
    public init(id: String, title: String, rootPath: String, kind: StorageCacheKind, reason: String,
                canClean: Bool = true, minimumAgeDays: Int? = nil, busyProcessHints: [String] = []) {
        self.id = id; self.title = title; self.rootPath = rootPath; self.kind = kind; self.reason = reason
        self.canClean = canClean; self.minimumAgeDays = minimumAgeDays; self.busyProcessHints = busyProcessHints
    }
    public func isBusy(processNames: [String]) -> Bool {
        if processNames.contains("__PROCESS_CHECK_UNAVAILABLE__") || processNames.contains("__MACDAILY_PROCESS_CHECK_FAILED__") { return true }
        return processNames.contains { name in busyProcessHints.contains { !($0.isEmpty) && name.localizedCaseInsensitiveContains($0) } }
    }
}
public struct StorageCacheCandidate: Equatable, Sendable, Identifiable {
    public var entry: StorageEntry
    public var rule: StorageCacheRule
    public var bytes: Int64
    public var id: String { entry.path }
    public var title: String { rule.title }
    public var ruleID: String { rule.id }
    public var reason: String { rule.reason }
    public var canClean: Bool { rule.canClean }
    public init(entry: StorageEntry, rule: StorageCacheRule, bytes: Int64) { self.entry = entry; self.rule = rule; self.bytes = bytes }
    public var selection: CleanupSelection { .init(entry: entry, reason: rule.reason, kind: .cache, cacheRuleID: rule.id) }
}

/// Explicit rules only. A directory merely named "cache" never makes a cleanup candidate.
public enum CacheRules {
    public static func catalog(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               applications: [StorageKnownApplication] = []) -> [StorageCacheRule] {
        func path(_ relative: String) -> String { home.appendingPathComponent(relative).path }
        var rules = [
            StorageCacheRule(id: "logs", title: L10n.text("30天前的用户日志"), rootPath: path("Library/Logs"), kind: .oldLogs,
                             reason: L10n.text("超过30天，但无法确认所属应用；本版本仅提供定位。"), canClean: false, minimumAgeDays: 30),
            StorageCacheRule(id: "xcode-derived", title: "Xcode DerivedData", rootPath: path("Library/Developer/Xcode/DerivedData"), kind: .developer,
                             reason: L10n.text("编译与索引缓存；再次开发时需要重新构建。"), busyProcessHints: ["xcode", "xcbuild", "swift", "clang"]),
            StorageCacheRule(id: "pip", title: L10n.text("pip 下载缓存"), rootPath: path("Library/Caches/pip"), kind: .developer,
                             reason: L10n.text("下载与wheel缓存；后续安装可能需要重新下载或构建。"), busyProcessHints: ["pip", "python"]),
            StorageCacheRule(id: "npm", title: L10n.text("npm 内容缓存"), rootPath: path(".npm/_cacache"), kind: .developer,
                             reason: L10n.text("npm可重新下载的内容缓存；不处理.npmrc、凭证或项目依赖。"), busyProcessHints: ["node", "npm", "npx"]),
            StorageCacheRule(id: "uv", title: L10n.text("uv 缓存"), rootPath: path(".cache/uv"), kind: .inspectionOnly,
                             reason: L10n.text("可能与环境共享引用；应由uv自身维护，本版本仅分析。"), canClean: false),
            StorageCacheRule(id: "pnpm", title: "pnpm store", rootPath: path("Library/pnpm/store"), kind: .inspectionOnly,
                             reason: L10n.text("内容可能与项目共享引用，应由pnpm自身维护。"), canClean: false)
        ]
        var seen = Set<String>()
        for app in applications.sorted(by: { $0.bundleIdentifier < $1.bundleIdentifier }) {
            let id = app.bundleIdentifier
            guard !id.isEmpty, !id.contains("/"), !id.contains(".."), seen.insert(id).inserted else { continue }
            for logName in Set([id, app.name]).sorted() where !logName.isEmpty && !logName.contains("/") && !logName.contains("..") {
                rules.append(.init(id: "logs:\(id):\(logName)", title: L10n.text("%@ 的旧日志", String(describing: app.name)),
                                   rootPath: path("Library/Logs/\(logName)"), kind: .oldLogs,
                                   reason: L10n.text("已确认应用目录中超过30天的日志；应用退出后才可整理。"),
                                   minimumAgeDays: 30, busyProcessHints: [app.name, id]))
            }
            guard !id.hasPrefix("com.apple."),
                  !["cloud", "dropbox", "onedrive", "safari", "chrome", "firefox", "brave", "edge", "keychain"].contains(where: { id.lowercased().contains($0) }) else { continue }
            rules.append(.init(id: "app:\(id)", title: app.name, rootPath: path("Library/Caches/\(id)"), kind: .application,
                               reason: L10n.text("已识别应用的用户缓存；可能需要重新生成，不处理该应用的资料、登录信息或配置。"),
                               busyProcessHints: [app.name, id]))
        }
        return rules
    }

    public static func discover(rules: [StorageCacheRule], now: Date = Date(), isCancelled: () -> Bool = { false }) throws -> [StorageCacheCandidate] {
        var result: [StorageCacheCandidate] = []
        for rule in rules {
            if isCancelled() { throw CancellationError() }
            let url = URL(fileURLWithPath: rule.rootPath)
            guard let root = try? StorageFileSystem.entry(at: url), root.isDirectory,
                  !root.isSymlink, !root.isCloudPlaceholder, !StorageFileSystem.hasSymlinkAncestor(url) else { continue }
            if let days = rule.minimumAgeDays {
                let limit = now.addingTimeInterval(-Double(days) * 86400)
                guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants]) else { continue }
                for case let child as URL in walker {
                    if isCancelled() { throw CancellationError() }
                    guard let entry = try? StorageFileSystem.entry(at: child) else { continue }
                    if entry.isSymlink || entry.isCloudPlaceholder || entry.isPackage { walker.skipDescendants(); continue }
                    if !rule.canClean && rules.contains(where: { $0.minimumAgeDays != nil && $0.canClean && StorageFileSystem.isInside(path: entry.path, root: $0.rootPath) }) { continue }
                    guard !entry.isDirectory, entry.isRegularFile, entry.modifiedAt < limit,
                          ["log", "txt", "json", "gz", "crash", "ips"].contains(child.pathExtension.lowercased()) else { continue }
                    result.append(.init(entry: entry, rule: rule, bytes: entry.allocatedBytes))
                }
            } else {
                do {
                    let manifest = try StorageManifest.capture(root: root, allowPackages: true, isCancelled: isCancelled)
                    result.append(.init(entry: root, rule: rule, bytes: manifest.allocatedBytes))
                } catch is CancellationError { throw CancellationError() }
                catch { continue }

            }
        }
        return result.sorted { $0.bytes == $1.bytes ? $0.entry.path < $1.entry.path : $0.bytes > $1.bytes }
    }
}
