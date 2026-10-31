import Foundation

/// Normalized events use Core Graphics button numbering and screen coordinates
/// (positive Y points down). This type never contains text typed by the user.
public struct MouseInput: Equatable, Sendable {
    public enum Kind: String, Sendable { case buttonDown, buttonUp, move, scroll, cancel }
    public var kind: Kind
    public var button: Int
    public var x: Double
    public var y: Double
    public var timestamp: Double
    public var modifiers: UInt64
    public var bundleIdentifier: String
    public var deltaX: Double
    public var deltaY: Double
    public var isContinuous: Bool
    public var isSynthetic: Bool
    public var isMouse: Bool
    public var clickCount: Int64
    public init(kind: Kind, button: Int = 0, x: Double = 0, y: Double = 0,
                timestamp: Double = 0, modifiers: UInt64 = 0, bundleIdentifier: String = "",
                deltaX: Double = 0, deltaY: Double = 0, isContinuous: Bool = false,
                isSynthetic: Bool = false, isMouse: Bool = true, clickCount: Int64 = 1) {
        self.kind = kind; self.button = button; self.x = x; self.y = y
        self.timestamp = timestamp; self.modifiers = modifiers; self.bundleIdentifier = bundleIdentifier
        self.deltaX = deltaX; self.deltaY = deltaY; self.isContinuous = isContinuous
        self.isSynthetic = isSynthetic; self.isMouse = isMouse; self.clickCount = clickCount
    }
}

public struct MouseDecision: Sendable {
    public var consumed: Bool
    public var replay: [MouseInput]
    public var shortcuts: [Shortcut]
    public var windowActions: [WindowAction]
    public var actions: [InputAction]
    /// Ephemeral recognition status, never proof that a downstream action ran.
    public var feedback: String?
    public init(consumed: Bool = false, replay: [MouseInput] = [], shortcuts: [Shortcut] = [], windowActions: [WindowAction] = [], actions: [InputAction] = [], feedback: String? = nil) {
        self.consumed = consumed; self.replay = replay; self.shortcuts = shortcuts; self.windowActions = windowActions; self.actions = actions
        self.feedback = feedback
    }
}

/// The runtime and the harmless tester use exactly the same direction rules.
public enum GestureDirectionRecognizer {
    public static func direction(dx: Double, dy: Double) -> MouseTrigger? {
        guard dx.isFinite, dy.isFinite else { return nil }
        guard dx != 0 || dy != 0 else { return nil }
        let sector = Int(floor((atan2(dy, dx) + .pi / 8) / (.pi / 4)))
        let directions: [MouseTrigger] = [.swipeRight, .swipeDownRight, .swipeDown, .swipeDownLeft, .swipeLeft, .swipeUpLeft, .swipeUp, .swipeUpRight]
        return directions[(sector % 8 + 8) % 8]
    }
    public static func isDirectional(_ trigger: MouseTrigger) -> Bool {
        switch trigger { case .swipeUp, .swipeDown, .swipeLeft, .swipeRight, .swipeUpLeft, .swipeUpRight, .swipeDownLeft, .swipeDownRight: true; default: false }
    }
    public static func title(for trigger: MouseTrigger) -> String {
        switch trigger {
        case .swipeUp: L10n.text("向上")
        case .swipeDown: L10n.text("向下")
        case .swipeLeft: L10n.text("向左")
        case .swipeRight: L10n.text("向右")
        case .swipeUpLeft: L10n.text("左上")
        case .swipeUpRight: L10n.text("右上")
        case .swipeDownLeft: L10n.text("左下")
        case .swipeDownRight: L10n.text("右下")
        case .click: L10n.text("点击")
        case .scrollUp: L10n.text("滚轮向上")
        case .scrollDown: L10n.text("滚轮向下")
        }
    }
}

