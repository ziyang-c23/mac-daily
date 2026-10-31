import Foundation
import CoreGraphics
import MacDailyCore
import PointerBridge

enum InputDeviceKind: Sendable { case mouse, trackpad, unknown }

/// The event thread reads a small value-only snapshot. All registry access and
/// pointer property writes are confined to the main actor.
private final class PointerDeviceCache: @unchecked Sendable {
    private let lock = NSLock()
    private var kinds: [UInt64: InputDeviceKind] = [:]
    private var builtInTouch = Set<UInt64>()
    func replace(_ value: [UInt64: InputDeviceKind], builtInTouch: Set<UInt64> = []) { lock.lock(); kinds = value; self.builtInTouch = builtInTouch; lock.unlock() }
    func isBuiltInTouch(_ id: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return builtInTouch.contains(id) }
    func kind(for id: UInt64) -> InputDeviceKind {
        lock.lock(); defer { lock.unlock() }
        return kinds[id] ?? .unknown
    }
}

@MainActor
final class PointerController {
    nonisolated private let cache = PointerDeviceCache()
    private var monitor: MDPointerMonitorRef?
    private var onChange: (([String]) -> Void)?
    private var requested = PointerSettings()
    private(set) var status = L10n.text("指针保持系统设置")
    var onStatus: ((String) -> Void)?
    private(set) var deviceNames: [String] = []

    init() {}

    func startMonitoring(onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
        guard monitor == nil else { publishDevices(); return }
        monitor = MDPointerMonitorCreate({ context in
            guard let context else { return }
            let owner = Unmanaged<PointerController>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { owner.topologyChanged() }
        }, Unmanaged.passUnretained(self).toOpaque())
        guard monitor != nil else {
            setStatus(L10n.text("当前系统无法枚举指针设备；未识别输入保持原行为"))
            return
        }
        publishDevices()
        if !MDPointerAttributionAvailable() {
            setStatus(L10n.text("当前系统无法确认输入设备；鼠标增强保持暂停"))
        }
    }

    func apply(_ settings: PointerSettings) {
        requested = settings
        guard let monitor else { setStatus(L10n.text("指针设备尚未就绪")); return }
        if settings.enabled {
            _ = MDPointerApply(monitor, settings.speed, settings.acceleration, settings.disableAcceleration)
        } else { _ = MDPointerRestore(monitor) }
        setStatus(MDPointerCopyStatus(monitor) as String)
    }

    func restore() {
        requested = PointerSettings()
        guard let monitor else { return }
        _ = MDPointerRestore(monitor)
        setStatus(MDPointerCopyStatus(monitor) as String)
    }

    func stopMonitoring() {
        requested = PointerSettings()
        if let monitor {
            _ = MDPointerRestore(monitor)
            setStatus(MDPointerCopyStatus(monitor) as String)
            MDPointerMonitorDestroy(monitor)
        }
        monitor = nil
        cache.replace([:]); deviceNames = []; onChange?([]); onChange = nil
    }

    nonisolated func identify(event: CGEvent) -> InputDeviceKind {
        let sender = MDPointerEventSenderID(event)
        guard sender != 0 else { return .unknown }
        return cache.kind(for: sender)
    }
    nonisolated func isBuiltInTrackpad(event: CGEvent) -> Bool {
        let sender = MDPointerEventSenderID(event)
        return sender != 0 && cache.isBuiltInTouch(sender)
    }

    private func topologyChanged() {
        publishDevices()
        if requested.enabled { apply(requested) }
    }

    private func publishDevices() {
        guard let monitor else { return }
        let devices = MDPointerCopyDevices(monitor) as NSArray
        var kinds: [UInt64: InputDeviceKind] = [:]
        var names: [String] = []
        var internalTouch = Set<UInt64>()
        for case let entry as NSDictionary in devices {
            guard let id = entry["id"] as? NSNumber, let kind = entry["kind"] as? NSNumber else { continue }
            let deviceKind: InputDeviceKind = kind.intValue == 1 ? .mouse : .trackpad
            kinds[id.uint64Value] = deviceKind
            if deviceKind == .trackpad, (entry["builtIn"] as? NSNumber)?.boolValue == true { internalTouch.insert(id.uint64Value) }
            if deviceKind == .mouse, let name = entry["name"] as? String { names.append(name) }
        }
        cache.replace(kinds, builtInTouch: internalTouch)
        deviceNames = Array(Set(names)).sorted()
        onChange?(deviceNames)
    }

    private func setStatus(_ value: String) { let text = L10n.text(value); status = text; onStatus?(text) }
}
