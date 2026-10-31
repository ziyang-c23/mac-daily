import AppKit
import ApplicationServices
import Combine
import MacDailyCore
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var selectedToolPage: ToolPage? = .dashboard
    @Published var appLanguage = AppLanguage(rawValue: UserDefaults.standard.string(forKey: AppLanguage.preferenceKey) ?? "system") ?? .system {
        didSet {
            guard appLanguage != oldValue else { return }
            UserDefaults.standard.set(appLanguage.rawValue, forKey: AppLanguage.preferenceKey)
            if appLanguage == .system { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
            else { UserDefaults.standard.set([appLanguage.rawValue], forKey: "AppleLanguages") }
        }
    }
    var languageNeedsReopen: Bool { appLanguage != L10n.launchLanguage }

    func reopenForLanguage() {
        UserDefaults.standard.synchronize()
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.1; done; exec /usr/bin/open \"$2\"",
                              "MacDailyReopen", String(getpid()), Bundle.main.bundleURL.path]
        relaunch.standardOutput = FileHandle.nullDevice; relaunch.standardError = FileHandle.nullDevice
        do {
            try relaunch.run()
            shutdown()
            NSApplication.shared.terminate(nil)
        } catch { errorMessage = L10n.text("无法重新打开应用：%@", error.localizedDescription) }
    }

    @Published var configuration = MouseConfiguration() {
        didSet {
            guard !applyingConfiguration, configuration != oldValue else { return }
            do {
                _ = try configuration.validated()
                try persist(configuration)
                var priorInput = oldValue
                priorInput.applications = configuration.applications
                priorInput.storage = configuration.storage
                priorInput.menuBar = configuration.menuBar
                priorInput.dashboard = configuration.dashboard
                priorInput.trackpad = configuration.trackpad
                if priorInput != configuration { runtime.update(configuration: configuration) }
                if configuration.windows != oldValue.windows { windowRuntime.update(settings: effectiveWindowSettings) }
                if configuration.menuBar != oldValue.menuBar { menuBar.update(settings: configuration.menuBar) }
                if configuration.dashboard != oldValue.dashboard { dashboard.apply(configuration.dashboard) }
                if configuration.trackpad != oldValue.trackpad { trackpad.update(settings: configuration.trackpad) }
            } catch {
                applyingConfiguration = true
                configuration = oldValue
                applyingConfiguration = false
                errorMessage = error.localizedDescription
            }
        }
    }
    @Published private(set) var isPaused = true
    @Published private(set) var gestureTesting = false
    @Published private(set) var mouseInspectionActive = false
    @Published private(set) var mouseInspectionMatches: [String: Int] = [:]
    @Published private(set) var mouseInspectionEvent = L10n.text("等待真实鼠标输入")
    @Published private(set) var mouseExecutionFeedback = L10n.text("尚未执行鼠标动作")
    var mouseSystemShortcuts: String { NativeMouseShortcutReader.summary }
    @Published private(set) var gestureFeedback = L10n.text("按住设置的鼠标按钮，移动后松开触发手势。")
    private var inputSuspension = InputSuspensionState()
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var status = L10n.text("鼠标增强尚未启用")
    @Published private(set) var deviceNames: [String] = []
    @Published private(set) var pointerStatus = L10n.text("指针保持系统设置")
    @Published private(set) var lastAction = L10n.text("尚未触发映射或手势")
    @Published private(set) var testEvent = L10n.text("在下面的区域试用滚轮和鼠标按键")
    @Published private(set) var conflicts: [String] = []
    @Published private(set) var startupEnabled = false
    @Published var errorMessage: String?
    @Published private(set) var configurationNeedsRecovery = false
    @Published private(set) var windowStatus = L10n.text("拖拽吸附尚未开启")
    @Published private(set) var windowRunning = false
    @Published private(set) var windowPracticeActive = false
    @Published private var practiceSnappingEnabled = false
    var windowSnappingRequested: Bool { windowPracticeActive ? practiceSnappingEnabled : configuration.windows.enabled }
    private var effectiveWindowSettings: WindowSettings {
        var settings = configuration.windows
        settings.enabled = windowSnappingRequested
        return settings
    }
    @Published private(set) var windowTarget = L10n.text("先切换到需要整理的窗口")

    let storage = StorageModel()
    let menuBar = MenuBarRuntime()
    let dashboard = DashboardModel()
    let trackpad = TrackpadRuntime()
    private lazy var inputActions: InputActionExecutor = {
        let executor = InputActionExecutor(windows: windowRuntime, quick: dashboard.actions)
        executor.onDashboard = { [weak self] in self?.menuBar.toggleDashboard() }
        return executor
    }()
    private var keyboardCleaning = false
    let configurationURL: URL
    private let runtime = MouseRuntime()
    private let windowRuntime = WindowRuntime()
    private let windowPractice = WindowPractice()
    private var applyingConfiguration = false
    private var observers: [NSObjectProtocol] = []
    private var launched = false
    private var terminating = false
    private var resumeOnLaunch = false
    private var activationURL: URL { configurationURL.deletingLastPathComponent().appendingPathComponent("activation.json") }

    init() {
        if let custom = ProcessInfo.processInfo.environment["MACDAILY_DATA_DIR"], !custom.isEmpty {
            configurationURL = URL(fileURLWithPath: custom, isDirectory: true).appendingPathComponent("configuration.json")
        } else {
            configurationURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MacDaily", isDirectory: true).appendingPathComponent("configuration.json")
        }
        if FileManager.default.fileExists(atPath: configurationURL.path) {
            do {
                configuration = try ConfigurationStore.decode(contentsOf: configurationURL)
            } catch {
                configurationNeedsRecovery = true
                errorMessage = L10n.text("无法读取现有配置，原文件已保留。请导入有效配置，或明确恢复默认。\n%@", String(describing: error.localizedDescription))
            }
        }
        runtime.onStatus = { [weak self] value in
            guard let self else { return }
            self.status = value
            self.isPaused = !self.runtime.isRunning || self.mouseInspectionActive
            self.accessibilityGranted = AXIsProcessTrusted()
        }
        runtime.onDevices = { [weak self] value in self?.deviceNames = value }
        runtime.onAction = { [weak self] value in self?.lastAction = value; self?.mouseExecutionFeedback = value }
        runtime.onInspectionEvent = { [weak self] value in self?.mouseInspectionEvent = value }
        runtime.onInspectionMatch = { [weak self] value in
            guard let self, self.mouseInspectionActive else { return }
            self.mouseInspectionMatches[value, default: 0] += 1
        }
        runtime.onGestureFeedback = { [weak self] value in self?.gestureFeedback = value }
        runtime.onPointerStatus = { [weak self] value in self?.pointerStatus = value }
        runtime.onTestEvent = { [weak self] value in self?.testEvent = value }
        runtime.executor = inputActions
        windowRuntime.onPracticeModeChanged = { [weak self] value in self?.windowPracticeActive = value }
        windowRuntime.onStatus = { [weak self] value in self?.windowStatus = value }
        windowRuntime.onRunningChanged = { [weak self] value in self?.windowRunning = value }
        windowRuntime.onTargetChanged = { [weak self] value in self?.windowTarget = value }
        if let size = try? activationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size <= 32, let data = try? Data(contentsOf: activationURL),
           let stored = try? JSONDecoder().decode(Bool.self, from: data) { resumeOnLaunch = stored }
        refreshEnvironment()
        dashboard.apply(configuration.dashboard)
        dashboard.onSettingsChanged = { [weak self] settings in self?.configuration.dashboard = settings }
        dashboard.onOpenStorage = { [weak self] in self?.showTool(.storage) }
        dashboard.onOpenSettings = { [weak self] in self?.showTool(.dashboard) }
        dashboard.actions.onStorage = { [weak self] in self?.showTool(.storage) }
        dashboard.actions.onWindowLayout = { [weak self] in self?.showTool(.windows) }
        dashboard.actions.onMousePause = { [weak self] in self?.togglePaused() }
        dashboard.actions.onKeyboardCleaningChanged = { [weak self] active in self?.setKeyboardCleaning(active) }
        dashboard.actions.onWillPresentOverlay = { [weak self] in self?.menuBar.hideDashboard() }
        trackpad.executor = inputActions
        trackpad.update(settings: configuration.trackpad)
    }

    func showTool(_ page: ToolPage) {
        menuBar.hideDashboard()
        selectedToolPage = page
        AppDelegate.showSettings()
    }

    private func setKeyboardCleaning(_ active: Bool) {
        guard active != keyboardCleaning else { return }
        keyboardCleaning = active
        if active {
            trackpad.setSuspended(L10n.text("清洁键盘"), true)
            inputSuspension.begin(.keyboardCleaning, wasRunning: !isPaused)
            runtime.stop(); isPaused = true
            var settings = effectiveWindowSettings
            settings.enabled = false
            windowRuntime.update(settings: settings)
            status = L10n.text("清洁键盘中")
        } else {
            if terminating { _ = inputSuspension.end(.keyboardCleaning); return }
            trackpad.setSuspended(L10n.text("清洁键盘"), false)
            windowRuntime.update(settings: effectiveWindowSettings)
            resumeAfterInputSuspension(inputSuspension.end(.keyboardCleaning))
        }
    }

    private func rememberActivation(_ enabled: Bool) {
        resumeOnLaunch = enabled
        do {
            try FileManager.default.createDirectory(at: activationURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(enabled).write(to: activationURL, options: .atomic)
        } catch { errorMessage = L10n.text("无法保存启用状态：%@", String(describing: error.localizedDescription)) }
    }

    func applicationDidLaunch() {
        guard !launched else { return }
        launched = true
        menuBar.start(model: self)
        windowRuntime.startTracking()
        windowRuntime.update(settings: effectiveWindowSettings)
        trackpad.startLifecycle()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.refreshEnvironment()
                    if !self.conflicts.isEmpty && !self.isPaused { self.pause() }
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshEnvironment() }
        })
        if resumeOnLaunch && accessibilityGranted && conflicts.isEmpty && !configurationNeedsRecovery { start() }
    }

    func refreshEnvironment() {
        accessibilityGranted = AXIsProcessTrusted()
        if launched { windowRuntime.refreshPermission(); menuBar.refreshPermission() }
        let names: [String: String] = [
            "cn.better365.betterandbetter": "BetterAndBetter",
            "com.better365.macmouse": "BetterMouse",
            "com.lujjjh.linearmouse": "LinearMouse",
            "com.caldis.mos": "Mos",
            "com.nuebling.mac-mouse-fix": "Mac Mouse Fix",
            "com.nuebling.mac-mouse-fix.helper": "Mac Mouse Fix",
            "com.better-mouse.bettermouse": "BetterMouse"
        ]
        let knownNames = ["betterandbetter", "linearmouse", "mos", "mac mouse fix", "macmousefix", "bettermouse", "strokemouse", "macgesture"]
        conflicts = Array(Set(NSWorkspace.shared.runningApplications.compactMap { app -> String? in
            let id = app.bundleIdentifier?.lowercased() ?? ""
            if let name = names[id], !name.isEmpty { return name }
            let local = app.localizedName ?? ""
            return knownNames.contains(local.lowercased()) ? local : nil
        })).sorted()
        if launched {
            let touchTools = ["betterandbetter", "bettertouchtool", "multitouch", "middleclick", "wheelclick"]
            let competing = NSWorkspace.shared.runningApplications.contains { touchTools.contains(($0.localizedName ?? "").lowercased()) }
            trackpad.setSuspended(L10n.text("其他触控板工具正在运行"), competing)
            trackpad.setSuspended(L10n.text("配置需要恢复"), configurationNeedsRecovery)
            trackpad.refresh()
        }
        startupEnabled = SMAppService.mainApp.status == .enabled
        if !accessibilityGranted {
            if !isPaused { pause() }
            status = L10n.text("等待辅助功能权限")
        } else if !conflicts.isEmpty {
            status = L10n.text("请先退出 %@，再启用鼠标增强", String(describing: conflicts.joined(separator: "、")))
        } else if mouseInspectionActive {
            status = L10n.text("真实鼠标检查中，不执行映射")
        } else if gestureTesting {
            status = L10n.text("手势试用中，鼠标增强暂时暂停")
        } else if isPaused {
            status = configurationNeedsRecovery ? L10n.text("配置需要恢复，鼠标增强已暂停") : L10n.text("已暂停，鼠标保持原有行为")
        }
    }

    func start() {
        guard !terminating else { return }
        refreshEnvironment()
        guard accessibilityGranted, conflicts.isEmpty, !configurationNeedsRecovery, !inputSuspension.isSuspended, !gestureTesting, !mouseInspectionActive else { return }
        do {
            _ = try configuration.validated()
            isPaused = !runtime.start(configuration: configuration)
            if !isPaused { rememberActivation(true); status = configuration.bindings.contains(where: \.enabled) ? L10n.text("鼠标增强运行中") : L10n.text("没有启用的规则，滚动设置仍有效") }
        } catch { errorMessage = error.localizedDescription }
    }

    func pause() {
        if mouseInspectionActive {
            mouseInspectionActive = false
            _ = inputSuspension.end(.gestureTest)
            trackpad.setSuspended(L10n.text("真实鼠标检查"), false)
        }
        inputSuspension.cancelResume()
        rememberActivation(false)
        runtime.stop()
        isPaused = true
        status = L10n.text("已暂停，鼠标保持原有行为")
    }

    func togglePaused() { isPaused ? start() : pause() }

    func shutdown() {
        terminating = true
        trackpad.stop()
        dashboard.stop()
        menuBar.stop()
        storage.shutdown()
        inputSuspension.reset()
        windowPractice.close()
        windowRuntime.stop()
        runtime.stop(drainPending: false)
        isPaused = true
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        openAccessibilitySettings()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func setStartup(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            startupEnabled = SMAppService.mainApp.status == .enabled
            if enabled && SMAppService.mainApp.status == .requiresApproval {
                errorMessage = L10n.text("请在系统设置 → 通用 → 登录项与扩展中允许 MacDaily。")
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { errorMessage = L10n.text("开机启动设置失败：%@", String(describing: error.localizedDescription)) }
    }

    func beginShortcutRecording() {
        guard !terminating else { return }
        inputSuspension.begin(.shortcutRecording, wasRunning: !isPaused)
        trackpad.setSuspended(L10n.text("录制快捷键"), true)
        runtime.stop(); isPaused = true
        status = L10n.text("录制快捷键中，鼠标增强暂时暂停")
    }

    func endShortcutRecording() {
        let shouldResume = inputSuspension.end(.shortcutRecording)
        trackpad.setSuspended(L10n.text("录制快捷键"), inputSuspension.count(for: .shortcutRecording) > 0)
        resumeAfterInputSuspension(shouldResume)
    }

    private func resumeAfterInputSuspension(_ shouldResume: Bool) {
        guard !terminating else { return }
        if gestureTesting { status = L10n.text("手势试用中，鼠标增强暂时暂停") }
        else if inputSuspension.isSuspended { status = L10n.text("录制快捷键中，鼠标增强暂时暂停") }
        else if shouldResume { start() }
        else { refreshEnvironment() }
    }

    func openWindowPractice() {
        if !windowPracticeActive { practiceSnappingEnabled = configuration.windows.enabled }
        windowRuntime.preparePractice()
        windowRuntime.update(settings: effectiveWindowSettings)
        windowPractice.open { [weak self] app, identifier in
            self?.windowRuntime.usePracticeApplication(app, identifier: identifier)
        } failure: { [weak self] message in self?.errorMessage = message }
    }

    func endWindowPractice() {
        windowRuntime.endPractice()
        windowPractice.close()
        windowRuntime.update(settings: configuration.windows)
    }

    func setWindowSnapping(_ enabled: Bool) {
        refreshEnvironment()
        guard !enabled || accessibilityGranted else {
            windowStatus = L10n.text("需要辅助功能权限才能拖拽分屏")
            return
        }
        if windowPracticeActive { practiceSnappingEnabled = enabled }
        else { configuration.windows.enabled = enabled }
        windowRuntime.update(settings: effectiveWindowSettings)
    }

    /// Commit only the activation editor's draft, preserving live window and mouse settings.
    func applyWindowActivationSettings(_ draft: WindowSettings) {
        guard !configurationNeedsRecovery else { return }
        var updated = configuration.windows
        updated.activationMode = draft.activationMode
        updated.activationProfile = draft.activationProfile
        updated.highlightActivationAreas = draft.highlightActivationAreas
        do {
            _ = try updated.validated()
            configuration.windows = updated
        } catch { errorMessage = error.localizedDescription }
    }

    func performWindowAction(_ action: WindowAction) {
        refreshEnvironment()
        guard accessibilityGranted else { windowStatus = L10n.text("需要辅助功能权限才能调整窗口"); return }
        windowRuntime.perform(action)
    }

    func addWindowException() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择不参与拖拽吸附的应用")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
              !configuration.windows.excludedApps.contains(where: { $0.bundleIdentifier == id }) else { return }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        configuration.windows.excludedApps.append(.init(bundleIdentifier: id, name: name))
    }

    func removeWindowException(_ id: UUID) { configuration.windows.excludedApps.removeAll { $0.id == id } }

    func startMouseInspection() {
        guard !terminating, !gestureTesting, !mouseInspectionActive, !keyboardCleaning, !inputSuspension.isSuspended else { return }
        refreshEnvironment()
        guard accessibilityGranted, conflicts.isEmpty, !configurationNeedsRecovery else { return }
        inputSuspension.begin(.gestureTest, wasRunning: !isPaused)
        mouseInspectionActive = true
        trackpad.setSuspended(L10n.text("真实鼠标检查"), true)
        runtime.stop(); isPaused = true
        mouseInspectionEvent = L10n.text("等待真实鼠标输入"); mouseInspectionMatches = [:]
        if !runtime.start(configuration: configuration, inspectionOnly: true) { endMouseInspection() }
        else { status = L10n.text("真实鼠标检查中，不执行映射") }
    }

    func endMouseInspection() {
        guard mouseInspectionActive else { return }
        runtime.stop(); isPaused = true; mouseInspectionActive = false
        trackpad.setSuspended(L10n.text("真实鼠标检查"), false)
        _ = inputSuspension.end(.gestureTest)
        inputSuspension.cancelResume()
        rememberActivation(false)
        status = L10n.text("已暂停，鼠标保持原有行为")
    }

    func beginGestureTesting() {
        guard !terminating, !mouseInspectionActive else { return }
        inputSuspension.begin(.gestureTest, wasRunning: !isPaused)
        trackpad.setSuspended(L10n.text("鼠标手势试用"), true)
        gestureTesting = true
        runtime.stop(); isPaused = true
        status = L10n.text("手势试用中，鼠标增强暂时暂停")
        gestureFeedback = L10n.text("在试用区按住左键模拟，或使用实际中键／右键，再移动和松开。")
    }

    func endGestureTesting() {
        let shouldResume = inputSuspension.end(.gestureTest)
        trackpad.setSuspended(L10n.text("鼠标手势试用"), inputSuspension.count(for: .gestureTest) > 0)
        gestureTesting = inputSuspension.count(for: .gestureTest) > 0
        resumeAfterInputSuspension(shouldResume)
    }

    func updateGestureTestFeedback(_ text: String) { gestureFeedback = text }

    func setPresetGroupEnabled(button: Int, directional: Bool, enabled: Bool) {
        let triggers: [MouseTrigger] = directional ? [.swipeUp, .swipeDown, .swipeLeft, .swipeRight] : [.scrollUp, .scrollDown]
        var candidate = configuration
        for trigger in triggers {
            let matches = candidate.bindings.indices.filter {
                candidate.bindings[$0].button == button && candidate.bindings[$0].trigger == trigger && candidate.bindings[$0].modifiers == 0
            }
            if !matches.isEmpty {
                if enabled {
                    if !matches.contains(where: { candidate.bindings[$0].enabled }), let index = matches.first { candidate.bindings[index].enabled = true }
                } else { for index in matches { candidate.bindings[index].enabled = false } }
            } else if enabled, let preset = MouseConfiguration().bindings.first(where: { $0.button == button && $0.trigger == trigger && $0.modifiers == 0 }) {
                var item = preset; item.enabled = true; candidate.bindings.append(item)
            }
        }
        configuration = candidate
    }

    func addBinding() {
        configuration.bindings.append(.init(button: 3, trigger: .click, shortcut: .init(keyCode: 33, modifiers: Shortcut.command, label: "⌘[")))
    }

    func removeBinding(_ id: UUID) { configuration.bindings.removeAll { $0.id == id } }

    func addApplicationException() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择需要特殊处理的应用")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        guard !configuration.exceptions.contains(where: { $0.bundleIdentifier == id }) else { return }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        configuration.exceptions.append(.init(bundleIdentifier: id, name: name))
    }

    func removeException(_ id: UUID) { configuration.exceptions.removeAll { $0.id == id } }

    func exportConfiguration() {
        let panel = NSSavePanel()
        panel.title = L10n.text("导出 MacDaily 配置")
        panel.nameFieldStringValue = "MacDaily-config.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try encode(configuration).write(to: url, options: .atomic) }
        catch { errorMessage = L10n.text("导出失败：%@", String(describing: error.localizedDescription)) }
    }

    func importConfiguration() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("导入 MacDaily 配置")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var candidate = try ConfigurationStore.decode(contentsOf: url)
            let alert = NSAlert()
            alert.messageText = L10n.text("替换当前 MacDaily 配置？")
            alert.informativeText = L10n.text("将载入 %@ 条鼠标规则及应用例外，以及触控板、窗口、空间、菜单栏和概览设置。输入增强、拖拽吸附与菜单栏收纳导入后保持关闭。", String(describing: candidate.bindings.count))
            alert.addButton(withTitle: L10n.text("导入"))
            alert.addButton(withTitle: L10n.text("取消"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            pause()
            candidate.windows.enabled = false
            candidate.menuBar.enabled = false
            candidate.trackpad.enabled = false
            practiceSnappingEnabled = false
            try replaceConfiguration(candidate)
        } catch { errorMessage = L10n.text("未导入，原配置保持不变：%@", String(describing: error.localizedDescription)) }
    }

    func restoreDefaults() {
        let alert = NSAlert()
        alert.messageText = L10n.text("恢复默认配置？")
        alert.informativeText = L10n.text("将恢复鼠标、触控板、窗口与工具偏好。输入增强预设关闭，指针保持系统值，拖拽吸附暂停。")
        alert.addButton(withTitle: L10n.text("恢复默认"))
        alert.addButton(withTitle: L10n.text("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            pause()
            try replaceConfiguration(MouseConfiguration())
        } catch { errorMessage = L10n.text("恢复失败：%@", String(describing: error.localizedDescription)) }
    }

    private func replaceConfiguration(_ candidate: MouseConfiguration) throws {
        try persist(candidate, allowRecovery: true)
        applyingConfiguration = true
        configuration = candidate
        applyingConfiguration = false
        configurationNeedsRecovery = false
        errorMessage = nil
        runtime.update(configuration: candidate)
        windowRuntime.update(settings: effectiveWindowSettings)
        menuBar.update(settings: candidate.menuBar)
        dashboard.apply(candidate.dashboard)
        trackpad.update(settings: candidate.trackpad)
    }

    private func encode(_ config: MouseConfiguration) throws -> Data {
        try ConfigurationStore(url: configurationURL).exportData(config)
    }

    private func persist(_ config: MouseConfiguration, allowRecovery: Bool = false) throws {
        guard !configurationNeedsRecovery || allowRecovery else {
            throw ConfigurationError.invalid(L10n.text("原配置无法读取。请先导入有效配置，或选择恢复默认；原文件尚未改动。"))
        }
        try FileManager.default.createDirectory(at: configurationURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try ConfigurationStore(url: configurationURL).save(config)
    }
}
