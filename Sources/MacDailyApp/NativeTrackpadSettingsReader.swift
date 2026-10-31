import AppKit
import Combine
import MacDailyCore

struct NativeTrackpadSettingRow: Identifiable, Equatable {
    let id: String
    let title: String
    let current: String
    let recommended: String
    let path: String
    let paneURL: String
    let hasConflict: Bool
}

@MainActor
final class NativeTrackpadSettingsReader: ObservableObject {
    @Published private(set) var status = NativeTrackpadStatus()
    @Published private(set) var rows: [NativeTrackpadSettingRow] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var activationObserver: NSObjectProtocol?

    func refresh() {
        let preferences = NativeTrackpadPreferences()
        let tap = preferences.trackpad("threeFingerTapGesture", driver: "TrackpadThreeFingerTapGesture")
        let horizontal = preferences.trackpad("threeFingerHorizSwipeGesture", driver: "TrackpadThreeFingerHorizSwipeGesture")
        let fourHorizontal = preferences.trackpad("fourFingerHorizSwipeGesture", driver: "TrackpadFourFingerHorizSwipeGesture")
        let vertical = preferences.trackpad("threeFingerVertSwipeGesture", driver: "TrackpadThreeFingerVertSwipeGesture")
        let fourVertical = preferences.trackpad("fourFingerVertSwipeGesture", driver: "TrackpadFourFingerVertSwipeGesture")
        let drag = preferences.trackpad("threeFingerDragGesture", driver: "TrackpadThreeFingerDrag")
        let force = preferences.global("com.apple.trackpad.forceClick")
        let expose = preferences.value("showAppExposeGestureEnabled", app: "com.apple.dock")
        let fn = preferences.value("AppleFnUsageType", app: "com.apple.HIToolbox")

        let newStatus = NativeTrackpadStatus(
            lookupThreeFinger: tap.map { $0.intValue != 0 },
            threeFingerHorizontal: horizontal.map { $0.intValue != 0 },
            threeFingerMissionControl: vertical.map { $0.intValue != 0 },
            threeFingerExpose: expose?.boolValue == false ? false : (expose?.boolValue == true ? vertical.map { $0.intValue != 0 } : nil),
            threeFingerDrag: drag?.boolValue,
            forceClick: force?.boolValue
        )
        if status != newStatus { status = newStatus }
        let trackpadPane = "x-apple.systempreferences:com.apple.Trackpad-Settings.extension"
        let accessPane = "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Mouse"
        let keyboardPane = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
        let morePath = L10n.text("系统设置 → 触控板 → 更多手势")
        let newRows: [NativeTrackpadSettingRow] = [
            .init(id: "spaces", title: L10n.text("轻扫切换全屏显示应用程序"),
                  current: swipeName(three: horizontal, four: fourHorizontal, suffix: L10n.text("左右轻扫")),
                  recommended: L10n.text("四指左右轻扫"), path: morePath + L10n.text(" → 轻扫切换全屏显示应用程序"),
                  paneURL: trackpadPane, hasConflict: newStatus.threeFingerHorizontal != false),
            .init(id: "missionControl", title: L10n.text("调度中心"),
                  current: swipeName(three: vertical, four: fourVertical, suffix: L10n.text("向上轻扫")),
                  recommended: L10n.text("四指向上轻扫"), path: morePath + L10n.text(" → 调度中心"),
                  paneURL: trackpadPane, hasConflict: newStatus.threeFingerMissionControl != false),
            .init(id: "expose", title: "App Exposé",
                  current: expose?.boolValue == false ? L10n.text("已关闭") : (expose == nil ? L10n.text("未读取到设置") : swipeName(three: vertical, four: fourVertical, suffix: L10n.text("向下轻扫"))),
                  recommended: L10n.text("四指向下轻扫"), path: morePath + " → App Exposé",
                  paneURL: trackpadPane, hasConflict: newStatus.threeFingerExpose != false),
            .init(id: "lookup", title: L10n.text("查询与数据检测器"),
                  current: tap.map { $0.intValue != 0 ? L10n.text("三指轻点") : (force?.boolValue == true ? L10n.text("单指用力点按") : L10n.text("力度查询未开启")) } ?? L10n.text("未读取到设置"),
                  recommended: L10n.text("单指用力点按"), path: L10n.text("系统设置 → 触控板 → 光标与点按 → 查询与数据检测器"),
                  paneURL: trackpadPane, hasConflict: newStatus.lookupThreeFinger != false),
            .init(id: "drag", title: L10n.text("使用触控板进行拖移"),
                  current: drag.map { $0.boolValue ? L10n.text("三指拖移已开启") : L10n.text("三指拖移关闭") } ?? L10n.text("未读取到设置"),
                  recommended: L10n.text("三指拖移关闭"), path: L10n.text("系统设置 → 无障碍 → 指针控制 → 触控板选项 → 拖移样式"),
                  paneURL: accessPane, hasConflict: newStatus.threeFingerDrag != false),
            .init(id: "fn", title: L10n.text("按下地球键时"),
                  current: fn.map { $0.intValue == 1 ? L10n.text("更改输入法") : ($0.intValue == 0 ? L10n.text("不执行操作") : L10n.text("系统配置值 %@", String(describing: $0.intValue))) } ?? L10n.text("未读取到设置"),
                  recommended: L10n.text("保留更改输入法"), path: L10n.text("系统设置 → 键盘 → 按下地球键时"),
                  paneURL: keyboardPane, hasConflict: false)
        ]
        if rows != newRows { rows = newRows }
    }

