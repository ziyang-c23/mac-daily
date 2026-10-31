import Foundation
import Testing
@testable import MacDailyCore

@Suite struct TrackpadTests {
    private let native = NativeTrackpadStatus(lookupThreeFinger: false, threeFingerHorizontal: false,
                                              threeFingerMissionControl: false, threeFingerExpose: false,
                                              threeFingerDrag: false, forceClick: true)
    private func configured() -> TrackpadSettings {
        var settings = TrackpadSettings(); settings.installRecommendedBindings(); return settings
    }
    private func contacts(_ count: Int, x: Double = 0.4, y: Double = 0.5) -> [TrackpadContact] {
        (0..<count).map { .init(id: Int32($0), x: x + Double($0) * 0.03, y: y) }
    }
    private func frame(_ count: Int, time: Double, x: Double = 0.4, y: Double = 0.5,
                       modifiers: UInt64 = 0, app: String = "browser", titlebar: Bool = false) -> TrackpadFrame {
        .init(contacts: contacts(count, x: x, y: y), timestamp: time, modifiers: modifiers,
              bundleIdentifier: app, isTitlebar: titlebar)
    }

    @Test func tapAndSwipeCommitOnceOnFullRelease() {
        var engine = TrackpadGestureEngine(settings: configured())
        let first = engine.process(frame(3, time: 1), native: native)
        #expect(first.sessionStarted); #expect(first.gesture == nil)
        #expect(first.shouldSuppressClick)
        let tap = engine.process(frame(0, time: 1.12), native: native)
        #expect(tap.gesture == .threeTap); #expect(tap.binding?.action == .middleClick)
        #expect(tap.shouldSuppressClick)
        let repeated = engine.process(frame(0, time: 1.14), native: native)
        #expect(repeated.gesture == nil)
        _ = engine.process(frame(3, time: 2), native: native)
        let preview = engine.process(frame(3, time: 2.10, x: 0.58), native: native)
        #expect(preview.preview == .threeRight); #expect(preview.gesture == nil)
        #expect(preview.shouldSuppressScroll)
        #expect(!preview.shouldSuppressClick)
        _ = engine.process(frame(2, time: 2.14, x: 0.58), native: native)
        let swipe = engine.process(frame(0, time: 2.17), native: native)
        #expect(swipe.gesture == .threeRight)
    }

    @Test func fourFingerTapCannotAlsoCommitThreeFingerTap() {
        var engine = TrackpadGestureEngine(settings: configured())
        _ = engine.process(frame(1, time: 1), native: native)
        _ = engine.process(frame(3, time: 1.02), native: native)
        let four = engine.process(frame(4, time: 1.04), native: native)
        #expect(!four.shouldSuppressScroll)
        #expect(four.shouldSuppressClick)
        _ = engine.process(frame(3, time: 1.08), native: native)
        _ = engine.process(frame(1, time: 1.10), native: native)
        let result = engine.process(frame(0, time: 1.12), native: native)
        #expect(result.gesture == .fourTap); #expect(result.binding?.action == .showDashboard)
        #expect(result.shouldSuppressClick)
        _ = engine.process(frame(4, time: 2), native: native)
        let nativeSwipe = engine.process(frame(4, time: 2.1, x: 0.65), native: native)
        #expect(nativeSwipe.captureKind == nil); #expect(!nativeSwipe.shouldSuppressScroll)
        #expect(!nativeSwipe.shouldSuppressClick)
        let end = engine.process(frame(0, time: 2.2), native: native)
        #expect(end.gesture == nil)
        _ = engine.process(frame(3, time: 3), native: native)
        _ = engine.process(frame(3, time: 3.08, x: 0.6), native: native)
        _ = engine.process(frame(4, time: 3.10, x: 0.6), native: native)
        let lateFourth = engine.process(frame(0, time: 3.18), native: native)
        #expect(lateFourth.gesture == nil)
    }

    @Test func movementOfOneFingerPreventsFalseTap() {
        var engine = TrackpadGestureEngine(settings: configured())
        _ = engine.process(frame(3, time: 1), native: native)
        var moved = contacts(3); moved[0].x += 0.08; moved[1].x -= 0.08
        _ = engine.process(.init(contacts: moved, timestamp: 1.08, bundleIdentifier: "browser"), native: native)
        let result = engine.process(frame(0, time: 1.15), native: native)
        #expect(result.gesture == nil)
        _ = engine.process(frame(3, time: 2), native: native)
        var singleFinger = contacts(3); singleFinger[0].x += 0.5
        _ = engine.process(.init(contacts: singleFinger, timestamp: 2.08, bundleIdentifier: "browser"), native: native)
        let singleFingerEnd = engine.process(frame(0, time: 2.15), native: native)
        #expect(singleFingerEnd.gesture == nil)
    }

