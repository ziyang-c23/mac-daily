import AppKit
import MacDailyCore

/// Owns only MacDaily's boundary item; the runtime owns the shared MacDaily entry.
/// The macOS 27 pusher-width mechanism follows CleanMenuBar's measurements:
/// https://github.com/atilac/CleanMenuBar/tree/e9652547fa5ff70e7e93ab76ac2966bedcafe02d (MIT).
@MainActor
final class MenuBarLayoutController {
    private let trigger: NSStatusItem
    private var boundary: NSStatusItem?
    private var expandedBoundaryFrame: CGRect?
    private let expandedLength: CGFloat = 12
    private let autosaveName = "MacDaily.menuBoundary_v27"

    private(set) var isEnabled = false
    private(set) var isExpanded = true
    private(set) var isArranging = false

    init(trigger: NSStatusItem) { self.trigger = trigger }

    /// Coordinates use Quartz's top-left origin, matching accessibility item frames.
    /// During collapse the cached expanded boundary is used because the pusher may be discarded.
    var boundaryFrameQuartz: CGRect? {
        if isExpanded, let frame = currentBoundaryFrame() {
            expandedBoundaryFrame = frame
            return frame
        }
        return expandedBoundaryFrame
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if !enabled { stop(); return }
        isEnabled = true
        seedInitialPosition()
        let item = NSStatusBar.system.statusItem(withLength: expandedLength)
        item.autosaveName = autosaveName
        item.isVisible = true
        item.button?.toolTip = L10n.text("MacDaily 收纳边界")
        item.button?.setAccessibilityLabel(L10n.text("MacDaily 收纳边界"))
        item.button?.setAccessibilityIdentifier("MacDaily.CollectionBoundary")
        boundary = item
        isExpanded = true
        updateAppearance()
    }

    func beginArrangement() {
        setEnabled(true)
        isArranging = true
        expand()
    }

    /// Call after the runtime has read the final expanded catalog.
    func finishArrangement() {
        isArranging = false
        collapse()
    }

    func expand() {
        guard let boundary else { return }
        boundary.length = expandedLength
        isExpanded = true
        updateAppearance()
    }

    func collapse() {
        guard let boundary, !isArranging,
              let length = MenuBarLayoutGeometry.collapsedLength(screenWidths: NSScreen.screens.map { Double($0.frame.width) }) else { return }
        if isExpanded, let frame = currentBoundaryFrame() { expandedBoundaryFrame = frame }
        isExpanded = false
        boundary.button?.image = nil
        boundary.length = CGFloat(length)
        // isVisible must stay true: removing the pusher would restore every item.
        boundary.isVisible = true
    }

    func invalidateLayoutForScreens() {
        expandedBoundaryFrame = nil
        if isExpanded { updateAppearance() }
        else { collapse() }
    }

    func stop() {
        if let boundary {
            boundary.length = expandedLength
            NSStatusBar.system.removeStatusItem(boundary)
        }
        boundary = nil
        isEnabled = false
        isExpanded = true
        isArranging = false
        expandedBoundaryFrame = nil
    }

    private func updateAppearance() {
        guard let boundary else { return }
        boundary.button?.image = isArranging ? Self.separatorImage() : nil
        boundary.isVisible = true
    }

    private func currentBoundaryFrame() -> CGRect? {
        guard let button = boundary?.button, let window = button.window,
              let primary = NSScreen.screens.first else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }

    private func seedInitialPosition() {
        // Seed only our new boundary; the system's existing Cmd-drag placement wins thereafter.
        let key = "NSStatusItem Preferred Position \(autosaveName)"
        guard UserDefaults.standard.object(forKey: key) == nil,
              let triggerName = trigger.autosaveName,
              let position = UserDefaults.standard.object(forKey: "NSStatusItem Preferred Position \(triggerName)") as? NSNumber else { return }
        let triggerWidth = max(trigger.button?.bounds.width ?? 0, 24)
        UserDefaults.standard.set(position.doubleValue + Double(triggerWidth + expandedLength), forKey: key)
    }

    private static func separatorImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 4, height: 14), flipped: false) { bounds in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 1, yRadius: 1).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
