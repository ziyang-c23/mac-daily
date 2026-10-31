import AppKit
import MacDailyCore

/// A preview panel never becomes key and never intercepts the drag that owns it.
@MainActor
final class WindowOverlay {
    private var panel: NSPanel?

    func show(quartzFrame: CGRect, primaryScreenHeight: CGFloat, title: String) {
        guard quartzFrame.width > 0, quartzFrame.height > 0 else { hide(); return }
        let frame = CGRect(x: quartzFrame.minX, y: primaryScreenHeight - quartzFrame.maxY,
                           width: quartzFrame.width, height: quartzFrame.height)
        let panel = self.panel ?? makePanel()
        panel.setFrame(frame, display: false)
        (panel.contentView as? SnapPreviewView)?.title = title
        panel.contentView?.needsDisplay = true
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = SnapPreviewView()
        self.panel = panel
        return panel
    }
}

private final class SnapPreviewView: NSView {
    var title = ""
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let outline = bounds.insetBy(dx: 3, dy: 3)
        let path = NSBezierPath(roundedRect: outline, xRadius: 12, yRadius: 12)
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
        path.lineWidth = 3
        path.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let text = NSAttributedString(string: L10n.text(title), attributes: attributes)
        let size = text.size()
        let badge = CGRect(x: bounds.midX - size.width / 2 - 14, y: bounds.midY - size.height / 2 - 9,
                           width: size.width + 28, height: size.height + 18)
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 9, yRadius: 9).fill()
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}
