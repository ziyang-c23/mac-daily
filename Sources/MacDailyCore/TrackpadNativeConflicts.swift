import Foundation

public struct NativeTrackpadStatus: Equatable, Sendable {
    public var lookupThreeFinger: Bool?
    public var threeFingerHorizontal: Bool?
    public var threeFingerMissionControl: Bool?
    public var threeFingerExpose: Bool?
    public var threeFingerDrag: Bool?
    public var forceClick: Bool?
    public init(lookupThreeFinger: Bool? = nil, threeFingerHorizontal: Bool? = nil,
                threeFingerMissionControl: Bool? = nil, threeFingerExpose: Bool? = nil,
                threeFingerDrag: Bool? = nil, forceClick: Bool? = nil) {
        self.lookupThreeFinger = lookupThreeFinger; self.threeFingerHorizontal = threeFingerHorizontal
        self.threeFingerMissionControl = threeFingerMissionControl; self.threeFingerExpose = threeFingerExpose
        self.threeFingerDrag = threeFingerDrag; self.forceClick = forceClick
    }
    public func conflict(for gesture: TrackpadGesture) -> String? {
        switch gesture {
        case .threeTap:
            if let drag = check(threeFingerDrag, conflict: L10n.text("三指拖移已开启"), unknown: L10n.text("尚未读取到三指拖移设置")) { return drag }
            return check(lookupThreeFinger, conflict: L10n.text("三指轻点用于系统查询，请改为单指用力点按"), unknown: L10n.text("尚未读取到系统查询手势"))
        case .threeLeft, .threeRight:
            if let drag = check(threeFingerDrag, conflict: L10n.text("三指拖移已开启"), unknown: L10n.text("尚未读取到三指拖移设置")) { return drag }
            return check(threeFingerHorizontal, conflict: L10n.text("系统仍使用三指切换全屏应用，请改为四指"), unknown: L10n.text("尚未读取到系统水平轻扫设置"))
        case .threeUp:
            if let drag = check(threeFingerDrag, conflict: L10n.text("三指拖移已开启"), unknown: L10n.text("尚未读取到三指拖移设置")) { return drag }
            return check(threeFingerMissionControl, conflict: L10n.text("系统仍使用三指打开调度中心，请改为四指"), unknown: L10n.text("尚未读取到调度中心手势"))
        case .threeDown:
            if let drag = check(threeFingerDrag, conflict: L10n.text("三指拖移已开启"), unknown: L10n.text("尚未读取到三指拖移设置")) { return drag }
            return check(threeFingerExpose, conflict: L10n.text("系统仍使用三指打开 App Exposé，请改为四指"), unknown: L10n.text("尚未读取到 App Exposé 手势"))
        default: return nil
        }
    }
    private func check(_ value: Bool?, conflict: String, unknown: String) -> String? {
        guard let value else { return unknown }
        return value ? conflict : nil
    }
}
