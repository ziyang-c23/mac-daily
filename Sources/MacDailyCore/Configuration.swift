import Foundation

public struct Shortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: UInt64
    public var label: String
    public init(keyCode: UInt16, modifiers: UInt64, label: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.label = label
    }
    public var displayLabel: String { L10n.text(label) }
    public static let command: UInt64 = 1 << 20
    public static let control: UInt64 = 1 << 18
    public static let option: UInt64 = 1 << 19
    public static let shift: UInt64 = 1 << 17
    public static let modifierMask: UInt64 = command | control | option | shift
}

public enum MouseTrigger: String, Codable, CaseIterable, Sendable {
    case click, scrollUp, scrollDown, swipeUp, swipeDown, swipeLeft, swipeRight
    case swipeUpLeft, swipeUpRight, swipeDownLeft, swipeDownRight
    public var title: String {
        switch self {
        case .click: L10n.text("点击")
        case .scrollUp: L10n.text("按住并向上滚动")
        case .scrollDown: L10n.text("按住并向下滚动")
        case .swipeUp: L10n.text("按住并向上移动")
        case .swipeDown: L10n.text("按住并向下移动")
        case .swipeLeft: L10n.text("按住并向左移动")
        case .swipeRight: L10n.text("按住并向右移动")
        case .swipeUpLeft: L10n.text("按住并向左上移动")
        case .swipeUpRight: L10n.text("按住并向右上移动")
        case .swipeDownLeft: L10n.text("按住并向左下移动")
        case .swipeDownRight: L10n.text("按住并向右下移动")
        }
    }
}

public struct MouseBinding: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var enabled: Bool
    public var button: Int
    public var trigger: MouseTrigger
    public var modifiers: UInt64
    public var shortcut: Shortcut
    public var windowAction: WindowAction?
    public var action: InputAction?
    public var effectiveAction: InputAction { action ?? windowAction.map(InputAction.window) ?? .shortcut(shortcut) }
    public init(id: UUID = UUID(), enabled: Bool = false, button: Int, trigger: MouseTrigger, modifiers: UInt64 = 0, shortcut: Shortcut, windowAction: WindowAction? = nil, action: InputAction? = nil) {
        self.id = id; self.enabled = enabled; self.button = button; self.trigger = trigger
        self.modifiers = modifiers; self.shortcut = shortcut; self.windowAction = windowAction; self.action = action
    }
    public static func buttonName(_ button: Int) -> String {
        switch button { case 1: L10n.text("右键"); case 2: L10n.text("中键"); case 3: L10n.text("侧键 1"); case 4: L10n.text("侧键 2"); default: L10n.text("按钮 %@", String(describing: button + 1)) }
    }
}

public struct ScrollSettings: Codable, Equatable, Sendable {
    public var smoothEnabled = true
    public var reverseVertical = true
    public var reverseHorizontal = false
    public var speed = 1.0
    public var smoothing = 0.16
    public var bypassWithModifiers = true
    public init() {}
}

public struct PointerSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var speed = 1.0
    public var acceleration = 0.6875
    public var disableAcceleration = false
    public init() {}
}

public struct ApplicationException: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var bundleIdentifier: String
    public var name: String
    public var disableScrolling: Bool
    public var disableBindings: Bool
    public var disableGestures: Bool
    public init(id: UUID = UUID(), bundleIdentifier: String, name: String, disableScrolling: Bool = true, disableBindings: Bool = true, disableGestures: Bool = true) {
        self.id = id; self.bundleIdentifier = bundleIdentifier; self.name = name
        self.disableScrolling = disableScrolling; self.disableBindings = disableBindings; self.disableGestures = disableGestures
    }
}

