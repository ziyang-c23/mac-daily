import Foundation

public enum MouseEventDevice: String, Sendable { case mouse, trackpad, unknown }

/// Keeps device attribution for one physical button hold. Scroll still requires
/// its own positive mouse attribution; trackpad events never inherit a hold.
public struct MouseEventAdapter: Sendable {
    private var senders: [Int: UInt64] = [:]
    public var admittedButtons: Set<Int> { Set(senders.keys) }
    public init() {}
    public mutating func reset() { senders.removeAll() }

    public mutating func adapt(_ source: MouseInput, device: MouseEventDevice, senderID: UInt64) -> MouseInput {
        var input = source
        guard !input.isSynthetic else { input.isMouse = false; return input }
        if input.kind == .cancel { return input }
        switch input.kind {
        case .buttonDown:
            input.isMouse = device == .mouse
            if input.isMouse { senders[input.button] = senderID }
        case .move, .buttonUp:
            let held = senders[input.button]
            let sameSender = held.map { $0 == 0 || senderID == 0 || $0 == senderID } ?? true
            input.isMouse = device == .mouse && sameSender
                || device == .unknown && held != nil && sameSender
            if input.kind == .buttonUp && input.isMouse { senders.removeValue(forKey: input.button) }
        case .scroll:
            input.isMouse = device == .mouse
            if let owner = senders.values.first, owner != 0, senderID != 0, owner != senderID { input.isMouse = false }
        case .cancel: break
        }
        return input
    }
}
