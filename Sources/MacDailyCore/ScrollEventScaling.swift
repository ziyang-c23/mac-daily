import CoreGraphics
import Foundation

/// Discrete wheel fields are coupled: changing the line field also rewrites the
/// fixed-point/pixel fields. Snapshot all inputs, then write each representation.
/// Sub-line movement is buffered so applications reading only whole lines still
/// receive the requested average speed. No event is posted by this type.
public struct DiscreteScrollScaler {
    private struct Axis {
        var lines = 0.0
        var fixed = 0.0
        var points = 0.0
        var pointRemainder = 0.0
        var pointOnly = false

        mutating func reset() { self = Axis() }
        private func whole(_ value: Double) -> Int64 {
            let magnitude = Int64(floor(abs(value) + 0.000_000_001))
            return value < 0 ? -magnitude : magnitude
        }
        mutating func scaled(line: Double, fixed inputFixed: Double, point: Double, factor: Double) -> (line: Int64, fixed: Double, point: Int64) {
            guard line != 0 || inputFixed != 0 || point != 0 else { return (0, 0, 0) }
            let isPointOnly = line == 0 && inputFixed == 0 && point != 0
            if isPointOnly != pointOnly && (lines != 0 || points != 0) { reset() }
            pointOnly = isPointOnly
            if isPointOnly {
                let delta = point * factor
                if points * delta < 0 { reset(); pointOnly = true }
                points += delta
                let whole = whole(points)
                points -= Double(whole)
                return (0, 0, whole)
            }
            // High-resolution discrete wheels may carry fractional fixed-point
            // lines while their integer line field is zero.
            let logicalLines = line != 0 ? line : inputFixed
            let delta = logicalLines * factor
            if lines * delta < 0 { reset() }
            lines += delta; fixed += inputFixed * factor; points += point * factor
            let whole = whole(lines)
            guard whole != 0 else { return (0, 0, 0) }
            let fraction = Double(whole) / lines
            let emittedFixed = fixed * fraction
            let intendedPoints = points * fraction
            pointRemainder += intendedPoints
            let emittedPoints = self.whole(pointRemainder)
            pointRemainder -= Double(emittedPoints)
            lines -= Double(whole); fixed -= emittedFixed; points -= intendedPoints
            if abs(lines) < 0.000_000_1 { lines = 0; fixed = 0; points = 0 }
            return (whole, emittedFixed, emittedPoints)
        }
    }
    private var horizontal = Axis()
    private var vertical = Axis()
    public init() {}
    public mutating func reset() { horizontal.reset(); vertical.reset() }

    /// Returns false when the physical tick has been accumulated but should not
    /// yet be delivered. The caller must discard that event, not post a zero tick.
    @discardableResult
    public mutating func apply(to event: CGEvent, xFactor: Double, yFactor: Double) -> Bool {
        guard event.type == .scrollWheel,
              xFactor.isFinite, yFactor.isFinite, abs(xFactor) <= 4, abs(yFactor) <= 4 else {
            reset(); return true
        }
        let rawX = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
        let rawY = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        let fixedX = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        let fixedY = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let pointX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        let pointY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let values = [rawX, rawY, fixedX, fixedY, pointX, pointY]
        guard values.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else { reset(); return true }
        // A phase-only event does not flush or erase an accumulated partial tick.
        if values.allSatisfy({ $0 == 0 }) { return true }
        let x = horizontal.scaled(line: rawX, fixed: fixedX, point: pointX, factor: xFactor)
        let y = vertical.scaled(line: rawY, fixed: fixedY, point: pointY, factor: yFactor)
        guard x.line != 0 || y.line != 0 || x.fixed != 0 || y.fixed != 0 || x.point != 0 || y.point != 0 else { return false }
        // Line fields first; their setters can replace the other representations.
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: y.line)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: x.line)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: y.fixed)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: x.fixed)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: y.point)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: x.point)
        return true
    }
}
