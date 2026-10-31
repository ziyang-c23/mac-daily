import AppKit
import ApplicationServices
import MacDailyCore

/// Window tiling is independent of mouse acceleration/scroll processing. It uses
/// a passive event tap: the system continues to own the native window drag.
@MainActor
final class WindowRuntime {
    var onStatus: ((String) -> Void)?
    var onRunningChanged: ((Bool) -> Void)?
    var onTargetChanged: ((String) -> Void)?
    var onPracticeModeChanged: ((Bool) -> Void)?
    private(set) var isRunning = false
    private(set) var lastStatus = L10n.text("尚未执行窗口动作")

    private var settings = WindowSettings()
    private var monitor: WindowDragMonitor?
    private let overlay = WindowOverlay()
    private let gestureOverlay = WindowOverlay()
    private let activationOverlay = WindowActivationOverlay()
    private var tracking = false
    private var sleeping = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var appObservers: [NSObjectProtocol] = []
    private var permissionTimer: Timer?
    private var lastExternalApp: NSRunningApplication?
    private var lastExternalTarget: Target?
    private var practiceApp: NSRunningApplication?
    private var practiceSelected = false
    private var practiceIdentifier: String?
    private var practiceAvailable: Bool {
        practiceApp?.isTerminated == false && practiceApp?.bundleIdentifier == "org.macdaily.practice"
            && practiceIdentifier != nil
    }
    private var drag: DragSession?
    private var pendingCommit: PendingCommit?
    private var history: [HistoryEntry] = []
    private var operationGeneration: UInt64 = 0
    private var lastAcceptedSequence: UInt64 = 0
    private var listenerGeneration: UInt64 = 0

    private struct Target {
        let window: AXUIElement
        let app: NSRunningApplication
        var bundleID: String { app.bundleIdentifier ?? "" }
        var name: String { app.localizedName ?? L10n.text("所选应用") }
    }
    struct GestureTarget {
        fileprivate let window: AXUIElement
        fileprivate let pid: pid_t
    }

    func captureGestureTarget(window: AXUIElement, pid: pid_t) -> GestureTarget? {
        guard let app = NSRunningApplication(processIdentifier: pid),
              makeTarget(window: window, app: app) != nil else { return nil }
        return GestureTarget(window: window, pid: pid)
    }

    func performGesture(_ action: WindowAction, target: GestureTarget) {
        gestureOverlay.hide()
        guard let app = NSRunningApplication(processIdentifier: target.pid),
              let frozen = makeTarget(window: target.window, app: app),
              targetStillValid(frozen) else { setStatus(L10n.text("触控板手势的目标窗口已不可用")); return }
        cancelDrag()
        perform(action, on: frozen)
    }

    func previewGesture(_ action: WindowAction?, target: GestureTarget?) {
        guard settings.previewEnabled, let action, let target, let app = NSRunningApplication(processIdentifier: target.pid),
              let frozen = makeTarget(window: target.window, app: app),
              let current = frame(of: frozen.window), let screen = bestScreen(for: current) else { gestureOverlay.hide(); return }
        let desired: CGRect?
        if action == .restore { desired = historyEntry(for: frozen).map { clamped($0.original, within: screen.visible) } }
        else { desired = WindowGeometry.frame(for: action, in: screen.visible, current: current, gap: settings.gap) }
        if let desired { gestureOverlay.show(quartzFrame: desired, primaryScreenHeight: NSScreen.screens.first?.frame.maxY ?? 0, title: action.title) }
        else { gestureOverlay.hide() }
    }
    private struct HistoryEntry {
        let window: AXUIElement
        let pid: pid_t
        var original: CGRect
        var applied: CGRect
    }
    private struct PendingCommit {
        let target: Target
        let generation: UInt64
        let sequence: UInt64
    }
    private struct DragSession {
        let sequence: UInt64
        let target: Target
        let down: CGPoint
        let original: CGRect
        let baselineForHistory: CGRect
        var expectedSize: CGSize
        var moved = false
        var restored = false
        var tracker = SnapZoneTracker()
    }
    private struct Screen {
        let id: CGDirectDisplayID
        let full: CGRect
        let visible: CGRect
    }

    init() {}

