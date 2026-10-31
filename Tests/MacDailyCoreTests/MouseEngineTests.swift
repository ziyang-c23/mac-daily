import Testing
@testable import MacDailyCore

struct MouseEngineTests {
    private let back = Shortcut(keyCode: 33, modifiers: Shortcut.command, label: "Back")
    private func config(_ triggers: [MouseTrigger], button: Int = 2, modifiers: UInt64 = 0) -> MouseConfiguration {
        var c = MouseConfiguration()
        c.bindings = triggers.map { MouseBinding(enabled: true, button: button, trigger: $0, modifiers: modifiers, shortcut: back) }
        return c
    }
    private func event(_ kind: MouseInput.Kind, button: Int = 2, x: Double = 100, y: Double = 100,
                       t: Double = 1, modifiers: UInt64 = 0, app: String = "test.app", dy: Double = 0,
                       synthetic: Bool = false, continuous: Bool = false, mouse: Bool = true) -> MouseInput {
        MouseInput(kind: kind, button: button, x: x, y: y, timestamp: t,
                   modifiers: modifiers, bundleIdentifier: app, deltaY: dy,
                   isContinuous: continuous, isSynthetic: synthetic, isMouse: mouse)
    }
    @Test func testDefaultsDoNotCaptureButtons() {
        var e = MouseEngine()
        #expect(!(e.process(event(.buttonDown)).consumed))
        #expect(!(e.process(event(.buttonUp, t: 1.1)).consumed))
    }
    @Test func testClickEmitsExactlyOneShortcutAtRelease() {
        var e = MouseEngine(configuration: config([.click]))
        #expect(e.process(event(.buttonDown)).consumed)
        let up = e.process(event(.buttonUp, t: 1.1))
        #expect(up.shortcuts == [back]); #expect(up.replay.isEmpty)
        #expect(!(e.process(event(.buttonUp, t: 1.2)).consumed))
    }
    @Test func testGestureOnlyShortPressReplaysNativeClick() {
        var e = MouseEngine(configuration: config([.swipeUp], button: 1))
        let down = event(.buttonDown, button: 1)
        let up = event(.buttonUp, button: 1, t: 1.2)
        _ = e.process(down)
        let out = e.process(up)
        #expect(out.replay == [down, up]); #expect(out.shortcuts.isEmpty)
    }
    @Test func testClickBindingDoesNotStealNativeDrag() {
        var e = MouseEngine(configuration: config([.click]))
        let down = event(.buttonDown)
        let move = event(.move, x: 110, t: 1.1)
        _ = e.process(down)
        #expect(e.process(move).replay == [down, move])
        #expect(!(e.process(event(.move, x: 140, t: 1.2)).consumed))
        #expect(!(e.process(event(.buttonUp, x: 140, t: 1.3)).consumed))
    }
    @Test func testRecognizedGestureSuppressesNativeClick() {
        var e = MouseEngine(configuration: config([.click, .swipeUp]))
        _ = e.process(event(.buttonDown))
        #expect(e.process(event(.move, y: 50, t: 1.1)).consumed)
        let out = e.process(event(.buttonUp, y: 50, t: 1.2))
        #expect(out.shortcuts == [back]); #expect(out.replay.isEmpty)
    }
    @Test func testUnsupportedDirectionFallsBackToNativeDrag() {
        var e = MouseEngine(configuration: config([.swipeUp]))
        let down = event(.buttonDown), move = event(.move, x: 180, t: 1.1)
        _ = e.process(down)
        #expect(e.process(move).replay == [down, move])
        #expect(!(e.process(event(.buttonUp, x: 180, t: 1.2)).consumed))
    }
    @Test func testDiagonalDoesNotBecomeAnUnrelatedGesture() {
        var e = MouseEngine(configuration: config([.click, .swipeUp, .swipeRight]))
        _ = e.process(event(.buttonDown))
        let move = e.process(event(.move, x: 150, y: 50, t: 1.1))
        let out = e.process(event(.buttonUp, x: 150, y: 50, t: 1.2))
        #expect(move.replay.count == 2)
        #expect(out.shortcuts.isEmpty); #expect(!out.consumed)
    }
    @Test func testReturningStrokeNeverBecomesClick() {
        var e = MouseEngine(configuration: config([.click, .swipeUp]))
        _ = e.process(event(.buttonDown))
        _ = e.process(event(.move, y: 50, t: 1.1))
        let out = e.process(event(.buttonUp, t: 1.2))
        #expect(out.shortcuts.isEmpty); #expect(out.replay.count == 3)
    }
    @Test func testComboConsumesWheelAndSuppressesReleaseClick() {
        var e = MouseEngine(configuration: config([.click, .scrollUp]))
        _ = e.process(event(.buttonDown))
        #expect(e.process(event(.scroll, t: 1.1, dy: 1)).shortcuts == [back])
        let tail = e.process(event(.scroll, t: 1.15, dy: 1))
        #expect(tail.consumed); #expect(tail.shortcuts.isEmpty)
        #expect(e.process(event(.scroll, t: 1.3, dy: 1)).shortcuts == [back])
        let up = e.process(event(.buttonUp, t: 1.4))
        #expect(up.consumed); #expect(up.shortcuts.isEmpty); #expect(up.replay.isEmpty)
    }
    @Test func testTouchScrollCannotTriggerHeldMouseCombo() {
        var e = MouseEngine(configuration: config([.scrollUp]))
        _ = e.process(event(.buttonDown))
        #expect(!(e.process(event(.scroll, t: 1.1, dy: 4, continuous: true)).consumed))
        #expect(e.process(event(.buttonUp, t: 1.2)).shortcuts.isEmpty)
    }
    @Test func testUnmappedWheelPreservesNativeOrdering() {
        var e = MouseEngine(configuration: config([.scrollUp]))
        let down = event(.buttonDown), wheel = event(.scroll, t: 1.1, dy: -1)
        _ = e.process(down)
        #expect(e.process(wheel).replay == [down, wheel])
        #expect(!(e.process(event(.buttonUp, t: 1.2)).consumed))
    }
    @Test func testSyntheticReplayCannotMutateSession() {
        var e = MouseEngine(configuration: config([.click]))
        _ = e.process(event(.buttonDown))
        #expect(!(e.process(event(.buttonUp, t: 1.1, app: "other.app", synthetic: true)).consumed))
        #expect(e.isCapturing)
        #expect(e.process(event(.buttonUp, t: 1.2)).shortcuts == [back])
    }
    @Test func testApplicationChangeCancelsAndSuppressesPhysicalUp() {
        var e = MouseEngine(configuration: config([.click]))
        _ = e.process(event(.buttonDown))
        let out = e.process(event(.buttonUp, t: 1.2, app: "other.app"))
        #expect(out.consumed); #expect(out.shortcuts.isEmpty); #expect(out.replay.isEmpty)
        #expect(!(e.isCapturing)); #expect(e.pendingReleaseButtons.isEmpty)
    }
    @Test func testEscapeOrPauseCancelsWithoutAction() {
        var e = MouseEngine(configuration: config([.click]))
        _ = e.process(event(.buttonDown)); _ = e.cancel()
        #expect(e.pendingReleaseButtons == [2])
        let out = e.process(event(.buttonUp, t: 1.2))
        #expect(out.consumed); #expect(out.shortcuts.isEmpty); #expect(out.replay.isEmpty)
    }
    @Test func testConfigurationChangeNeverFiresOldOrNewBinding() {
        var e = MouseEngine(configuration: config([.click]))
        _ = e.process(event(.buttonDown)); _ = e.update(configuration: MouseConfiguration())
        #expect(e.process(event(.buttonUp, t: 1.2)).shortcuts.isEmpty)
    }
    @Test func testModifiersMustMatchExactly() {
        var e = MouseEngine(configuration: config([.click], modifiers: Shortcut.option))
        #expect(!(e.process(event(.buttonDown)).consumed))
        #expect(!(e.process(event(.buttonDown, modifiers: Shortcut.option | Shortcut.shift)).consumed))
        #expect(e.process(event(.buttonDown, modifiers: Shortcut.option)).consumed)
        let out = e.process(event(.buttonUp, t: 1.2))
        #expect(out.shortcuts.isEmpty); #expect(out.consumed)
    }
    @Test func testDeviceSpecificFlagBitsAreIgnored() {
        var e = MouseEngine(configuration: config([.click], modifiers: Shortcut.command))
        #expect(e.process(event(.buttonDown, modifiers: Shortcut.command | 0x108)).consumed)
        #expect(e.process(event(.buttonUp, t: 1.2, modifiers: Shortcut.command)).shortcuts == [back])
    }
    @Test func testApplicationExceptionsCanDisableOnlyGestures() {
        var c = config([.click, .swipeUp])
        c.exceptions = [.init(bundleIdentifier: "test.app", name: "Test", disableScrolling: false, disableBindings: false, disableGestures: true)]
        var e = MouseEngine(configuration: c)
        _ = e.process(event(.buttonDown))
        #expect(!(e.process(event(.move, y: 50, t: 1.1)).replay.isEmpty))
        #expect(!(e.process(event(.buttonUp, y: 50, t: 1.2)).consumed))
    }
    @Test func testApplicationExceptionsCanDisableOnlyBindings() {
        var c = config([.click, .swipeUp])
        c.exceptions = [.init(bundleIdentifier: "test.app", name: "Test", disableScrolling: false, disableBindings: true, disableGestures: false)]
        var e = MouseEngine(configuration: c)
        _ = e.process(event(.buttonDown))
        #expect(e.process(event(.buttonUp, y: 50, t: 1.2)).shortcuts == [back])
    }
    @Test func testUnwatchedButtonsAndTrackpadPassThrough() {
        var e = MouseEngine(configuration: config([.click]))
        #expect(!(e.process(event(.buttonDown, button: 0)).consumed))
        #expect(!(e.process(event(.buttonDown, mouse: false)).consumed))
        #expect(!(e.isCapturing))
    }
    @Test func testSecondButtonCancelsCaptureWithoutSwallowingNewDown() {
        var e = MouseEngine(configuration: config([.click]))
        _ = e.process(event(.buttonDown))
        #expect(!(e.process(event(.buttonDown, button: 0, t: 1.1)).consumed))
        #expect(e.process(event(.buttonUp, t: 1.2)).consumed)
        #expect(!(e.process(event(.buttonUp, button: 0, t: 1.3)).consumed))
    }
    @Test func testHighPollingRateDoesNotPreventValidGesture() {
        var e = MouseEngine(configuration: config([.swipeUp]))
        _ = e.process(event(.buttonDown))
        for i in 0..<1_000 {
            let out = e.process(event(.move, y: 98, t: 1 + Double(i) / 1000))
            #expect(out.consumed); #expect(out.replay.isEmpty)
        }
        #expect(e.process(event(.buttonUp, y: 50, t: 2.1)).shortcuts == [back])
    }
    @Test func testCoalescedFallbackKeepsBufferBoundedAndPreservesDelta() {
        var e = MouseEngine(configuration: config([.swipeUp]))
        _ = e.process(event(.buttonDown))
        for i in 0..<1_000 {
            var input = event(.move, y: 98, t: 1 + Double(i) / 1000)
            input.deltaX = 0.01; input.deltaY = -0.02
            _ = e.process(input)
        }
        let out = e.process(event(.buttonUp, x: 150, y: 50, t: 2.1))
        #expect(out.shortcuts.isEmpty); #expect(out.replay.count <= 130)
        #expect(abs(out.replay.reduce(0) { $0 + $1.deltaX } - 10) < 0.00001)
        #expect(abs(out.replay.reduce(0) { $0 + $1.deltaY } + 20) < 0.00001)
    }
    @Test func testLongCaptureFallsBackWithoutAction() {
        var e = MouseEngine(configuration: config([.swipeUp]))
        _ = e.process(event(.buttonDown))
        let out = e.process(event(.move, y: 98, t: 7))
        #expect(out.replay.count == 2); #expect(!e.isCapturing)
        #expect(!e.process(event(.buttonUp, t: 7.1)).consumed)
    }
    @Test func testNewDownAfterMissedReleaseCanStartNewSession() {
        var e = MouseEngine(configuration: config([.click]))
        _ = e.process(event(.buttonDown)); _ = e.cancel()
        #expect(e.process(event(.buttonDown, t: 2)).consumed)
        #expect(e.process(event(.buttonUp, t: 2.1)).shortcuts == [back])
    }
}
