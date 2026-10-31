import MacDailyCore
import AppKit
import ApplicationServices

@MainActor
final class QuickActionCleaningController: NSObject {
    var onFinish: (() -> Void)?
    private var windows: [CleaningWindow] = []
    private var countdownLabels: [NSTextField] = []
    private var timer: Timer?
    private var monitor: Any?
    private var keyboardTap: KeyboardCleaningTap?
    private var seconds = 30
    private var colorIndex = 0
    private let colors: [NSColor] = [.black, .white, .red, .green, .blue]

    func start(keyboard: Bool, onKeyboardReady: () -> Void, onWillPresent: () -> Void) throws {
        if keyboard {
            let tap = KeyboardCleaningTap()
            guard tap.start() else {
                throw NSError(domain: "MacDaily.Cleaning", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.text("清洁键盘需要 MacDaily 的辅助功能权限")])
            }
            keyboardTap = tap
            onKeyboardReady()
        }
        onWillPresent()
        for screen in NSScreen.screens {
            let window = CleaningWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.backgroundColor = .black
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 18
            stack.translatesAutoresizingMaskIntoConstraints = false
            let title = NSTextField(labelWithString: keyboard ? L10n.text("清洁键盘") : L10n.text("清洁屏幕"))
            title.font = .systemFont(ofSize: 26, weight: .semibold); title.textColor = .white
            let subtitle = NSTextField(labelWithString: keyboard ? L10n.text("按键已暂停 · 鼠标可点击结束") : L10n.text("左右方向键切换颜色 · Escape 结束"))
            subtitle.textColor = .white; subtitle.font = .systemFont(ofSize: 15)
            stack.addArrangedSubview(title); stack.addArrangedSubview(subtitle)
            if keyboard {
                let label = NSTextField(labelWithString: L10n.text("30 秒后自动结束"))
                label.textColor = .white; countdownLabels.append(label); stack.addArrangedSubview(label)
            } else {
                let next = NSButton(title: L10n.text("切换颜色"), target: self, action: #selector(nextColor))
                next.appearance = NSAppearance(named: .aqua)
                next.bezelStyle = .rounded; stack.addArrangedSubview(next)
            }
            let close = NSButton(title: L10n.text("结束清洁"), target: self, action: #selector(finish))
            close.appearance = NSAppearance(named: .aqua)
            close.bezelStyle = .rounded; stack.addArrangedSubview(close)
            window.contentView?.addSubview(stack)
            if let view = window.contentView {
                NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: view.centerXAnchor), stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
            }
            window.makeKeyAndOrderFront(nil); windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        if keyboard {
            seconds = 30
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.seconds -= 1
                    self.countdownLabels.forEach { $0.stringValue = L10n.text("%@ 秒后自动结束", String(describing: self.seconds)) }
                    if self.seconds <= 0 { self.finish() }
                }
            }
        } else {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                if event.keyCode == 53 { self.finish(); return nil }
                if event.keyCode == 123 || event.keyCode == 124 { self.nextColor(); return nil }
                return event
            }
        }
    }

    @objc private func nextColor() {
        colorIndex = (colorIndex + 1) % colors.count
        windows.forEach { window in
            window.backgroundColor = colors[colorIndex]
            let color: NSColor = colorIndex == 1 ? .black : .white
            if let stack = window.contentView?.subviews.first as? NSStackView {
                stack.arrangedSubviews.compactMap { $0 as? NSTextField }.forEach { $0.textColor = color }
            }
        }
    }

    @objc private func finish() { onFinish?() }

    func stop() {
        keyboardTap?.stop(); keyboardTap = nil
        timer?.invalidate(); timer = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        windows.forEach { $0.close() }; windows.removeAll(); countdownLabels.removeAll()
    }
}

private final class CleaningWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class KeyboardCleaningTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    func start() -> Bool {
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue) | (CGEventMask(1) << CGEventType.flagsChanged.rawValue) | (CGEventMask(1) << 14)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let context, let tap = Unmanaged<KeyboardCleaningTap>.fromOpaque(context).takeUnretainedValue().tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return nil
        }, userInfo: pointer) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }
    deinit { stop() }
}
