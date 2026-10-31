import Foundation

public struct MenuBarSettings: Codable, Equatable, Sendable {
    public var enabled = false
    /// Zero keeps a manual reveal open until the user closes it.
    public var autoHideDelay = 5.0
    public init() {}
    public func validated() throws -> Self {
        guard [0.0, 5, 10, 15, 30].contains(autoHideDelay) else {
            throw ConfigurationError.invalid(L10n.text("请选择菜单栏的收起时间"))
        }
        return self
    }
}
