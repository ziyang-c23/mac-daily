import Foundation

public enum WindowAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds
    case maximize, center, restore, nextDisplay, previousDisplay
    public var id: String { rawValue }
    public var title: String { L10n.text(canonicalTitle) }
    public var canonicalTitle: String {
        switch self {
        case .leftHalf: "左半屏"
        case .rightHalf: "右半屏"
        case .topHalf: "上半屏"
        case .bottomHalf: "下半屏"
        case .topLeft: "左上角"
        case .topRight: "右上角"
        case .bottomLeft: "左下角"
        case .bottomRight: "右下角"
        case .leftThird: "左侧三分之一"
        case .centerThird: "中间三分之一"
        case .rightThird: "右侧三分之一"
        case .leftTwoThirds: "左侧三分之二"
        case .rightTwoThirds: "右侧三分之二"
        case .maximize: "填满屏幕"
        case .center: "居中"
        case .restore: "还原窗口"
        case .nextDisplay: "移到下一显示器"
        case .previousDisplay: "移到上一显示器"
        }
    }
}

public struct WindowAppException: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var bundleIdentifier: String
    public var name: String
    public init(id: UUID = UUID(), bundleIdentifier: String, name: String) {
        self.id = id; self.bundleIdentifier = bundleIdentifier; self.name = name
    }
}

public struct WindowSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var gap = 0.0
    public var edgeThreshold = 20.0
    public var previewEnabled = true
    public var restoreOnDrag = true
    public var excludedApps: [WindowAppException] = []
    public var activationMode: WindowActivationMode = .standard
    public var activationProfile = WindowActivationProfile.recommended
    public var highlightActivationAreas = true
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case enabled, gap, edgeThreshold, previewEnabled, restoreOnDrag, excludedApps
        case activationMode, activationProfile, highlightActivationAreas
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        gap = try values.decode(Double.self, forKey: .gap)
        edgeThreshold = try values.decode(Double.self, forKey: .edgeThreshold)
        previewEnabled = try values.decode(Bool.self, forKey: .previewEnabled)
        restoreOnDrag = try values.decode(Bool.self, forKey: .restoreOnDrag)
        excludedApps = try values.decode([WindowAppException].self, forKey: .excludedApps)
        activationMode = try values.decodeIfPresent(WindowActivationMode.self, forKey: .activationMode) ?? .standard
        activationProfile = try values.decodeIfPresent(WindowActivationProfile.self, forKey: .activationProfile) ?? .recommended
        highlightActivationAreas = try values.decodeIfPresent(Bool.self, forKey: .highlightActivationAreas) ?? true
    }
    public func excludes(_ bundleIdentifier: String) -> Bool {
        excludedApps.contains { $0.bundleIdentifier == bundleIdentifier }
    }
    public func validated() throws -> WindowSettings {
        _ = try activationProfile.validated()
        guard gap.isFinite, (0...32).contains(gap), edgeThreshold.isFinite, (8...48).contains(edgeThreshold),
              excludedApps.count <= 128,
              Set(excludedApps.map(\.id)).count == excludedApps.count,
              Set(excludedApps.map(\.bundleIdentifier)).count == excludedApps.count,
              excludedApps.allSatisfy({ !$0.bundleIdentifier.isEmpty && $0.bundleIdentifier.count < 256 && $0.name.count < 256 }) else {
            throw ConfigurationError.invalid(L10n.text("窗口参数或应用例外无效"))
        }
        return self
    }
}

