import AppKit
import MacDailyCore
import SwiftUI

private typealias GestureViewState<Value> = SwiftUI.State<Value>

/// Recognition-only fixture: it consumes engine decisions for display, never
/// posts a key, calls a window action, or writes the user's mouse configuration.
struct SafeGestureTestView: View {
    @ObservedObject var model: AppModel
    @GestureViewState private var feedback = L10n.text("按住左键、中键或右键，在区域内移动后松开")
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.text("识别练习：模拟输入，不执行动作"), systemImage: "hand.draw")
                .font(.callout.weight(.medium))
            Text(L10n.text("此画布使用模拟规则练习方向与距离，不检查设备归属或正式规则。左键可模拟中键，也可按住右键、中键移动或滚动。"))
                .font(.caption).foregroundStyle(.secondary)
            GestureRecognitionArea(threshold: model.configuration.gestureThreshold,
                                   onBegin: model.beginGestureTesting,
                                   onEnd: model.endGestureTesting,
                                   onFeedback: { feedback = $0; model.updateGestureTestFeedback($0) })
                .frame(height: 190)
            Text(feedback).font(.callout).foregroundStyle(.secondary)
                .accessibilityIdentifier("gesture-test-feedback")
                .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 5)
    }
}

private struct GestureRecognitionArea: NSViewRepresentable {
    let threshold: Double
    let onBegin: () -> Void
    let onEnd: () -> Void
    let onFeedback: (String) -> Void
    func makeNSView(context: Context) -> GestureRecognitionNSView {
        let view = GestureRecognitionNSView()
        view.onBegin = onBegin; view.onEnd = onEnd; view.onFeedback = onFeedback
        view.setThreshold(threshold)
        return view
    }
    func updateNSView(_ view: GestureRecognitionNSView, context: Context) {
        view.onBegin = onBegin; view.onEnd = onEnd; view.onFeedback = onFeedback
        view.setThreshold(threshold)
    }
    static func dismantleNSView(_ view: GestureRecognitionNSView, coordinator: ()) { view.invalidate() }
}

/// Reconcile outside SwiftUI's hierarchy update. A queued reconciliation owns
/// this object, so a detached/deallocated NSView cannot lose its final end call.
private final class GestureTestLifecycle {
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    private var desired = false
    private var notified = false
    func setActive(_ value: Bool) {
        desired = value
        DispatchQueue.main.async { [self] in
            if desired && !notified { notified = true; onBegin?() }
            else if !desired && notified { notified = false; onEnd?() }
        }
    }
}

