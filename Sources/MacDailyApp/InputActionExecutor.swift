import AppKit
import ApplicationServices
import Darwin
import MacDailyCore

@MainActor
struct TrackpadActionContext {
    let frontPID: pid_t
    let bundleIdentifier: String
    let pointer: CGPoint
    let focusedWindow: AXUIElement?
    let window: WindowRuntime.GestureTarget?
    let titlebarWindow: WindowRuntime.GestureTarget?
    var isTitlebar: Bool { titlebarWindow != nil }
}

@MainActor
final class InputActionExecutor {
    static let marker: Int64 = 0x4D41434441494C59
    private let windows: WindowRuntime
    private let quick: QuickActionService
    var onDashboard: (() -> Void)?
    private var minimizedWindows: [pid_t: AXUIElement] = [:]
    init(windows: WindowRuntime, quick: QuickActionService) { self.windows = windows; self.quick = quick }

    func capture() -> Task<TrackpadActionContext, Never> {
        let front = NSWorkspace.shared.frontmostApplication
        return captureMouse(pid: front?.processIdentifier ?? 0, bundleIdentifier: front?.bundleIdentifier ?? "",
                            point: CGEvent(source: nil)?.location ?? .zero)
    }

    func captureMouse(pid: pid_t, bundleIdentifier: String, point: CGPoint) -> Task<TrackpadActionContext, Never> {
        Task { [windows] in
            let result = await Task.detached(priority: .userInitiated) { InputAXCapture.read(pid: pid, point: point) }.value
            let focusedTarget = result.focused.flatMap { windows.captureGestureTarget(window: $0, pid: pid) }
            return TrackpadActionContext(frontPID: pid, bundleIdentifier: bundleIdentifier, pointer: point,
                focusedWindow: focusedTarget == nil ? nil : result.focused,
                window: focusedTarget,
                titlebarWindow: result.titlebar.flatMap { windows.captureGestureTarget(window: $0, pid: result.titlebarPID) })
        }
    }

    func preview(_ action: InputAction?, context: TrackpadActionContext?, titlebar: Bool) {
        guard case .window(let action) = action, let context,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == context.frontPID else {
            windows.previewGesture(nil, target: nil); return
        }
        windows.previewGesture(action, target: titlebar ? context.titlebarWindow : context.window)
    }

    @discardableResult
    func execute(_ action: InputAction, context: TrackpadActionContext, titlebar: Bool) -> String {
        windows.previewGesture(nil, target: nil)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == context.frontPID else { return L10n.text("前台应用已切换，已取消动作") }
        switch action {
        case .window(let action):
            guard let target = titlebar ? context.titlebarWindow : context.window else { return L10n.text("没有可调整的目标窗口") }
            windows.performGesture(action, target: target)
            return windows.lastStatus
        case .shortcut(let shortcut):
            guard AXIsProcessTrusted(), let source = CGEventSource(stateID: .privateState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: false) else { return L10n.text("未能发送快捷键") }
            for event in [down, up] { event.flags = CGEventFlags(rawValue: shortcut.modifiers); post(event) }
            let sent = L10n.text("已发送 %@", shortcut.displayLabel)
            return NativeMouseShortcutReader.problem(for: shortcut).map { sent + "；" + $0 } ?? sent
        case .middleClick:
            guard AXIsProcessTrusted(), let source = CGEventSource(stateID: .privateState),
                  let down = CGEvent(mouseEventSource: source, mouseType: .otherMouseDown, mouseCursorPosition: context.pointer, mouseButton: .center),
                  let up = CGEvent(mouseEventSource: source, mouseType: .otherMouseUp, mouseCursorPosition: context.pointer, mouseButton: .center) else { return L10n.text("未能发送中键点按") }
            for event in [down, up] { event.flags = []; post(event) }
            return L10n.text("已发送中键点按")
        case .system(let action): return performSystem(action, context: context)
        case .quick(let action): quick.perform(action); return quick.message ?? action.title
        case .showDashboard: onDashboard?()
        }
        return action.title
    }
    private func performSystem(_ action: MouseSystemAction, context: TrackpadActionContext) -> String {
        guard AXIsProcessTrusted() else { return L10n.text("需要辅助功能权限") }
        switch action {
        case .brightnessUp, .brightnessDown:
            return MouseDisplayBrightness.adjust(by: action == .brightnessUp ? 1.0 / 16.0 : -1.0 / 16.0)
        case .restoreMinimized:
            guard let window = minimizedWindows[context.frontPID] else { return L10n.text("此应用没有由 MacDaily 最小化的窗口") }
            let result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            guard result == .success else { minimizedWindows.removeValue(forKey: context.frontPID); return L10n.text("未能恢复最小化窗口") }
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            minimizedWindows.removeValue(forKey: context.frontPID)
            return L10n.text("已恢复最小化窗口")
        case .minimize, .toggleFullScreen:
            guard let window = context.focusedWindow else { return L10n.text("没有可调整的目标窗口") }
            if action == .minimize {
                let result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                guard result == .success else { return L10n.text("未能最小化窗口") }
                minimizedWindows[context.frontPID] = window
                return L10n.text("已最小化窗口")
            }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success,
                  let full = value as? Bool else { return L10n.text("此窗口不支持全屏切换") }
            let result = AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, full ? kCFBooleanFalse : kCFBooleanTrue)
            return result == .success ? L10n.text("已请求切换全屏") : L10n.text("未能切换全屏")
        }
    }

    private func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.post(tap: .cghidEventTap)
    }
}

