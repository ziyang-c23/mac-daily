import Foundation

public enum ApplicationSort: String, Codable, CaseIterable, Sendable {
    case name, size, lastUsed
    public var title: String {
        switch self {
        case .name: L10n.text("名称")
        case .size: L10n.text("大小")
        case .lastUsed: L10n.text("上次使用")
        }
    }
}

public struct ApplicationsSettings: Codable, Equatable, Sendable {
    public var extraScanDirectories: [String] = []
    public var ignoredPaths: [String] = []
    public var sort: ApplicationSort = .name
    public var showSystemApps = false
    public init() {}
}
