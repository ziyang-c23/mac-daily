import Foundation
import Darwin
import Testing
@testable import MacDailyCore

private final class CleanupFixture {
    let root: URL
    init() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = ProcessInfo.processInfo.environment["MACDAILY_TEST_TMP"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? repository.appendingPathComponent("tmp/storage-cleanup/fixtures", isDirectory: true)
        root = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func file(_ name: String, _ data: Data = Data("same-content".utf8)) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url); return url
    }
    func entry(_ name: String) throws -> StorageEntry { try StorageFileSystem.entry(at: root.appendingPathComponent(name)) }
    func find(roots: [URL]? = nil, preferred: [String] = []) throws -> DuplicateScanResult {
        try DuplicateFinder.find(roots: roots ?? [root], preferredKeepPaths: preferred,
                                 scratchDirectory: root.appendingPathComponent("scan-index"))
    }
    func service(failNames: Set<String> = []) -> CleanupService {
        CleanupService(allowedRoots: [root], trasher: { [root] url in
            if failNames.contains(url.lastPathComponent) { throw CocoaError(.fileWriteNoPermission) }
            let destination = root.appendingPathComponent("fake-trash/\(UUID().uuidString)-\(url.lastPathComponent)")
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: destination); return destination
        })
    }
}

struct StorageDuplicateTests {
    @Test func sameContentUsesBytesNotNamesAndHonorsPreferredFolder() throws {
        let f = try CleanupFixture()
        let first = try f.file("a.txt"), second = try f.file("keep/renamed.bin")
        _ = try f.file("other/a.txt", Data("different!!!".utf8))
        let result = try f.find(preferred: [second.deletingLastPathComponent().path])
        #expect(result.completed); #expect(result.groups.count == 1)
        #expect(Set(result.groups[0].members.map(\.path)) == Set([first.path, second.path]))
        #expect(result.groups[0].preferredKeepPath == second.path)
    }
    @Test func sameSamplesDifferentMiddleAreNotDuplicates() throws {
        let f = try CleanupFixture(); var a = Data(repeating: 65, count: 256 * 1024), b = a
        a[100_000] = 1; b[100_000] = 2
        _ = try f.file("a", a); _ = try f.file("b", b)
        #expect(try f.find().groups.isEmpty)
    }
    @Test func hardLinksDoNotBecomeReclaimableCopies() throws {
        let f = try CleanupFixture(); let a = try f.file("a")
        try FileManager.default.linkItem(at: a, to: f.root.appendingPathComponent("hardlink"))
        _ = try f.file("copy")
        let result = try f.find()
        #expect(result.groups.count == 1); #expect(result.groups[0].members.count == 2)
        #expect(Set(result.groups[0].members.map(\.identity)).count == 2)
    }
    @Test func symlinksAndPackagesAndEnvironmentsAreSkipped() throws {
        let f = try CleanupFixture(); let original = try f.file("a")
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("link"), withDestinationURL: original)
        _ = try f.file("product.app/Contents/copy")
        _ = try f.file("environment/pyvenv.cfg")
        _ = try f.file("environment/copy")
        _ = try f.file(".git/copy"); _ = try f.file("models/copy"); _ = try f.file(".cache/copy")
        #expect(try f.find().groups.isEmpty)
    }
    @Test func changedEntriesAndPlaceholdersCannotBeCompared() throws {
        let f = try CleanupFixture(); let a = try f.file("a"); _ = try f.file("b")
        let old = try f.entry("a"), b = try f.entry("b")
        try Data("changed-content".utf8).write(to: a)
        #expect(throws: (any Error).self) { try DuplicateFinder.contentsEqual(old, b) }
        var cloud = b; cloud.isCloudPlaceholder = true
        #expect(throws: (any Error).self) { try DuplicateFinder.contentsEqual(cloud, old) }
    }
    @Test func cancellationStopsComparison() throws {
        let f = try CleanupFixture(); _ = try f.file("a"); _ = try f.file("b")
        #expect(throws: CancellationError.self) {
            try DuplicateFinder.find(roots: [f.root], scratchDirectory: f.root.appendingPathComponent("scan-index"), isCancelled: { true })
        }
    }
    @Test func overlappingRootsDoNotProduceRepeatedMembers() throws {
        let f = try CleanupFixture(); _ = try f.file("a"); _ = try f.file("child/b")
        let result = try f.find(roots: [f.root, f.root.appendingPathComponent("child")])
        #expect(result.groups.count == 1); #expect(result.groups[0].members.count == 2)
    }
}

