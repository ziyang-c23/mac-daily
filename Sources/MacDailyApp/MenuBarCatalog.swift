import MacDailyCore
import AppKit
import ApplicationServices
import Foundation

/// The AX element is a process-local handle; only the display metadata is used by the panel.
struct MenuBarItem: Identifiable, Equatable, @unchecked Sendable {
    let id: String
    let bundleIdentifier: String
    let title: String
    let applicationName: String
    let applicationURL: URL?
    let frame: CGRect
    let processIdentifier: pid_t
    let element: AXUIElement
    let canActivate: Bool

    init(id: String, bundleIdentifier: String, title: String, applicationName: String,
         applicationURL: URL?, frame: CGRect, processIdentifier: pid_t, element: AXUIElement,
         canActivate: Bool = true) {
        self.id = id; self.bundleIdentifier = bundleIdentifier; self.title = title
        self.applicationName = applicationName; self.applicationURL = applicationURL
        self.frame = frame; self.processIdentifier = processIdentifier; self.element = element
        self.canActivate = canActivate
    }
    var isSystemItem: Bool { bundleIdentifier.hasPrefix("com.apple.") }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.bundleIdentifier == rhs.bundleIdentifier && lhs.title == rhs.title
            && lhs.applicationName == rhs.applicationName && lhs.applicationURL == rhs.applicationURL
            && lhs.frame == rhs.frame && lhs.processIdentifier == rhs.processIdentifier
            && lhs.canActivate == rhs.canActivate
    }
}

struct MenuBarActivationResult: Sendable {
    let succeeded: Bool
    let message: String
}

@MainActor
final class MenuBarCatalog {
    /// Collecting app metadata is cheap; the AX requests run concurrently off the main thread.
    func scan(excluding processIdentifier: pid_t = getpid()) async -> [MenuBarItem] {
        let applications = NSWorkspace.shared.runningApplications.compactMap { app -> MenuBarApplication? in
            guard !app.isTerminated,
                  let bundleIdentifier = app.bundleIdentifier else { return nil }
            return .init(pid: app.processIdentifier, bundleIdentifier: bundleIdentifier,
                         name: app.localizedName ?? bundleIdentifier, url: app.bundleURL)
        }
        return await Task.detached(priority: .userInitiated) {
            let output = MenuBarScanAccumulator()
            DispatchQueue.concurrentPerform(iterations: applications.count) { index in
                autoreleasepool {
                    let items = MenuBarAX.items(for: applications[index])
                    output.append(items)
                }
            }
            // Per-app extras are preferred over the system host's copies of the same item.
            let items = output.items.sorted { lhs, rhs in
                let leftHost = lhs.bundleIdentifier.caseInsensitiveCompare("com.apple.MenuBarAgent") == .orderedSame
                let rightHost = rhs.bundleIdentifier.caseInsensitiveCompare("com.apple.MenuBarAgent") == .orderedSame
                if leftHost != rightHost { return !leftHost }
                return lhs.id < rhs.id
            }
            var frames = Set<String>(), unique: [MenuBarItem] = []
            for item in items {
                let key = "\(item.frame.minX.rounded()):\(item.frame.minY.rounded()):\(item.frame.width.rounded()):\(item.frame.height.rounded())"
                if frames.insert(key).inserted { unique.append(item) }
            }
            return unique.filter { $0.processIdentifier != processIdentifier }.sorted {
                if abs($0.frame.midY - $1.frame.midY) > 2 { return $0.frame.midY < $1.frame.midY }
                if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
                return $0.id < $1.id
            }
        }.value
    }

    /// Opens the status item's own menu. It never substitutes opening the app's main window.
    func activate(_ item: MenuBarItem) async -> MenuBarActivationResult {
        await Task.detached(priority: .userInitiated) {
            AXUIElementSetMessagingTimeout(item.element, 0.5)
            let result = AXUIElementPerformAction(item.element, kAXPressAction as CFString)
            switch result {
            case .success: return .init(succeeded: true, message: L10n.text("已打开%@", String(describing: item.title)))
            case .actionUnsupported: return .init(succeeded: false, message: L10n.text("%@未提供辅助功能点击动作", String(describing: item.title)))
            case .invalidUIElement: return .init(succeeded: false, message: L10n.text("%@的菜单栏项目已变化，请重新展开", String(describing: item.applicationName)))
            default: return .init(succeeded: false, message: L10n.text("无法打开%@（辅助功能 %@）", String(describing: item.title), String(describing: result.rawValue)))
            }
        }.value
    }

    func observeMenu(of item: MenuBarItem, onChange: @escaping @MainActor (Bool) -> Void) -> MenuBarTrackingObservation? {
        MenuBarTrackingObservation(item: item, onChange: onChange)
    }

    /// A one-shot read used at the auto-collapse boundary, not a polling loop.
    func isMenuOpen(for item: MenuBarItem) async -> Bool {
        await Task.detached(priority: .utility) { MenuBarAX.menuIsOpen(item.element) }.value
    }
}

