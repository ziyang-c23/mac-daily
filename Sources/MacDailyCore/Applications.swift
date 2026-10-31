import Foundation
import CoreServices
import Security

public struct InstalledApplication: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var bundleIdentifier: String
    public var version: String
    public var developer: String
    public var architecture: String
    public var lastUsed: Date?
    public var bytes: Int64
    public var isSystem: Bool
    public var appGroups: [String]
    public var relatedBundleIdentifiers: [String]
    public var caskToken: String?
    public var uninstallerPath: String?
    public init(path: String, name: String, bundleIdentifier: String, version: String = "", developer: String = "", architecture: String = "", lastUsed: Date? = nil, bytes: Int64 = 0, isSystem: Bool = false, appGroups: [String] = [], caskToken: String? = nil, uninstallerPath: String? = nil, relatedBundleIdentifiers: [String] = []) {
        self.path = path; self.name = name; self.bundleIdentifier = bundleIdentifier; self.version = version
        self.developer = developer; self.architecture = architecture; self.lastUsed = lastUsed; self.bytes = bytes
        self.isSystem = isSystem; self.appGroups = appGroups; self.relatedBundleIdentifiers = relatedBundleIdentifiers; self.caskToken = caskToken; self.uninstallerPath = uninstallerPath
    }
    public var caskCommand: String? { caskToken.map { "brew uninstall --cask \($0)" } }
}