    @Test func applicationRulesOverrideGlobalAndExcludedAppsPassThrough() {
        var settings = configured()
        settings.bindings.append(.init(gesture: .threeTap, action: .showDashboard, bundleIdentifier: "special"))
        settings.excludedApps.append(.init(bundleIdentifier: "excluded", name: "Excluded"))
        var engine = TrackpadGestureEngine(settings: settings)
        _ = engine.process(frame(3, time: 1, app: "special"), native: native)
        let special = engine.process(frame(0, time: 1.1, app: "special"), native: native)
        #expect(special.binding?.action == .showDashboard)
        let excluded = engine.process(frame(3, time: 2, app: "excluded"), native: native)
        #expect(!engine.isCapturing); #expect(!excluded.shouldSuppressScroll)
        let end = engine.process(frame(0, time: 2.1, app: "excluded"), native: native)
        #expect(end.gesture == nil)
    }

    @Test func nativeConflictsAffectOnlyMatchingGestures() {
        var status = native; status.lookupThreeFinger = true; status.threeFingerHorizontal = true
        var engine = TrackpadGestureEngine(settings: configured())
        let conflictedTap = engine.process(frame(3, time: 1), native: status)
        #expect(!conflictedTap.shouldSuppressClick)
        let horizontal = engine.process(frame(3, time: 1.1, x: 0.60), native: status)
        #expect(horizontal.preview == nil)
        #expect(!horizontal.shouldSuppressScroll)
        let end = engine.process(frame(0, time: 1.2), native: status)
        #expect(end.gesture == nil); #expect(end.feedback?.contains("四指") == true)
        _ = engine.process(frame(3, time: 2), native: status)
        _ = engine.process(frame(3, time: 2.1, y: 0.7), native: status)
        let vertical = engine.process(frame(0, time: 2.2), native: status)
        #expect(vertical.gesture == .threeUp)
        #expect(NativeTrackpadStatus().conflict(for: .threeTap) != nil)
        #expect(NativeTrackpadStatus().conflict(for: .cornerTopLeft) == nil)
    }

    @Test func cornerNeedsItsModifierAndOriginalCorner() {
        var engine = TrackpadGestureEngine(settings: configured())
        _ = engine.process(frame(1, time: 1, x: 0.05, y: 0.95), native: native)
        let ordinary = engine.process(frame(0, time: 1.1), native: native)
        #expect(ordinary.gesture == nil)
        let modifiers = Shortcut.control | Shortcut.option
        let start = engine.process(frame(1, time: 2, x: 0.05, y: 0.95, modifiers: modifiers), native: native)
        #expect(start.shouldSuppressClick)
        let corner = engine.process(frame(0, time: 2.1, modifiers: modifiers), native: native)
        #expect(corner.gesture == .cornerTopLeft); #expect(corner.binding?.action == .window(.topLeft))
    }

    @Test func titlebarGesturesDoNotCaptureContentScrolling() {
        var engine = TrackpadGestureEngine(settings: configured())
        _ = engine.process(frame(2, time: 1, modifiers: Shortcut.option), native: native)
        let content = engine.process(frame(2, time: 1.1, x: 0.6, modifiers: Shortcut.option), native: native)
        #expect(!content.shouldSuppressScroll)
        let end = engine.process(frame(0, time: 1.2, modifiers: Shortcut.option), native: native)
        #expect(end.gesture == nil)
        _ = engine.process(frame(2, time: 2, modifiers: Shortcut.option, titlebar: true), native: native)
        let preview = engine.process(frame(2, time: 2.1, x: 0.6, modifiers: Shortcut.option, titlebar: true), native: native)
        #expect(preview.preview == .titlebarRight); #expect(preview.shouldSuppressScroll)
        let committed = engine.process(frame(0, time: 2.2, modifiers: Shortcut.option), native: native)
        #expect(committed.gesture == .titlebarRight)
    }

    @Test func cancellationAndAppChangesRequireAllFingersToLift() {
        var engine = TrackpadGestureEngine(settings: configured())
        _ = engine.process(frame(3, time: 1), native: native)
        engine.cancel()
        let afterCancel = engine.process(frame(3, time: 1.1, x: 0.6), native: native)
        #expect(afterCancel.preview == nil)
        _ = engine.process(frame(0, time: 1.2), native: native)
        _ = engine.process(frame(3, time: 2), native: native)
        let changed = engine.process(frame(3, time: 2.1, x: 0.6, app: "other"), native: native)
        #expect(changed.sessionEnded); #expect(!engine.isCapturing)
        let released = engine.process(frame(0, time: 2.2, app: "other"), native: native)
        #expect(released.gesture == nil)
        _ = engine.process(frame(3, time: 3), native: native)
        engine.reset()
        _ = engine.process(frame(3, time: 4), native: native)
        let afterRestart = engine.process(frame(0, time: 4.1), native: native)
        #expect(afterRestart.gesture == .threeTap)
    }

    @Test func settingsRoundTripKeepsScopesAndActions() throws {
        var settings = configured()
        settings.bindings.append(.init(gesture: .threeTap, action: .quick(.keepAwake), bundleIdentifier: "special"))
        #expect(try JSONDecoder().decode(TrackpadSettings.self, from: JSONEncoder().encode(settings)) == settings)
        #expect(try settings.validated() == settings)
        let count = settings.bindings.count
        settings.installRecommendedBindings()
        #expect(settings.bindings.count == count)
    }
}
