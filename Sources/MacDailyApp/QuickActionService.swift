import AppKit
import ApplicationServices
import Combine
import CoreAudio
import IOKit.pwr_mgt
import MacDailyCore

@MainActor
final class QuickActionService: ObservableObject {
    @Published var states: [DashboardAction: Bool] = [:]
    @Published var message: String?
    @Published var durationMinutes = 30
    var onMousePause: (() -> Void)?
    var onWindowLayout: (() -> Void)?
    var onStorage: (() -> Void)?
    var onKeyboardCleaningChanged: ((Bool) -> Void)?
    var onWillPresentOverlay: (() -> Void)?
    var dockAnchorDisplayUUID: String? {
        didSet {
            dockAnchor.update(displayUUID: dockAnchorDisplayUUID)
            states[.pinDock] = dockAnchor.isRunning
        }
    }
    var availableDockDisplays: [DockAnchorDisplay] { DockScreenAnchor.displays }

    private let dockAnchor = DockScreenAnchor()
    private let outputMute = DashboardOutputMute()

    private var assertions: [DashboardAction: IOPMAssertionID] = [:]
    private var expiry: [DashboardAction: Timer] = [:]
    private var cleaning: QuickActionCleaningController?
    private var notchWindows: [NSWindow] = []
    private var observers: [NSObjectProtocol] = []
    private var operation: Task<Void, Never>?

