import Foundation

/// Fractions of a display or its usable frame. Coordinates start at the top left.
public struct NormalizedWindowRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public func validated() throws -> Self {
        guard [x, y, width, height].allSatisfy(\.isFinite), x >= 0, y >= 0,
              width >= 1.0 / 48, height >= 1.0 / 48,
              x + width <= 1.0000000001, y + height <= 1.0000000001 else {
            throw ConfigurationError.invalid(L10n.text("激活区域与窗口位置必须位于屏幕内，且不能小于 1/48 屏幕"))
        }
        return self
    }
    public func frame(in bounds: CGRect) -> CGRect? {
        guard (try? validated()) != nil, WindowGeometry.isValid(bounds) else { return nil }
        return CGRect(x: bounds.minX + x * bounds.width, y: bounds.minY + y * bounds.height,
                      width: width * bounds.width, height: height * bounds.height)
    }
}

public enum WindowActivationMode: String, Codable, CaseIterable, Sendable {
    case standard, custom
}
public enum WindowDisplayOrientation: String, Codable, CaseIterable, Identifiable, Sendable {
    case landscape, portrait
    public var id: String { rawValue }
    public var gridColumns: Int { self == .landscape ? 24 : 12 }
    public var gridRows: Int { self == .landscape ? 12 : 24 }
    public var title: String { self == .landscape ? L10n.text("横屏") : L10n.text("竖屏") }
    public init(screen: CGRect) { self = screen.width >= screen.height ? .landscape : .portrait }
}
public struct WindowActivationArea: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var rect: NormalizedWindowRect
    public var action: WindowAction?
    public var customTarget: NormalizedWindowRect?
    public init(id: UUID = UUID(), name: String, enabled: Bool = true, rect: NormalizedWindowRect,
                action: WindowAction? = nil, customTarget: NormalizedWindowRect? = nil) {
        self.id = id; self.name = name; self.enabled = enabled; self.rect = rect
        self.action = action; self.customTarget = customTarget
    }
    public func validated() throws -> Self {
        _ = try rect.validated()
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 128,
              action != nil || customTarget != nil,
              ![WindowAction.restore, .nextDisplay, .previousDisplay].contains(where: { $0 == action }) else {
            throw ConfigurationError.invalid(L10n.text("激活区域需要名称和可用的窗口布局"))
        }
        if let customTarget { _ = try customTarget.validated() }
        return self
    }
}
public struct WindowActivationProfile: Codable, Equatable, Sendable {
    public var landscape: [WindowActivationArea]
    public var portrait: [WindowActivationArea]
    public init(landscape: [WindowActivationArea] = [], portrait: [WindowActivationArea] = []) {
        self.landscape = landscape; self.portrait = portrait
    }
    public func areas(for orientation: WindowDisplayOrientation) -> [WindowActivationArea] {
        orientation == .landscape ? landscape : portrait
    }
    public func validated() throws -> Self {
        let all = landscape + portrait
        guard landscape.count <= 64, portrait.count <= 64, Set(all.map(\.id)).count == all.count else {
            throw ConfigurationError.invalid(L10n.text("激活区域过多或标识重复"))
        }
        for area in all { _ = try area.validated() }
        return self
    }
    public static let recommended: WindowActivationProfile = {
        func areas(_ orientation: WindowDisplayOrientation) -> [WindowActivationArea] {
            let columns = Double(orientation.gridColumns), rows = Double(orientation.gridRows)
            func region(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ action: WindowAction?, _ target: NormalizedWindowRect? = nil, _ name: String? = nil) -> WindowActivationArea {
                .init(name: name ?? action?.canonicalTitle ?? "自定义布局", rect: .init(x: x / columns, y: y / rows, width: w / columns, height: h / rows), action: action, customTarget: target)
            }
            if orientation == .landscape {
                return [region(0,3,1,6,.leftHalf), region(23,3,1,6,.rightHalf),
                        region(0,1,1,2,.topHalf), region(23,1,1,2,.topHalf),
                        region(0,9,1,2,.bottomHalf), region(23,9,1,2,.bottomHalf),
                        region(0,0,1,1,.topLeft), region(23,0,1,1,.topRight),
                        region(0,11,1,1,.bottomLeft), region(23,11,1,1,.bottomRight),
                        region(1,11,6,1,.leftThird), region(9,11,6,1,.centerThird), region(17,11,6,1,.rightThird),
                        region(7,11,2,1,.leftTwoThirds), region(15,11,2,1,.rightTwoThirds),
                        region(11,10,2,1,nil,.init(x: 1/6, y: 0, width: 2/3, height: 1),"中间三分之二"),
                        region(1,0,22,1,.maximize)]
            }
            return [region(1,23,5,1,.leftHalf), region(6,23,5,1,.rightHalf),
                    region(0,1,1,4,.topHalf), region(11,1,1,4,.topHalf),
                    region(0,19,1,4,.bottomHalf), region(11,19,1,4,.bottomHalf),
                    region(0,0,1,1,.topLeft), region(11,0,1,1,.topRight),
                    region(0,23,1,1,.bottomLeft), region(11,23,1,1,.bottomRight),
                    region(0,5,1,3,nil,.init(x: 0,y: 0,width: 1,height: 1/3),"上方三分之一"),
                    region(0,10,1,4,nil,.init(x: 0,y: 1/3,width: 1,height: 1/3),"中间三分之一"),
                    region(0,16,1,3,nil,.init(x: 0,y: 2/3,width: 1,height: 1/3),"下方三分之一"),
                    region(0,8,1,2,nil,.init(x: 0,y: 0,width: 1,height: 2/3),"上方三分之二"),
                    region(0,14,1,2,nil,.init(x: 0,y: 1/3,width: 1,height: 2/3),"下方三分之二"),
                    region(1,11,1,2,nil,.init(x: 0,y: 1/6,width: 1,height: 2/3),"中间三分之二"),
                    region(1,0,10,1,.maximize)]
        }
        return .init(landscape: areas(.landscape), portrait: areas(.portrait))
    }()
}
public struct WindowActivationMatch: Equatable, Sendable {
    public var areaID: UUID
    public var title: String
    public var frame: CGRect
    public var action: WindowAction?
}
public enum WindowActivationResolver {
    public static func regionFrame(for area: WindowActivationArea, in screen: CGRect) -> CGRect? {
        area.rect.frame(in: screen)
    }
    public static func resolve(at point: CGPoint, screen: CGRect, visibleFrame: CGRect, current: CGRect,
                               gap: Double, profile: WindowActivationProfile) -> WindowActivationMatch? {
        guard point.x.isFinite, point.y.isFinite, WindowGeometry.isValid(screen),
              WindowGeometry.isValid(visibleFrame), WindowGeometry.isValid(current),
              gap.isFinite, (0...32).contains(gap) else { return nil }
        for area in profile.areas(for: .init(screen: screen)) where area.enabled {
            guard (try? area.validated()) != nil, let region = regionFrame(for: area, in: screen),
                  region.contains(point) else { continue }
            let target: CGRect?
            if let action = area.action {
                target = WindowGeometry.frame(for: action, in: visibleFrame, current: current, gap: gap)
            } else {
                target = area.customTarget?.frame(in: visibleFrame)?.insetBy(dx: gap, dy: gap)
            }
            guard let target, WindowGeometry.isValid(target) else { return nil }
            return .init(areaID: area.id, title: area.name, frame: target, action: area.action)
        }
        return nil
    }
}
