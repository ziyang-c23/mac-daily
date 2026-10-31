import AppKit
import ApplicationServices
import MacDailyCore
import PointerBridge

/// UI/lifecycle boundary. Input filtering runs on a separate run loop.
@MainActor
final class MouseRuntime {
    var onStatus: ((String) -> Void)?
    var onDevices: (([String]) -> Void)?
    var onAction: ((String) -> Void)?
    weak var executor: InputActionExecutor?
    var onInspectionEvent: ((String) -> Void)?
    var onInspectionMatch: ((String) -> Void)?
    var onPointerStatus: ((String) -> Void)?
    var onTestEvent: ((String) -> Void)?
    var onGestureFeedback: ((String) -> Void)?
    private(set) var isRunning = false
    private let pointer = PointerController()
    private var worker: MouseEventWorker?
    private var configuration = MouseConfiguration()
    private var observers: [NSObjectProtocol] = []
    private var sleeping = false
    private var permissionWatch: Timer?
    private var contextTasks: [UUID: Task<TrackpadActionContext, Never>] = [:]
    private var inspectionOnly = false

    init() {
        pointer.onStatus = { [weak self] text in self?.onPointerStatus?(text) }
    }

    @discardableResult
    func start(configuration: MouseConfiguration, inspectionOnly: Bool = false) -> Bool {
        guard !isRunning else { update(configuration: configuration); return true }
        guard AXIsProcessTrusted() else { onStatus?(L10n.text("需要辅助功能权限，授权后点击重新检查。")); return false }
        self.configuration = configuration
        self.inspectionOnly = inspectionOnly
        pointer.startMonitoring { [weak self] names in
            self?.onDevices?(names)
            self?.worker?.deviceTopologyChanged()
        }
        let newWorker = MouseEventWorker(configuration: configuration, inspectionOnly: inspectionOnly, classify: { [pointer] event in pointer.identify(event: event) })
        newWorker.onStatus = { [weak self] message in Task { @MainActor in self?.onStatus?(message) } }
        newWorker.onSessionBegan = { [weak self] token, pid, target, point in
            DispatchQueue.main.async {
                guard let self, self.isRunning, !self.inspectionOnly, let executor = self.executor else { return }
                self.contextTasks[token] = executor.captureMouse(pid: pid, bundleIdentifier: target, point: point)
            }
        }
        newWorker.onAction = { [weak self] action, token in
            DispatchQueue.main.async {
                guard let self, self.isRunning, !self.sleeping, !self.inspectionOnly,
                      let capture = self.contextTasks[token] else { return }
                Task { @MainActor [weak self] in
                    let context = await capture.value
                    guard let self, self.isRunning, !self.sleeping, !self.inspectionOnly else { return }
                    let result = self.executor?.execute(action, context: context, titlebar: false) ?? L10n.text("动作执行器尚未就绪")
                    self.onAction?(result)
                }
            }
        }
        newWorker.onSessionEnded = { [weak self] token in
            DispatchQueue.main.async { self?.contextTasks.removeValue(forKey: token) }
        }
        newWorker.onInspectionEvent = { [weak self] text in
            DispatchQueue.main.async { self?.onInspectionEvent?(text) }
        }
        newWorker.onInspectionMatch = { [weak self] match in
            DispatchQueue.main.async { self?.onInspectionMatch?(match) }
        }
        newWorker.onPermissionLost = { [weak self] in
            Task { @MainActor in self?.stop(); self?.onStatus?(L10n.text("辅助功能权限已失效，鼠标增强已暂停")) }
        }
        newWorker.onGestureFeedback = { [weak self] value in Task { @MainActor in self?.onGestureFeedback?(value) } }
        newWorker.onTestEvent = { [weak self] text in Task { @MainActor in self?.onTestEvent?(text) } }
        newWorker.setForeground(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "", pid: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
        guard newWorker.start() else {
            pointer.stopMonitoring(); onStatus?(L10n.text("未能启动鼠标监听。请检查辅助功能权限后重试。")); return false
        }
        worker = newWorker; isRunning = true
        if !inspectionOnly { pointer.apply(configuration.pointer) }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self?.worker?.setForeground(app?.bundleIdentifier ?? "", pid: app?.processIdentifier ?? 0) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }; self.sleeping = true
                self.worker?.suspend(); self.pointer.restore(); self.onStatus?(L10n.text("已随系统休眠暂停"))
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }; self.sleeping = false
                if AXIsProcessTrusted() {
                    self.worker?.resume(); if !self.inspectionOnly { self.pointer.apply(self.configuration.pointer) }
                    self.onStatus?(L10n.text("鼠标增强已恢复"))
                } else { self.stop(); self.onStatus?(L10n.text("权限已失效，鼠标增强已暂停")) }
            }
        })
        let watch = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                if !AXIsProcessTrusted() { self.stop(); self.onStatus?(L10n.text("辅助功能权限已失效，鼠标增强已暂停")) }
            }
        }
        watch.tolerance = 1
        permissionWatch = watch; RunLoop.main.add(watch, forMode: .common)
        onStatus?(inspectionOnly ? L10n.text("真实鼠标检查中，不执行映射") : configuration.bindings.contains(where: \.enabled) ? L10n.text("鼠标增强已启用") : L10n.text("没有启用的规则，滚动设置仍有效")); onPointerStatus?(pointer.status)
        return true
    }

    func update(configuration: MouseConfiguration) {
        self.configuration = configuration
        worker?.update(configuration)
        if isRunning && !sleeping && !inspectionOnly { pointer.apply(configuration.pointer); onPointerStatus?(pointer.status) }
    }

    func stop(drainPending: Bool = true) {
        isRunning = false; sleeping = false
        for task in contextTasks.values { task.cancel() }; contextTasks.removeAll()
        permissionWatch?.invalidate(); permissionWatch = nil
        worker?.stop(drainPending: drainPending); worker = nil
        pointer.restore(); pointer.stopMonitoring()
        for token in observers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        observers.removeAll()
        onStatus?(L10n.text("已暂停，鼠标保持原生操作")); onPointerStatus?(pointer.status)
    }


}

