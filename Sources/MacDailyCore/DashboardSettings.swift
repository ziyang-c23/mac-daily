import Foundation

public enum DashboardCard: String, Codable, CaseIterable, Identifiable, Sendable {
    case cpu, gpu, memory, disk, network, battery, temperature
    public var id: String { rawValue }
    public var title: String {
        switch self { case .cpu: "CPU"; case .gpu: "GPU"; case .memory: L10n.text("内存"); case .disk: L10n.text("磁盘"); case .network: L10n.text("网络"); case .battery: L10n.text("电池"); case .temperature: L10n.text("温度") }
    }
    public var symbol: String {
        switch self { case .cpu: "cpu"; case .gpu: "display"; case .memory: "memorychip"; case .disk: "internaldrive"; case .network: "network"; case .battery: "battery.100"; case .temperature: "thermometer.medium" }
    }
}

public enum DashboardAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case keepAwake, keepDisplayAwake, darkMode, lockScreen, screenSaver, hideDesktop, hideDock, hideMenuBar, lockDock, hideNotch, cleanScreen, cleanKeyboard, mousePause, windowLayout, storage, trash, lowPower, displays, systemSettings, activityMonitor, pinDock, muteAudio, audioSettings, wifiSettings, bluetoothSettings
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .keepAwake: L10n.text("保持唤醒"); case .keepDisplayAwake: L10n.text("保持亮屏"); case .darkMode: L10n.text("深色模式"); case .lockScreen: L10n.text("锁屏"); case .screenSaver: L10n.text("进入屏保")
        case .hideDesktop: L10n.text("隐藏桌面文件"); case .hideDock: L10n.text("隐藏 Dock"); case .hideMenuBar: L10n.text("自动隐藏菜单栏"); case .lockDock: L10n.text("锁定 Dock 图标"); case .hideNotch: L10n.text("隐藏刘海")
        case .cleanScreen: L10n.text("清洁屏幕"); case .cleanKeyboard: L10n.text("清洁键盘"); case .mousePause: L10n.text("暂停鼠标增强"); case .windowLayout: L10n.text("窗口排列"); case .storage: L10n.text("空间整理")
        case .trash: L10n.text("查看废纸篓"); case .lowPower: L10n.text("省电设置"); case .displays: L10n.text("显示器设置"); case .systemSettings: L10n.text("系统设置"); case .activityMonitor: L10n.text("活动监视器")
        case .pinDock: L10n.text("固定 Dock 显示器"); case .muteAudio: L10n.text("静音"); case .audioSettings: L10n.text("声音设置"); case .wifiSettings: L10n.text("Wi-Fi 设置"); case .bluetoothSettings: L10n.text("蓝牙设置")
        }
    }
    public var symbol: String {
        switch self {
        case .keepAwake: "cup.and.saucer"; case .keepDisplayAwake: "sun.max"; case .darkMode: "circle.lefthalf.filled"; case .lockScreen: "lock"; case .screenSaver: "play.rectangle"
        case .hideDesktop: "eye.slash"; case .hideDock: "dock.rectangle"; case .hideMenuBar: "menubar.rectangle"; case .lockDock: "lock.rectangle"; case .hideNotch: "laptopcomputer"
        case .cleanScreen: "sparkles.rectangle.stack"; case .cleanKeyboard: "keyboard"; case .mousePause: "computermouse"; case .windowLayout: "rectangle.split.2x1"; case .storage: "internaldrive"
        case .trash: "trash"; case .lowPower: "bolt"; case .displays: "display.2"; case .systemSettings: "gearshape"; case .activityMonitor: "waveform.path.ecg"
        case .pinDock: "lock.display"; case .muteAudio: "speaker.slash"; case .audioSettings: "speaker.wave.2"; case .wifiSettings: "wifi"; case .bluetoothSettings: "antenna.radiowaves.left.and.right"
        }
    }
    public var isLink: Bool { [.windowLayout, .storage, .trash, .lowPower, .displays, .systemSettings, .activityMonitor, .audioSettings, .wifiSettings, .bluetoothSettings].contains(self) }
    public var description: String {
        switch self {
        case .keepAwake: L10n.text("定时防止系统因空闲而休眠，屏幕仍可关闭")
        case .keepDisplayAwake: L10n.text("定时保持屏幕亮起，适合阅读、展示和下载")
        case .darkMode: L10n.text("切换 macOS 深色与浅色外观")
        case .lockScreen: L10n.text("立即锁定当前会话")
        case .screenSaver: L10n.text("立即进入系统屏幕保护程序")
        case .hideDesktop: L10n.text("隐藏或显示桌面文件和文件夹，文件位置不变")
        case .hideDock: L10n.text("切换程序坞自动隐藏")
        case .hideMenuBar: L10n.text("切换菜单栏自动隐藏")
        case .lockDock: L10n.text("锁定程序坞图标的排列与增删")
        case .pinDock: L10n.text("阻止其他显示器边缘触发 Dock，固定目标在偏好中选择")
        case .hideNotch: L10n.text("在刘海屏顶部显示黑色背景带")
        case .cleanScreen: L10n.text("全屏纯色方便擦拭屏幕，可切换黑、白、红、绿、蓝")
        case .cleanKeyboard: L10n.text("暂停键盘输入30秒，鼠标可随时结束")
        case .mousePause: L10n.text("暂停或恢复已有鼠标增强")
        case .windowLayout: L10n.text("打开分屏、窗口排列和拖拽吸附设置")
        case .storage: L10n.text("打开空间地图、大文件、重复文件与缓存整理")
        case .trash: L10n.text("在 Finder 查看废纸篓中的项目")
        case .lowPower: L10n.text("查看省电状态并打开系统电池设置")
        case .displays: L10n.text("打开扩展、镜像、分辨率和显示器排列设置")
        case .systemSettings: L10n.text("打开 macOS 系统设置")
        case .activityMonitor: L10n.text("查看进程、CPU、内存、能耗和磁盘活动")
        case .muteAudio: L10n.text("切换当前声音输出设备的静音状态")
        case .audioSettings: L10n.text("打开声音输入、输出和音量设置")
        case .wifiSettings: L10n.text("打开 Wi-Fi 连接设置")
        case .bluetoothSettings: L10n.text("打开蓝牙设备与连接设置")
        }
    }
}