public struct MouseConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion = 9
    public var scroll = ScrollSettings()
    public var pointer = PointerSettings()
    public var gestureThreshold = 36.0
    public var windows = WindowSettings()
    public var storage = StorageSettings()
    public var menuBar = MenuBarSettings()
    public var dashboard = DashboardSettings()
    public var trackpad = TrackpadSettings()
    public var applications = ApplicationsSettings()
    public var bindings: [MouseBinding] = [
        .init(button: 3, trigger: .click, shortcut: .init(keyCode: 33, modifiers: Shortcut.command, label: "⌘[ 后退")),
        .init(button: 4, trigger: .click, shortcut: .init(keyCode: 30, modifiers: Shortcut.command, label: "⌘] 前进")),
        .init(button: 2, trigger: .click, shortcut: .init(keyCode: 48, modifiers: Shortcut.command, label: "⌘Tab 切换应用")),
        .init(button: 1, trigger: .scrollUp, shortcut: .init(keyCode: 48, modifiers: Shortcut.control, label: "⌃Tab 下一个标签页")),
        .init(button: 1, trigger: .scrollDown, shortcut: .init(keyCode: 48, modifiers: Shortcut.control | Shortcut.shift, label: "⌃⇧Tab 上一个标签页")),
        .init(button: 2, trigger: .swipeUp, shortcut: .init(keyCode: 126, modifiers: Shortcut.control, label: "⌃↑ 调度中心")),
        .init(button: 2, trigger: .swipeDown, shortcut: .init(keyCode: 13, modifiers: Shortcut.command, label: "⌘W 关闭窗口")),
        .init(button: 2, trigger: .swipeLeft, shortcut: .init(keyCode: 123, modifiers: Shortcut.control, label: "⌃← 上一个桌面")),
        .init(button: 2, trigger: .swipeRight, shortcut: .init(keyCode: 124, modifiers: Shortcut.control, label: "⌃→ 下一个桌面")),
        .init(button: 1, trigger: .swipeLeft, shortcut: .init(keyCode: 33, modifiers: Shortcut.command, label: "⌘["), windowAction: .leftHalf),
        .init(button: 1, trigger: .swipeRight, shortcut: .init(keyCode: 30, modifiers: Shortcut.command, label: "⌘]"), windowAction: .rightHalf),
        .init(button: 1, trigger: .swipeUp, shortcut: .init(keyCode: 126, modifiers: Shortcut.control, label: "⌃↑"), windowAction: .maximize),
        .init(button: 1, trigger: .swipeDown, shortcut: .init(keyCode: 125, modifiers: Shortcut.control, label: "⌃↓"), windowAction: .restore)
    ]
    public var exceptions: [ApplicationException] = []
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, scroll, pointer, gestureThreshold, bindings, exceptions, windows, storage, menuBar, dashboard, trackpad, applications
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard (1...9).contains(version) else { throw ConfigurationError.invalid(L10n.text("不支持的配置版本")) }
        schemaVersion = 9
        applications = version >= 8 ? try values.decode(ApplicationsSettings.self, forKey: .applications) : ApplicationsSettings()
        trackpad = version >= 7 ? try values.decode(TrackpadSettings.self, forKey: .trackpad) : TrackpadSettings()
        dashboard = version >= 6 ? try values.decode(DashboardSettings.self, forKey: .dashboard) : DashboardSettings()
        menuBar = version >= 5 ? try values.decode(MenuBarSettings.self, forKey: .menuBar) : MenuBarSettings()
        storage = version >= 4 ? try values.decode(StorageSettings.self, forKey: .storage) : StorageSettings()
        scroll = try values.decode(ScrollSettings.self, forKey: .scroll)
        pointer = try values.decode(PointerSettings.self, forKey: .pointer)
        gestureThreshold = try values.decode(Double.self, forKey: .gestureThreshold)
        bindings = try values.decode([MouseBinding].self, forKey: .bindings)
        exceptions = try values.decode([ApplicationException].self, forKey: .exceptions)
        // Legacy schemas cannot enable new behavior or inject an action that an
        // older app would interpret as the fallback keyboard shortcut.
        if version == 1 {
            guard bindings.allSatisfy({ $0.windowAction == nil && $0.action == nil }) else { throw ConfigurationError.invalid(L10n.text("窗口动作需要新版配置格式")) }
            windows = WindowSettings()
        } else {
            windows = try values.decode(WindowSettings.self, forKey: .windows)
        }
    }
    public func exception(for bundleID: String) -> ApplicationException? {
        exceptions.first { $0.bundleIdentifier == bundleID }
    }
    public func validated() throws -> MouseConfiguration {
        guard schemaVersion == 9 else { throw ConfigurationError.invalid(L10n.text("不支持的配置版本")) }
        guard scroll.speed.isFinite, (0.2...4).contains(scroll.speed), scroll.smoothing.isFinite, (0.04...0.5).contains(scroll.smoothing),
              pointer.speed.isFinite, (0.2...4).contains(pointer.speed), pointer.acceleration.isFinite, (0...3).contains(pointer.acceleration),
              gestureThreshold.isFinite, (12...160).contains(gestureThreshold), bindings.count <= 128, exceptions.count <= 128 else {
            throw ConfigurationError.invalid(L10n.text("参数超出支持范围"))
        }
        _ = try windows.validated()
        _ = try storage.validated()
        _ = try menuBar.validated()
        _ = try dashboard.validated()
        _ = try trackpad.validated()
        var keys = Set<String>(); var ids = Set<UUID>()
        for b in bindings {
            guard (1...31).contains(b.button), b.shortcut.keyCode < 128,
                  b.modifiers & ~Shortcut.modifierMask == 0, b.shortcut.modifiers & ~Shortcut.modifierMask == 0,
                  b.shortcut.label.count <= 128, ids.insert(b.id).inserted else { throw ConfigurationError.invalid(L10n.text("按键规则无效")) }
            if case .shortcut(let shortcut) = b.effectiveAction {
                guard shortcut.keyCode < 128, shortcut.modifiers & ~Shortcut.modifierMask == 0, shortcut.label.count <= 128 else { throw ConfigurationError.invalid(L10n.text("按键规则无效")) }
            }
            guard !(b.button == 1 && b.trigger == .click) else { throw ConfigurationError.invalid(L10n.text("右键保留普通点击；可配置滚轮或方向手势")) }
            if b.enabled && !keys.insert("\(b.button):\(b.trigger.rawValue):\(b.modifiers)").inserted { throw ConfigurationError.invalid(L10n.text("存在重复启用的按键规则")) }
        }
        guard Set(exceptions.map(\.id)).count == exceptions.count,
              Set(exceptions.map(\.bundleIdentifier)).count == exceptions.count,
              exceptions.allSatisfy({ !$0.bundleIdentifier.isEmpty && $0.bundleIdentifier.count < 256 && $0.name.count < 256 }) else { throw ConfigurationError.invalid(L10n.text("应用例外无效或重复")) }
        return self
    }
}
public enum ConfigurationError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(s) = self { return s }; return nil }
}
