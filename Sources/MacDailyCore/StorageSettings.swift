import Foundation

public enum StorageSizeMetric: String, Codable, CaseIterable, Sendable {
    case allocated, logical
    public var title: String { self == .allocated ? L10n.text("磁盘占用估算") : L10n.text("文件大小") }
}
public struct StorageSettings: Codable, Equatable, Sendable {
    public var minimumLargeFileBytes: Int64 = 100_000_000
    public var sizeMetric: StorageSizeMetric = .allocated
    public var excludedPaths: [String] = []
    public var preferredKeepPaths: [String] = []
    public init() {}
    public func validated() throws -> Self {
        guard (1_000_000...10_000_000_000_000).contains(minimumLargeFileBytes),
              excludedPaths.count <= 128, preferredKeepPaths.count <= 128,
              (excludedPaths + preferredKeepPaths).allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4096 }),
              Set(excludedPaths).count == excludedPaths.count,
              Set(preferredKeepPaths).count == preferredKeepPaths.count else {
            throw ConfigurationError.invalid(L10n.text("空间设置中的路径或大小无效"))
        }
        return self
    }
}
