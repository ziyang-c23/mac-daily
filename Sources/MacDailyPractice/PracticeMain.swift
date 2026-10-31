import MacDailyCore
import AppKit
import Foundation

@MainActor
final class PracticeDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let metrics = NSTextField(labelWithString: "")
    private var parentPID: pid_t = 0
    private var identifier = ""
    private var parentWatch: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        guard let p = args.firstIndex(of: "--parent-pid"), p + 1 < args.count, let pid = Int32(args[p + 1]),
              let i = args.firstIndex(of: "--practice-id"), i + 1 < args.count, UUID(uuidString: args[i + 1]) != nil,
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "org.macdaily.app" else {
            NSApplication.shared.terminate(nil); return
        }
        parentPID = pid; identifier = args[i + 1]
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: L10n.text("MacDaily 分屏练习"))
        appMenu.addItem(withTitle: L10n.text("退出练习"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        NSApplication.shared.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 380),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("MacDaily 分屏练习")
        window.setAccessibilityIdentifier(identifier)
        window.minSize = NSSize(width: 300, height: 240)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSView()
        let title = NSTextField(labelWithString: L10n.text("拖动这个窗口，试试分屏"))
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString: L10n.text("拖到两侧：半屏 · 拖到角落：四分屏\n拖到顶部：填满 · 拖到底部：三分屏"))
        hint.alignment = .center; hint.textColor = .secondaryLabelColor
        let pin = NSTextField(labelWithString: L10n.text("练习目标已固定，切换应用不会改变目标"))
        pin.font = .systemFont(ofSize: 12); pin.textColor = .secondaryLabelColor
        metrics.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        metrics.alignment = .center; metrics.textColor = .secondaryLabelColor
        metrics.maximumNumberOfLines = 3
        let back = NSButton(title: L10n.text("回到窗口设置"), target: self, action: #selector(backToSettings))
        back.bezelStyle = .rounded
        let stack = NSStackView(views: [title, hint, pin, metrics, back])
        stack.orientation = .vertical; stack.spacing = 20; stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16)])
        window.contentView = content
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        updateMetrics()
        parentWatch = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if NSRunningApplication(processIdentifier: self.parentPID)?.isTerminated != false { NSApplication.shared.terminate(nil) }
            }
        }
        parentWatch?.tolerance = 1
    }
    @objc private func backToSettings() {
        NSRunningApplication(processIdentifier: parentPID)?.activate(options: [.activateAllWindows])
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("org.macdaily.practice.return"), object: identifier, userInfo: nil, deliverImmediately: true)
    }
    private func updateMetrics() {
        guard let window, let screen = window.screen ?? NSScreen.screens.first else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let f = window.frame; let v = screen.visibleFrame
        metrics.stringValue = L10n.text("窗口：%@ × %@   位置：%@, %@\n可用区域：%@, %@ · %@ × %@", String(describing: Int(f.width)), String(describing: Int(f.height)), String(describing: Int(f.minX)), String(describing: Int(primaryHeight - f.maxY)), String(describing: Int(v.minX)), String(describing: Int(primaryHeight - v.maxY)), String(describing: Int(v.width)), String(describing: Int(v.height)))
    }
    func windowDidMove(_ notification: Notification) { updateMetrics() }
    func windowDidResize(_ notification: Notification) { updateMetrics() }
    func windowDidChangeScreen(_ notification: Notification) { updateMetrics() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { parentWatch?.invalidate() }
}

@main
@MainActor
struct PracticeMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = PracticeDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