private final class MouseEventWorker: @unchecked Sendable {
    static let marker: Int64 = 0x4D41434441494C59
    var onStatus: ((String) -> Void)?
    var onAction: ((InputAction, UUID) -> Void)?
    var onSessionBegan: ((UUID, pid_t, String, CGPoint) -> Void)?
    var onSessionEnded: ((UUID) -> Void)?
    var onInspectionEvent: ((String) -> Void)?
    var onInspectionMatch: ((String) -> Void)?
    var onTestEvent: ((String) -> Void)?
    var onPermissionLost: (() -> Void)?
    var onGestureFeedback: ((String) -> Void)?
    private let classify: (CGEvent) -> InputDeviceKind
    private var engine: MouseEngine
    private var configuration: MouseConfiguration
    private var foreground = ""
    private var foregroundPID: pid_t = 0
    private let inspectionOnly: Bool
    private var adapter = MouseEventAdapter()
    private var sessionToken: UUID?
    private var sessionButton: Int?
    private var lastInspectionTime = 0.0
    private var diagnosticOrigin: CGPoint?
    private var diagnosticDelta = CGPoint.zero
    private let lock = NSLock()
    private var loop: CFRunLoop?
    private var tap: CFMachPort?
    private var runThread: Thread?
    private var requestedStop = false
    private var started = false
    private var suspended = false
    private var draining = false
    private var drainTimer: Timer?
    private var smoother = SmoothScrollAccumulator()
    private var discreteScaler = DiscreteScrollScaler()
    private var timer: Timer?
    private var lastTick = 0.0
    private var lastFeedback = ""
    private var lastFeedbackTime = 0.0
    private var remainderX = 0.0
    private var remainderY = 0.0
    private var scrollLocation = CGPoint.zero
    private var scrollFlags = CGEventFlags()
    private var scrollDuration = 0.16

    init(configuration: MouseConfiguration, inspectionOnly: Bool, classify: @escaping (CGEvent) -> InputDeviceKind) {
        self.configuration = configuration; self.engine = MouseEngine(configuration: configuration); self.classify = classify; self.inspectionOnly = inspectionOnly
    }

