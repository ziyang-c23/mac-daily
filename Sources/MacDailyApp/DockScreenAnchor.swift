import MacDailyCore
import AppKit
import ApplicationServices

struct DockAnchorDisplay: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Prevents Dock activation at the outer edge of displays other than the anchor.
/// Movement events are edited in place; window dragging is outside this tap's mask.
@MainActor
final class DockScreenAnchor {
    var onStopped: ((String) -> Void)?
    private let filter = DockAnchorEventFilter()
    private var source: CFRunLoopSource?
    private var screenObserver: NSObjectProtocol?
    private var anchorUUID: String?
    private(set) var isRunning = false

    static var displays: [DockAnchorDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let id = identifier(screen) else { return nil }
            return DockAnchorDisplay(id: id, name: screen.localizedName)
        }
    }

    @discardableResult
    func start(displayUUID: String?) -> Bool {
        stop()
        anchorUUID = displayUUID
        guard rebuildGeometry() else { return false }
        guard AXIsProcessTrusted() else { onStopped?(L10n.text("固定 Dock 显示器需要 MacDaily 的辅助功能权限")); return false }
        let context = Unmanaged.passUnretained(filter).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << CGEventType.mouseMoved.rawValue,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<DockAnchorEventFilter>.fromOpaque(context).takeUnretainedValue().handle(type, event: event)
            }, userInfo: context) else {
            onStopped?(L10n.text("未能启动 Dock 显示器固定，请检查 MacDaily 的辅助功能权限"))
            return false
        }
        filter.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        filter.onDisabled = { [weak self] in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.stop(); self.onStopped?(L10n.text("Dock 显示器固定已停止，辅助功能监听被关闭"))
            }
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                if !self.rebuildGeometry() { self.stop() }
            }
        }
        return true
    }

    func update(displayUUID: String?) {
        guard isRunning else { return }
        anchorUUID = displayUUID
        if !rebuildGeometry() { stop() }
    }

    /// Refresh orientation when the dashboard opens, without a polling task.
    func refreshGeometry() {
        guard isRunning else { return }
        if !rebuildGeometry() { stop() }
    }

    private func rebuildGeometry() -> Bool {
        let screens = NSScreen.screens
        guard let selectedUUID = anchorUUID ?? screens.first.flatMap(Self.identifier), screens.contains(where: { Self.identifier($0) == selectedUUID }) else {
            onStopped?(L10n.text("固定的 Dock 显示器已断开，请重新选择显示器"))
            return false
        }
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        let orientation = CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String ?? "bottom"
        let rects = screens.compactMap { screen -> (id: String, frame: CGRect)? in
            guard let id = Self.identifier(screen), let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (id, CGDisplayBounds(number.uint32Value))
        }
        filter.anchorUUID = selectedUUID
        filter.orientation = orientation
        filter.screens = rects
        return true
    }

    private static func identifier(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String
    }

    func stop() {
        if let tap = filter.tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        source = nil; screenObserver = nil; filter.tap = nil; filter.onDisabled = nil
        filter.screens = []; isRunning = false
    }
}

private final class DockAnchorEventFilter {
    var tap: CFMachPort?
    var onDisabled: (() -> Void)?
    var anchorUUID = ""
    var orientation = "bottom"
    var screens: [(id: String, frame: CGRect)] = []

    func handle(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByUserInput {
            onDisabled?(); return Unmanaged.passUnretained(event)
        }
        guard type == .mouseMoved, event.getIntegerValueField(.eventSourceUserData) != 0x4D41434441494C59 else { return Unmanaged.passUnretained(event) }
        let point = event.location
        let target = DockAnchorGeometry.adjustedPoint(point, screens: screens, anchorUUID: anchorUUID, orientation: orientation)
        if target != point { event.location = target }
        return Unmanaged.passUnretained(event)
    }
}


/// Geometry shared by the live event filter and isolated layout verification.
struct DockAnchorGeometry {
    static func adjustedPoint(_ point: CGPoint, screens: [(id: String, frame: CGRect)], anchorUUID: String, orientation: String) -> CGPoint {
        guard let screen = screens.first(where: { $0.frame.contains(point) }), screen.id != anchorUUID else { return point }
        // Shared edges remain open for normal movement between displays.
        let frame = screen.frame
        var target = point
        switch orientation {
        case "left":
            guard point.x < frame.minX + 2 else { return point }
            let crossesDisplay = screens.contains { $0.id != screen.id && abs($0.frame.maxX - frame.minX) <= 1 && point.y >= $0.frame.minY && point.y < $0.frame.maxY }
            if !crossesDisplay { target.x = frame.minX + 2 }
        case "right":
            guard point.x >= frame.maxX - 2 else { return point }
            let crossesDisplay = screens.contains { $0.id != screen.id && abs($0.frame.minX - frame.maxX) <= 1 && point.y >= $0.frame.minY && point.y < $0.frame.maxY }
            if !crossesDisplay { target.x = frame.maxX - 2 }
        default:
            guard point.y >= frame.maxY - 2 else { return point }
            let crossesDisplay = screens.contains { $0.id != screen.id && abs($0.frame.minY - frame.maxY) <= 1 && point.x >= $0.frame.minX && point.x < $0.frame.maxX }
            if !crossesDisplay { target.y = frame.maxY - 2 }
        }
        return target
    }
}
