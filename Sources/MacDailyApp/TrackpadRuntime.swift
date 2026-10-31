import AppKit
import ApplicationServices
import Combine
import MacDailyCore
import TrackpadBridge

private final class TrackpadCallbackOwner: @unchecked Sendable {
    weak var runtime: TrackpadRuntime?
    let generation: UInt64
    init(runtime: TrackpadRuntime, generation: UInt64) { self.runtime = runtime; self.generation = generation }
}

@MainActor
final class TrackpadRuntime: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var testing = false
    @Published private(set) var status = L10n.text("触控板增强尚未开启")
    @Published private(set) var feedback = L10n.text("选择预设后，可先在试用页观察识别结果。")
    @Published private(set) var contacts: [TrackpadContact] = []
    @Published private(set) var lastGesture: TrackpadGesture?
    let nativeSettings = NativeTrackpadSettingsReader()
    weak var executor: InputActionExecutor?

    private var settings = TrackpadSettings()
    private var engine = TrackpadGestureEngine()
    private var monitor: MDTrackpadMonitorRef?
    private var callbackOwner: TrackpadCallbackOwner?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private let pointer = PointerController()
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var physicallyTouching = false
    private var contextTask: Task<TrackpadActionContext, Never>?
    private var context: TrackpadActionContext?
    private var bufferedFrames: [TrackpadFrame] = []
    private var observers: [NSObjectProtocol] = []
    private var nativeSubscription: AnyCancellable?
    private var suspended = Set<String>()
    private var sleeping = false
    private var lifecycleStarted = false
    private var previousPreview: TrackpadGesture?
    private var lastUIFrame: Double = 0
    private var scrollOwned = false
    private var clickOwned = false
    private var clickUntil: Double = 0
    private var scrollUntil: Double = 0
    private var consumedClick = false
    private var ownedMomentum = false

    func startLifecycle() {
        guard !lifecycleStarted else { return }
        lifecycleStarted = true
        nativeSettings.startObserving()
        nativeSubscription = nativeSettings.$status.dropFirst().removeDuplicates().sink { [weak self] _ in
            guard let self else { return }
            self.cancelSession(L10n.text("系统手势配置已更新"))
            self.updateStatus()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancelSession(L10n.text("前台应用已切换")) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }; self.sleeping = true; self.stopStream(); self.status = L10n.text("已随系统休眠暂停")
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.sleeping = false; self.refresh() }
        })
        refresh()
    }

    func update(settings: TrackpadSettings) {
        self.settings = settings
        engine.update(settings: effectiveSettings)
        cancelSession(L10n.text("触控板规则已更新"))
        reconcile()
    }

    func setSuspended(_ reason: String, _ value: Bool) {
        let changed: Bool
        if value { changed = suspended.insert(reason).inserted }
        else { changed = suspended.remove(reason) != nil }
        guard changed else { return }
        reconcile()
    }

    func refresh() {
        nativeSettings.refresh()
        if !testing && monitor != nil && !AXIsProcessTrusted() { stopStream() }
        reconcile()
    }

    func beginTesting() {
        guard !testing else { return }
        stopStream(); testing = true
        lastGesture = nil; feedback = L10n.text("请在内建触控板上操作；试用只显示识别结果。")
        reconcile()
    }
    func endTesting() {
        guard testing else { return }
        stopStream(); testing = false
        reconcile()
    }
    private var effectiveSettings: TrackpadSettings {
        var result = settings
        if testing && result.bindings.isEmpty { result.installRecommendedBindings() }
        return result
    }

    private func reconcile() {
        guard lifecycleStarted else { return }
        guard !sleeping, suspended.isEmpty else {
            stopStream(); status = sleeping ? L10n.text("已随系统休眠暂停") : L10n.text("暂时暂停：%@", String(describing: suspended.sorted().joined(separator: L10n.text("、"))))
            return
        }
        guard settings.enabled || testing else { stopStream(); status = L10n.text("触控板增强已关闭"); return }
        guard testing || settings.bindings.contains(where: \.enabled) else { stopStream(); status = L10n.text("请先选择预设或启用手势规则"); return }
        guard testing || AXIsProcessTrusted() else { stopStream(); status = L10n.text("需要 MacDaily 的辅助功能权限"); return }
        if monitor == nil { startStream() }
        if monitor != nil { updateStatus() }
    }

    private func startStream() {
        generation &+= 1
        let owner = TrackpadCallbackOwner(runtime: self, generation: generation)
        let callback: MDTrackpadFrameCallback = { context, contacts, count, timestamp in
            guard let context else { return }
            let owner = Unmanaged<TrackpadCallbackOwner>.fromOpaque(context).takeUnretainedValue()
            let values = (0..<count).map { index -> TrackpadContact in
                let contact = contacts[index]
                return TrackpadContact(id: contact.identifier, x: contact.x, y: contact.y)
            }
            DispatchQueue.main.async { [weak runtime = owner.runtime, generation = owner.generation] in
                runtime?.receive(values, time: timestamp, generation: generation)
            }
        }
        guard let monitor = MDTrackpadMonitorCreate(callback, Unmanaged.passUnretained(owner).toOpaque()) else {
            status = L10n.text("无法打开内建触控板接口"); return
        }
        guard MDTrackpadMonitorIsAvailable(monitor) else {
            status = L10n.text(MDTrackpadMonitorCopyStatus(monitor) as String)
            MDTrackpadMonitorDestroy(monitor); return
        }
        callbackOwner = owner; self.monitor = monitor
        engine = TrackpadGestureEngine(settings: effectiveSettings)
        if !testing {
            pointer.startMonitoring { _ in }
            guard installFilter() else { stopStream(); status = L10n.text("未能启动触控板输入处理，请检查辅助功能权限"); return }
        }
        guard MDTrackpadMonitorStart(monitor) else {
            let message = L10n.text(MDTrackpadMonitorCopyStatus(monitor) as String)
            stopStream(); status = message; return
        }
        running = !testing
    }

    private func stopStream() {
        generation &+= 1
        if let monitor { MDTrackpadMonitorStop(monitor); MDTrackpadMonitorDestroy(monitor) }
        monitor = nil; callbackOwner = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil; tapSource = nil
        pointer.stopMonitoring()
        engine = TrackpadGestureEngine(settings: effectiveSettings)
        contextTask?.cancel(); contextTask = nil; context = nil; bufferedFrames = []
        physicallyTouching = false; contacts = []; running = false
        clearOwnership(); executor?.preview(nil, context: nil, titlebar: false)
    }

    private func cancelSession(_ message: String) {
        engine.cancel(); contextTask?.cancel(); contextTask = nil; context = nil; bufferedFrames = []
        sequence &+= 1
        clearOwnership(); previousPreview = nil
        executor?.preview(nil, context: nil, titlebar: false)
        if physicallyTouching { feedback = message }
    }
    private func clearOwnership() {
        scrollOwned = false; clickOwned = false; clickUntil = 0; scrollUntil = 0
        consumedClick = false; ownedMomentum = false
    }

    private func receive(_ values: [TrackpadContact], time: Double, generation: UInt64) {
        guard generation == self.generation, monitor != nil, !sleeping, suspended.isEmpty else { return }
        if !testing && !AXIsProcessTrusted() { stopStream(); status = L10n.text("辅助功能权限已失效，触控板增强已暂停"); return }
        let newSession = !physicallyTouching && !values.isEmpty
        if newSession {
            sequence &+= 1; context = nil; contextTask = nil; bufferedFrames = []
            previousPreview = nil; scrollOwned = false; ownedMomentum = false
        }
        physicallyTouching = !values.isEmpty
        let flags = CGEventSource.flagsState(.combinedSessionState).rawValue & Shortcut.modifierMask
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let titlebarPossible = values.count == 2 && effectiveSettings.bindings.contains {
            $0.enabled && $0.gesture.isTitlebar && $0.modifiers == flags && ($0.bundleIdentifier == nil || $0.bundleIdentifier == bundle)
        }
        let cornerPossible = values.count == 1 && effectiveSettings.bindings.contains {
            $0.enabled && $0.gesture.isCorner && $0.modifiers == flags && ($0.bundleIdentifier == nil || $0.bundleIdentifier == bundle)
        }
        if contextTask == nil && (values.count >= 3 || titlebarPossible || cornerPossible), let executor {
            let task = executor.capture(); contextTask = task
            let current = sequence
            Task { [weak self] in
                let value = await task.value
                guard !Task.isCancelled, let self, self.sequence == current, self.monitor != nil else { return }
                self.context = value
                let frames = self.bufferedFrames; self.bufferedFrames = []
                for var frame in frames { frame.isTitlebar = value.isTitlebar; self.recognize(frame) }
                if self.physicallyTouching, let gesture = self.previousPreview, !self.testing {
                    let modifiers = CGEventSource.flagsState(.combinedSessionState).rawValue & Shortcut.modifierMask
                    let binding = self.effectiveSettings.binding(for: gesture, modifiers: modifiers, bundleIdentifier: value.bundleIdentifier)
                    self.executor?.preview(binding?.action, context: value, titlebar: gesture.isTitlebar)
                }
            }
        }
        let frame = TrackpadFrame(contacts: values, timestamp: time, modifiers: flags, bundleIdentifier: bundle, isTitlebar: context?.isTitlebar ?? false)
        // Titlebar hit testing resolves off the input path; retain its initial
        // frames so a quick two-finger gesture is not lost while AX responds.
        if (titlebarPossible || !bufferedFrames.isEmpty) && context == nil && contextTask != nil {
            bufferedFrames.append(frame)
        } else { recognize(frame) }
        if testing && (time - lastUIFrame >= 1.0 / 30 || values.isEmpty) {
            contacts = values; lastUIFrame = time
        }
    }

    private func recognize(_ frame: TrackpadFrame) {
        let result = engine.process(frame, native: nativeSettings.status)
        let now = ProcessInfo.processInfo.systemUptime
        if !testing {
            scrollOwned = result.shouldSuppressScroll
            clickOwned = result.shouldSuppressClick
            if scrollOwned { scrollUntil = now + 0.18 }
            if clickOwned { clickUntil = now + 0.18 }
            if result.captureKind == .fourFinger { scrollOwned = false; scrollUntil = 0; ownedMomentum = false }
        }
        if let text = result.feedback { feedback = text }
        if result.preview != previousPreview {
            previousPreview = result.preview
            if let gesture = result.preview,
               let binding = effectiveSettings.binding(for: gesture, modifiers: frame.modifiers, bundleIdentifier: frame.bundleIdentifier) {
                if testing { feedback = L10n.text("%@ → %@（试用）", String(describing: gesture.title), String(describing: binding.action.title)) }
                else if let context { executor?.preview(binding.action, context: context, titlebar: gesture.isTitlebar) }
            } else { executor?.preview(nil, context: nil, titlebar: false) }
        }
        if let gesture = result.gesture {
            lastGesture = gesture
            if testing { feedback = L10n.text("%@ 已识别，试用不执行动作", String(describing: gesture.title)) }
            else if let binding = result.binding, let task = contextTask {
                let current = sequence
                Task { [weak self] in
                    let context = await task.value
                    guard let self, self.running, !self.testing, self.sequence == current, !Task.isCancelled else { return }
                    self.feedback = self.executor?.execute(binding.action, context: context, titlebar: gesture.isTitlebar) ?? L10n.text("动作执行器尚未就绪")
                }
            }
        }
        if result.sessionEnded { executor?.preview(nil, context: nil, titlebar: false); previousPreview = nil }
    }

    private func installFilter() -> Bool {
        let types: [CGEventType] = [.scrollWheel, .leftMouseDown, .leftMouseUp, .keyDown, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let runtime = Unmanaged<TrackpadRuntime>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated { runtime.filter(type, event) }
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }
        self.tap = tap; tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func filter(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == InputActionExecutor.marker { return Unmanaged.passUnretained(event) }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if AXIsProcessTrusted(), let tap { cancelSession(L10n.text("输入处理已恢复，当前手势取消")); CGEvent.tapEnable(tap: tap, enable: true) }
            else { Task { @MainActor [weak self] in self?.refresh() } }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53 { cancelSession(L10n.text("已按 Escape 取消手势")) }
        if type == .flagsChanged, physicallyTouching {
            cancelSession(L10n.text("修饰键已切换，手势取消"))
        }
        guard [.scrollWheel, .leftMouseDown, .leftMouseUp].contains(type), pointer.isBuiltInTrackpad(event: event) else {
            return Unmanaged.passUnretained(event)
        }
        let now = ProcessInfo.processInfo.systemUptime
        if type == .scrollWheel {
            let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            if scrollOwned || now < scrollUntil { if momentum != 0 { ownedMomentum = true }; return nil }
            if ownedMomentum && momentum != 0 { if momentum == 4 { ownedMomentum = false }; return nil }
            ownedMomentum = false
        } else if type == .leftMouseDown && (clickOwned || now < clickUntil) { consumedClick = true; return nil }
        else if type == .leftMouseUp && consumedClick { consumedClick = false; return nil }
        return Unmanaged.passUnretained(event)
    }

    private func updateStatus() {
        if testing { status = L10n.text("触控板试用中 · 只识别，不执行") }
        else if running {
            let blocked = settings.bindings.filter { $0.enabled && nativeSettings.status.conflict(for: $0.gesture) != nil }.count
            status = blocked > 0 ? L10n.text("触控板增强运行中 · %@ 条规则等待系统手势配置", String(describing: blocked)) : L10n.text("触控板增强运行中")
        }
    }

    func stop() {
        lifecycleStarted = false
        stopStream(); testing = false
        nativeSubscription = nil; nativeSettings.stopObserving()
        for token in observers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        observers.removeAll(); lifecycleStarted = false
    }
}