    init() {
        dockAnchor.onStopped = { [weak self] message in
            self?.states[.pinDock] = false; self?.message = message
        }
        outputMute.onChange = { [weak self] value in self?.states[.muteAudio] = value }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.endCleaning() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.endCleaning()
                if self.states[.hideNotch] == true { self.showNotchBand() }
            }
        })
    }

    func refresh() {
        dockAnchor.refreshGeometry()
        states[.pinDock] = dockAnchor.isRunning
        states[.muteAudio] = outputMute.refresh()
        states[.darkMode] = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        states[.hideDesktop] = Self.preference("CreateDesktop", domain: "com.apple.finder").map { !$0 } ?? false
        states[.hideDock] = Self.preference("autohide", domain: "com.apple.dock") ?? false
        states[.lockDock] = Self.preference("contents-immutable", domain: "com.apple.dock") ?? false
        states[.hideMenuBar] = Self.preference("_HIHideMenuBar", domain: "NSGlobalDomain") ?? false
        states[.lowPower] = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    func perform(_ action: DashboardAction) {
        message = nil
        switch action {
        case .keepAwake, .keepDisplayAwake: toggleAssertion(action)
        case .mousePause: onMousePause?()
        case .windowLayout: onWindowLayout?()
        case .storage: onStorage?()
        case .lockScreen: lockScreen()
        case .pinDock:
            if dockAnchor.isRunning { dockAnchor.stop() } else { dockAnchor.start(displayUUID: dockAnchorDisplayUUID) }
            states[.pinDock] = dockAnchor.isRunning
        case .muteAudio:
            do { states[.muteAudio] = try outputMute.toggle() } catch { message = error.localizedDescription }
        case .audioSettings: openSettings("com.apple.preference.sound")
        case .wifiSettings: openSettings("com.apple.wifi-settings-extension")
        case .bluetoothSettings: openSettings("com.apple.BluetoothSettings")
        case .screenSaver:
            openApplication("/System/Library/CoreServices/ScreenSaverEngine.app")
        case .trash:
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash", isDirectory: true))
        case .lowPower: openSettings("com.apple.preference.battery")
        case .displays: openSettings("com.apple.preference.displays")
        case .systemSettings: openApplication("/System/Applications/System Settings.app")
        case .activityMonitor: openApplication("/System/Applications/Utilities/Activity Monitor.app")
        case .hideNotch:
            if states[.hideNotch] == true { hideNotchBand() } else { showNotchBand() }
        case .cleanScreen: startCleaning(keyboard: false)
        case .cleanKeyboard: startCleaning(keyboard: true)
        case .darkMode:
            let next = !(states[action] ?? false)
            runOperation(action, target: next) {
                try Self.appleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(next ? "true" : "false")")
            }
        case .hideDesktop, .hideDock, .lockDock, .hideMenuBar:
            let next = !(states[action] ?? false)
            runOperation(action, target: next) {
                let domain: String, key: String, value: Bool, process: String
                switch action {
                case .hideDesktop: domain = "com.apple.finder"; key = "CreateDesktop"; value = !next; process = "Finder"
                case .hideDock: domain = "com.apple.dock"; key = "autohide"; value = next; process = "Dock"
                case .lockDock: domain = "com.apple.dock"; key = "contents-immutable"; value = next; process = "Dock"
                default: domain = "NSGlobalDomain"; key = "_HIHideMenuBar"; value = next; process = "Dock"
                }
                try Self.run("/usr/bin/defaults", ["write", domain == "NSGlobalDomain" ? "-g" : domain, key, "-bool", value ? "true" : "false"])
                try Self.run("/usr/bin/killall", [process])
            }
        }
    }

    private func runOperation(_ action: DashboardAction, target: Bool, operation: @escaping @Sendable () throws -> Void) {
        guard self.operation == nil else { message = L10n.text("上一项设置正在应用"); return }
        self.operation = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> String? in
                do { try operation(); return nil } catch { return error.localizedDescription }
            }.value
            guard let self else { return }
            self.operation = nil
            if let result { self.message = result } else { self.states[action] = target }
        }
    }

    private func toggleAssertion(_ action: DashboardAction) {
        if let id = assertions.removeValue(forKey: action) {
            IOPMAssertionRelease(id)
            expiry.removeValue(forKey: action)?.invalidate()
            states[action] = false
            return
        }
        var id: IOPMAssertionID = 0
        let type = action == .keepAwake ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertionTypePreventUserIdleDisplaySleep
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "MacDaily \(action.title)" as CFString, &id)
        guard result == kIOReturnSuccess else { message = L10n.text("未能启用%@：%@", String(describing: action.title), String(describing: result)); return }
        assertions[action] = id; states[action] = true
        if durationMinutes > 0 {
            expiry[action] = Timer.scheduledTimer(withTimeInterval: Double(durationMinutes * 60), repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let id = self.assertions.removeValue(forKey: action) else { return }
                    IOPMAssertionRelease(id); self.expiry.removeValue(forKey: action)?.invalidate(); self.states[action] = false
                }
            }
        }
    }

    private func lockScreen() {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: false) else { return }
        for event in [down, up] {
            event.flags = [.maskCommand, .maskControl]
            event.setIntegerValueField(.eventSourceUserData, value: 0x4D41434441494C59)
            event.post(tap: .cghidEventTap)
        }
    }

    private func startCleaning(keyboard: Bool) {
        endCleaning()
        let controller = QuickActionCleaningController()
        controller.onFinish = { [weak self] in self?.endCleaning() }
        do {
            try controller.start(keyboard: keyboard, onKeyboardReady: { [weak self] in self?.onKeyboardCleaningChanged?(true) }, onWillPresent: { [weak self] in self?.onWillPresentOverlay?() })
            cleaning = controller
            states[keyboard ? .cleanKeyboard : .cleanScreen] = true
        } catch { message = error.localizedDescription }
    }

    private func endCleaning() {
        let wasKeyboard = states[.cleanKeyboard] == true
        cleaning?.stop(); cleaning = nil
        states[.cleanKeyboard] = false; states[.cleanScreen] = false
        if wasKeyboard { onKeyboardCleaningChanged?(false) }
    }

    private func showNotchBand() {
        hideNotchBand()
        for screen in NSScreen.screens where screen.safeAreaInsets.top > 0 {
            let height = screen.safeAreaInsets.top
            let window = NSWindow(contentRect: NSRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.backgroundColor = .black
            window.ignoresMouseEvents = true
            window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.orderFrontRegardless(); notchWindows.append(window)
        }
        states[.hideNotch] = !notchWindows.isEmpty
        if notchWindows.isEmpty { message = L10n.text("当前显示器没有刘海区域") }
    }

    private func hideNotchBand() {
        notchWindows.forEach { $0.close() }; notchWindows.removeAll(); states[.hideNotch] = false
    }

    private func openApplication(_ path: String) {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init()) { [weak self] _, error in
            if let error { Task { @MainActor in self?.message = error.localizedDescription } }
        }
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }

    private static func preference(_ key: String, domain: String) -> Bool? {
        let app = domain == "NSGlobalDomain" ? kCFPreferencesAnyApplication : domain as CFString
        CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (CFPreferencesCopyValue(key as CFString, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber)?.boolValue
    }

    nonisolated private static func run(_ path: String, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        let output = Pipe(); process.standardError = output; process.standardOutput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "MacDaily.QuickAction", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? L10n.text("设置执行失败")])
        }
    }

    nonisolated private static func appleScript(_ source: String) throws {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { throw NSError(domain: "MacDaily.QuickAction", code: 1, userInfo: [NSLocalizedDescriptionKey: error[NSAppleScript.errorMessage] as? String ?? L10n.text("设置执行失败")]) }
    }

    func stop() {
        endCleaning(); hideNotchBand(); dockAnchor.stop(); outputMute.stop()
        states[.pinDock] = false
        expiry.values.forEach { $0.invalidate() }; expiry.removeAll()
        assertions.values.forEach { IOPMAssertionRelease($0) }; assertions.removeAll()
        states[.keepAwake] = false; states[.keepDisplayAwake] = false
        for observer in observers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll(); operation?.cancel(); operation = nil
    }
}