/// Pure input arbitration. Call on one serial queue. Replay must be stamped by
/// the platform adapter and emitted in order before the next action is sent.
public struct MouseEngine: Sendable {
    private struct Session: Sendable {
        var down: MouseInput
        var bindings: [MouseBinding]
        var moves: [MouseInput] = []
        var maximumDistance = 0.0
        var comboConsumed = false
        var lastComboTime: Double?
        var progressKey = "short"
    }
    private var configuration: MouseConfiguration
    private var session: Session?
    public private(set) var pendingReleaseButtons: Set<Int> = []
    public var isCapturing: Bool { session != nil }
    public init(configuration: MouseConfiguration = MouseConfiguration()) { self.configuration = configuration }

    @discardableResult
    public mutating func update(configuration: MouseConfiguration) -> MouseDecision {
        let result = cancel(reason: L10n.text("配置已更改，已取消当前操作"))
        self.configuration = configuration
        return result
    }

    /// Cancellation deliberately performs no native click and no shortcut.
    /// Keep the tap alive until the corresponding physical up, where possible.
    @discardableResult
    public mutating func cancel(reason: String = L10n.text("已取消手势")) -> MouseDecision {
        let hadSession = session != nil
        if let session { pendingReleaseButtons.insert(session.down.button) }
        session = nil
        return MouseDecision(feedback: hadSession ? reason : nil)
    }

    public mutating func process(_ input: MouseInput) -> MouseDecision {
        // Posted replay and action events must never mutate the physical session.
        guard !input.isSynthetic else { return MouseDecision() }
        if input.kind == .cancel { return cancel() }
        guard input.isMouse else { return MouseDecision() }
        if input.kind == .buttonUp, pendingReleaseButtons.remove(input.button) != nil {
            return MouseDecision(consumed: true)
        }
        if pendingReleaseButtons.contains(input.button), input.kind == .move {
            return MouseDecision(consumed: true)
        }
        if input.kind == .buttonDown {
            // A new physical down proves a missed up occurred while the hook was absent.
            pendingReleaseButtons.remove(input.button)
        }
        var cancellationFeedback: String?
        if let active = session {
            let changedApp = active.down.bundleIdentifier != input.bundleIdentifier
            let changedModifiers = normalized(active.down.modifiers) != normalized(input.modifiers)
            let invalidTime = !input.timestamp.isFinite || input.timestamp < active.down.timestamp
            if changedApp || changedModifiers || invalidTime {
                let reason = changedApp ? L10n.text("前台应用已切换，已取消当前操作")
                    : changedModifiers ? L10n.text("修饰键已变化，已取消当前操作") : L10n.text("输入时序变化，已取消当前操作")
                cancellationFeedback = cancel(reason: reason).feedback
                if input.kind == .buttonUp, pendingReleaseButtons.remove(input.button) != nil {
                    return MouseDecision(consumed: true, feedback: cancellationFeedback)
                }
                if input.kind == .move, input.button == active.down.button { return MouseDecision(consumed: true, feedback: cancellationFeedback) }
            }
        }
        var decision: MouseDecision
        switch input.kind {
        case .buttonDown: decision = begin(input)
        case .move: decision = move(input)
        case .buttonUp: decision = end(input)
        case .scroll: decision = scroll(input)
        case .cancel: decision = cancel()
        }
        if decision.feedback == nil { decision.feedback = cancellationFeedback }
        return decision
    }

    private func normalized(_ flags: UInt64) -> UInt64 { flags & Shortcut.modifierMask }
    private func isGesture(_ trigger: MouseTrigger) -> Bool { GestureDirectionRecognizer.isDirectional(trigger) }
    private mutating func begin(_ input: MouseInput) -> MouseDecision {
        // Two held buttons must not create a partially hidden chord in the app.
        if session != nil { return cancel(reason: L10n.text("另一个按钮已按下，已取消当前操作")) }
        guard input.button >= 1, input.timestamp.isFinite, input.x.isFinite, input.y.isFinite else { return MouseDecision() }
        let exception = configuration.exception(for: input.bundleIdentifier)
        let bindings = configuration.bindings.filter {
            $0.enabled && $0.button == input.button && $0.modifiers == normalized(input.modifiers)
            && (isGesture($0.trigger) ? exception?.disableGestures != true : exception?.disableBindings != true)
        }
        guard !bindings.isEmpty else { return MouseDecision() }
        session = Session(down: input, bindings: bindings)
        let instruction = bindings.contains(where: { isGesture($0.trigger) })
            ? L10n.text("移动后松开识别手势") : L10n.text("等待点击或滚轮组合")
        return MouseDecision(consumed: true, feedback: L10n.text("已按住%@，%@", String(describing: MouseBinding.buttonName(input.button)), String(describing: instruction)))
    }

