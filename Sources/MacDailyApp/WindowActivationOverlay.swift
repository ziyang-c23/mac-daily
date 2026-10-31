import AppKit
import MacDailyCore

/// A single display-local panel highlights regions only while a native window is moving.
/// Like the destination preview, it cannot receive focus or intercept any pointer input.
@MainActor
final class WindowActivationOverlay {
    private var panel: NSPanel?
    private var lastFrame: CGRect?
    private var lastAreas: [WindowActivationArea] = []
    private var lastActiveID: UUID?

    func show(profile: WindowActivationProfile, screen: CGRect, primaryScreenHeight: CGFloat, activeID: UUID?) {
        let areas = profile.areas(for: .init(screen: screen)).filter {
            $0.enabled && (try? $0.validated()) != nil
        }
        guard !areas.isEmpty else { hide(); return }
        let frame = CGRect(x: screen.minX, y: primaryScreenHeight - screen.maxY,
                           width: screen.width, height: screen.height)
        let panel = self.panel ?? makePanel()
        if lastFrame != frame || lastAreas != areas || lastActiveID != activeID {
            panel.setFrame(frame, display: false)
            if let view = panel.contentView as? ActivationRegionView {
                view.areas = areas; view.activeID = activeID
                view.needsDisplay = true
            }
            lastFrame = frame; lastAreas = areas; lastActiveID = activeID
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
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
        panel.contentView = ActivationRegionView()
        self.panel = panel
        return panel
    }
}

private final class ActivationRegionView: NSView {
    var areas: [WindowActivationArea] = []
    var activeID: UUID?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // Reverse drawing keeps the first matching region visually on top too.
        for area in areas.reversed() {
            guard let rect = area.rect.frame(in: bounds) else { continue }
            let active = area.id == activeID
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            NSColor.controlAccentColor.withAlphaComponent(active ? 0.27 : 0.09).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(active ? 0.95 : 0.4).setStroke()
            path.lineWidth = active ? 2 : 1
            path.stroke()
            guard rect.width >= 58, rect.height >= 22 else { continue }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            let text = NSAttributedString(string: L10n.text(area.name), attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: active ? .semibold : .regular),
                .foregroundColor: NSColor.labelColor.withAlphaComponent(active ? 1 : 0.7),
                .paragraphStyle: paragraph
            ])
            text.draw(in: CGRect(x: rect.minX + 4, y: rect.midY - 7,
                                 width: rect.width - 8, height: 16))
        }
    }
}
