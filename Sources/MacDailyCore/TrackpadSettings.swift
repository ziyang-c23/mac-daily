import Foundation

public enum MouseSystemAction: String, Codable, CaseIterable, Sendable {
    case minimize, restoreMinimized, toggleFullScreen, brightnessUp, brightnessDown
    public var title: String {
        switch self {
        case .minimize: L10n.text("最小化窗口")
        case .restoreMinimized: L10n.text("恢复最小化窗口")
        case .toggleFullScreen: L10n.text("切换窗口全屏")
        case .brightnessUp: L10n.text("提高亮度")
        case .brightnessDown: L10n.text("降低亮度")
        }
    }
}

public enum InputAction: Codable, Equatable, Sendable {
    case shortcut(Shortcut)
    case middleClick
    case window(WindowAction)
    case quick(DashboardAction)
    case showDashboard
    case system(MouseSystemAction)
    public var title: String {
        switch self {
        case .shortcut(let shortcut): shortcut.displayLabel
        case .middleClick: L10n.text("中键点按")
        case .window(let action): action.title
        case .quick(let action): action.title
        case .showDashboard: L10n.text("打开 MacDaily 面板")
        case .system(let action): action.title
        }
    }
}

public enum TrackpadGesture: String, Codable, CaseIterable, Identifiable, Sendable {
    case threeTap, fourTap, threeLeft, threeRight, threeUp, threeDown
    case cornerTopLeft, cornerTopRight, cornerBottomLeft, cornerBottomRight
    case titlebarLeft, titlebarRight, titlebarUp, titlebarDown
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .threeTap: L10n.text("三指轻点")
        case .fourTap: L10n.text("四指轻点")
        case .threeLeft: L10n.text("三指向左轻扫")
        case .threeRight: L10n.text("三指向右轻扫")
        case .threeUp: L10n.text("三指向上轻扫")
        case .threeDown: L10n.text("三指向下轻扫")
        case .cornerTopLeft: L10n.text("左上角轻点")
        case .cornerTopRight: L10n.text("右上角轻点")
        case .cornerBottomLeft: L10n.text("左下角轻点")
        case .cornerBottomRight: L10n.text("右下角轻点")
        case .titlebarLeft: L10n.text("标题栏双指向左")
        case .titlebarRight: L10n.text("标题栏双指向右")
        case .titlebarUp: L10n.text("标题栏双指向上")
        case .titlebarDown: L10n.text("标题栏双指向下")
        }
    }
    public var symbol: String {
        switch self {
        case .threeTap, .fourTap: "hand.tap"
        case .threeLeft, .titlebarLeft: "arrow.left"
        case .threeRight, .titlebarRight: "arrow.right"
        case .threeUp, .titlebarUp: "arrow.up"
        case .threeDown, .titlebarDown: "arrow.down"
        case .cornerTopLeft: "arrow.up.left"
        case .cornerTopRight: "arrow.up.right"
        case .cornerBottomLeft: "arrow.down.left"
        case .cornerBottomRight: "arrow.down.right"
        }
    }
    public var requiredModifiers: UInt64 {
        switch self {
        case .cornerTopLeft, .cornerTopRight, .cornerBottomLeft, .cornerBottomRight: Shortcut.control | Shortcut.option
        case .titlebarLeft, .titlebarRight, .titlebarUp, .titlebarDown: Shortcut.option
        default: 0
        }
    }
    public var isCorner: Bool { [.cornerTopLeft, .cornerTopRight, .cornerBottomLeft, .cornerBottomRight].contains(self) }
    public var isTitlebar: Bool { [.titlebarLeft, .titlebarRight, .titlebarUp, .titlebarDown].contains(self) }
}

public struct TrackpadBinding: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var enabled: Bool
    public var gesture: TrackpadGesture
    public var modifiers: UInt64
    public var action: InputAction
    public var bundleIdentifier: String?
    public init(id: UUID = UUID(), enabled: Bool = true, gesture: TrackpadGesture, modifiers: UInt64? = nil,
                action: InputAction = .middleClick, bundleIdentifier: String? = nil) {
        self.id = id; self.enabled = enabled; self.gesture = gesture
        self.modifiers = modifiers ?? gesture.requiredModifiers
        self.action = action; self.bundleIdentifier = bundleIdentifier
    }
}

public struct TrackpadAppException: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var bundleIdentifier: String
    public var name: String
    public init(id: UUID = UUID(), bundleIdentifier: String, name: String) {
        self.id = id; self.bundleIdentifier = bundleIdentifier; self.name = name
    }
}

