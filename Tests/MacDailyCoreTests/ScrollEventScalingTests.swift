import CoreGraphics
import Testing
@testable import MacDailyCore

struct ScrollEventScalingTests {
    private func wheel(x: Int32 = 0, y: Int32 = 1) -> CGEvent {
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)!
    }
    private func vertical(_ event: CGEvent) -> (Double, Double, Double) {
        (event.getDoubleValueField(.scrollWheelEventDeltaAxis1),
         event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
         event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
    }
    @Test func reversalKeepsAllRepresentationsInSameDirection() {
        var scaler = DiscreteScrollScaler(); let event = wheel(); let original = vertical(event)
        #expect(scaler.apply(to: event, xFactor: 1, yFactor: -1) == true)
        let output = vertical(event)
        #expect(output.0 == -original.0); #expect(output.1 == -original.1); #expect(output.2 == -original.2)
    }
    @Test func scalingDoesNotMultiplyAlreadyModifiedFields() {
        var scaler = DiscreteScrollScaler(); let event = wheel(); let original = vertical(event)
        #expect(scaler.apply(to: event, xFactor: 1, yFactor: 2) == true)
        let output = vertical(event)
        #expect(output.0 == original.0 * 2); #expect(output.1 == original.1 * 2); #expect(output.2 == original.2 * 2)
    }
    @Test func unityPreservesOriginalPixelRatio() {
        var scaler = DiscreteScrollScaler(); let event = wheel(); let original = vertical(event)
        #expect(scaler.apply(to: event, xFactor: 1, yFactor: 1) == true)
        let output = vertical(event)
        #expect(output.0 == original.0); #expect(output.1 == original.1); #expect(output.2 == original.2)
    }
    @Test func fractionalSpeedAccumulatesWholeLinesAndAssociatedFields() {
        var scaler = DiscreteScrollScaler(); let baseline = vertical(wheel())
        var delivered = 0, sumLines = 0.0, sumFixed = 0.0, sumPoints = 0.0
        for _ in 0..<10 {
            let event = wheel()
            if scaler.apply(to: event, xFactor: 1, yFactor: 0.2) {
                delivered += 1; let out = vertical(event); sumLines += out.0; sumFixed += out.1; sumPoints += out.2
            }
        }
        #expect(delivered == 2); #expect(sumLines == baseline.0 * 2)
        #expect(abs(sumFixed - baseline.1 * 2) < 0.00001); #expect(sumPoints == baseline.2 * 2)
    }
    @Test func fractionalAboveOnePreservesTotalDistance() {
        var scaler = DiscreteScrollScaler(); let baseline = vertical(wheel())
        var sumLines = 0.0, sumFixed = 0.0, sumPoints = 0.0
        for _ in 0..<4 {
            let event = wheel(); #expect(scaler.apply(to: event, xFactor: 1, yFactor: 1.5) == true)
            let out = vertical(event); sumLines += out.0; sumFixed += out.1; sumPoints += out.2
        }
        #expect(sumLines == 6); #expect(sumFixed == baseline.1 * 6); #expect(sumPoints == baseline.2 * 6)
    }
    @Test func horizontalAndVerticalBuffersAreIndependent() {
        var scaler = DiscreteScrollScaler()
        let first = wheel(x: 1), second = wheel(x: 1)
        #expect(scaler.apply(to: first, xFactor: -0.5, yFactor: 1) == true)
        #expect(first.getIntegerValueField(.scrollWheelEventDeltaAxis2) == 0)
        #expect(first.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 1)
        #expect(scaler.apply(to: second, xFactor: -0.5, yFactor: 1) == true)
        #expect(second.getIntegerValueField(.scrollWheelEventDeltaAxis2) == -1)
        #expect(second.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 1)
    }
    @Test func resetDropsPendingFraction() {
        var scaler = DiscreteScrollScaler()
        #expect(scaler.apply(to: wheel(), xFactor: 1, yFactor: 0.5) == false); scaler.reset()
        #expect(scaler.apply(to: wheel(), xFactor: 1, yFactor: 0.5) == false)
    }
    @Test func reversingPhysicalDirectionDiscardsOldPartialTick() {
        var scaler = DiscreteScrollScaler()
        #expect(scaler.apply(to: wheel(), xFactor: 1, yFactor: 0.5) == false)
        #expect(scaler.apply(to: wheel(y: -1), xFactor: 1, yFactor: 0.5) == false)
        let last = wheel(y: -1)
        #expect(scaler.apply(to: last, xFactor: 1, yFactor: 0.5) == true)
        #expect(last.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -1)
    }
    @Test func decimalAccumulationDoesNotLoseTheTenthTick() {
        var scaler = DiscreteScrollScaler(); var count: Int64 = 0
        for _ in 0..<10 {
            let event = wheel()
            if scaler.apply(to: event, xFactor: 1, yFactor: 0.3) { count += event.getIntegerValueField(.scrollWheelEventDeltaAxis1) }
        }
        #expect(count == 3)
    }
    @Test func malformedFactorLeavesInputUntouched() {
        var scaler = DiscreteScrollScaler(); let event = wheel(); let before = vertical(event)
        #expect(scaler.apply(to: event, xFactor: 1, yFactor: .nan) == true)
        let after = vertical(event)
        #expect(before.0 == after.0); #expect(before.1 == after.1); #expect(before.2 == after.2)
    }
}
