import Darwin
import Foundation
import Testing
@testable import MacDailyCore

struct StorageScannerTests {
    private func fixture(_ run: (URL) throws -> Void) throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = repo.appendingPathComponent("tmp/storage-scan/fixtures/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try run(folder)
    }
    private func write(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5a, count: bytes).write(to: url)
    }
    @Test func scanAndPageHierarchyWithoutReadingContents() throws {
        try fixture { base in
            let root = base.appendingPathComponent("input"), index = base.appendingPathComponent("session")
            try write(root.appendingPathComponent("a/small.txt"), bytes: 10)
            try write(root.appendingPathComponent("a/large.txt"), bytes: 3000)
            try write(root.appendingPathComponent("b.bin"), bytes: 100)
            let result = try StorageScanner.scan(root: root, indexDirectory: index)
            #expect(result.coverage.completed); #expect(result.coverage.files == 3)
            #expect(result.totalLogicalBytes == 3110)
            let page = try StorageIndex.query(result: result, directory: root, query: .init(metric: .logical))
            #expect(page.totalCount == 2); #expect(page.items.first?.name == "a")
            #expect(page.items.first?.logicalBytes == 3010)
            let files = try StorageIndex.query(result: result, query: .init(minimumLogicalBytes: 50, metric: .logical, offset: 1, limit: 1))
            #expect(files.totalCount == 2); #expect(files.items.first?.name == "b.bin")
            let txt = try StorageIndex.query(result: result, query: .init(search: "large", fileExtension: ".txt"))
            #expect(txt.totalCount == 1)
            #expect(throws: (any Error).self) { try StorageIndex.query(result: result, directory: base) }
        }
    }
    @Test func skipsSymlinkLoopsAndOwnIndexAndExplicitExclusions() throws {
        try fixture { root in
            try write(root.appendingPathComponent("keep.bin"), bytes: 23)
            try write(root.appendingPathComponent("excluded/private.bin"), bytes: 50)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
            let index = root.appendingPathComponent("cache/session")
            let result = try StorageScanner.scan(root: root, indexDirectory: index, excludedPaths: [root.appendingPathComponent("excluded").path])
            #expect(result.totalLogicalBytes == 23)
            #expect(result.coverage.skippedSymlinks == 1)
            #expect(result.coverage.skippedExcluded >= 2)
            #expect(result.coverage.hasOmissions)
            #expect(result.coverage.files == 1)
        }
    }
    @Test func hardLinksCountAllocationOnceAndSparseLogicalSizeIsSeparate() throws {
        try fixture { base in
            let root = base.appendingPathComponent("input"), original = root.appendingPathComponent("a.bin")
            try write(original, bytes: 8192)
            try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("b.bin"))
            let sparse = root.appendingPathComponent("sparse.bin")
            FileManager.default.createFile(atPath: sparse.path, contents: nil)
            let file = try FileHandle(forWritingTo: sparse); try file.truncate(atOffset: 10_000_000); try file.close()
            let source = try StorageFileSystem.entry(at: original), other = try StorageFileSystem.entry(at: root.appendingPathComponent("b.bin"))
            #expect(source.identity == other.identity)
            let sparseEntry = try StorageFileSystem.entry(at: sparse)
            #expect(sparseEntry.logicalBytes == 10_000_000)
            #expect(sparseEntry.allocatedBytes < sparseEntry.logicalBytes)
            let result = try StorageScanner.scan(root: root, indexDirectory: base.appendingPathComponent("session"))
            #expect(result.totalLogicalBytes == 10_016_384)
            #expect(result.totalAllocatedBytes == source.allocatedBytes + sparseEntry.allocatedBytes)
        }
    }
    @Test func packageRollupRemainsSingleVisibleItem() throws {
        try fixture { base in
            let root = base.appendingPathComponent("input"), package = root.appendingPathComponent("Example.app")
            try write(package.appendingPathComponent("Contents/Resources/payload.bin"), bytes: 1000)
            let result = try StorageScanner.scan(root: root, indexDirectory: base.appendingPathComponent("session"))
            let page = try StorageIndex.query(result: result, directory: root)
            #expect(page.totalCount == 1); #expect(page.items.first?.entry.isPackage == true)
            #expect(page.items.first?.logicalBytes == 1000)
            #expect(try StorageIndex.query(result: result).items.isEmpty)
        }
    }
    @Test func cancellationReturnsExplicitPartialResult() throws {
        try fixture { base in
            let root = base.appendingPathComponent("input")
            try write(root.appendingPathComponent("a"), bytes: 1)
            let result = try StorageScanner.scan(root: root, indexDirectory: base.appendingPathComponent("session"), isCancelled: { true })
            #expect(result.coverage.cancelled); #expect(!result.coverage.completed)
            #expect(result.coverage.files == 0); #expect(result.coverage.hasOmissions)
        }
    }
    @Test func rootNormalizationAndSymlinkAncestorAreConservative() throws {
        try fixture { base in
            let root = base.appendingPathComponent("input")
            try write(root.appendingPathComponent("a"), bytes: 1)
            let link = base.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
            #expect(StorageFileSystem.hasSymlinkAncestor(link.appendingPathComponent("a")))
            #expect(!StorageFileSystem.hasSymlinkAncestor(root.appendingPathComponent("a")))
            #expect(StorageFileSystem.normalizedRoots([root, root.appendingPathComponent("nested"), root]).count == 1)
            #expect(!StorageFileSystem.isInside(path: root.path + "2", root: root.path))
            #expect(throws: (any Error).self) { try StorageScanner.scan(root: link, indexDirectory: base.appendingPathComponent("session")) }
            #expect(throws: (any Error).self) { try StorageScanner.scan(root: root, indexDirectory: link.appendingPathComponent("index")) }
        }
    }
    @Test func metadataSignatureChangesWhenFileReplaced() throws {
        try fixture { root in
            let file = root.appendingPathComponent("file")
            try write(file, bytes: 12)
            let before = try StorageFileSystem.entry(at: file)
            try Data(repeating: 0x31, count: 12).write(to: file, options: .atomic)
            let after = try StorageFileSystem.entry(at: file)
            #expect(before.metadataSignature != after.metadataSignature)
            #expect(before.logicalBytes == after.logicalBytes)
        }
    }
    @Test func unreadableDirectoryIsReportedWhenOSDeniesIt() throws {
        try fixture { base in
            let root = base.appendingPathComponent("input"), denied = root.appendingPathComponent("denied")
            try write(denied.appendingPathComponent("private"), bytes: 12)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
            let result = try StorageScanner.scan(root: root, indexDirectory: base.appendingPathComponent("session"))
            if getuid() != 0 { #expect(result.coverage.errors > 0); #expect(result.coverage.hasOmissions) }
        }
    }
    @Test func appOwnedMarkerIsAcceptedButOtherExistingContentsAreRejected() throws {
        try fixture { base in
            let root = base.appendingPathComponent("input"), session = base.appendingPathComponent("owned")
            try write(root.appendingPathComponent("file"), bytes: 10)
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            let marker = session.appendingPathComponent(".macdaily-session")
            try Data("MacDaily storage session".utf8).write(to: marker)
            let result = try StorageScanner.scan(root: root, indexDirectory: session)
            #expect(result.coverage.files == 1)
            #expect(throws: (any Error).self) { try StorageScanner.scan(root: root, indexDirectory: session) }
            let malformed = base.appendingPathComponent("bad")
            try write(malformed.appendingPathComponent(".macdaily-session"), bytes: 10)
            #expect(throws: (any Error).self) { try StorageScanner.scan(root: root, indexDirectory: malformed) }
        }
    }
    @Test func cloudClassificationDoesNotNeedToOpenCloudContent() {
        #expect(StorageFileSystem.isCloudPlaceholder(fileFlags: 0x40000000))
        #expect(StorageFileSystem.isCloudPlaceholder(fileFlags: 0, ubiquitous: true, downloaded: false))
        #expect(!StorageFileSystem.isCloudPlaceholder(fileFlags: 0, ubiquitous: true, downloaded: true))
        #expect(!StorageFileSystem.isCloudPlaceholder(fileFlags: 0))
    }
    @Test func heapPaginationMatchesCompleteOrderInBothDirections() throws {
        try fixture { base in
            let root = base.appendingPathComponent("input")
            for i in 0..<130 { try write(root.appendingPathComponent("file-\(i).bin"), bytes: i + 1) }
            let result = try StorageScanner.scan(root: root, indexDirectory: base.appendingPathComponent("session"))
            for order in [StorageSort.sizeAscending, .sizeDescending] {
                let all = try StorageIndex.query(result: result, query: .init(sort: order, metric: .logical, limit: 1000))
                let page = try StorageIndex.query(result: result, query: .init(sort: order, metric: .logical, offset: 47, limit: 17))
                #expect(page.totalCount == 130)
                #expect(page.items == Array(all.items.dropFirst(47).prefix(17)))
            }
        }
    }
    @Test func corruptIndexNeverLooksLikeEmptySuccessfulResults() throws {
        try fixture { base in
            let root = base.appendingPathComponent("input")
            try write(root.appendingPathComponent("a"), bytes: 1)
            let result = try StorageScanner.scan(root: root, indexDirectory: base.appendingPathComponent("session"))
            try Data("broken".utf8).write(to: #require(result.indexFiles.first))
            #expect(throws: (any Error).self) { try StorageIndex.query(result: result) }
        }
    }
}
