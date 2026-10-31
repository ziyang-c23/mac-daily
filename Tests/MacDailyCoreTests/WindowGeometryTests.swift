import Foundation
import Testing
@testable import MacDailyCore

struct WindowGeometryTests {
    let screen = CGRect(x: -1440, y: -240, width: 1440, height: 900)
    let current = CGRect(x: -1000, y: -100, width: 600, height: 400)

    @Test func halvesAndQuartersUseTopLeftCoordinates() {
        #expect(WindowGeometry.frame(for: .leftHalf, in: screen, current: current) == CGRect(x: -1440, y: -240, width: 720, height: 900))
        #expect(WindowGeometry.frame(for: .bottomRight, in: screen, current: current) == CGRect(x: -720, y: 210, width: 720, height: 450))
        #expect(WindowGeometry.frame(for: .topHalf, in: screen, current: current)?.minY == -240)
    }
    @Test func thirdsAndTwoThirdsPartitionVisibleArea() throws {
        let left = try #require(WindowGeometry.frame(for: .leftTwoThirds, in: screen, current: current))
        let right = try #require(WindowGeometry.frame(for: .rightThird, in: screen, current: current))
        let center = try #require(WindowGeometry.frame(for: .centerThird, in: screen, current: current))
        #expect(left.maxX == right.minX); #expect(right.maxX == screen.maxX)
        #expect(left.width == 960); #expect(center.midX == screen.midX)
    }
    @Test func gapsAreSharedBetweenTilesAndOutside() throws {
        let left = try #require(WindowGeometry.frame(for: .leftHalf, in: screen, current: current, gap: 10))
        let right = try #require(WindowGeometry.frame(for: .rightHalf, in: screen, current: current, gap: 10))
        #expect(left.minX == screen.minX + 10)
        #expect(right.minX - left.maxX == 10)
        #expect(right.maxX == screen.maxX - 10)
        #expect(left.minY == screen.minY + 10); #expect(left.maxY == screen.maxY - 10)
        let thirds = try #require(WindowGeometry.frame(for: .leftTwoThirds, in: screen, current: current, gap: 10))
        let final = try #require(WindowGeometry.frame(for: .rightThird, in: screen, current: current, gap: 10))
        #expect(abs(final.minX - thirds.maxX - 10) < 0.00001)
    }
    @Test func portraitAndNegativeMonitorFramesStayInsideBounds() throws {
        let portrait = CGRect(x: 1920, y: -700, width: 900, height: 1600)
        for action in WindowAction.allCases where ![.restore, .nextDisplay, .previousDisplay].contains(action) {
            let result = try #require(WindowGeometry.frame(for: action, in: portrait, current: current, gap: 8))
            #expect(portrait.contains(result)); #expect(result.width > 0); #expect(result.height > 0)
        }
    }
    @Test func maximizeUsesVisibleFrameAndCenterPreservesSize() {
        let visible = CGRect(x: 0, y: 30, width: 1470, height: 820)
        #expect(WindowGeometry.frame(for: .maximize, in: visible, current: current) == visible)
        let centered = WindowGeometry.frame(for: .center, in: visible, current: current)
        #expect(centered?.size == current.size)
        #expect(centered?.midX == visible.midX); #expect(centered?.midY == visible.midY)
        let huge = CGRect(x: 0, y: 0, width: 3000, height: 3000)
        #expect(WindowGeometry.frame(for: .center, in: visible, current: huge) == visible)
    }
    @Test func restoreAndDisplayActionsRequireRuntimeHistory() {
        for action in [WindowAction.restore, .nextDisplay, .previousDisplay] {
            #expect(WindowGeometry.frame(for: action, in: screen, current: current) == nil)
        }
    }
    @Test func invalidGeometryIsRejected() {
        #expect(WindowGeometry.frame(for: .maximize, in: .zero, current: current) == nil)
        #expect(WindowGeometry.frame(for: .maximize, in: screen, current: current, gap: -.infinity) == nil)
        #expect(WindowGeometry.frame(for: .maximize, in: screen, current: current, gap: -1) == nil)
        #expect(WindowGeometry.frame(for: .maximize, in: screen, current: current, gap: 100) == nil)
        #expect(WindowGeometry.frame(for: .maximize, in: screen, current: CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)) == nil)
        #expect(WindowGeometry.frame(for: .leftHalf, in: CGRect(x: 0, y: 0, width: 20, height: 20), current: current, gap: 20) == nil)
    }
    @Test func edgeAndCornerZonesHaveDeterministicPriority() {
        let s = CGRect(x: 0, y: 0, width: 1200, height: 900)
        #expect(SnapZoneResolver.action(at: CGPoint(x: 5, y: 5), screen: s) == .topLeft)
        #expect(SnapZoneResolver.action(at: CGPoint(x: 1190, y: 895), screen: s) == .bottomRight)
        #expect(SnapZoneResolver.action(at: CGPoint(x: 600, y: 5), screen: s) == .maximize)
        #expect(SnapZoneResolver.action(at: CGPoint(x: 5, y: 450), screen: s) == .leftHalf)
        #expect(SnapZoneResolver.action(at: CGPoint(x: 1195, y: 450), screen: s) == .rightHalf)
        #expect(SnapZoneResolver.action(at: CGPoint(x: 200, y: 895), screen: s) == .leftThird)
        #expect(SnapZoneResolver.action(at: CGPoint(x: 600, y: 895), screen: s) == .centerThird)
        #expect(SnapZoneResolver.action(at: CGPoint(x: 1000, y: 895), screen: s) == .rightThird)
    }
    @Test func interiorAndDistantOutsideNeverSnap() {
        #expect(SnapZoneResolver.action(at: CGPoint(x: -800, y: 200), screen: screen) == nil)
        #expect(SnapZoneResolver.action(at: CGPoint(x: -1450, y: 200), screen: screen) == nil)
        #expect(SnapZoneResolver.action(at: CGPoint(x: 4, y: 200), screen: screen) == nil)
        #expect(SnapZoneResolver.action(at: CGPoint(x: CGFloat.nan, y: 200), screen: screen) == nil)
        #expect(SnapZoneResolver.action(at: CGPoint(x: -1439, y: 200), screen: screen, threshold: .nan) == nil)
        #expect(SnapZoneResolver.action(at: CGPoint(x: -1439, y: 200), screen: screen) == .leftHalf)
    }
    @Test func bottomSlideExpandsFromEntryThird() {
        let s = CGRect(x: 0, y: 0, width: 1200, height: 900)
        var tracker = SnapZoneTracker()
        #expect(tracker.action(at: CGPoint(x: 200, y: 895), screen: s) == .leftThird)
        #expect(tracker.action(at: CGPoint(x: 600, y: 895), screen: s) == .leftTwoThirds)
        #expect(tracker.action(at: CGPoint(x: 1000, y: 895), screen: s) == .maximize)
        #expect(tracker.action(at: CGPoint(x: 200, y: 895), screen: s) == .leftThird)
        tracker.reset()
        #expect(tracker.action(at: CGPoint(x: 1000, y: 895), screen: s) == .rightThird)
        #expect(tracker.action(at: CGPoint(x: 600, y: 895), screen: s) == .rightTwoThirds)
    }
    @Test func leavingBottomAndChangingScreensResetExpansion() {
        let s = CGRect(x: 0, y: 0, width: 1200, height: 900)
        var tracker = SnapZoneTracker()
        _ = tracker.action(at: CGPoint(x: 200, y: 895), screen: s)
        #expect(tracker.action(at: CGPoint(x: 600, y: 400), screen: s) == nil)
        #expect(tracker.action(at: CGPoint(x: 600, y: 895), screen: s) == .centerThird)
        let next = CGRect(x: -1200, y: -900, width: 1200, height: 900)
        #expect(tracker.action(at: CGPoint(x: -200, y: -5), screen: next) == .rightThird)
    }
}
