import MacDailyCore
import AppKit
import ApplicationServices

@MainActor
final class MenuBarOrderController {
    enum MoveError: LocalizedError {
        case eventCreationFailed
        var errorDescription: String? { L10n.text("无法创建菜单栏拖动事件") }
    }

    private final class MoveSession {
        let up: CGEvent
        let restore: CGEvent
        var currentPoint: CGPoint
        var pressed = false
        var cursorHidden = false
        init(up: CGEvent, restore: CGEvent, point: CGPoint) {
            self.up = up; self.restore = restore; currentPoint = point
        }
    }
    private var active: MoveSession?

    /// Completes owned input synchronously, including when the app is about to terminate.
    func cancel() {
        if let session = active { finish(session) }
    }

    private func finish(_ session: MoveSession) {
        guard active === session else { return }
        active = nil
        if session.pressed {
            session.up.location = session.currentPoint
            session.up.post(tap: .cghidEventTap)
            session.pressed = false
        }
        session.restore.post(tap: .cghidEventTap)
        if session.cursorHidden {
            CGDisplayShowCursor(CGMainDisplayID())
            session.cursorHidden = false
        }
    }

    /// Moves a status item using the system's Command-drag interaction.
    /// Both the source frame and target point use Quartz/AX coordinates.
    /// The caller serializes moves and supplies positions from its latest catalog.
    func move(from frame: CGRect, to target: CGPoint) async throws {
        try Task.checkCancellation()
        guard let pointer = CGEvent(source: nil),
              let source = CGEventSource(stateID: .combinedSessionState) else {
            throw MoveError.eventCreationFailed
        }
        let originalPoint = pointer.location
        let start = CGPoint(x: frame.midX, y: frame.midY)
        let marker: Int64 = 0x4D41434441494C59
        func event(_ type: CGEventType, at point: CGPoint, flags: CGEventFlags) throws -> CGEvent {
            guard let result = CGEvent(mouseEventSource: source, mouseType: type,
                                       mouseCursorPosition: point, mouseButton: .left) else {
                throw MoveError.eventCreationFailed
            }
            result.flags = flags
            result.setIntegerValueField(.eventSourceUserData, value: marker)
            return result
        }
        let moveToStart = try event(.mouseMoved, at: start, flags: pointer.flags)
        let down = try event(.leftMouseDown, at: start, flags: .maskCommand)
        let up = try event(.leftMouseUp, at: target, flags: .maskCommand)
        let restore = try event(.mouseMoved, at: originalPoint, flags: pointer.flags)
        let dragged = try (1...8).map { step -> CGEvent in
            let fraction = CGFloat(step) / 8
            let point = CGPoint(x: start.x + (target.x - start.x) * fraction,
                                y: start.y + (target.y - start.y) * fraction)
            return try event(.leftMouseDragged, at: point, flags: .maskCommand)
        }
        let session = MoveSession(up: up, restore: restore, point: start)
        active = session
        session.cursorHidden = CGDisplayHideCursor(CGMainDisplayID()) == .success
        defer { finish(session) }
        @MainActor func wait(_ nanoseconds: UInt64) async throws {
            try await Task.sleep(nanoseconds: nanoseconds)
            guard active === session else { throw CancellationError() }
        }

        moveToStart.post(tap: .cghidEventTap)
        try await wait(60_000_000)
        down.post(tap: .cghidEventTap)
        session.pressed = true
        try await wait(80_000_000)
        for drag in dragged {
            try Task.checkCancellation()
            drag.post(tap: .cghidEventTap)
            session.currentPoint = drag.location
            try await wait(15_000_000)
        }
        up.post(tap: .cghidEventTap)
        session.pressed = false
        try await wait(100_000_000)
    }
}