    func startObserving() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        let names = [
            "com.apple.AppleMultitouchTrackpadDomainDidChangeNotification",
            "com.apple.IOTrackpadPropertyDidChangeNotification",
            "com.apple.AppleMenuGesturesDidChangeNotification",
            "UniversalAccessDomainMouseSettingsDidChangeNotification",
            "3FVertSwipeDidChangeNotification", "4FVertSwipeDidChangeNotification",
            "3FHorizSwipeDidChangeNotification", "4FHorizSwipeDidChangeNotification"
        ]
        let center = DistributedNotificationCenter.default()
        for name in names {
            distributedObservers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
    }

    func stopObserving() {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        let center = DistributedNotificationCenter.default()
        distributedObservers.forEach { center.removeObserver($0) }
        distributedObservers.removeAll()
    }

    func open(_ row: NativeTrackpadSettingRow) {
        guard let url = URL(string: row.paneURL) else { return }
        NSWorkspace.shared.open(url)
    }

    private func swipeName(three: NSNumber?, four: NSNumber?, suffix: String) -> String {
        if let three, three.intValue != 0 { return L10n.text("三指%@", suffix) }
        if let four, four.intValue != 0 { return L10n.text("四指%@", suffix) }
        return three != nil && four != nil ? L10n.text("已关闭") : L10n.text("未读取到设置")
    }
}

private struct NativeTrackpadPreferences {
    init() {
        for app in [kCFPreferencesAnyApplication, "com.apple.AppleMultitouchTrackpad" as CFString,
                    "com.apple.dock" as CFString, "com.apple.HIToolbox" as CFString] {
            CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
    }
    func trackpad(_ key: String, driver: String) -> NSNumber? {
        // Effective ByHost globals reflect the native pane. The driver's shared
        // plist can differ after a migration, so it is read only when absent.
        global("com.apple.trackpad." + key) ?? value(driver, app: "com.apple.AppleMultitouchTrackpad")
    }
    func global(_ key: String) -> NSNumber? {
        read(key, app: kCFPreferencesAnyApplication, host: kCFPreferencesCurrentHost)
            ?? read(key, app: kCFPreferencesAnyApplication, host: kCFPreferencesAnyHost)
    }
    func value(_ key: String, app: String) -> NSNumber? {
        read(key, app: app as CFString, host: kCFPreferencesCurrentHost)
            ?? read(key, app: app as CFString, host: kCFPreferencesAnyHost)
    }
    private func read(_ key: String, app: CFString, host: CFString) -> NSNumber? {
        CFPreferencesCopyValue(key as CFString, app, kCFPreferencesCurrentUser, host) as? NSNumber
    }
}