public enum ApplicationInventory {
    public static var defaultRoots: [URL] {
        [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }
    public static func scan(roots: [URL] = defaultRoots, includeSystem: Bool = false,
                            isCancelled: () -> Bool = { false }, onApplication: (InstalledApplication) -> Void = { _ in }) throws -> [InstalledApplication] {
        var results: [InstalledApplication] = [], seen = Set<String>()
        let casks = caskApplications()
        func visit(_ url: URL) throws {
            if isCancelled() { throw CancellationError() }
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if url.pathExtension.lowercased() == "app" {
                if var app = application(at: url) {
                    app.caskToken = casks[path] ?? casks[url.resolvingSymlinksInPath().path]
                    app.bytes = try measuredSize(at: url.resolvingSymlinksInPath(), isCancelled: isCancelled)
                    results.append(app); onApplication(app)
                }
                return
            }
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { return }
            for child in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
                try visit(child)
            }
        }
        for root in roots + (includeSystem ? [URL(fileURLWithPath: "/System/Applications")] : []) { try visit(root) }
        return results.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public static func application(at url: URL) -> InstalledApplication? {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL), let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let identifier = info["CFBundleIdentifier"] as? String ?? ""
        let bundle = Bundle(url: url)
        let display = bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String
        let name = [display, bundle?.localizedInfoDictionary?["CFBundleName"] as? String, info["CFBundleDisplayName"] as? String, info["CFBundleName"] as? String].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? url.deletingPathExtension().lastPathComponent
        var groups: [String] = [], developer = ""
        var code: SecStaticCode?
        if SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code {
            var signing: CFDictionary?
            if SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signing) == errSecSuccess,
               let signing = signing as? [String: Any] {
                developer = signing[kSecCodeInfoTeamIdentifier as String] as? String ?? ""
                if let certificates = signing[kSecCodeInfoCertificates as String] as? [SecCertificate], let certificate = certificates.first {
                    developer = SecCertificateCopySubjectSummary(certificate) as String? ?? developer
                }
                if let entitlements = signing[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
                    groups = entitlements["com.apple.security.application-groups"] as? [String] ?? []
                }
            }
        }
        let metadata = MDItemCreate(kCFAllocatorDefault, url.path as CFString)
        let lastUsed = metadata.flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }
        let executable = (info["CFBundleExecutable"] as? String).map { url.appendingPathComponent("Contents/MacOS/\($0)") }
        let uninstallers = (try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        let uninstaller = uninstallers.first { candidate in
            let lower = candidate.deletingPathExtension().lastPathComponent.lowercased()
            return candidate.pathExtension == "app" && candidate != url && lower.contains("uninstall") && lower.contains(url.deletingPathExtension().lastPathComponent.lowercased())
        }
        return InstalledApplication(path: url.standardizedFileURL.path, name: name, bundleIdentifier: identifier,
                                    version: info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String ?? "",
                                    developer: developer, architecture: executable.map(architecture(at:)) ?? "",
                                    lastUsed: lastUsed, isSystem: url.resolvingSymlinksInPath().path.hasPrefix("/System/"), appGroups: groups, uninstallerPath: uninstaller?.path, relatedBundleIdentifiers: embeddedBundleIdentifiers(at: url))
    }
    private static func embeddedBundleIdentifiers(at url: URL) -> [String] {
        var identifiers = Set<String>()
        guard let iterator = FileManager.default.enumerator(at: url.appendingPathComponent("Contents"), includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return [] }
        for case let child as URL in iterator {
            guard ["app", "xpc", "appex"].contains(child.pathExtension.lowercased()),
                  (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            let infoURL = child.appendingPathComponent("Contents/Info.plist")
            if let data = try? Data(contentsOf: infoURL),
               let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty {
                identifiers.insert(identifier)
            }
        }
        return identifiers.sorted()
    }
    public static func measuredSize(at url: URL, isCancelled: () -> Bool = { false }) throws -> Int64 {
        do { return try size(at: url, isCancelled: isCancelled) }
        catch is CancellationError { throw CancellationError() }
        catch { return -1 }
    }
    public static func size(at url: URL, isCancelled: () -> Bool = { false }) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        let values = try url.resourceValues(forKeys: keys)
        if values.isSymbolicLink == true { return 0 }
        if values.isDirectory != true { return Int64(values.fileSize ?? 0) }
        var size: Int64 = 0
        var failed = false
        if let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), errorHandler: { _, _ in failed = true; return true }) {
            for case let child as URL in iterator {
                if isCancelled() { throw CancellationError() }
                let item = try? child.resourceValues(forKeys: keys)
                if item == nil { failed = true }
                if item?.isSymbolicLink == true { continue }
                if item?.isDirectory != true { size += Int64(item?.fileSize ?? 0) }
            }
        }
        return failed ? -1 : size
    }
    private static func architecture(at url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }; defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), data.count >= 8 else { return "" }
        func u32(_ offset: Int, _ big: Bool) -> UInt32 {
            guard offset + 4 <= data.count else { return 0 }
            let b = Array(data[offset..<offset+4])
            return big ? UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]) : UInt32(b[3]) << 24 | UInt32(b[2]) << 16 | UInt32(b[1]) << 8 | UInt32(b[0])
        }
        let magic = u32(0, true); var types: [UInt32] = []
        if magic == 0xcafebabe || magic == 0xcafebabf {
            let stride = magic == 0xcafebabf ? 32 : 20
            for i in 0..<min(Int(u32(4, true)), (data.count-8)/stride) { types.append(u32(8+i*stride, true)) }
        } else if magic == 0xcffaedfe || magic == 0xcefaedfe { types = [u32(4, false)] }
        else if magic == 0xfeedfacf || magic == 0xfeedface { types = [u32(4, true)] }
        let arm = types.contains(0x0100000c), intel = types.contains(0x01000007) || types.contains(7)
        return arm && intel ? "Universal" : arm ? "Apple Silicon" : intel ? "Intel" : ""
    }
    private static func caskApplications() -> [String: String] {
        var result: [String: String] = [:]
        for base in ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"] {
            let root = URL(fileURLWithPath: base)
            for token in (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? [] {
                let directory = root.appendingPathComponent(token)
                guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { continue }
                for case let item as URL in iterator {
                    if item.pathExtension == "app" {
                        result[item.resolvingSymlinksInPath().path] = token
                        if (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true { iterator.skipDescendants() }
                    }
                }
            }
        }
        return result
    }
}

public enum ApplicationFileCategory: String, CaseIterable, Sendable { case application, cache, log, preference, data, shared }
public struct ApplicationRelatedItem: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var path: String
    public var category: ApplicationFileCategory
    public var reason: String
    public var ownerIDs: [String]
    public var ownerPaths: [String]
    public var defaultSelected: Bool
    public var bytes: Int64
    public var canTrash: Bool
    public init(path: String, category: ApplicationFileCategory, reason: String, ownerIDs: [String] = [], ownerPaths: [String] = [], defaultSelected: Bool = false, bytes: Int64 = 0, canTrash: Bool = true) {
        self.path = path; self.category = category; self.reason = reason; self.ownerIDs = ownerIDs; self.ownerPaths = ownerPaths
        self.defaultSelected = defaultSelected; self.bytes = bytes; self.canTrash = canTrash
    }
}

