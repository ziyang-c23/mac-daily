import Testing
@testable import MacDailyCore

struct InputSuspensionTests {
    @Test func gestureThenRecordingResumesOnlyAfterBothEnd() {
        var state = InputSuspensionState()
        state.begin(.gestureTest,wasRunning:true)
        state.begin(.shortcutRecording,wasRunning:false)
        do { let resumed = state.end(.gestureTest); #expect(!resumed) }; #expect(state.isSuspended)
        do { let resumed = state.end(.shortcutRecording); #expect(resumed) }; #expect(!state.isSuspended)
        do { let resumed = state.end(.shortcutRecording); #expect(!resumed) }
    }
    @Test func recordingThenGestureResumesOnlyAfterBothEnd() {
        var state = InputSuspensionState()
        state.begin(.shortcutRecording,wasRunning:true)
        state.begin(.gestureTest,wasRunning:false)
        do { let resumed = state.end(.shortcutRecording); #expect(!resumed) }; #expect(state.isSuspended)
        do { let resumed = state.end(.gestureTest); #expect(resumed) }; #expect(!state.isSuspended)
    }
    @Test func oppositeEndOrderKeepsTheSameIntent() {
        var state = InputSuspensionState()
        state.begin(.gestureTest,wasRunning:true)
        state.begin(.shortcutRecording,wasRunning:false)
        do { let resumed = state.end(.shortcutRecording); #expect(!resumed) }; do { let resumed = state.end(.gestureTest); #expect(resumed) }
    }
    @Test func repeatedMountsBalanceBeforeResuming() {
        var state = InputSuspensionState()
        state.begin(.gestureTest,wasRunning:true)
        state.begin(.gestureTest,wasRunning:false)
        #expect(state.count(for:.gestureTest) == 2)
        do { let resumed = state.end(.gestureTest); #expect(!resumed) }; #expect(state.count(for:.gestureTest) == 1)
        do { let resumed = state.end(.gestureTest); #expect(resumed) }; #expect(state.count(for:.gestureTest) == 0)
    }
    @Test func unmatchedEndCannotConsumeAnotherActivitysIntent() {
        var state = InputSuspensionState()
        state.begin(.gestureTest,wasRunning:true)
        do { let resumed = state.end(.shortcutRecording); #expect(!resumed) }; #expect(state.count(for:.gestureTest) == 1)
        do { let resumed = state.end(.gestureTest); #expect(resumed) }
    }
    @Test func deliberatePausePreventsAutomaticRestart() {
        var state = InputSuspensionState()
        state.begin(.gestureTest,wasRunning:true)
        state.begin(.shortcutRecording,wasRunning:false)
        state.cancelResume()
        do { let resumed = state.end(.gestureTest); #expect(!resumed) }; do { let resumed = state.end(.shortcutRecording); #expect(!resumed) }
        #expect(!state.isSuspended)
    }
    @Test func initiallyPausedInputRemainsPaused() {
        var state = InputSuspensionState()
        state.begin(.gestureTest,wasRunning:false)
        do { let resumed = state.end(.gestureTest); #expect(!resumed) }; #expect(!state.isSuspended)
    }
    @Test func resetDiscardsCountsAndResumeOnTermination() {
        var state = InputSuspensionState()
        state.begin(.gestureTest,wasRunning:true)
        state.begin(.shortcutRecording,wasRunning:false)
        state.reset()
        #expect(!state.isSuspended)
        #expect(state.count(for:.gestureTest) == 0 && state.count(for:.shortcutRecording) == 0)
        do { let resumed = state.end(.gestureTest); #expect(!resumed) }; do { let resumed = state.end(.shortcutRecording); #expect(!resumed) }
    }
    @Test func completedCyclesCannotLeakOldResumeIntent() {
        var state = InputSuspensionState()
        state.begin(.gestureTest,wasRunning:true)
        do { let resumed = state.end(.gestureTest); #expect(resumed) }
        state.begin(.gestureTest,wasRunning:false)
        do { let resumed = state.end(.gestureTest); #expect(!resumed) }
        state.begin(.shortcutRecording,wasRunning:true)
        do { let resumed = state.end(.shortcutRecording); #expect(resumed) }
    }
}