    private mutating func move(_ input: MouseInput) -> MouseDecision {
        guard var active = session, input.button == active.down.button else { return MouseDecision() }
        guard input.x.isFinite, input.y.isFinite else {
            return MouseDecision(consumed: true, feedback: cancel(reason: L10n.text("输入位置无效，已取消当前操作")).feedback)
        }
        let dx = input.x - active.down.x, dy = input.y - active.down.y
        active.maximumDistance = max(active.maximumDistance, hypot(dx, dy))
        if active.comboConsumed { session = active; return MouseDecision(consumed: true) }
        // Coalesce old packets rather than rejecting a slow gesture simply
        // because a high-poll-rate mouse produced many tiny movements.
        if active.moves.count >= 128 {
            var reduced: [MouseInput] = []
            for index in stride(from: 0, to: active.moves.count, by: 2) {
                if index + 1 < active.moves.count {
                    var combined = active.moves[index + 1]
                    combined.deltaX += active.moves[index].deltaX
                    combined.deltaY += active.moves[index].deltaY
                    reduced.append(combined)
                } else { reduced.append(active.moves[index]) }
            }
            active.moves = reduced
        }
        active.moves.append(input)
        let gestureBindings = active.bindings.filter { isGesture($0.trigger) }
        // Click/hold-wheel bindings should not steal the button's ordinary drag.
        let dragThreshold = gestureBindings.isEmpty ? 6.0 : configuration.gestureThreshold
        let direction = GestureDirectionRecognizer.direction(dx: dx, dy: dy)
        // A small initial sideways wobble must not abandon a partial-direction
        // profile before the user has had a chance to complete its intended stroke.
        let nativeThreshold = gestureBindings.isEmpty ? dragThreshold : dragThreshold * 1.75
        let unsupportedDirection = active.maximumDistance >= nativeThreshold
            && (gestureBindings.isEmpty || (direction != nil && !gestureBindings.contains { $0.trigger == direction }))
        // A long held drag becomes native; packet count does not alter recognition.
        let exhausted = input.timestamp - active.down.timestamp > 5
        if unsupportedDirection || exhausted {
            session = nil
            let feedback = exhausted ? L10n.text("手势超时，保留原生拖动")
                : gestureBindings.isEmpty ? L10n.text("已转为原生拖动")
                : L10n.text("未设置%@，保留原生拖动", String(describing: direction.map { GestureDirectionRecognizer.title(for: $0) } ?? L10n.text("这个方向")))
            return MouseDecision(consumed: true, replay: [active.down] + active.moves, feedback: feedback)
        }
        var feedback: String?
        if !gestureBindings.isEmpty {
            let reached = hypot(dx, dy) >= configuration.gestureThreshold
            let progress = !reached ? "short" : direction.map(\.rawValue) ?? "ambiguous"
            if progress != active.progressKey {
                active.progressKey = progress
                if !reached { feedback = L10n.text("继续沿一个方向移动后松开") }
                else if let direction {
                    let title = GestureDirectionRecognizer.title(for: direction)
                    feedback = gestureBindings.contains(where: { $0.trigger == direction })
                        ? L10n.text("%@已就绪，松开触发", String(describing: title)) : L10n.text("%@尚未配置", String(describing: title))
                } else { feedback = L10n.text("方向不明确，请沿一个方向移动") }
            }
        }
        session = active
        return MouseDecision(consumed: true, feedback: feedback)
    }