    func start() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            autoreleasepool {
                let mask: CGEventMask = [CGEventType.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                    .rightMouseDown, .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp,
                    .otherMouseDragged, .scrollWheel, .keyDown].reduce(0) { $0 | (1 << $1.rawValue) }
                let callback: CGEventTapCallBack = { _, type, event, context in
                    guard let context else { return Unmanaged.passUnretained(event) }
                    return Unmanaged<MouseEventWorker>.fromOpaque(context).takeUnretainedValue().handle(type, event)
                }
                guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                    eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()),
                    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
                    ready.signal(); return
                }
                lock.lock(); tap = port; loop = CFRunLoopGetCurrent(); started = !requestedStop; let shouldRun = started; lock.unlock()
                if shouldRun {
                    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
                    CGEvent.tapEnable(tap: port, enable: true)
                }
                ready.signal()
                if shouldRun { CFRunLoopRun() }
                cancelInteraction(); CGEvent.tapEnable(tap: port, enable: false)
                CFMachPortInvalidate(port)
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
                lock.lock(); loop = nil; tap = nil; started = false; lock.unlock()
            }
        }
        thread.name = "MacDaily.MouseEvents"; thread.qualityOfService = .userInteractive
        runThread = thread; thread.start()
        _ = ready.wait(timeout: .now() + 2)
        lock.lock(); let success = started; lock.unlock()
        if !success { stop() }
        return success
    }

    private func enqueue(_ block: @escaping () -> Void) {
        lock.lock(); let target = loop; lock.unlock()
        if let target { CFRunLoopPerformBlock(target, CFRunLoopMode.commonModes.rawValue, block); CFRunLoopWakeUp(target) }
    }
    func setForeground(_ bundle: String, pid: pid_t) {
        lock.lock(); let hasLoop = loop != nil; lock.unlock()
        if !hasLoop { foreground = bundle; foregroundPID = pid; return }
        enqueue { [self] in if foreground != bundle || foregroundPID != pid { cancelInteraction(reason: L10n.text("前台应用已切换，已取消当前操作")); foreground = bundle; foregroundPID = pid } }
    }
    func update(_ config: MouseConfiguration) {
        enqueue { [self] in cancelInteraction(reason: L10n.text("配置已修改，已取消当前操作")); configuration = config; _ = engine.update(configuration: config) }
    }
    func deviceTopologyChanged() {
        enqueue { [self] in cancelInteraction(reason: L10n.text("鼠标连接已变化，已取消当前手势")) }
    }
    func suspend() {
        enqueue { [self] in suspended = true; cancelInteraction(reason: L10n.text("系统休眠，当前手势已取消")) }
    }
    func resume() {
        enqueue { [self] in suspended = false; if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }
    }
    func stop(drainPending: Bool = true) {
        lock.lock(); requestedStop = true; let target = loop; lock.unlock()
        guard let target else { return }
        let finished = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(target, CFRunLoopMode.commonModes.rawValue) { [self] in
            suspended = true; cancelInteraction()
            if !inspectionOnly && drainPending && !engine.pendingReleaseButtons.isEmpty {
                draining = true
                let expiry = Timer(timeInterval: 5, repeats: false) { [weak self] _ in self?.finishStop() }
                drainTimer = expiry; RunLoop.current.add(expiry, forMode: .common)
            } else { finishStop() }
            finished.signal()
        }
        CFRunLoopWakeUp(target)
        _ = finished.wait(timeout: .now() + 1)
    }

    private func finishStop() {
        draining = false; drainTimer?.invalidate(); drainTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        CFRunLoopStop(CFRunLoopGetCurrent())
    }

    private func cancelInteraction(reason: String = L10n.text("已取消手势")) {
        if let token = sessionToken { onSessionEnded?(token); sessionToken = nil; sessionButton = nil }
        let cancelled = engine.cancel(reason: reason)
        if let text = cancelled.feedback { publishFeedback(text) }
        stopSmoothing()
    }
    private func stopSmoothing(resetDiscrete: Bool = true) {
        if resetDiscrete { discreteScaler.reset() }
        timer?.invalidate(); timer = nil; smoother.reset(); remainderX = 0; remainderY = 0
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return Unmanaged.passUnretained(event) }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancelInteraction()
            if !AXIsProcessTrusted() {
                suspended = true; onPermissionLost?(); return Unmanaged.passUnretained(event)
            }
            if !suspended, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            onStatus?(L10n.text("鼠标监听中断，已取消当前手势并尝试恢复"))
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 { cancelInteraction(reason: L10n.text("已按 Esc 取消手势")) }
            return Unmanaged.passUnretained(event)
        }
        let isDown = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type)
        let isUp = [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(type)
        let isMove = [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type)
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        let device = classify(event)
        let isMouse = device == .mouse
        let kind: MouseInput.Kind = isDown ? .buttonDown : isUp ? .buttonUp : isMove ? .move : .scroll
        let raw = MouseInput(kind: kind, button: button, x: event.location.x, y: event.location.y,
            timestamp: Double(event.timestamp) / 1_000_000_000,
            modifiers: event.flags.rawValue & Shortcut.modifierMask, bundleIdentifier: foreground,
            deltaX: isMove ? event.getDoubleValueField(.mouseEventDeltaX) : type == .scrollWheel ? scrollDelta(event, vertical: false) : 0,
            deltaY: isMove ? event.getDoubleValueField(.mouseEventDeltaY) : type == .scrollWheel ? scrollDelta(event, vertical: true) : 0,
            isContinuous: type == .scrollWheel && event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
            isSynthetic: false, isMouse: false, clickCount: event.getIntegerValueField(.mouseEventClickState))
        let sender = MDPointerEventSenderID(event)
        let input = adapter.adapt(raw, device: device == .mouse ? .mouse : device == .trackpad ? .trackpad : .unknown, senderID: sender)
        if isDown {
            stopSmoothing()
            if input.isMouse { diagnosticOrigin = event.location; diagnosticDelta = .zero }
        }
        if isMove && input.isMouse { diagnosticDelta.x += input.deltaX; diagnosticDelta.y += input.deltaY }
        if suspended {
            if inspectionOnly { return Unmanaged.passUnretained(event) }
            if (isUp || isMove) && engine.pendingReleaseButtons.contains(button) && input.isMouse {
                let consumed = engine.process(input).consumed
                if draining && engine.pendingReleaseButtons.isEmpty { finishStop() }
                return consumed ? nil : Unmanaged.passUnretained(event)
            }
            return Unmanaged.passUnretained(event)
        }
        if isDown && isMouse {
            onTestEvent?(L10n.text("%@已识别", String(describing: MouseBinding.buttonName(button))))
            if button == 1 || button == 2 {
                let configured = configuration.bindings.contains { $0.enabled && $0.button == button }
                if !configured { publishFeedback(L10n.text("%@没有启用规则，可先在手势试用区练习", String(describing: MouseBinding.buttonName(button)))) }
            }
        } else if isDown && button >= 1 {
            publishFeedback(L10n.text("未确认该按键来自外接鼠标，保留原生操作"))
        }
        let decision = engine.process(input)
        if isDown && engine.isCapturing {
            let token = UUID(); sessionToken = token; sessionButton = button
            if !inspectionOnly { onSessionBegan?(token, foregroundPID, foreground, event.location) }
        }
        if let text = decision.feedback { publishFeedback(text) }
        let now = ProcessInfo.processInfo.systemUptime
        if !isMove || now - lastInspectionTime >= 0.08 {
            lastInspectionTime = now
            let attribution = input.isMouse ? L10n.text("鼠标") : device == .trackpad ? L10n.text("触控板") : L10n.text("来源未确认")
            let eventName: String
            switch kind {
            case .buttonDown: eventName = L10n.text("按下")
            case .buttonUp: eventName = L10n.text("松开")
            case .move: eventName = L10n.text("移动")
            case .scroll: eventName = L10n.text("滚轮")
            case .cancel: eventName = L10n.text("取消")
            }
            let description = L10n.text("%@ · %@ · 按钮 %@ · sender %@ · Δ %@ / %@", eventName, attribution, String(button), String(sender), String(Int(input.deltaX)), String(Int(input.deltaY)))
            let displacement = diagnosticOrigin.map { origin in
                L10n.text("位置位移 %@ / %@ · 累计增量 %@ / %@", String(Int(input.x - origin.x)), String(Int(input.y - origin.y)), String(Int(diagnosticDelta.x)), String(Int(diagnosticDelta.y)))
            } ?? ""
            let result = decision.actions.first.map { L10n.text("匹配动作：%@", $0.title) } ?? decision.feedback ?? ""
            onInspectionEvent?([description, displacement, result].filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        if inspectionOnly, let action = decision.actions.first {
            let trigger: MouseTrigger
            if kind == .scroll { trigger = input.deltaY > 0 ? .scrollUp : .scrollDown }
            else if let origin = diagnosticOrigin,
                    hypot(input.x - origin.x, input.y - origin.y) >= configuration.gestureThreshold,
                    let direction = GestureDirectionRecognizer.direction(dx: input.x - origin.x, dy: input.y - origin.y) { trigger = direction }
            else { trigger = .click }
            onInspectionMatch?(MouseBinding.buttonName(sessionButton ?? button) + " · " + GestureDirectionRecognizer.title(for: trigger) + " · " + action.title)
        }
        if !inspectionOnly {
            for replay in decision.replay { postReplay(replay) }
            if let token = sessionToken { for action in decision.actions { onAction?(action, token) } }
        }
        if isUp || !engine.isCapturing {
            if let token = sessionToken { onSessionEnded?(token); sessionToken = nil; sessionButton = nil }
        }
        if inspectionOnly { return Unmanaged.passUnretained(event) }
        if decision.consumed { if type == .scrollWheel { stopSmoothing() }; return nil }
        guard type == .scrollWheel, input.isMouse else { return Unmanaged.passUnretained(event) }
        let excluded = configuration.exception(for: foreground)?.disableScrolling == true
        let transform = ScrollMath.transform(deltaX: input.deltaX, deltaY: input.deltaY,
            isContinuous: input.isContinuous, isMouse: true, modifiers: input.modifiers,
            settings: configuration.scroll, excluded: excluded, synthetic: false)
        guard transform.handled else { stopSmoothing(); return Unmanaged.passUnretained(event) }
        if transform.smooth {
            discreteScaler.reset()
            scrollLocation = event.location; scrollFlags = event.flags; scrollDuration = transform.duration
            // Discrete CGEvent wheel values are lines; convert to a predictable pixel step.
            smoother.add(x: transform.x * 36, y: transform.y * 36)
            beginSmoothing(); return nil
        }
        stopSmoothing(resetDiscrete: false)
        let sx = configuration.scroll.reverseHorizontal ? -configuration.scroll.speed : configuration.scroll.speed
        let sy = configuration.scroll.reverseVertical ? -configuration.scroll.speed : configuration.scroll.speed
        return discreteScaler.apply(to: event, xFactor: sx, yFactor: sy) ? Unmanaged.passUnretained(event) : nil
    }

    private func publishFeedback(_ text: String) {
        let now = ProcessInfo.processInfo.systemUptime
        guard text != lastFeedback || now - lastFeedbackTime > 0.3 else { return }
        lastFeedback = text; lastFeedbackTime = now; onGestureFeedback?(text)
    }

    private func scrollDelta(_ event: CGEvent, vertical: Bool) -> Double {
        let fixed = event.getDoubleValueField(vertical ? .scrollWheelEventFixedPtDeltaAxis1 : .scrollWheelEventFixedPtDeltaAxis2)
        if fixed != 0 { return fixed }
        let lines = event.getDoubleValueField(vertical ? .scrollWheelEventDeltaAxis1 : .scrollWheelEventDeltaAxis2)
        if lines != 0 { return lines }
        return event.getDoubleValueField(vertical ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2) / 36
    }

    private func beginSmoothing() {
        guard timer == nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let newTimer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
        newTimer.tolerance = 0.001
        timer = newTimer; RunLoop.current.add(newTimer, forMode: .common)
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let delta = smoother.step(deltaTime: now - lastTick, duration: scrollDuration); lastTick = now
        remainderX += delta.x; remainderY += delta.y
        let x = Int32(remainderX.rounded()); let y = Int32(remainderY.rounded())
        remainderX -= Double(x); remainderY -= Double(y)
        if x != 0 || y != 0, let source = CGEventSource(stateID: .privateState),
           let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0) {
            event.location = scrollLocation; event.flags = scrollFlags
            event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.post(tap: .cgSessionEventTap)
        }
        if !smoother.isActive { timer?.invalidate(); timer = nil; smoother.reset() }
    }
    private func postReplay(_ input: MouseInput) {
        if input.kind == .scroll {
            if let event = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .privateState), units: .line,
                wheelCount: 2, wheel1: Int32(input.deltaY.rounded()), wheel2: Int32(input.deltaX.rounded()), wheel3: 0) {
                event.location = CGPoint(x: input.x, y: input.y)
                event.flags = CGEventFlags(rawValue: input.modifiers)
                event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
                event.post(tap: .cgSessionEventTap)
            }
            return
        }
        let type: CGEventType
        switch input.kind {
        case .buttonDown: type = input.button == 0 ? .leftMouseDown : input.button == 1 ? .rightMouseDown : .otherMouseDown
        case .buttonUp: type = input.button == 0 ? .leftMouseUp : input.button == 1 ? .rightMouseUp : .otherMouseUp
        case .move: type = input.button == 0 ? .leftMouseDragged : input.button == 1 ? .rightMouseDragged : .otherMouseDragged
        default: return
        }
        guard let button = CGMouseButton(rawValue: UInt32(input.button)),
              let event = CGEvent(mouseEventSource: CGEventSource(stateID: .privateState), mouseType: type,
                mouseCursorPosition: CGPoint(x: input.x, y: input.y), mouseButton: button) else { return }
        event.flags = CGEventFlags(rawValue: input.modifiers)
        if input.kind == .move {
            event.setDoubleValueField(.mouseEventDeltaX, value: input.deltaX)
            event.setDoubleValueField(.mouseEventDeltaY, value: input.deltaY)
        }
        event.setIntegerValueField(.mouseEventClickState, value: input.clickCount)
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.post(tap: .cgSessionEventTap)
    }
}