public struct TrackpadSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var bindings: [TrackpadBinding] = []
    public var cornerSize = 0.20
    public var tapDuration = 0.250
    public var tapMovement = 0.025
    public var swipeDistance = 0.10
    public var axisDominance = 1.5
    public var excludedApps: [TrackpadAppException] = []
    public init() {}
    public static var recommendedBindings: [TrackpadBinding] {
        [
            .init(gesture: .threeTap, action: .middleClick),
            .init(gesture: .fourTap, action: .showDashboard),
            .init(gesture: .threeLeft, action: .shortcut(.init(keyCode: 48, modifiers: Shortcut.control | Shortcut.shift, label: "⌃⇧Tab 上一个标签页"))),
            .init(gesture: .threeRight, action: .shortcut(.init(keyCode: 48, modifiers: Shortcut.control, label: "⌃Tab 下一个标签页"))),
            .init(gesture: .threeUp, action: .window(.maximize)),
            .init(gesture: .threeDown, action: .window(.restore)),
            .init(gesture: .cornerTopLeft, action: .window(.topLeft)),
            .init(gesture: .cornerTopRight, action: .window(.topRight)),
            .init(gesture: .cornerBottomLeft, action: .window(.bottomLeft)),
            .init(gesture: .cornerBottomRight, action: .window(.bottomRight)),
            .init(gesture: .titlebarLeft, action: .window(.leftHalf)),
            .init(gesture: .titlebarRight, action: .window(.rightHalf)),
            .init(gesture: .titlebarUp, action: .window(.maximize)),
            .init(gesture: .titlebarDown, action: .window(.restore))
        ]
    }
    public mutating func installRecommendedBindings() {
        for binding in Self.recommendedBindings where !bindings.contains(where: {
            $0.bundleIdentifier == nil && $0.gesture == binding.gesture && $0.modifiers == binding.modifiers
        }) { bindings.append(binding) }
    }
    public func excludes(_ bundleIdentifier: String) -> Bool {
        excludedApps.contains { $0.bundleIdentifier == bundleIdentifier }
    }
    public func binding(for gesture: TrackpadGesture, modifiers: UInt64, bundleIdentifier: String) -> TrackpadBinding? {
        guard !excludes(bundleIdentifier) else { return nil }
        let candidates = bindings.filter { $0.enabled && $0.gesture == gesture && $0.modifiers == modifiers }
        return candidates.first { $0.bundleIdentifier == bundleIdentifier }
            ?? candidates.first { $0.bundleIdentifier == nil }
    }
    public func validated() throws -> Self {
        guard cornerSize.isFinite, (0.08...0.35).contains(cornerSize),
              tapDuration.isFinite, (0.10...0.60).contains(tapDuration),
              tapMovement.isFinite, (0.005...0.08).contains(tapMovement),
              swipeDistance.isFinite, (0.04...0.30).contains(swipeDistance),
              axisDominance.isFinite, (1.1...3).contains(axisDominance),
              bindings.count <= 256, excludedApps.count <= 128 else { throw ConfigurationError.invalid(L10n.text("触控板识别参数超出支持范围")) }
        var keys = Set<String>()
        guard Set(bindings.map(\.id)).count == bindings.count else { throw ConfigurationError.invalid(L10n.text("触控板规则编号重复")) }
        for binding in bindings {
            guard binding.modifiers & ~Shortcut.modifierMask == 0,
                  binding.bundleIdentifier.map({ !$0.isEmpty && $0.count < 256 }) ?? true else { throw ConfigurationError.invalid(L10n.text("触控板规则无效")) }
            if case .shortcut(let shortcut) = binding.action {
                guard shortcut.keyCode < 128, shortcut.modifiers & ~Shortcut.modifierMask == 0 else { throw ConfigurationError.invalid(L10n.text("触控板快捷键无效")) }
            }
            if binding.enabled && !keys.insert("\(binding.bundleIdentifier ?? "*"):\(binding.gesture.rawValue):\(binding.modifiers)").inserted {
                throw ConfigurationError.invalid(L10n.text("同一应用中存在重复启用的触控板规则"))
            }
        }
        guard Set(excludedApps.map(\.id)).count == excludedApps.count,
              Set(excludedApps.map(\.bundleIdentifier)).count == excludedApps.count,
              excludedApps.allSatisfy({ !$0.bundleIdentifier.isEmpty && $0.bundleIdentifier.count < 256 }) else { throw ConfigurationError.invalid(L10n.text("触控板应用例外重复或无效")) }
        return self
    }
}