    private mutating func end(_ input: MouseInput) -> MouseDecision {
        guard var active = session, input.button == active.down.button else { return MouseDecision() }
        session = nil
        guard input.x.isFinite, input.y.isFinite else { return MouseDecision(consumed: true) }
        if active.comboConsumed { return MouseDecision(consumed: true, feedback: L10n.text("滚轮组合结束")) }
        let dx = input.x - active.down.x, dy = input.y - active.down.y
        active.maximumDistance = max(active.maximumDistance, hypot(dx, dy))
        if input.timestamp - active.down.timestamp > 5 && active.bindings.contains(where: { isGesture($0.trigger) }) {
            return MouseDecision(consumed: true, replay: [active.down] + active.moves + [input], feedback: L10n.text("按住时间过长，未触发手势"))
        }
        if active.maximumDistance >= configuration.gestureThreshold,
           hypot(dx, dy) >= configuration.gestureThreshold,
           let trigger = GestureDirectionRecognizer.direction(dx: dx, dy: dy),
           let binding = active.bindings.first(where: { $0.trigger == trigger }) {
            return actionDecision(binding, feedback: L10n.text("已识别：%@", String(describing: GestureDirectionRecognizer.title(for: trigger))))
        }
        // Click mappings require a stationary press even when gesture threshold is larger.
        if active.maximumDistance < 6, let binding = active.bindings.first(where: { $0.trigger == .click }) {
            return actionDecision(binding, feedback: L10n.text("已识别：%@点击", String(describing: MouseBinding.buttonName(input.button))))
        }
        let feedback: String
        let distance = hypot(dx, dy)
        if !active.bindings.contains(where: { isGesture($0.trigger) }) {
            feedback = L10n.text("未触发滚轮组合，保留原生操作")
        } else if distance < configuration.gestureThreshold {
            feedback = active.maximumDistance >= configuration.gestureThreshold
                ? L10n.text("已回到起点，未触发手势")
                : L10n.text("距离不足（%@ / %@ pt）", String(describing: Int(distance.rounded())), String(describing: Int(configuration.gestureThreshold.rounded())))
        } else if let direction = GestureDirectionRecognizer.direction(dx: dx, dy: dy) {
            feedback = L10n.text("未启用%@的规则", String(describing: GestureDirectionRecognizer.title(for: direction)))
        } else { feedback = L10n.text("方向不明确，未触发手势") }
        return MouseDecision(consumed: true, replay: [active.down] + active.moves + [input], feedback: feedback)
    }

    private mutating func scroll(_ input: MouseInput) -> MouseDecision {
        guard var active = session, !input.isContinuous,
              input.deltaY.isFinite, input.deltaY != 0 else { return MouseDecision() }
        let trigger: MouseTrigger = input.deltaY > 0 ? .scrollUp : .scrollDown
        guard let binding = active.bindings.first(where: { $0.trigger == trigger }) else {
            if active.comboConsumed { return MouseDecision(consumed: true) }
            session = nil
            return MouseDecision(consumed: true, replay: [active.down] + active.moves + [input], feedback: L10n.text("未启用这个滚轮方向，保留原生操作"))
        }
        active.comboConsumed = true
        active.moves.removeAll(keepingCapacity: false)
        let ready = active.lastComboTime.map { input.timestamp - $0 >= 0.12 } ?? true
        var feedback: String?
        if ready {
            active.lastComboTime = input.timestamp
            active.progressKey = "comboAction"
            feedback = L10n.text("已识别：%@组合", String(describing: GestureDirectionRecognizer.title(for: trigger)))
        } else if active.progressKey != "comboCooldown" {
            active.progressKey = "comboCooldown"
            feedback = L10n.text("滚轮组合间隔过短，已合并")
        }
        session = active
        return ready ? actionDecision(binding, feedback: feedback)
            : MouseDecision(consumed: true, feedback: feedback)
    }

    private func actionDecision(_ binding: MouseBinding, feedback: String? = nil) -> MouseDecision {
        let action = binding.effectiveAction
        switch action {
        case .window(let window): return MouseDecision(consumed: true, windowActions: [window], actions: [action], feedback: feedback)
        case .shortcut(let shortcut): return MouseDecision(consumed: true, shortcuts: [shortcut], actions: [action], feedback: feedback)
        default: return MouseDecision(consumed: true, actions: [action], feedback: feedback)
        }
    }
}