struct StorageCleanupTests {
    @Test func trashIsInjectedAndReportsMovedBytesNotFreed() throws {
        let f = try CleanupFixture(); let url = try f.file("a"), entry = try f.entry("a")
        let service = f.service(), preview = try service.preview([.init(entry: entry, reason: "手动选择")])
        #expect(preview.items.count == 1)
        let results = service.execute(preview)
        #expect(results.count == 1); #expect(results[0].status == .moved)
        #expect(results[0].movedBytes == entry.allocatedBytes)
        #expect(results[0].message.contains("不代表")); #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: try #require(results[0].trashURL).path))
    }
    @Test func staleSelectionIsRejectedBeforePreview() throws {
        let f = try CleanupFixture(); let a = try f.file("a"), old = try f.entry("a")
        try Data("new-version".utf8).write(to: a)
        let preview = try f.service().preview([.init(entry: old, reason: "手动")])
        #expect(preview.items.isEmpty); #expect(!preview.issues.isEmpty)
        #expect(FileManager.default.fileExists(atPath: a.path))
    }
    @Test func fileReplacementAfterPreviewIsSkipped() throws {
        let f = try CleanupFixture(); let a = try f.file("a")
        let service = f.service(), preview = try service.preview([.init(entry: try f.entry("a"), reason: "手动")])
        try FileManager.default.removeItem(at: a); try Data("replacement".utf8).write(to: a)
        #expect(service.execute(preview)[0].status == .skipped)
        #expect(FileManager.default.fileExists(atPath: a.path))
    }
    @Test func directoryChangesInvalidatePreviewIncludingDeepContents() throws {
        let f = try CleanupFixture(); let deep = try f.file("folder/child/a")
        let service = f.service(), preview = try service.preview([.init(entry: try f.entry("folder"), reason: "手动")])
        #expect(preview.items.count == 1)
        try Data("changed deep file".utf8).write(to: deep)
        #expect(service.execute(preview)[0].status == .skipped)
        let second = try service.preview([.init(entry: try f.entry("folder"), reason: "手动")])
        _ = try f.file("folder/new")
        #expect(service.execute(second)[0].status == .skipped)
    }
    @Test func parentAndChildSelectionsAreNotDoubleCounted() throws {
        let f = try CleanupFixture(); _ = try f.file("folder/a")
        let service = f.service()
        let preview = try service.preview([.init(entry: try f.entry("folder"), reason: "目录"), .init(entry: try f.entry("folder/a"), reason: "文件")])
        #expect(preview.items.count == 1); #expect(preview.issues.count == 1)
        #expect(preview.totalBytes == (try f.entry("folder/a")).allocatedBytes)
    }
    @Test func symlinkSelectionAndSymlinkAncestorAreRejected() throws {
        let f = try CleanupFixture(); let file = try f.file("folder/a")
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("alias"), withDestinationURL: file)
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("folder-alias"), withDestinationURL: file.deletingLastPathComponent())
        let preview = try f.service().preview([.init(entry: try f.entry("alias"), reason: "手动"), .init(entry: try f.entry("folder-alias/a"), reason: "手动")])
        #expect(preview.items.isEmpty); #expect(preview.issues.count == 2)
    }
    @Test func missingKeeperOrSelectingEveryCopyPreventsCleanup() throws {
        let f = try CleanupFixture(); let a = try f.file("a"), b = try f.file("b")
        let ea = try f.entry("a"), eb = try f.entry("b"), service = f.service()
        let preview = try service.preview([.init(entry: ea, reason: "重复", kind: .duplicate, retainedEntries: [eb])])
        #expect(preview.items.count == 1)
        try FileManager.default.removeItem(at: b)
        #expect(service.execute(preview)[0].status == .skipped)
        _ = try f.file("b"); let freshB = try f.entry("b")
        let all = try service.preview([.init(entry: ea, reason: "重复", kind: .duplicate, retainedEntries: [freshB]), .init(entry: freshB, reason: "重复", kind: .duplicate, retainedEntries: [ea])])
        #expect(all.items.isEmpty); #expect(FileManager.default.fileExists(atPath: a.path))
    }
    @Test func trashFailureDoesNotFallBackAndPartialSuccessIsExplicit() throws {
        let f = try CleanupFixture(); let a = try f.file("a"), b = try f.file("b")
        let service = f.service(failNames: ["b"])
        let preview = try service.preview([.init(entry: try f.entry("a"), reason: "手动"), .init(entry: try f.entry("b"), reason: "手动")])
        let result = service.execute(preview)
        #expect(result.filter { $0.status == .moved }.count == 1)
        #expect(result.filter { $0.status == .failed }.count == 1)
        #expect(!FileManager.default.fileExists(atPath: a.path)); #expect(FileManager.default.fileExists(atPath: b.path))
    }
    @Test func cancellationLeavesEveryItemUntouched() throws {
        let f = try CleanupFixture(); let a = try f.file("a"), service = f.service()
        let preview = try service.preview([.init(entry: try f.entry("a"), reason: "手动")])
        #expect(service.execute(preview, isCancelled: { true })[0].status == .skipped)
        #expect(FileManager.default.fileExists(atPath: a.path))
    }
    @Test func protectedDescendantRefusesManualDirectory() throws {
        let f = try CleanupFixture(); _ = try f.file("folder/.git/config")
        let preview = try f.service().preview([.init(entry: try f.entry("folder"), reason: "手动")])
        #expect(preview.items.isEmpty); #expect(!preview.issues.isEmpty)
    }
    @Test func specialFilesAreRefusedWithoutOpeningThem() throws {
        let f = try CleanupFixture(); let pipe = f.root.appendingPathComponent("pipe")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        let preview = try f.service().preview([.init(entry: try f.entry("pipe"), reason: "手动")])
        #expect(preview.items.isEmpty); #expect(!preview.issues.isEmpty)
    }
    @Test func packageInternalSelectionCannotBypassProtection() throws {
        let f = try CleanupFixture(); _ = try f.file("Example.app/Contents/resource.txt")
        #expect(try f.service().preview([.init(entry: try f.entry("Example.app/Contents/resource.txt"), reason: "手动")]).items.isEmpty)
    }
    @Test func manualCacheAndAncestorCannotBypassCacheRules() throws {
        let f = try CleanupFixture(); _ = try f.file("Library/Caches/pip/a")
        let service = f.service()
        let preview = try service.preview([
            .init(entry: try f.entry("Library/Caches/pip"), reason: "手动"),
            .init(entry: try f.entry("Library"), reason: "父目录")])
        #expect(preview.items.isEmpty); #expect(!preview.issues.isEmpty)
    }
    @Test func externalAllowedRootCannotAdmitUnselectedSibling() throws {
        let f = try CleanupFixture(); _ = try f.file("allowed/a"); _ = try f.file("other/b")
        let service = CleanupService(allowedRoots: [f.root.appendingPathComponent("allowed")], trasher: { _ in nil })
        #expect(try service.preview([.init(entry: try f.entry("other/b"), reason: "手动")]).items.isEmpty)
        #expect(try service.preview([.init(entry: try f.entry("allowed"), reason: "手动")]).items.isEmpty)
    }
}

