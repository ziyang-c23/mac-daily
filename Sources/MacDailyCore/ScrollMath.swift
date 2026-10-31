import Foundation

public struct ScrollTransform: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var handled: Bool
    public var smooth: Bool
    public var duration: Double
    public init(x: Double, y: Double, handled: Bool, smooth: Bool, duration: Double) {
        self.x = x; self.y = y; self.handled = handled; self.smooth = smooth; self.duration = duration
    }
}

public enum ScrollMath {
    /// Continuous scroll is deliberately passed through, including momentum.
    /// Hardware that emits continuous events is not re-smoothed heuristically.
    public static func transform(deltaX: Double, deltaY: Double, isContinuous: Bool,
                                 isMouse: Bool = true, modifiers: UInt64 = 0,
                                 settings: ScrollSettings, excluded: Bool = false,
                                 synthetic: Bool = false) -> ScrollTransform {
        let bypass = excluded || synthetic || !isMouse || isContinuous || !deltaX.isFinite || !deltaY.isFinite
        if bypass { return .init(x: deltaX, y: deltaY, handled: false, smooth: false, duration: 0) }
        let speed = settings.speed.isFinite ? min(4, max(0.2, settings.speed)) : 1
        let x = deltaX * speed * (settings.reverseHorizontal ? -1 : 1)
        let y = deltaY * speed * (settings.reverseVertical ? -1 : 1)
        let modifiersDisable = settings.bypassWithModifiers && modifiers & (Shortcut.command | Shortcut.control | Shortcut.option) != 0
        let smooth = settings.smoothEnabled && !modifiersDisable
        let duration = settings.smoothing.isFinite ? min(0.5, max(0.04, settings.smoothing)) : 0.16
        return .init(x: x, y: y, handled: smooth || x != deltaX || y != deltaY, smooth: smooth, duration: duration)
    }
}

/// Exponential motion tail. Each step returns a delta, never an absolute scroll.
/// A final residual step preserves total distance instead of losing fractional ticks.
public struct SmoothScrollAccumulator: Sendable {
    public private(set) var pendingX = 0.0
    public private(set) var pendingY = 0.0
    public var isActive: Bool { pendingX != 0 || pendingY != 0 }
    public init() {}
    public mutating func add(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return }
        // Changing direction must not fight an old inertia tail on that axis.
        if pendingX * x < 0 { pendingX = 0 }
        if pendingY * y < 0 { pendingY = 0 }
        pendingX = min(100_000, max(-100_000, pendingX + x))
        pendingY = min(100_000, max(-100_000, pendingY + y))
    }
    public mutating func step(deltaTime: Double, duration: Double) -> (x: Double, y: Double) {
        guard deltaTime.isFinite, deltaTime > 0 else { return (0, 0) }
        let tau = duration.isFinite ? max(0.01, duration / 3) : 0.16 / 3
        let fraction = 1 - exp(-deltaTime / tau)
        var x = pendingX * fraction, y = pendingY * fraction
        pendingX -= x; pendingY -= y
        if abs(pendingX) < 0.01 { x += pendingX; pendingX = 0 }
        if abs(pendingY) < 0.01 { y += pendingY; pendingY = 0 }
        return (x, y)
    }
    public mutating func reset() { pendingX = 0; pendingY = 0 }
}
