import Foundation

/// Small pure policies shared by explicit tiling and delayed drag commits.
public enum WindowTransitionPolicy {
    /// A run of layout changes keeps its first baseline. A manually moved or
    /// resized window starts a new run, so Restore returns to that newer frame.
    public static func restoreBaseline(current: CGRect, previousOriginal: CGRect?, previousApplied: CGRect?, tolerance: CGFloat = 6) -> CGRect {
        guard WindowGeometry.isValid(current), let original = previousOriginal, let applied = previousApplied,
              WindowGeometry.isValid(original), WindowGeometry.isValid(applied), tolerance.isFinite, tolerance >= 0 else { return current }
        let stillApplied = abs(current.minX - applied.minX) <= tolerance
            && abs(current.minY - applied.minY) <= tolerance
            && abs(current.width - applied.width) <= tolerance
            && abs(current.height - applied.height) <= tolerance
        return stillApplied ? original : current
    }

    /// A delayed release must not affect the old application after Escape, a
    /// new drag, a settings change, or an application switch.
    public static func mayCommit(capturedGeneration: UInt64, currentGeneration: UInt64, targetPID: Int32, foregroundPID: Int32?) -> Bool {
        capturedGeneration == currentGeneration && targetPID > 0 && foregroundPID == targetPID
    }
}