public enum ApplicationAssociationResolver {
    private static let locations: [(String, ApplicationFileCategory)] = [
        ("Library/Caches", .cache), ("Library/Logs", .log), ("Library/Preferences", .preference),
        ("Library/Saved Application State", .data), ("Library/HTTPStorages", .data), ("Library/WebKit", .data),
        ("Library/Containers", .data), ("Library/Group Containers", .shared), ("Library/Application Support", .data)
    ]
    public static func resolve(applications: [InstalledApplication], selectedPaths: Set<String>, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               ignoredPaths: [String] = [], isCancelled: () -> Bool = { false },
                               registeredPaths: (String) -> [String] = launchServicesPaths) throws -> [ApplicationRelatedItem] {
        let selected = applications.filter { selectedPaths.contains($0.path) }
        var merged: [String: ApplicationRelatedItem] = [:]
        var registered: [String: [String]] = [:]
        for app in selected where !app.bundleIdentifier.isEmpty {
            registered[app.bundleIdentifier] = registeredPaths(app.bundleIdentifier).filter { FileManager.default.fileExists(atPath: $0) && !$0.contains("/.Trash/") && !$0.contains("/.Trashes/") }
        }
        for app in selected {
            if isCancelled() { throw CancellationError() }
            merged[app.path] = .init(path: app.path, category: .application, reason: "应用本体", ownerIDs: [app.bundleIdentifier], ownerPaths: [app.path], defaultSelected: !app.isSystem && app.caskToken == nil && app.uninstallerPath == nil, bytes: app.bytes, canTrash: !app.isSystem && app.caskToken == nil && app.uninstallerPath == nil)
        }
        for (relative, category) in locations {
            let root = home.appendingPathComponent(relative)
            let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for child in children {
                if isCancelled() { throw CancellationError() }
                guard !ignoredPaths.contains(where: { inside(child.path, $0) }) else { continue }
                let filename = child.lastPathComponent
                var owners: [InstalledApplication] = [], reason = "Bundle ID 匹配", named = false
                if category == .shared {
                    owners = applications.filter { $0.appGroups.contains(filename) }; reason = "应用声明的 App Group"
                } else if relative == "Library/Application Support" {
                    let exact = applications.filter { associationIdentifiers($0).contains { !$0.isEmpty && matches(filename, $0) } }
                    if exact.isEmpty { owners = applications.filter { $0.name.caseInsensitiveCompare(filename) == .orderedSame }; reason = "应用名称匹配"; named = true }
                    else { owners = exact }
                } else {
                    owners = applications.filter { associationIdentifiers($0).contains { !$0.isEmpty && matches(filename, $0) } }
                }
                guard owners.contains(where: { selectedPaths.contains($0.path) }) else { continue }
                let ownerPaths = Array(Set(owners.map(\.path) + owners.flatMap { registered[$0.bundleIdentifier] ?? [] })).sorted()
                let shared = Set(owners.map(\.bundleIdentifier)).count > 1 || ownerPaths.contains { !selectedPaths.contains($0) }
                let canTrash = owners.allSatisfy { !$0.isSystem && $0.caskToken == nil && $0.uninstallerPath == nil }
                merged[child.path] = .init(path: child.path, category: shared ? .shared : category, reason: reason,
                                           ownerIDs: Array(Set(owners.map(\.bundleIdentifier))).sorted(), ownerPaths: ownerPaths,
                                           defaultSelected: !shared && !named && canTrash && (category == .cache || category == .log),
                                           bytes: try ApplicationInventory.measuredSize(at: child, isCancelled: isCancelled), canTrash: canTrash)
            }
        }
        if isCancelled() { throw CancellationError() }
        return merged.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    public static func scanLeftovers(applications: [InstalledApplication], home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                    ignoredPaths: [String] = [], isCancelled: () -> Bool = { false },
                                    registeredPaths: (String) -> [String] = launchServicesPaths) throws -> [ApplicationRelatedItem] {
        var result: [ApplicationRelatedItem] = []
        let known = Set(applications.flatMap { associationIdentifiers($0) }.map { $0.lowercased() })
        for (relative, category) in locations where category != .shared && relative != "Library/Application Support" {
            for child in (try? FileManager.default.contentsOfDirectory(at: home.appendingPathComponent(relative), includingPropertiesForKeys: nil)) ?? [] {
                if isCancelled() { throw CancellationError() }
                guard !ignoredPaths.contains(where: { inside(child.path, $0) }) else { continue }
                if relative == "Library/Preferences" && child.pathExtension != "plist" { continue }
                if relative == "Library/HTTPStorages" && child.pathExtension != "binarycookies" && (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true { continue }
                var identifier = child.lastPathComponent
                for suffix in [".plist", ".savedState", ".binarycookies"] where identifier.hasSuffix(suffix) { identifier.removeLast(suffix.count) }
                let pieces = identifier.split(separator: ".")
                guard pieces.count >= 3, !identifier.hasPrefix("com.apple."), !identifier.hasPrefix("group.com.apple."), !identifier.hasPrefix("systemgroup.com.apple."), !known.contains(identifier.lowercased()),
                      identifier.range(of: "^[A-Za-z][A-Za-z0-9-]*(\\.[A-Za-z0-9_-]+){2,}$", options: .regularExpression) != nil else { continue }
                let installed = registeredPaths(identifier).contains { FileManager.default.fileExists(atPath: $0) && !$0.contains("/.Trash/") && !$0.contains("/.Trashes/") }
                guard !installed else { continue }
                result.append(.init(path: child.path, category: category, reason: "未找到对应应用", ownerIDs: [identifier], bytes: try ApplicationInventory.measuredSize(at: child, isCancelled: isCancelled)))
            }
        }
        if isCancelled() { throw CancellationError() }
        return result.sorted { $0.path < $1.path }
    }
    public static func launchServicesPaths(_ identifier: String) -> [String] {
        (LSCopyApplicationURLsForBundleIdentifier(identifier as CFString, nil)?.takeRetainedValue() as? [URL] ?? []).map(\.path)
    }
    private static func associationIdentifiers(_ app: InstalledApplication) -> [String] {
        let ids = [app.bundleIdentifier] + app.relatedBundleIdentifiers
        // Squirrel names its updater cache after the host bundle identifier.
        return ids + ids.filter { !$0.isEmpty }.map { $0 + ".ShipIt" }
    }
    private static func matches(_ name: String, _ identifier: String) -> Bool {
        if name.caseInsensitiveCompare(identifier) == .orderedSame { return true }
        return [".plist", ".savedState", ".binarycookies"].contains { name.caseInsensitiveCompare(identifier + $0) == .orderedSame }
    }
    fileprivate static func inside(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
}

public struct ApplicationCleanupResult: Identifiable, Sendable {
    public var id: String { path }
    public var path: String
    public var status: CleanupStatus
    public var message: String
    public var movedBytes: Int64
    public var trashURL: URL?
}
public enum ApplicationCleanupService {
    public static func preview(items: [ApplicationRelatedItem], selectedIDs: Set<String>) -> [ApplicationRelatedItem] {
        let selected = items.filter { selectedIDs.contains($0.id) && $0.canTrash }.sorted { $0.path.count < $1.path.count }
        var result: [ApplicationRelatedItem] = []
        for item in selected where !result.contains(where: { ApplicationAssociationResolver.inside(item.path, $0.path) }) { result.append(item) }
        return result
    }
    public static func execute(items: [ApplicationRelatedItem], quit: @Sendable (String) async -> Bool = { _ in true },
                               trash: @Sendable (URL) throws -> URL? = systemTrash) async -> [ApplicationCleanupResult] {
        var blocked = Set<String>(), results: [ApplicationCleanupResult] = []
        for path in Set(items.flatMap(\.ownerPaths)) {
            if URL(fileURLWithPath: path).standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL { blocked.insert(path) }
            else if !(await quit(path)) { blocked.insert(path) }
        }
        for item in items {
            let reason: String?
            if item.category == .application && URL(fileURLWithPath: item.path).standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL { reason = "当前运行的 MacDaily" }
            else if !item.canTrash { reason = "此项目使用专用管理入口" }
            else if !blocked.isDisjoint(with: item.ownerPaths) { reason = "应用尚未退出" }
            else if !FileManager.default.fileExists(atPath: item.path) { reason = "项目已不存在" }
            else { reason = nil }
            if let reason { results.append(.init(path: item.path, status: .skipped, message: reason, movedBytes: 0)); continue }
            do {
                let destination = try trash(URL(fileURLWithPath: item.path))
                results.append(.init(path: item.path, status: .moved, message: "已移入废纸篓", movedBytes: max(0, item.bytes), trashURL: destination))
            } catch { results.append(.init(path: item.path, status: .failed, message: error.localizedDescription, movedBytes: 0)) }
        }
        return results
    }
    public static func systemTrash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }
}