private final class GestureRecognitionNSView: NSView {
    var onBegin: (() -> Void)? { didSet { lifecycle.onBegin = onBegin } }
    var onEnd: (() -> Void)? { didSet { lifecycle.onEnd = onEnd } }
    private let lifecycle = GestureTestLifecycle()
    var onFeedback: ((String) -> Void)?
    private var threshold = 36.0
    private var engine = MouseEngine()
    private var pressedButton: Int?
    private var points: [CGPoint] = []
    private var displayText = L10n.text("按住并移动 → 松开")
    private var active = false
    private var invalidated = false
    private var observers: [NSObjectProtocol] = []
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.text("手势试用区域"))
        setAccessibilityHelp(L10n.text("可用左键模拟中键方向手势，也支持实际中键和右键。此区域不执行真实动作。"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        guard let window else { leave(); return }
        invalidated = false
        enter()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in self?.cancel(L10n.text("试用已结束")); self?.leave() })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.cancel(L10n.text("窗口已切换，当前手势已取消")) })
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in self?.enter() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.cancel(L10n.text("系统休眠，当前手势已取消")) })
    }
    func setThreshold(_ value: Double) {
        guard value != threshold else { return }
        threshold = value
        configureEngine()
    }
    private func configureEngine() {
        var config = MouseConfiguration()
        config.gestureThreshold = threshold
        config.bindings = []
        for button in [1, 2] {
            for trigger in MouseTrigger.allCases.filter({ $0 != .click }) {
                config.bindings.append(.init(enabled: true, button: button, trigger: trigger,
                    shortcut: .init(keyCode: 0, modifiers: 0, label: trigger.title)))
            }
        }
        engine = MouseEngine(configuration: config)
        pressedButton = nil; points = []; needsDisplay = true
    }
    private func enter() {
        guard !active, !invalidated else { return }
        active = true; configureEngine(); lifecycle.setActive(true)
    }
    private func leave() {
        guard active else { return }
        active = false; _ = engine.cancel(); pressedButton = nil; lifecycle.setActive(false)
    }
    func invalidate() { invalidated = true; cancel(L10n.text("试用已结束")); leave(); removeObservers() }
    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }
    deinit { lifecycle.setActive(false); removeObservers() }
    private func cancel(_ message: String) {
        _ = engine.cancel(); pressedButton = nil; points = []
        displayText = message; onFeedback?(message); needsDisplay = true
    }
    private func normalized(_ event: NSEvent, kind: MouseInput.Kind, button: Int) -> MouseInput {
        let point = convert(event.locationInWindow, from: nil)
        let dx = kind == .scroll ? event.scrollingDeltaX : kind == .move ? event.deltaX : 0
        let dy = kind == .scroll ? event.scrollingDeltaY : kind == .move ? event.deltaY : 0
        return MouseInput(kind: kind, button: button, x: point.x, y: point.y, timestamp: event.timestamp,
                          modifiers: 0, bundleIdentifier: "org.macdaily.gesture-test",
                          deltaX: dx, deltaY: dy,
                          isContinuous: kind == .scroll && event.hasPreciseScrollingDeltas,
                          isSynthetic: false, isMouse: true)
    }
    private func consume(_ event: NSEvent, kind: MouseInput.Kind) {
        enter()
        window?.makeFirstResponder(self)
        let button = event.buttonNumber == 0 ? 2 : event.buttonNumber
        if kind == .buttonDown {
            configureEngine(); pressedButton = button
            points = [convert(event.locationInWindow, from: nil)]
        }
        let input = normalized(event, kind: kind, button: button)
        if kind == .move {
            points.append(CGPoint(x: input.x, y: input.y))
            if points.count > 128 { points.removeFirst(points.count - 128) }
        }
        let decision = engine.process(input)
        let actualName = event.buttonNumber == 0 ? L10n.text("左键模拟中键") : MouseBinding.buttonName(event.buttonNumber)
        if let feedback = decision.feedback { displayText = feedback; onFeedback?("\(actualName) · \(feedback)") }
        else if kind == .buttonDown { displayText = L10n.text("%@按下", String(describing: actualName)); onFeedback?(L10n.text("%@已识别", String(describing: actualName))) }
        if kind == .buttonUp { pressedButton = nil }
        // Intentionally discard replay, shortcuts and windowActions.
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) { consume(event, kind: .buttonDown) }
    override func mouseDragged(with event: NSEvent) { consume(event, kind: .move) }
    override func mouseUp(with event: NSEvent) { consume(event, kind: .buttonUp) }
    override func rightMouseDown(with event: NSEvent) { consume(event, kind: .buttonDown) }
    override func rightMouseDragged(with event: NSEvent) { consume(event, kind: .move) }
    override func rightMouseUp(with event: NSEvent) { consume(event, kind: .buttonUp) }
    override func otherMouseDown(with event: NSEvent) { consume(event, kind: .buttonDown) }
    override func otherMouseDragged(with event: NSEvent) { consume(event, kind: .move) }
    override func otherMouseUp(with event: NSEvent) { consume(event, kind: .buttonUp) }
    override func scrollWheel(with event: NSEvent) {
        guard let button = pressedButton else {
            onFeedback?(L10n.text("请先按住中键或右键，再滚动")); return
        }
        let decision = engine.process(normalized(event, kind: .scroll, button: button))
        let feedback = decision.feedback ?? (event.hasPreciseScrollingDeltas ? L10n.text("连续滚动保持原样，不参与按住滚轮组合") : L10n.text("已读取滚轮"))
        displayText = feedback; onFeedback?(feedback); needsDisplay = true
        // No action or replay is dispatched by this recognition-only fixture.
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancel(L10n.text("已按 Esc 取消手势")) }
        else { super.keyDown(with: event) }
    }
    override func resignFirstResponder() -> Bool { cancel(L10n.text("当前手势已取消")); return super.resignFirstResponder() }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        shape.fill(); NSColor.separatorColor.setStroke(); shape.lineWidth = 1; shape.stroke()
        if points.count > 1 {
            let path = NSBezierPath(); path.move(to: points[0])
            for point in points.dropFirst() { path.line(to: point) }
            NSColor.controlAccentColor.setStroke(); path.lineWidth = 3; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
            if let end = points.last { NSColor.controlAccentColor.setFill(); NSBezierPath(ovalIn: CGRect(x: end.x - 4, y: end.y - 4, width: 8, height: 8)).fill() }
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
        let text = displayText as NSString; let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: max(12, (bounds.width - size.width) / 2), y: bounds.height - 28), withAttributes: attrs)
    }
}