/// Coordinates use Quartz/Accessibility conventions: top-left origin, Y down.
/// Pass the display's *visible* frame here to respect menu bars and the Dock.
public enum WindowGeometry {
    public static func isValid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0 && rect.maxX.isFinite && rect.maxY.isFinite
    }

    public static func frame(for action: WindowAction, in screen: CGRect, current: CGRect, gap: Double = 0) -> CGRect? {
        guard isValid(screen), isValid(current), gap.isFinite, (0...32).contains(gap) else { return nil }
        let available = screen.insetBy(dx: gap, dy: gap)
        guard isValid(available) else { return nil }
        func cell(_ start: Int, _ end: Int, _ count: Int, _ length: CGFloat) -> (CGFloat, CGFloat)? {
            let unit = (length - CGFloat(count - 1) * gap) / CGFloat(count)
            guard unit > 0 else { return nil }
            return (CGFloat(start) * (unit + gap), CGFloat(end - start) * unit + CGFloat(end - start - 1) * gap)
        }
        func tile(x: (Int, Int, Int), y: (Int, Int, Int)) -> CGRect? {
            guard let horizontal = cell(x.0, x.1, x.2, available.width),
                  let vertical = cell(y.0, y.1, y.2, available.height) else { return nil }
            return CGRect(x: available.minX + horizontal.0, y: available.minY + vertical.0,
                          width: horizontal.1, height: vertical.1)
        }
        switch action {
        case .leftHalf: return tile(x: (0, 1, 2), y: (0, 1, 1))
        case .rightHalf: return tile(x: (1, 2, 2), y: (0, 1, 1))
        case .topHalf: return tile(x: (0, 1, 1), y: (0, 1, 2))
        case .bottomHalf: return tile(x: (0, 1, 1), y: (1, 2, 2))
        case .topLeft: return tile(x: (0, 1, 2), y: (0, 1, 2))
        case .topRight: return tile(x: (1, 2, 2), y: (0, 1, 2))
        case .bottomLeft: return tile(x: (0, 1, 2), y: (1, 2, 2))
        case .bottomRight: return tile(x: (1, 2, 2), y: (1, 2, 2))
        case .leftThird: return tile(x: (0, 1, 3), y: (0, 1, 1))
        case .centerThird: return tile(x: (1, 2, 3), y: (0, 1, 1))
        case .rightThird: return tile(x: (2, 3, 3), y: (0, 1, 1))
        case .leftTwoThirds: return tile(x: (0, 2, 3), y: (0, 1, 1))
        case .rightTwoThirds: return tile(x: (1, 3, 3), y: (0, 1, 1))
        case .maximize: return available
        case .center:
            let size = CGSize(width: min(current.width, available.width), height: min(current.height, available.height))
            return CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2, width: size.width, height: size.height)
        case .restore, .nextDisplay, .previousDisplay: return nil
        }
    }
}

/// Hit zones use the full display frame; do not pass the Dock/menu-bar inset.
public enum SnapZoneResolver {
    public static func action(at point: CGPoint, screen: CGRect, threshold: Double = 20) -> WindowAction? {
        guard WindowGeometry.isValid(screen), point.x.isFinite, point.y.isFinite,
              threshold.isFinite, (8...48).contains(threshold),
              screen.insetBy(dx: -3, dy: -3).contains(point) else { return nil }
        let edge = min(threshold, min(screen.width, screen.height) / 4)
        let corner = min(80.0, min(screen.width, screen.height) / 5)
        let left = point.x <= screen.minX + edge, right = point.x >= screen.maxX - edge
        let top = point.y <= screen.minY + edge, bottom = point.y >= screen.maxY - edge
        if (left && point.y <= screen.minY + corner) || (top && point.x <= screen.minX + corner) { return .topLeft }
        if (right && point.y <= screen.minY + corner) || (top && point.x >= screen.maxX - corner) { return .topRight }
        if (left && point.y >= screen.maxY - corner) || (bottom && point.x <= screen.minX + corner) { return .bottomLeft }
        if (right && point.y >= screen.maxY - corner) || (bottom && point.x >= screen.maxX - corner) { return .bottomRight }
        if left { return .leftHalf }
        if right { return .rightHalf }
        if top { return .maximize }
        if bottom {
            switch bottomColumn(point, screen: screen) { case 0: return .leftThird; case 1: return .centerThird; default: return .rightThird }
        }
        return nil
    }
    fileprivate static func bottomColumn(_ point: CGPoint, screen: CGRect) -> Int {
        min(2, max(0, Int(floor((point.x - screen.minX) / screen.width * 3))))
    }
}

/// Entering a bottom third selects it. Sliding into an adjacent third expands
/// the preview to two thirds. Leaving that edge or changing display resets it.
public struct SnapZoneTracker {
    private var bottomAnchor: Int?
    private var lastScreen: CGRect?
    public init() {}
    public mutating func reset() { bottomAnchor = nil; lastScreen = nil }
    public mutating func action(at point: CGPoint, screen: CGRect, threshold: Double = 20) -> WindowAction? {
        if lastScreen != screen { bottomAnchor = nil; lastScreen = screen }
        guard let action = SnapZoneResolver.action(at: point, screen: screen, threshold: threshold) else {
            bottomAnchor = nil; return nil
        }
        guard [.leftThird, .centerThird, .rightThird].contains(action) else { bottomAnchor = nil; return action }
        let column = SnapZoneResolver.bottomColumn(point, screen: screen)
        if bottomAnchor == nil { bottomAnchor = column }
        let lower = min(bottomAnchor!, column), upper = max(bottomAnchor!, column)
        switch upper - lower {
        case 0: return action
        case 1: return lower == 0 ? .leftTwoThirds : .rightTwoThirds
        default: return .maximize
        }
    }
}