    func startTracking() {
        guard !tracking else { return }
        tracking = true
        rememberExternal(NSWorkspace.shared.frontmostApplication)
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                        object: nil, queue: .main) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self else { return }
                if app?.processIdentifier == getpid(), let previous = self.lastExternalApp {
                    self.lastExternalTarget = self.focusedTarget(app: previous) ?? self.lastExternalTarget
                }
                self.rememberExternal(app)
                // Clicking a title bar normally activates that application. Do
                // not cancel its drag, but an unrelated activation invalidates it.
                let operationTarget = self.drag?.target ?? self.pendingCommit?.target
                if let operationTarget, app?.processIdentifier != operationTarget.app.processIdentifier {
                    self.cancelDrag()
                }
            }
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                        object: nil, queue: .main) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self else { return }
                self.history.removeAll { $0.pid == app?.processIdentifier }
                if self.practiceSelected && self.practiceApp?.processIdentifier == app?.processIdentifier {
                    self.cancelDrag()
                    self.onTargetChanged?(L10n.text("练习窗口已关闭（仍锁定）"))
                    self.setStatus(L10n.text("练习窗口已关闭；请重新打开，或点击结束练习"))
                }
                if self.drag?.target.app.processIdentifier == app?.processIdentifier
                    || self.pendingCommit?.target.app.processIdentifier == app?.processIdentifier { self.cancelDrag() }
                if self.lastExternalApp?.processIdentifier == app?.processIdentifier {
                    self.lastExternalApp = nil; self.lastExternalTarget = nil
                    if !self.practiceSelected { self.onTargetChanged?(L10n.text("先点选要调整的窗口")) }
                }
            }
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelDrag() }
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification,
                                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sleeping = true; self?.stopListening(); self?.setStatus(L10n.text("系统休眠，窗口吸附已暂停"))
            }
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping = false; self?.refreshPermission() }
        })
        appObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelDrag() }
        })
        refreshPermission()
    }

    func update(settings: WindowSettings) {
        guard self.settings != settings else { refreshPermission(); return }
        self.settings = settings
        cancelDrag()
        refreshPermission()
    }

    func refreshPermission() {
        guard tracking, !sleeping else { return }
        guard AXIsProcessTrusted() else {
            stopListening(); setStatus(L10n.text("需要辅助功能权限才能调整窗口"))
            return
        }
        guard settings.enabled else {
            stopListening(); setStatus(L10n.text("拖拽吸附已关闭，仍可使用布局动作"))
            return
        }
        guard !isRunning else { return }
        let next = WindowDragMonitor()
        listenerGeneration &+= 1
        let generation = listenerGeneration
        next.onSample = { [weak self] sample in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.listenerGeneration == generation else { return }
                    self.handle(sample)
                }
            }
        }
        guard next.start() else {
            setStatus(L10n.text("未能启动拖拽监听，请重新检查辅助功能权限"))
            return
        }
        monitor = next; setRunning(true)
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !AXIsProcessTrusted() else { return }
                self.stopListening(); self.setStatus(L10n.text("辅助功能权限已失效，窗口吸附已暂停"))
            }
        }
        timer.tolerance = 1
        permissionTimer = timer; RunLoop.main.add(timer, forMode: .common)
        setStatus(settings.activationMode == .custom ? L10n.text("拖动窗口到自定义激活区域，预览后松手分屏") : L10n.text("拖动窗口到屏幕边缘，预览后松手分屏"))
    }

    func stop() {
        stopListening()
        gestureOverlay.hide()
        for token in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        for token in appObservers { NotificationCenter.default.removeObserver(token) }
        workspaceObservers.removeAll(); appObservers.removeAll()
        tracking = false; sleeping = false; lastExternalApp = nil; lastExternalTarget = nil
        practiceSelected = false; practiceApp = nil; practiceIdentifier = nil
        onPracticeModeChanged?(false)
    }

    /// Pins routing before the helper launch begins, so a not-yet-ready fixture
    /// can never make a quick action fall through to a user window.
    func preparePractice() {
        cancelDrag()
        practiceSelected = true; practiceApp = nil; practiceIdentifier = nil
        onPracticeModeChanged?(true)
        onTargetChanged?(L10n.text("正在打开练习窗口（已锁定）"))
        setStatus(L10n.text("练习模式已锁定：只会调整练习窗口"))
    }

    /// A separate bundled helper exercises the same external AX path. Its PID
    /// and a per-launch accessibility identifier jointly identify one window.
    func usePracticeApplication(_ app: NSRunningApplication, identifier: String) {
        // Ignore a helper launch completing after the user explicitly ended practice.
        guard practiceSelected else { return }
        guard app.processIdentifier != getpid(), app.bundleIdentifier == "org.macdaily.practice",
              !app.isTerminated, !identifier.isEmpty, identifier.count <= 128 else {
            setStatus(L10n.text("练习程序身份无效；仍保持练习锁定"))
            return
        }
        cancelDrag()
        practiceApp = app; practiceIdentifier = identifier; practiceSelected = true
        onPracticeModeChanged?(true)
        onTargetChanged?(L10n.text("分屏练习窗口（已锁定）"))
        setStatus(L10n.text("练习模式已锁定：只会调整练习窗口"))
    }

    /// Only an explicit user action may unlock the external-window route.
    func endPractice() {
        cancelDrag()
        practiceSelected = false; practiceApp = nil; practiceIdentifier = nil
        onPracticeModeChanged?(false)
        onTargetChanged?(lastExternalApp?.localizedName ?? L10n.text("先点选要调整的窗口"))
        setStatus(L10n.text("已结束练习，可调整选中的应用窗口"))
    }

    /// Explicit layout actions work even while automatic drag snapping is off.
    func perform(_ action: WindowAction, expectedBundleIdentifier: String? = nil) {
        guard AXIsProcessTrusted() else { setStatus(L10n.text("请先授权辅助功能，再调整窗口")); return }
        cancelDrag()
        let invocation: WindowInvocation = expectedBundleIdentifier == nil ? .explicitLayout : .mouseBinding
        let inputTargetsPractice = NSWorkspace.shared.frontmostApplication?.processIdentifier == practiceApp?.processIdentifier
            && (expectedBundleIdentifier == nil || expectedBundleIdentifier == "org.macdaily.practice")
        let route = WindowTargetPolicy.route(practiceActive: practiceSelected, practiceAvailable: practiceAvailable,
                                             invocation: invocation, targetIsPractice: inputTargetsPractice)
        let chosen: Target?
        switch route {
        case .deny:
            setStatus(practiceAvailable ? L10n.text("练习模式只接受练习窗口中的鼠标动作") : L10n.text("练习窗口已关闭；请重新打开，或点击结束练习"))
            return
        case .practice:
            // A failed helper AX lookup is a failure, never a reason to fall back
            // to a real user window or to clear the pinned practice mode.
            chosen = practiceTarget()
        case .regular:
            let app: NSRunningApplication?
            if let expectedBundleIdentifier {
                let front = NSWorkspace.shared.frontmostApplication
                guard front?.bundleIdentifier == expectedBundleIdentifier else {
                    setStatus(L10n.text("目标应用已切换，已取消窗口动作")); return
                }
                app = front
            } else {
                let front = NSWorkspace.shared.frontmostApplication
                app = front?.processIdentifier != getpid() ? front : lastExternalApp
            }
            if expectedBundleIdentifier == nil && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
                chosen = lastExternalTarget ?? app.flatMap { focusedTarget(app: $0) }
            } else { chosen = app.flatMap { focusedTarget(app: $0) } }
        }
        guard let target = chosen, !target.app.isTerminated else {
            setStatus(practiceSelected ? L10n.text("无法读取练习窗口；仍保持练习锁定，不会调整其他窗口") : L10n.text("先点选一个可调整的应用窗口，再使用布局动作")); return
        }
        perform(action, on: target)
    }

    private func perform(_ action: WindowAction, on target: Target) {
        guard let current = frame(of: target.window), let screen = bestScreen(for: current) else {
            setStatus(L10n.text("无法读取窗口位置或显示器信息")); return
        }
        let previous = historyEntry(for: target)
        let baseline = WindowTransitionPolicy.restoreBaseline(current: current, previousOriginal: previous?.original,
                                                              previousApplied: previous?.applied)
        // A manual move/resize starts a new layout chain, even when automatic
        // drag snapping was disabled while that change happened.
        if let previous, !close(current, previous.applied, tolerance: 6) { removeHistory(for: target) }
        let desired: CGRect
        let outputScreen: Screen
        switch action {
        case .restore:
            guard let entry = historyEntry(for: target) else { setStatus(L10n.text("这个窗口没有可还原的布局")); return }
            let destinationScreen = bestScreen(for: entry.original) ?? screen
            desired = clamped(entry.original, within: destinationScreen.visible)
            outputScreen = destinationScreen
        case .nextDisplay, .previousDisplay:
            let displays = screens()
            guard displays.count > 1, let index = displays.firstIndex(where: { $0.id == screen.id }) else {
                setStatus(L10n.text("当前只有一个显示器")); return
            }
            let offset = action == .nextDisplay ? 1 : displays.count - 1
            let destination = displays[(index + offset) % displays.count]
            let normalizedX = (current.minX - screen.visible.minX) / max(1, screen.visible.width)
            let normalizedY = (current.minY - screen.visible.minY) / max(1, screen.visible.height)
            desired = clamped(CGRect(x: destination.visible.minX + normalizedX * destination.visible.width,
                                     y: destination.visible.minY + normalizedY * destination.visible.height,
                                     width: current.width, height: current.height), within: destination.visible)
            outputScreen = destination
        default:
            guard let layout = WindowGeometry.frame(for: action, in: screen.visible, current: current, gap: settings.gap) else { return }
            desired = layout; outputScreen = screen
        }
        let result = apply(desired, target: target, visibleFrame: outputScreen.visible, originalForHistory: baseline,
                           remember: action != .restore, title: action.title)
        if action == .restore && result != nil { removeHistory(for: target) }
    }

    private func rememberExternal(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != getpid(), app.bundleIdentifier != "org.macdaily.practice",
              app.activationPolicy == .regular, !app.isTerminated else { return }
        lastExternalApp = app; lastExternalTarget = focusedTarget(app: app)
        if !practiceSelected { onTargetChanged?(app.localizedName ?? L10n.text("上一个应用")) }
    }
    private func setStatus(_ text: String) { lastStatus = text; onStatus?(text) }
    private func setRunning(_ value: Bool) {
        guard isRunning != value else { return }; isRunning = value; onRunningChanged?(value)
    }
    private func stopListening() {
        listenerGeneration &+= 1
        cancelDrag()
        permissionTimer?.invalidate(); permissionTimer = nil
        monitor?.stop(); monitor = nil; setRunning(false)
    }
    private func cancelDrag() {
        if let target = drag?.target ?? pendingCommit?.target { discardHistoryIfManuallyChanged(target) }
        operationGeneration &+= 1; drag = nil; pendingCommit = nil; overlay.hide(); activationOverlay.hide()
    }
    private func discardHistoryIfManuallyChanged(_ target: Target) {
        guard let entry = historyEntry(for: target), let current = frame(of: target.window),
              !close(current, entry.applied, tolerance: 6) else { return }
        removeHistory(for: target)
    }

    private func handle(_ sample: WindowDragMonitor.Sample) {
        guard isRunning, !sleeping else { return }
        if sample.kind == .interrupted {
            cancelDrag()
            if !AXIsProcessTrusted() { stopListening(); setStatus(L10n.text("辅助功能权限已失效，窗口吸附已暂停")) }
            return
        }
        if sample.kind == .cancel { cancelDrag(); return }
        // Old queued events must never move a window after a stalled app recovers.
        guard ProcessInfo.processInfo.systemUptime - sample.receivedAt < 0.5 else { cancelDrag(); return }
        switch sample.kind {
        case .down:
            cancelDrag(); lastAcceptedSequence = sample.sequence
            guard let target = target(at: sample.point), !isExcluded(target),
                  let start = frame(of: target.window) else { return }
            rememberExternal(target.app)
            if target.app.processIdentifier != getpid() { lastExternalTarget = target }
            let previous = historyEntry(for: target)
            let baseline = WindowTransitionPolicy.restoreBaseline(current: start, previousOriginal: previous?.original,
                                                                  previousApplied: previous?.applied)
            if let previous, !close(start, previous.applied, tolerance: 6) { removeHistory(for: target) }
            drag = DragSession(sequence: sample.sequence, target: target, down: sample.point,
                               original: start, baselineForHistory: baseline, expectedSize: start.size)
        case .drag:
            guard var session = drag, session.sequence == sample.sequence,
                  targetStillValid(session.target, automatic: true), var current = frame(of: session.target.window),
                  let screen = screen(at: sample.point) else { cancelDrag(); return }
            // Cmd-drag can move a background window without activating it. Let
            // that remain native; do not promise a preview that cannot commit.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == session.target.app.processIdentifier else {
                overlay.hide(); activationOverlay.hide(); return
            }
            // Native resize operations are not native window moves.
            guard close(current.size, session.expectedSize, tolerance: 3) else {
                removeHistory(for: session.target); cancelDrag(); return
            }
            let pointerMoved = hypot(sample.point.x - session.down.x, sample.point.y - session.down.y) >= 6
            let frameMoved = hypot(current.minX - session.original.minX, current.minY - session.original.minY) >= 2
            guard session.moved || (pointerMoved && frameMoved) else { return }
            session.moved = true
            if settings.restoreOnDrag && !session.restored,
               let entry = historyEntry(for: session.target), close(session.original, entry.applied, tolerance: 6) {
                let grab = min(1, max(0, (session.down.x - session.original.minX) / max(1, session.original.width)))
                let topOffset = min(44, max(0, session.down.y - session.original.minY))
                let restored = clamped(CGRect(x: sample.point.x - entry.original.width * grab,
                                              y: sample.point.y - topOffset,
                                              width: entry.original.width, height: entry.original.height), within: screen.visible)
                // A failed AX write must not become a 45 Hz retry/rollback
                // loop. This drag returns entirely to the native application.
                session.restored = true
                guard let actual = apply(restored, target: session.target, visibleFrame: screen.visible,
                                         originalForHistory: entry.original, remember: false, title: L10n.text("恢复原尺寸"), publish: false) else {
                    cancelDrag()
                    setStatus(L10n.text("无法恢复原尺寸，本次拖动保持原生行为"))
                    return
                }
                session.expectedSize = actual.size
                current = actual
            }
            let match = dragDestination(at: sample.point, screen: screen, current: current, tracker: &session.tracker)
            if settings.activationMode == .custom, settings.highlightActivationAreas {
                activationOverlay.show(profile: settings.activationProfile, screen: screen.full,
                                       primaryScreenHeight: primaryHeight, activeID: match?.areaID)
            } else { activationOverlay.hide() }
            if settings.previewEnabled, let match {
                overlay.show(quartzFrame: match.frame, primaryScreenHeight: primaryHeight, title: match.title)
            } else { overlay.hide() }
            drag = session
        case .up:
            guard var session = drag, session.sequence == sample.sequence else { cancelDrag(); return }
            drag = nil; overlay.hide(); activationOverlay.hide()
            // Mouse-up can occur outside the last sampled zone. Recompute it so
            // a throttled final drag cannot accidentally commit a stale preview.
            guard session.moved, let screen = screen(at: sample.point),
                  let current = frame(of: session.target.window),
                  let match = dragDestination(at: sample.point, screen: screen, current: current, tracker: &session.tracker) else {
                if session.moved || session.restored { removeHistory(for: session.target) }
                return
            }
            let generation = operationGeneration
            pendingCommit = PendingCommit(target: session.target, generation: generation, sequence: session.sequence)
            // Let the target application complete its native mouse-up first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard self.isRunning, let pending = self.pendingCommit,
                          pending.generation == generation, pending.sequence == session.sequence,
                          self.lastAcceptedSequence == session.sequence,
                          WindowTransitionPolicy.mayCommit(capturedGeneration: generation, currentGeneration: self.operationGeneration,
                                                           targetPID: session.target.app.processIdentifier,
                                                           foregroundPID: NSWorkspace.shared.frontmostApplication?.processIdentifier),
                          self.targetStillValid(session.target, automatic: true) else {
                        if self.pendingCommit?.generation == generation { self.cancelDrag() }
                        return
                    }
                    self.pendingCommit = nil
                    _ = self.apply(match.frame, target: session.target, visibleFrame: screen.visible,
                                   originalForHistory: session.baselineForHistory, remember: true, title: match.title)
                }
            }
        default: break
        }
    }

    /// Activation uses full display coordinates; output layouts use only its usable frame.
    /// A custom profile deliberately has no standard-edge fallback when no area matches.
    private func dragDestination(at point: CGPoint, screen: Screen, current: CGRect,
                                 tracker: inout SnapZoneTracker) -> (frame: CGRect, title: String, areaID: UUID?)? {
        if settings.activationMode == .custom {
            guard let match = WindowActivationResolver.resolve(at: point, screen: screen.full,
                                                               visibleFrame: screen.visible, current: current,
                                                               gap: settings.gap, profile: settings.activationProfile) else { return nil }
            return (match.frame, match.title, match.areaID)
        }
        guard let action = tracker.action(at: point, screen: screen.full, threshold: settings.edgeThreshold),
              let frame = WindowGeometry.frame(for: action, in: screen.visible, current: current, gap: settings.gap) else { return nil }
        return (frame, action.title, nil)
    }

    // MARK: Accessibility
    private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name, &value) == .success ? value : nil
    }
    private func string(_ element: AXUIElement, _ name: CFString) -> String? { attribute(element, name) as? String }
    private func bool(_ element: AXUIElement, _ name: CFString) -> Bool { (attribute(element, name) as? NSNumber)?.boolValue == true }
    private func frame(of window: AXUIElement) -> CGRect? {
        guard let position = attribute(window, kAXPositionAttribute as CFString), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(window, kAXSizeAttribute as CFString), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              [point.x, point.y, dimensions.width, dimensions.height].allSatisfy(\.isFinite), dimensions.width > 1, dimensions.height > 1 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
    private func makeTarget(window: AXUIElement, app: NSRunningApplication) -> Target? {
        guard app.processIdentifier != getpid() else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.2)
        let exactPractice = isPracticeWindow(window, app: app)
        guard WindowTargetPolicy.route(practiceActive: practiceSelected, practiceAvailable: practiceAvailable,
                                        invocation: .drag, targetIsPractice: exactPractice) != .deny,
              app.processIdentifier != getpid(), app.activationPolicy == .regular,
              string(window, kAXRoleAttribute as CFString) == kAXWindowRole,
              string(window, kAXSubroleAttribute as CFString) == kAXStandardWindowSubrole,
              !bool(window, "AXFullScreen" as CFString), !bool(window, kAXMinimizedAttribute as CFString) else { return nil }
        var movable: DarwinBoolean = false, resizable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &movable) == .success, movable.boolValue,
              AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &resizable) == .success, resizable.boolValue else { return nil }
        return Target(window: window, app: app)
    }
    private func isPracticeWindow(_ window: AXUIElement, app: NSRunningApplication) -> Bool {
        guard practiceSelected, practiceAvailable, let practiceApp, let practiceIdentifier,
              app.processIdentifier == practiceApp.processIdentifier,
              app.bundleIdentifier == "org.macdaily.practice" else { return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success, pid == practiceApp.processIdentifier else { return false }
        return string(window, kAXIdentifierAttribute as CFString) == practiceIdentifier
            && string(window, kAXTitleAttribute as CFString) == L10n.text("MacDaily 分屏练习")
    }
    private func practiceTarget() -> Target? {
        guard AXIsProcessTrusted(), practiceSelected, practiceAvailable, let practiceApp else {
            if practiceSelected { onTargetChanged?(L10n.text("练习窗口未就绪（仍锁定）")) }
            return nil
        }
        let application = AXUIElementCreateApplication(practiceApp.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        guard let windows = attribute(application, kAXWindowsAttribute as CFString) as? [AXUIElement],
              let window = windows.first(where: { isPracticeWindow($0, app: practiceApp) }) else { return nil }
        return makeTarget(window: window, app: practiceApp)
    }
    private func focusedTarget(app: NSRunningApplication) -> Target? {
        guard app.processIdentifier != getpid() else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        guard let value = attribute(application, kAXFocusedWindowAttribute as CFString), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return makeTarget(window: value as! AXUIElement, app: app)
    }
    private func target(at point: CGPoint) -> Target? {
        // The controller never manipulates its own settings window. Avoid
        // synchronous self-AX queries on the AppKit main thread altogether.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() else { return nil }
        if practiceSelected {
            guard practiceAvailable,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == practiceApp?.processIdentifier else { return nil }
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        if let window = attribute(hit, kAXWindowAttribute as CFString), CFGetTypeID(window) == AXUIElementGetTypeID() {
            return makeTarget(window: window as! AXUIElement, app: app)
        }
        var current = hit
        for _ in 0..<8 {
            if string(current, kAXRoleAttribute as CFString) == kAXWindowRole { return makeTarget(window: current, app: app) }
            guard let parent = attribute(current, kAXParentAttribute as CFString), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = parent as! AXUIElement
        }
        return nil
    }
    private func isExcluded(_ target: Target) -> Bool { settings.excludedApps.contains { $0.bundleIdentifier == target.bundleID } }
    private func targetStillValid(_ target: Target, automatic: Bool = false) -> Bool {
        !target.app.isTerminated && (!automatic || !isExcluded(target)) && AXIsProcessTrusted()
            && WindowTargetPolicy.route(practiceActive: practiceSelected, practiceAvailable: practiceAvailable,
                                        invocation: .drag, targetIsPractice: isPracticeWindow(target.window, app: target.app)) != .deny
            && !bool(target.window, "AXFullScreen" as CFString) && !bool(target.window, kAXMinimizedAttribute as CFString)
    }

    @discardableResult
    private func apply(_ requested: CGRect, target: Target, visibleFrame: CGRect, originalForHistory: CGRect,
                       remember: Bool, title: String, publish: Bool = true) -> CGRect? {
        guard targetStillValid(target), let before = frame(of: target.window) else {
            if publish { setStatus(L10n.text("窗口已关闭或无法调整")) }; return nil
        }
        var point = requested.origin, size = requested.size
        guard let position = AXValueCreate(.cgPoint, &point), let dimensions = AXValueCreate(.cgSize, &size) else { return nil }
        let p1 = AXUIElementSetAttributeValue(target.window, kAXPositionAttribute as CFString, position)
        let resize = AXUIElementSetAttributeValue(target.window, kAXSizeAttribute as CFString, dimensions)
        let p2 = AXUIElementSetAttributeValue(target.window, kAXPositionAttribute as CFString, position)
        guard p1 == .success, resize == .success, p2 == .success, var actual = frame(of: target.window) else {
            var oldPoint = before.origin, oldSize = before.size
            if let old = AXValueCreate(.cgSize, &oldSize) { AXUIElementSetAttributeValue(target.window, kAXSizeAttribute as CFString, old) }
            if let old = AXValueCreate(.cgPoint, &oldPoint) { AXUIElementSetAttributeValue(target.window, kAXPositionAttribute as CFString, old) }
            if publish { setStatus(L10n.text("%@ 无法完成此布局；已尝试恢复原位置", String(describing: target.name))) }
            return nil
        }
        // Some applications clamp their minimum size. Keep the actual title bar
        // on the destination display and report the limitation instead of success.
        let contained = clamped(actual, within: visibleFrame, resize: false)
        if !close(actual.origin, contained.origin, tolerance: 1) {
            var origin = contained.origin
            if let value = AXValueCreate(.cgPoint, &origin) {
                AXUIElementSetAttributeValue(target.window, kAXPositionAttribute as CFString, value)
                actual = frame(of: target.window) ?? actual
            }
        }
        if remember { rememberFrame(target: target, original: originalForHistory, applied: actual) }
        if publish {
            if close(actual, requested, tolerance: 4) { setStatus("\(target.name) · \(title)") }
            else { setStatus(L10n.text("已调整 %@；此窗口有尺寸或位置限制", String(describing: target.name))) }
        }
        return actual
    }

    // MARK: Screens and restoration
    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    private func quartz(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height) }
    private func screens() -> [Screen] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return Screen(id: number.uint32Value, full: quartz(screen.frame), visible: quartz(screen.visibleFrame))
        }
    }
    private func screen(at point: CGPoint) -> Screen? { screens().first { $0.full.contains(point) } }
    private func bestScreen(for frame: CGRect) -> Screen? {
        screens().max { a, b in area(frame.intersection(a.full)) < area(frame.intersection(b.full)) }
    }
    private func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : max(0, rect.width) * max(0, rect.height) }
    private func clamped(_ frame: CGRect, within bounds: CGRect, resize: Bool = true) -> CGRect {
        let width = resize ? min(frame.width, bounds.width) : frame.width
        let height = resize ? min(frame.height, bounds.height) : frame.height
        return CGRect(x: min(max(frame.minX, bounds.minX), max(bounds.minX, bounds.maxX - width)),
                      y: min(max(frame.minY, bounds.minY), max(bounds.minY, bounds.maxY - height)), width: width, height: height)
    }
    private func close(_ a: CGPoint, _ b: CGPoint, tolerance: CGFloat) -> Bool { abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance }
    private func close(_ a: CGSize, _ b: CGSize, tolerance: CGFloat) -> Bool { abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance }
    private func close(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool { close(a.origin, b.origin, tolerance: tolerance) && close(a.size, b.size, tolerance: tolerance) }
    private func historyIndex(for target: Target) -> Int? { history.firstIndex { $0.pid == target.app.processIdentifier && CFEqual($0.window, target.window) } }
    private func historyEntry(for target: Target) -> HistoryEntry? { historyIndex(for: target).map { history[$0] } }
    private func removeHistory(for target: Target) { if let i = historyIndex(for: target) { history.remove(at: i) } }
    private func rememberFrame(target: Target, original: CGRect, applied: CGRect) {
        if let i = historyIndex(for: target) { history[i].original = original; history[i].applied = applied }
        else {
            if history.count >= 64 { history.removeFirst() }
            history.append(.init(window: target.window, pid: target.app.processIdentifier, original: original, applied: applied))
        }
    }
}

