import Foundation
import Testing
@testable import MacDailyCore

struct WindowTransitionPolicyTests {
    let original = CGRect(x: 100, y: 140, width: 700, height: 500)
    let tiled = CGRect(x: 0, y: 30, width: 720, height: 870)

    @Test func repeatedLayoutsKeepFirstUnsnappedFrame() {
        let baseline = WindowTransitionPolicy.restoreBaseline(current: tiled, previousOriginal: original, previousApplied: tiled)
        #expect(baseline == original)
        let next = CGRect(x: 720, y: 30, width: 720, height: 870)
        #expect(WindowTransitionPolicy.restoreBaseline(current: next, previousOriginal: baseline, previousApplied: next) == original)
    }
    @Test func manualMoveStartsANewRestoreBaseline() {
        let manuallyMoved = CGRect(x: 240, y: 180, width: tiled.width, height: tiled.height)
        #expect(WindowTransitionPolicy.restoreBaseline(current: manuallyMoved, previousOriginal: original, previousApplied: tiled) == manuallyMoved)
    }
    @Test func manualResizeStartsANewRestoreBaseline() {
        let manuallyResized = CGRect(x: tiled.minX, y: tiled.minY, width: 900, height: 600)
        #expect(WindowTransitionPolicy.restoreBaseline(current: manuallyResized, previousOriginal: original, previousApplied: tiled) == manuallyResized)
    }
    @Test func missingOrInvalidHistoryKeepsCurrentFrame() {
        #expect(WindowTransitionPolicy.restoreBaseline(current: tiled, previousOriginal: nil, previousApplied: nil) == tiled)
        #expect(WindowTransitionPolicy.restoreBaseline(current: tiled, previousOriginal: .zero, previousApplied: tiled) == tiled)
        #expect(WindowTransitionPolicy.restoreBaseline(current: tiled, previousOriginal: original, previousApplied: tiled, tolerance: .nan) == tiled)
    }
    @Test func systemRoundingWithinToleranceKeepsRestoreBaseline() {
        let rounded = CGRect(x: tiled.minX + 1, y: tiled.minY, width: tiled.width - 1, height: tiled.height)
        #expect(WindowTransitionPolicy.restoreBaseline(current: rounded, previousOriginal: original, previousApplied: tiled) == original)
    }
    @Test func delayedCommitRequiresSameGenerationAndForegroundApplication() {
        #expect(WindowTransitionPolicy.mayCommit(capturedGeneration: 12, currentGeneration: 12, targetPID: 123, foregroundPID: 123))
        #expect(!WindowTransitionPolicy.mayCommit(capturedGeneration: 12, currentGeneration: 13, targetPID: 123, foregroundPID: 123))
        #expect(!WindowTransitionPolicy.mayCommit(capturedGeneration: 12, currentGeneration: 12, targetPID: 123, foregroundPID: 456))
        #expect(!WindowTransitionPolicy.mayCommit(capturedGeneration: 12, currentGeneration: 12, targetPID: 123, foregroundPID: nil))
        #expect(!WindowTransitionPolicy.mayCommit(capturedGeneration: 12, currentGeneration: 12, targetPID: 0, foregroundPID: 0))
    }
}
