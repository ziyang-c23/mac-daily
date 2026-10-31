import Foundation

public enum WindowInvocation: CaseIterable, Equatable, Sendable {
    case explicitLayout
    case mouseBinding
    case drag
}

public enum WindowTargetRoute: Equatable, Sendable {
    case practice
    case regular
    case deny
}

/// Practice is an explicit, sticky targeting mode. Frontmost-application changes
/// never authorize leaving it. A closed practice window means no target, not a
/// fallback to whatever real application happened to be active most recently.
public enum WindowTargetPolicy {
    public static func route(practiceActive: Bool, practiceAvailable: Bool, invocation: WindowInvocation,
                             targetIsPractice: Bool = false) -> WindowTargetRoute {
        guard practiceActive else { return .regular }
        guard practiceAvailable else { return .deny }
        switch invocation {
        case .explicitLayout: return .practice
        case .mouseBinding, .drag: return targetIsPractice ? .practice : .deny
        }
    }
}
