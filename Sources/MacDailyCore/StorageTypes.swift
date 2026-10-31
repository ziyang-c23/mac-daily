import Foundation

public struct StorageEntry: Codable, Equatable, Sendable, Identifiable {
    public var path: String
    public var isDirectory: Bool
    public var isRegularFile: Bool
    public var isPackage: Bool
    public var isSymlink: Bool
    public var isCloudPlaceholder: Bool
    public var isInsidePackage: Bool
    public var logicalBytes: Int64
    public var allocatedBytes: Int64
    public var modifiedAt: Date
    public var linkCount: Int
    public var identity: String
    public var volumeID: String
    public var metadataSignature: String
    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }
    public var name: String { url.lastPathComponent.isEmpty ? path : url.lastPathComponent }
    public init(path: String, isDirectory: Bool = false, isRegularFile: Bool = true, isPackage: Bool = false, isSymlink: Bool = false,
                isCloudPlaceholder: Bool = false, isInsidePackage: Bool = false, logicalBytes: Int64 = 0,
                allocatedBytes: Int64 = 0, modifiedAt: Date = .distantPast, linkCount: Int = 1, identity: String = "",
                volumeID: String = "", metadataSignature: String = "") {
        self.path = path; self.isDirectory = isDirectory; self.isRegularFile = isRegularFile; self.isPackage = isPackage
        self.isSymlink = isSymlink; self.isCloudPlaceholder = isCloudPlaceholder; self.isInsidePackage = isInsidePackage
        self.logicalBytes = logicalBytes; self.allocatedBytes = allocatedBytes; self.modifiedAt = modifiedAt; self.linkCount = linkCount
        self.identity = identity; self.volumeID = volumeID; self.metadataSignature = metadataSignature
    }
}

public struct StorageItem: Codable, Equatable, Sendable, Identifiable {
    public var entry: StorageEntry
    public var logicalBytes: Int64
    public var allocatedBytes: Int64
    public var id: String { entry.id }
    public var path: String { entry.path }
    public var name: String { entry.name }
    public var url: URL { entry.url }
    public var isDirectory: Bool { entry.isDirectory }
    public init(entry: StorageEntry, logicalBytes: Int64? = nil, allocatedBytes: Int64? = nil) {
        self.entry = entry; self.logicalBytes = logicalBytes ?? entry.logicalBytes
        self.allocatedBytes = allocatedBytes ?? entry.allocatedBytes
    }
    public func bytes(for metric: StorageSizeMetric) -> Int64 { metric == .logical ? logicalBytes : allocatedBytes }
}

public enum StorageSort: String, Codable, CaseIterable, Sendable, Identifiable {
    case sizeDescending, sizeAscending, name, modifiedNewest, modifiedOldest
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .sizeDescending: L10n.text("占用从大到小")
        case .sizeAscending: L10n.text("占用从小到大")
        case .name: L10n.text("名称")
        case .modifiedNewest: L10n.text("最近修改")
        case .modifiedOldest: L10n.text("最早修改")
        }
    }
}
public struct StorageQuery: Sendable {
    public var minimumLogicalBytes: Int64
    public var search: String
    public var fileExtension: String
    public var modifiedBefore: Date?
    public var sort: StorageSort
    public var metric: StorageSizeMetric
    public var offset: Int
    public var limit: Int
    public init(minimumLogicalBytes: Int64 = 0, search: String = "", fileExtension: String = "", modifiedBefore: Date? = nil,
                sort: StorageSort = .sizeDescending, metric: StorageSizeMetric = .allocated, offset: Int = 0, limit: Int = 100) {
        self.minimumLogicalBytes = minimumLogicalBytes; self.search = search; self.fileExtension = fileExtension
        self.modifiedBefore = modifiedBefore; self.sort = sort; self.metric = metric; self.offset = offset; self.limit = limit
    }
}
public struct StoragePage: Sendable {
    public var items: [StorageItem]
    public var totalCount: Int
    public init(items: [StorageItem], totalCount: Int) { self.items = items; self.totalCount = totalCount }
}
public struct StorageCoverage: Codable, Equatable, Sendable {
    public var files = 0
    public var directories = 0
    public var skippedSymlinks = 0
    public var skippedCloudFiles = 0
    public var skippedExcluded = 0
    public var skippedMounts = 0
    public var errors = 0
    public var errorSamples: [String] = []
    public var cancelled = false
    public var completed = false
    public init() {}
    public var hasOmissions: Bool { skippedExcluded + skippedMounts + skippedSymlinks + skippedCloudFiles + errors > 0 || cancelled }
}
public struct StorageScanProgress: Sendable {
    public var files: Int
    public var directories: Int
    public var logicalBytes: Int64
    public var allocatedBytes: Int64
    public var currentPath: String
    public init(files: Int, directories: Int, logicalBytes: Int64, allocatedBytes: Int64, currentPath: String) {
        self.files = files; self.directories = directories; self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes; self.currentPath = currentPath
    }
}
public struct StorageScanResult: Sendable {
    public let rootURL: URL
    public let indexDirectory: URL
    public let root: StorageItem
    public let directories: [String: StorageItem]
    public let totalLogicalBytes: Int64
    public let totalAllocatedBytes: Int64
    public let coverage: StorageCoverage
    public let finishedAt: Date
    public let indexFiles: [URL]
    public init(rootURL: URL, indexDirectory: URL, root: StorageItem, directories: [String: StorageItem],
                totalLogicalBytes: Int64, totalAllocatedBytes: Int64, coverage: StorageCoverage, finishedAt: Date, indexFiles: [URL]) {
        self.rootURL = rootURL; self.indexDirectory = indexDirectory; self.root = root; self.directories = directories
        self.totalLogicalBytes = totalLogicalBytes; self.totalAllocatedBytes = totalAllocatedBytes
        self.coverage = coverage; self.finishedAt = finishedAt; self.indexFiles = indexFiles
    }
}
public enum StorageError: LocalizedError {
    case invalidRoot(String), invalidIndex(String), unavailable(String), cancelled
    public var errorDescription: String? {
        switch self {
        case .invalidRoot(let s): L10n.text("无法扫描此位置：%@", String(describing: s))
        case .invalidIndex(let s): L10n.text("无法读取扫描索引：%@", String(describing: s))
        case .unavailable(let s): s
        case .cancelled: L10n.text("扫描已取消")
        }
    }
}