public struct PinnedDashboardApp: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var bundleIdentifier: String
    public var path: String
    public var name: String
    public init(id: UUID = UUID(), bundleIdentifier: String, path: String, name: String) {
        self.id = id; self.bundleIdentifier = bundleIdentifier; self.path = path; self.name = name
    }
}

public struct DashboardSettings: Codable, Equatable, Sendable {
    public var cards: [DashboardCard] = [.cpu, .gpu, .memory, .disk, .network, .battery]
    public static let legacyActions: [DashboardAction] = [.keepAwake, .keepDisplayAwake, .darkMode, .lockScreen, .hideDesktop, .hideDock, .windowLayout, .storage]
    public static let defaultActions: [DashboardAction] = [.keepAwake, .darkMode, .lockScreen, .keepDisplayAwake, .screenSaver, .cleanScreen, .cleanKeyboard, .hideDesktop, .hideDock, .hideNotch, .hideMenuBar, .pinDock, .displays, .lowPower, .trash, .storage, .windowLayout, .muteAudio]
    public var actions: [DashboardAction] = Self.defaultActions
    public var pinnedApps: [PinnedDashboardApp] = []
    public var networkInterface: String?
    public var dockAnchorDisplayUUID: String?
    public var showMenuNetwork = false
    public var awakeDurationMinutes = 30
    public init() {}
    private enum CodingKeys: String, CodingKey { case cards, actions, pinnedApps, networkInterface, dockAnchorDisplayUUID, showMenuNetwork, awakeDurationMinutes }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cards = try values.decode([DashboardCard].self, forKey: .cards)
        let savedActions = try values.decode([DashboardAction].self, forKey: .actions)
        actions = savedActions == Self.legacyActions ? Self.defaultActions : savedActions
        pinnedApps = try values.decode([PinnedDashboardApp].self, forKey: .pinnedApps)
        networkInterface = try values.decodeIfPresent(String.self, forKey: .networkInterface)
        dockAnchorDisplayUUID = try values.decodeIfPresent(String.self, forKey: .dockAnchorDisplayUUID)
        showMenuNetwork = try values.decode(Bool.self, forKey: .showMenuNetwork)
        awakeDurationMinutes = try values.decode(Int.self, forKey: .awakeDurationMinutes)
    }
    public func validated() throws -> Self {
        guard Set(cards).count == cards.count, Set(actions).count == actions.count,
              Set(pinnedApps.map(\.id)).count == pinnedApps.count,
              Set(pinnedApps.map(\.bundleIdentifier)).count == pinnedApps.count else { throw ConfigurationError.invalid(L10n.text("面板项目重复")) }
        guard [0, 15, 30, 60].contains(awakeDurationMinutes) else { throw ConfigurationError.invalid(L10n.text("请选择保持唤醒的时长")) }
        return self
    }
}

/// Counter deltas are reset when interfaces change or the machine wakes.
public struct MonitorCounterRate: Sendable {
    private var previous: (identity: String, value: UInt64, time: Double)?
    public init() {}
    public mutating func sample(identity: String, value: UInt64, time: Double) -> Double {
        defer { previous = (identity, value, time) }
        guard let previous, previous.identity == identity, value >= previous.value, time > previous.time else { return 0 }
        return Double(value - previous.value) / (time - previous.time)
    }
    public mutating func reset() { previous = nil }
}
