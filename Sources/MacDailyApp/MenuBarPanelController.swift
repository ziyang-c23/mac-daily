import MacDailyCore
import AppKit

/// Displays catalog entries without capturing menu-bar pixels.
@MainActor
final class MenuBarPanelController: NSObject {
    var onSelect: ((MenuBarItem) -> Void)?
    var onDismiss: (() -> Void)?
    private var panel: CollectionPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var anchor = CGRect.zero
    var isVisible: Bool { panel?.isVisible == true }

    func show(items: [MenuBarItem], anchor: CGRect, screen: NSScreen? = nil) {
        self.anchor = anchor
        guard let screen = screen ?? NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main else { return }
        let panel = self.panel ?? makePanel()
        let cardWidth: CGFloat = 94
        let contentWidth = max(220, CGFloat(items.count) * cardWidth + 16)
        let width = min(contentWidth, min(760, screen.visibleFrame.width - 24))
        let height: CGFloat = 112
        let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let frame = CGRect(x: min(max(anchor.maxX - width, bounds.minX), bounds.maxX - width),
                           y: max(bounds.minY, min(anchor.minY - height - 6, bounds.maxY - height)),
                           width: width, height: height)
        let background = NSVisualEffectView(frame: CGRect(origin: .zero, size: frame.size))
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 11
        background.layer?.masksToBounds = true
        if items.isEmpty {
            let label = NSTextField(wrappingLabelWithString: L10n.text("暂无收纳图标\n在「菜单栏」设置中调整分区。"))
            label.alignment = .center; label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.frame = CGRect(x: 12, y: 31, width: width - 24, height: 44)
            background.addSubview(label)
        } else {
            let scroll = NSScrollView(frame: CGRect(x: 8, y: 8, width: width - 16, height: height - 16))
            scroll.drawsBackground = false; scroll.borderType = .noBorder
            scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = false
            scroll.autohidesScrollers = true
            let content = NSView(frame: CGRect(x: 0, y: 0, width: CGFloat(items.count) * cardWidth, height: 87))
            for (index, item) in items.enumerated() {
                let button = CollectionButton(item: item, frame: CGRect(x: CGFloat(index) * cardWidth, y: 7, width: cardWidth - 4, height: 76))
                button.target = self; button.action = #selector(selectItem(_:))
                content.addSubview(button)
            }
            scroll.documentView = content
            background.addSubview(scroll)
        }
        panel.contentView = background
        panel.setFrame(frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    func hide(notify: Bool = false) {
        let wasVisible = isVisible
        panel?.orderOut(nil)
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if notify && wasVisible { onDismiss?() }
    }

    @objc private func selectItem(_ button: CollectionButton) { onSelect?(button.item) }

    private func makePanel() -> CollectionPanel {
        let panel = CollectionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow
        self.panel = panel
        return panel
    }

    private func installMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown && event.keyCode == 53 { self.hide(notify: true); return nil }
            if event.type != .keyDown && event.window !== self.panel {
                let point = NSEvent.mouseLocation
                if !self.anchor.contains(point) && self.panel?.frame.contains(point) != true { self.hide(notify: true) }
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let point = NSEvent.mouseLocation
                if !self.anchor.contains(point) && self.panel?.frame.contains(point) != true { self.hide(notify: true) }
            }
        }
    }
}

private final class CollectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class CollectionButton: NSButton {
    let item: MenuBarItem
    init(item: MenuBarItem, frame: CGRect) {
        self.item = item
        super.init(frame: frame)
        title = item.title
        font = .systemFont(ofSize: 11)
        lineBreakMode = .byTruncatingTail
        imagePosition = .imageAbove; imageScaling = .scaleProportionallyDown
        isBordered = false
        setButtonType(.momentaryChange)
        let icon = item.applicationURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: item.applicationName)
        image = icon?.copy() as? NSImage
        image?.size = NSSize(width: 32, height: 32)
        toolTip = item.applicationName == item.title ? item.title : "\(item.applicationName) · \(item.title)"
        setAccessibilityLabel(toolTip)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