/// The passive callback never calls Accessibility or AppKit. Those operations
/// happen after dispatch onto the UI actor, outside the tap callback's deadline.
private final class WindowDragMonitor: @unchecked Sendable {
    enum Kind { case down, drag, up, cancel, interrupted }
    struct Sample {
        let kind: Kind
        let point: CGPoint
        let receivedAt: Double
        let sequence: UInt64
    }
    var onSample: ((Sample) -> Void)?
    private let lock = NSLock()
    private var loop: CFRunLoop?
    private var tap: CFMachPort?
    private var stopRequested = false
    private var ready = false
    private var thread: Thread?
    private var sequence: UInt64 = 0
    private var lastDragTime = 0.0

    func start() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            autoreleasepool {
                let mask = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
                let callback: CGEventTapCallBack = { _, type, event, context in
                    guard let context else { return Unmanaged.passUnretained(event) }
                    Unmanaged<WindowDragMonitor>.fromOpaque(context).takeUnretainedValue().receive(type, event)
                    return Unmanaged.passUnretained(event)
                }
                guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                                  eventsOfInterest: mask, callback: callback,
                                                  userInfo: Unmanaged.passUnretained(self).toOpaque()),
                      let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { semaphore.signal(); return }
                lock.lock(); tap = port; loop = CFRunLoopGetCurrent(); ready = !stopRequested; let run = ready; lock.unlock()
                if run { CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes); CGEvent.tapEnable(tap: port, enable: true) }
                semaphore.signal()
                if run { CFRunLoopRun() }
                CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port)
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
                lock.lock(); loop = nil; tap = nil; ready = false; lock.unlock()
            }
        }
        thread.name = "MacDaily.WindowDrag"; thread.qualityOfService = .userInteractive
        self.thread = thread; thread.start()
        _ = semaphore.wait(timeout: .now() + 1)
        lock.lock(); let success = ready; lock.unlock()
        if !success { stop() }
        return success
    }
    func stop() {
        lock.lock(); stopRequested = true; let loop = loop; lock.unlock()
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { [self] in
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            CFRunLoopStop(loop)
        }
        CFRunLoopWakeUp(loop)
    }
    private func receive(_ type: CGEventType, _ event: CGEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            onSample?(.init(kind: .interrupted, point: .zero, receivedAt: now, sequence: sequence))
            lock.lock(); let stopped = stopRequested; lock.unlock()
            if !stopped && AXIsProcessTrusted(), let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        if event.getIntegerValueField(.eventSourceUserData) == 0x4D41434441494C59 { return }
        let kind: Kind
        switch type {
        case .leftMouseDown: sequence &+= 1; kind = .down
        case .leftMouseDragged:
            guard now - lastDragTime >= 1.0 / 45.0 else { return }
            lastDragTime = now; kind = .drag
        case .leftMouseUp: kind = .up
        case .keyDown:
            guard event.getIntegerValueField(.keyboardEventKeycode) == 53 else { return }; kind = .cancel
        default: return
        }
        onSample?(.init(kind: kind, point: event.location, receivedAt: now, sequence: sequence))
    }
}