struct StorageCacheRuleTests {
    @Test func catalogUsesExplicitRulesAndNeverIncludesSensitiveCaches() throws {
        let f = try CleanupFixture()
        let rules = CacheRules.catalog(home: f.root, applications: [.init(bundleIdentifier: "org.example.editor", name: "Editor"), .init(bundleIdentifier: "com.apple.CloudKit", name: "Cloud"), .init(bundleIdentifier: "com.google.Chrome", name: "Chrome"), .init(bundleIdentifier: "../../Documents", name: "Bad")])
        #expect(rules.contains { $0.id == "app:org.example.editor" })
        #expect(!rules.contains { $0.kind == .application && ($0.id.contains("CloudKit") || $0.id.contains("Chrome") || $0.id.contains("../")) })
        #expect(rules.first { $0.id == "uv" }?.canClean == false)
        #expect(rules.first { $0.id == "pnpm" }?.canClean == false)
        #expect(rules.first { $0.id == "npm" }?.rootPath.hasSuffix(".npm/_cacache") == true)
    }
    @Test func logsOnlyOfferOldRecognizedFilesAndBusyCacheCannotBeTrashed() throws {
        let f = try CleanupFixture(); let old = try f.file("Library/Logs/old.log")
        _ = try f.file("Library/Logs/new.log"); _ = try f.file("Library/Logs/settings.db")
        let date = Date().addingTimeInterval(-40 * 86400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: old.path)
        _ = try f.file("Library/Caches/pip/a")
        let rules = CacheRules.catalog(home: f.root)
        let candidates = try CacheRules.discover(rules: rules)
        #expect(candidates.filter { $0.ruleID == "logs" }.map(\.entry.path) == [old.path])
        let pip = try #require(candidates.first { $0.ruleID == "pip" })
        let service = CleanupService(allowedRoots: [f.root], cacheRules: rules, busyProcessNames: { ["python3"] }, trasher: { _ in nil })
        let preview = try service.preview([pip.selection])
        #expect(preview.items.isEmpty); #expect(preview.issues.contains { $0.contains("运行") })
    }
    @Test func knownAppLogsUseOwnerRuleAndUnknownLogsAreAnalysisOnly() throws {
        let f = try CleanupFixture()
        let known = try f.file("Library/Logs/org.example.editor/old.log")
        let unknown = try f.file("Library/Logs/unknown.log")
        let date = Date().addingTimeInterval(-40 * 86400)
        for file in [known, unknown] { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path) }
        let rules = CacheRules.catalog(home: f.root, applications: [.init(bundleIdentifier: "org.example.editor", name: "Editor")])
        let found = try CacheRules.discover(rules: rules)
        #expect(found.filter { $0.entry.path == known.path }.count == 1)
        let owned = try #require(found.first { $0.entry.path == known.path })
        #expect(owned.canClean); #expect(owned.rule.isBusy(processNames: ["Editor"]))
        #expect(found.first { $0.entry.path == unknown.path }?.canClean == false)
        #expect(owned.rule.isBusy(processNames: ["__MACDAILY_PROCESS_CHECK_FAILED__"]))
    }
    @Test func analysisOnlyCacheNeverPassesPreviewAndWholeCacheRequired() throws {
        let f = try CleanupFixture(); _ = try f.file(".cache/uv/a"); _ = try f.file(".npm/_cacache/a")
        let rules = CacheRules.catalog(home: f.root), service = CleanupService(allowedRoots: [f.root], cacheRules: rules, trasher: { _ in nil })
        let uv = try #require(CacheRules.discover(rules: rules).first { $0.ruleID == "uv" })
        #expect(try service.preview([uv.selection]).items.isEmpty)
        let child = CleanupSelection(entry: try f.entry(".npm/_cacache/a"), reason: "缓存", kind: .cache, cacheRuleID: "npm")
        #expect(try service.preview([child]).items.isEmpty)
    }
}