/// Reads and toggles the actual default output device's master mute property.
@MainActor
private final class DashboardOutputMute {
    var onChange: ((Bool) -> Void)?
    private var device: AudioObjectID = kAudioObjectUnknown
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private var muteListener: AudioObjectPropertyListenerBlock?
    private var defaultAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    func refresh() -> Bool {
        if defaultListener == nil {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.onChange?(self.refresh())
                }
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, .main, listener) == noErr { defaultListener = listener }
        }
        var current: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, 0, nil, &size, &current) == noErr else { return false }
        if current != device {
            removeMuteListener()
            device = current
            if AudioObjectHasProperty(device, &muteAddress) {
                let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.onChange?(self.readMuted())
                    }
                }
                if AudioObjectAddPropertyListenerBlock(device, &muteAddress, .main, listener) == noErr { muteListener = listener }
            }
        }
        return readMuted()
    }

    func toggle() throws -> Bool {
        let next = !refresh()
        var settable = DarwinBoolean(false)
        guard device != kAudioObjectUnknown, AudioObjectHasProperty(device, &muteAddress),
              AudioObjectIsPropertySettable(device, &muteAddress, &settable) == noErr, settable.boolValue else {
            throw NSError(domain: "MacDaily.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.text("当前音频输出设备不支持系统静音")])
        }
        var value: UInt32 = next ? 1 : 0
        let result = AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        guard result == noErr else { throw NSError(domain: "MacDaily.Audio", code: Int(result), userInfo: [NSLocalizedDescriptionKey: L10n.text("未能切换当前音频输出设备的静音状态（%@）", String(describing: result))]) }
        return readMuted()
    }

    private func readMuted() -> Bool {
        guard device != kAudioObjectUnknown, AudioObjectHasProperty(device, &muteAddress) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &value) == noErr && value != 0
    }

    private func removeMuteListener() {
        if let muteListener { AudioObjectRemovePropertyListenerBlock(device, &muteAddress, .main, muteListener) }
        muteListener = nil
    }

    func stop() {
        removeMuteListener()
        if let defaultListener { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, .main, defaultListener) }
        defaultListener = nil; device = kAudioObjectUnknown
    }
}
