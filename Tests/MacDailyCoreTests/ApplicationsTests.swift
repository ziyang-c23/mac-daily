import Foundation
import Testing
@testable import MacDailyCore

private final class ApplicationsFixture {
    let root: URL
    init() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = repository.appendingPathComponent("tmp/apps-core/fixtures/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func file(_ path: String, content: Data = Data("fixture".utf8)) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url); return url
    }
    func app(_ name: String, id: String) throws -> InstalledApplication {
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": "Example", "CFBundleShortVersionString": "2.3", "CFBundleExecutable": "Example"]
        _ = try file("\(name)/Contents/Info.plist", content: PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
        _ = try file("\(name)/Contents/MacOS/Example", content: Data([0xcf,0xfa,0xed,0xfe,0x0c,0,0,1]))
        return try #require(ApplicationInventory.application(at: root.appendingPathComponent(name)))
    }
}

struct ApplicationsTests {
    @Test func registeredCopyOutsideScanRootsKeepsCacheUnselected() throws {
        let f = try ApplicationsFixture()
        let app = try f.app("Applications/One.app", id: "org.example.product")
        let other = try f.app("Builds/Two.app", id: "org.example.product")
        _ = try f.file("Library/Caches/org.example.product/data")
        let related = try ApplicationAssociationResolver.resolve(applications: [app], selectedPaths: [app.path], home: f.root, registeredPaths: { _ in [app.path, other.path] })
        let cache = try #require(related.first { $0.path.hasSuffix("Caches/org.example.product") })
        #expect(cache.category == .shared)
        #expect(!cache.defaultSelected)
        #expect(Set(cache.ownerPaths) == [app.path, other.path])
    }
    @Test func updaterCachesAndSystemPreferencesAreNotOrphanApps() throws {
        let f = try ApplicationsFixture()
        let app = try f.app("Installed.app", id: "org.example.installed")
        _ = try f.file("Library/Caches/org.example.installed.ShipIt/state")
        _ = try f.file("Library/Preferences/group.com.apple.mail.plist")
        _ = try f.file("Library/Preferences/org.example.installed_stats.sqlite3")
        let related = try ApplicationAssociationResolver.resolve(applications: [app], selectedPaths: [app.path], home: f.root)
        #expect(related.contains { $0.path.hasSuffix(".ShipIt") && $0.defaultSelected })
        let leftovers = try ApplicationAssociationResolver.scanLeftovers(applications: [app], home: f.root, registeredPaths: { _ in [] })
        #expect(leftovers.isEmpty)
    }
    @Test func frameworkAliasesDoNotSkipSiblingVersionDirectories() throws {
        let f = try ApplicationsFixture()
        _ = try f.file("Framework/Versions/A/data", content: Data(repeating: 1, count: 2048))
        try FileManager.default.createSymbolicLink(atPath: f.root.appendingPathComponent("Framework/Versions/Current").path, withDestinationPath: "A")
        _ = try f.file("Framework/Versions/B/data", content: Data(repeating: 2, count: 4096))
        try FileManager.default.createSymbolicLink(atPath: f.root.appendingPathComponent("Framework/Resources").path, withDestinationPath: "Versions/Current")
        #expect(try ApplicationInventory.size(at: f.root.appendingPathComponent("Framework")) == 6144)
    }
    @Test func inventoryGroupsNestedHelpersAndFindsClassifiedApps() throws {
        let f = try ApplicationsFixture()
        _ = try f.app("Applications/Product.app", id: "org.example.product")
        _ = try f.app("Applications/Product.app/Contents/Helpers/Helper.app", id: "org.example.helper")
        _ = try f.app("Applications/Utilities/Another.app", id: "org.example.another")
        let apps = try ApplicationInventory.scan(roots: [f.root.appendingPathComponent("Applications")])
        #expect(apps.count == 2)
        #expect(apps.allSatisfy { $0.version == "2.3" && $0.architecture == "Apple Silicon" && $0.bytes > 0 })
    }
    @Test func applicationSymlinkUsesTargetSizeAndMissingSizeIsUnknown() throws {
        let f = try ApplicationsFixture()
        _ = try f.app("Caskroom/Product.app", id: "org.example.product")
        let link = f.root.appendingPathComponent("Applications/Product.app")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.root.appendingPathComponent("Caskroom/Product.app"))
        let apps = try ApplicationInventory.scan(roots: [link.deletingLastPathComponent()])
        #expect(apps.count == 1); #expect(apps[0].path == link.path); #expect(apps[0].bytes > 0)
        #expect(try ApplicationInventory.measuredSize(at: f.root.appendingPathComponent("missing")) == -1)
    }
    @Test func multipleCopiesMakeRelatedCacheOptIn() throws {
        let f = try ApplicationsFixture()
        let a = try f.app("One.app", id: "org.example.product"), b = try f.app("Two.app", id: "org.example.product")
        let cache = try f.file("Library/Caches/org.example.product/cache")
        let items = try ApplicationAssociationResolver.resolve(applications: [a,b], selectedPaths: [a.path], home: f.root)
        let item = try #require(items.first { $0.path == cache.deletingLastPathComponent().path })
        #expect(!item.defaultSelected); #expect(item.category == .shared)
        let all = try ApplicationAssociationResolver.resolve(applications: [a,b], selectedPaths: [a.path,b.path], home: f.root)
        #expect(all.first { $0.path == item.path }?.defaultSelected == true)
    }
    @Test func exactIdentifiersAndDeclaredGroupsDetermineOwnership() throws {
        let f = try ApplicationsFixture()
        var a = try f.app("One.app", id: "org.example.product")
        var b = try f.app("Two.app", id: "org.example.other")
        a.appGroups = ["TEAM.shared"]; b.appGroups = ["TEAM.shared"]
        _ = try f.file("Library/Group Containers/TEAM.shared/data")
        _ = try f.file("Library/Caches/org.example.product/cache")
        _ = try f.file("Library/Caches/org.example.productExtra/cache")
        _ = try f.file("Library/Preferences/org.example.product.plist")
        let items = try ApplicationAssociationResolver.resolve(applications: [a,b], selectedPaths: [a.path], home: f.root)
        #expect(!items.contains { $0.path.contains("productExtra") })
        #expect(items.first { $0.category == .cache }?.defaultSelected == true)
        #expect(items.first { $0.category == .preference }?.defaultSelected == false)
        let group = try #require(items.first { $0.category == .shared })
        #expect(Set(group.ownerIDs) == [a.bundleIdentifier,b.bundleIdentifier]); #expect(!group.defaultSelected)
    }
    @Test func embeddedHelperPreferencesBelongToInstalledHost() throws {
        let f = try ApplicationsFixture()
        _ = try f.app("Applications/Product.app", id: "org.example.product")
        _ = try f.app("Applications/Product.app/Contents/Helpers/Helper.app", id: "org.example.productHelper")
        let preference = try f.file("Library/Preferences/org.example.productHelper.plist")
        let apps = try ApplicationInventory.scan(roots: [f.root.appendingPathComponent("Applications")])
        #expect(apps.count == 1)
        #expect(apps[0].relatedBundleIdentifiers == ["org.example.productHelper"])
        let related = try ApplicationAssociationResolver.resolve(applications: apps, selectedPaths: [apps[0].path], home: f.root)
        let item = try #require(related.first { $0.path == preference.path })
        #expect(item.ownerIDs == ["org.example.product"]); #expect(item.category == .preference)
        let leftovers = try ApplicationAssociationResolver.scanLeftovers(applications: apps, home: f.root, registeredPaths: { _ in [] })
        #expect(leftovers.isEmpty)
    }
    @Test func leftoversConsultRegisteredCopiesAndIgnoreConda() throws {
        let f = try ApplicationsFixture()
        _ = try f.file("Library/Caches/org.example.absent/cache")
        _ = try f.file("Library/Preferences/org.example.present.plist")
        let registered = try f.app("Elsewhere.app", id: "org.example.present")
        _ = try f.file(".conda/config")
        let items = try ApplicationAssociationResolver.scanLeftovers(applications: [], home: f.root, registeredPaths: { id in id == registered.bundleIdentifier ? [registered.path] : [] })
        #expect(items.count == 1); #expect(items[0].ownerIDs == ["org.example.absent"]); #expect(!items[0].defaultSelected)
    }
    @Test func previewMergesParentsAndPaths() {
        let parent = ApplicationRelatedItem(path: "/sample/App.app", category: .application, reason: "", bytes: 20)
        let child = ApplicationRelatedItem(path: "/sample/App.app/Contents/data", category: .data, reason: "", bytes: 10)
        let sibling = ApplicationRelatedItem(path: "/sample/App.app-other", category: .cache, reason: "", bytes: 5)
        let preview = ApplicationCleanupService.preview(items: [parent,child,parent,sibling], selectedIDs: [parent.id,child.id,sibling.id])
        #expect(preview.count == 2); #expect(preview.map(\.bytes).reduce(0,+) == 25)
    }
    @Test func refusedQuitAndTrashFailureLeaveOtherItemsProcessable() async throws {
        let f = try ApplicationsFixture()
        let a = try f.file("a"), b = try f.file("b"), c = try f.file("c")
        let items = [ApplicationRelatedItem(path: a.path, category: .cache, reason: "", ownerPaths: ["blocked"]),
                     ApplicationRelatedItem(path: b.path, category: .cache, reason: ""),
                     ApplicationRelatedItem(path: c.path, category: .cache, reason: "", bytes: 7)]
        let destination = f.root.appendingPathComponent("trashed-c")
        let results = await ApplicationCleanupService.execute(items: items, quit: { $0 != "blocked" }, trash: { url in
            if url == b { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: url, to: destination); return destination
        })
        #expect(results.map(\.status) == [.skipped,.failed,.moved]); #expect(results[2].movedBytes == 7)
        #expect(FileManager.default.fileExists(atPath: a.path)); #expect(!FileManager.default.fileExists(atPath: c.path))
    }
    @Test func cancellationStopsInventoryAndAssociations() throws {
        let f = try ApplicationsFixture(); let a = try f.app("One.app", id: "org.example.product")
        #expect(throws: CancellationError.self) { try ApplicationInventory.scan(roots: [f.root], isCancelled: { true }) }
        #expect(throws: CancellationError.self) { try ApplicationAssociationResolver.resolve(applications: [a], selectedPaths: [a.path], home: f.root, isCancelled: { true }) }
    }
}