extension StorageCleanupTests {
    @Test func startupDataAliasMapsOnlyMatchingUserFile() throws {
        let f = try CleanupFixture()
        let url = try f.file("ordinary-alias-check.txt")
        let alias = URL(fileURLWithPath: "/System/Volumes/Data" + url.path)
        guard FileManager.default.fileExists(atPath: alias.path) else { return }
        let raw = try StorageFileSystem.entry(at: alias)
        let normalized = StorageSafetyPolicy.normalizedUserEntry(raw)
        #expect(normalized.path == url.path)
        #expect(normalized.identity == raw.identity)
        let preview = try f.service().preview([.init(entry: raw, reason: "隔离别名测试")])
        #expect(preview.items.count == 1)
        #expect(preview.items.first?.entry.path == url.path)
        var replaced = raw
        replaced.identity = "not-the-current-file"
        #expect(StorageSafetyPolicy.normalizedUserEntry(replaced).path == alias.path)
    }
    @Test func changedVolumeIdentityNeverPassesPreview() throws {
        let f = try CleanupFixture()
        let file = try f.file("volume-check.txt")
        var entry = try StorageFileSystem.entry(at: file)
        entry.volumeID = "different-volume"
        let preview = try f.service().preview([.init(entry: entry, reason: "卷身份测试")])
        #expect(preview.items.isEmpty)
        #expect(!preview.issues.isEmpty)
    }
}
