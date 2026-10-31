/// Short-lived UI activities share one resume intent. Overlapping activities
/// cannot lose the original running state or resume while another is active.
public enum InputSuspensionReason: Hashable, Sendable {
    case gestureTest
    case shortcutRecording
    case keyboardCleaning
}

public struct InputSuspensionState: Sendable {
    private var counts: [InputSuspensionReason: Int] = [:]
    private var resumeWhenReleased = false
    public init() {}
    public var isSuspended: Bool { !counts.isEmpty }
    public func count(for reason: InputSuspensionReason) -> Int { counts[reason] ?? 0 }

    public mutating func begin(_ reason: InputSuspensionReason, wasRunning: Bool) {
        counts[reason, default: 0] += 1
        resumeWhenReleased = resumeWhenReleased || wasRunning
    }

    /// Only the final matched end consumes the resume intent. An unmatched end
    /// neither resumes input nor steals intent belonging to an active activity.
    @discardableResult
    public mutating func end(_ reason: InputSuspensionReason) -> Bool {
        guard let count = counts[reason], count > 0 else { return false }
        if count == 1 { counts.removeValue(forKey: reason) }
        else { counts[reason] = count - 1 }
        guard !isSuspended else { return false }
        let shouldResume = resumeWhenReleased
        resumeWhenReleased = false
        return shouldResume
    }

    /// A deliberate pause wins over earlier automatic-resume intent.
    public mutating func cancelResume() { resumeWhenReleased = false }
    public mutating func reset() { counts.removeAll(); resumeWhenReleased = false }
}