private struct InputAXCapture: @unchecked Sendable {
    var focused: AXUIElement?
    var titlebar: AXUIElement?
    var titlebarPID: pid_t = 0
    static func read(pid: pid_t, point: CGPoint) -> Self {
        guard AXIsProcessTrusted(), pid > 0 else { return Self() }
        var result = Self()
        if pid != getpid() {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.15)
            result.focused = element(app, kAXFocusedWindowAttribute as CFString)
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { return result }
        var owner: pid_t = 0
        guard AXUIElementGetPid(hit, &owner) == .success, owner != getpid() else { return result }
        let role = value(hit, kAXRoleAttribute as CFString) as? String ?? ""
        let blocked = ["AXButton", "AXMenuButton", "AXPopUpButton", "AXTabGroup", "AXRadioButton", "AXTextField", "AXTextArea", "AXToolbar"]
        guard !blocked.contains(role) else { return result }
        var node = hit
        var window: AXUIElement?
        var explicitTitlebar = false
        for _ in 0..<10 {
            let nodeRole = value(node, kAXRoleAttribute as CFString) as? String ?? ""
            if blocked.contains(nodeRole) { return result }
            if nodeRole == "AXTitleBar" { explicitTitlebar = true }
            if nodeRole == kAXWindowRole { window = node; break }
            guard let parent = element(node, kAXParentAttribute as CFString) else { break }
            node = parent
        }
        if window == nil { window = element(hit, kAXWindowAttribute as CFString) }
        guard let window, let frame = frame(window) else { return result }
        if let title = element(window, kAXTitleUIElementAttribute as CFString), CFEqual(title, hit) { explicitTitlebar = true }
        let blankStandardTitle = role == kAXWindowRole && (value(window, kAXSubroleAttribute as CFString) as? String) == kAXStandardWindowSubrole
        if explicitTitlebar || (blankStandardTitle && point.y >= frame.minY && point.y < frame.minY + 28) {
            result.titlebar = window; result.titlebarPID = owner
        }
        return result
    }
    private static func value(_ node: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, attribute, &result) == .success ? result : nil
    }
    private static func element(_ node: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        guard let result = value(node, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(result, to: AXUIElement.self)
    }
    private static func frame(_ node: AXUIElement) -> CGRect? {
        guard let position = value(node, kAXPositionAttribute as CFString), let size = value(node, kAXSizeAttribute as CFString),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero; var s = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &p),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
}