private struct MenuBarApplication: Sendable {
    let pid: pid_t
    let bundleIdentifier: String
    let name: String
    let url: URL?
}

private final class MenuBarScanAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MenuBarItem] = []
    func append(_ items: [MenuBarItem]) { lock.lock(); values.append(contentsOf: items); lock.unlock() }
    var items: [MenuBarItem] { lock.lock(); defer { lock.unlock() }; return values }
}

private enum MenuBarAX {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }
    static func element(_ object: CFTypeRef?) -> AXUIElement? {
        guard let object, CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
        return (object as! AXUIElement)
    }
    static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name) as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent),
              point.x.isFinite, point.y.isFinite, extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else { return nil }
        return CGRect(origin: point, size: extent)
    }
    static func items(for application: MenuBarApplication) -> [MenuBarItem] {
        let app = AXUIElementCreateApplication(application.pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        // AXExtrasMenuBar represents status items, unlike AXMenuBar's application commands.
        guard let extras = element(attribute(app, kAXExtrasMenuBarAttribute)),
              let children = attribute(extras, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        let isMenuBarHost = application.bundleIdentifier.caseInsensitiveCompare("com.apple.MenuBarAgent") == .orderedSame
        // macOS 27's host exposes a wrapper for each status item. The named,
        // pressable button/menu-extra is the wrapper's child, not the wrapper.
        let statusElements = isMenuBarHost ? children.flatMap { wrapper -> [AXUIElement] in
            let role = string(wrapper, kAXRoleAttribute)
            if role == kAXButtonRole || role == kAXMenuBarItemRole { return [wrapper] }
            return attribute(wrapper, kAXChildrenAttribute) as? [AXUIElement] ?? []
        } : children
        var result: [MenuBarItem] = []
        for (index, child) in statusElements.enumerated() {
            guard let frame = frame(child) else { continue }
            let title = string(child, kAXTitleAttribute) ?? string(child, kAXDescriptionAttribute)
                ?? string(child, kAXHelpAttribute) ?? application.name
            let identifier = string(child, kAXIdentifierAttribute) ?? "item-\(index)"
            var actionNames: CFArray?
            let canActivate = AXUIElementCopyActionNames(child, &actionNames) == .success
                && ((actionNames as? [String])?.contains(kAXPressAction) ?? false)
            result.append(.init(id: "\(application.bundleIdentifier):\(identifier)", bundleIdentifier: application.bundleIdentifier,
                                title: title, applicationName: isMenuBarHost ? title : application.name, applicationURL: application.url,
                                frame: frame, processIdentifier: application.pid, element: child, canActivate: canActivate))
        }
        return result
    }
    static func menuIsOpen(_ element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, 0.2)
        if self.element(attribute(element, kAXShownMenuUIElementAttribute)) != nil { return true }
        return (attribute(element, kAXSelectedAttribute) as? Bool) == true
    }
}

/// Notifications are attached only for the item being operated, then removed when the interaction ends.
@MainActor
final class MenuBarTrackingObservation {
    private struct Registration {
        let observer: AXObserver
        let element: AXUIElement
        let notifications: [CFString]
    }
    private var registrations: [Registration] = []
    private let onChange: @MainActor (Bool) -> Void
    private(set) var isOpen = false

    init?(item: MenuBarItem, onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
        var owner: pid_t = item.processIdentifier
        AXUIElementGetPid(item.element, &owner)
        for pid in Set([item.processIdentifier, owner]) {
            var observer: AXObserver?
            guard AXObserverCreate(pid, menuBarTrackingCallback, &observer) == .success, let observer else { continue }
            let app = AXUIElementCreateApplication(pid)
            let targets = pid == owner ? [app, item.element] : [app]
            var registered = false
            for element in targets {
                let names = [kAXMenuOpenedNotification, kAXMenuClosedNotification].compactMap { name -> CFString? in
                    let value = name as CFString
                    return AXObserverAddNotification(observer, element, value, Unmanaged.passUnretained(self).toOpaque()) == .success ? value : nil
                }
                if !names.isEmpty { registrations.append(.init(observer: observer, element: element, notifications: names)); registered = true }
            }
            if registered { CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        }
        if registrations.isEmpty { return nil }
    }
    func stop() {
        for registration in registrations {
            for notification in registration.notifications { AXObserverRemoveNotification(registration.observer, registration.element, notification) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(registration.observer), .commonModes)
        }
        registrations.removeAll()
    }
    fileprivate func received(_ notification: CFString) {
        let open = (notification as String) == kAXMenuOpenedNotification
        guard open != isOpen else { return }
        isOpen = open
        onChange(open)
    }
    deinit {
        for registration in registrations {
            for notification in registration.notifications { AXObserverRemoveNotification(registration.observer, registration.element, notification) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(registration.observer), .commonModes)
        }
    }
}

private func menuBarTrackingCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let token = Unmanaged<MenuBarTrackingObservation>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { token.received(notification) }
}
