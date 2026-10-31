import Testing
@testable import MacDailyCore

struct WindowTargetPolicyTests {
    @Test func layoutButtonsStayPinnedWhenFocusMovesOutsidePractice() {
        // targetIsPractice=false models an external app becoming frontmost.
        #expect(WindowTargetPolicy.route(practiceActive: true, practiceAvailable: true, invocation: .explicitLayout,
                                         targetIsPractice: false) == .practice)
        #expect(WindowTargetPolicy.route(practiceActive: true, practiceAvailable: true, invocation: .explicitLayout,
                                         targetIsPractice: true) == .practice)
    }
    @Test func externalMouseBindingsAreDeniedInsteadOfRedirected() {
        #expect(WindowTargetPolicy.route(practiceActive: true, practiceAvailable: true, invocation: .mouseBinding,
                                         targetIsPractice: false) == .deny)
    }
    @Test func nativeDraggingAnotherWindowCannotEscapePracticeMode() {
        #expect(WindowTargetPolicy.route(practiceActive: true, practiceAvailable: true, invocation: .drag,
                                         targetIsPractice: false) == .deny)
    }
    @Test func bindingsAndDragsMayOperateOnThePracticeWindowItself() {
        for invocation in [WindowInvocation.mouseBinding, .drag] {
            #expect(WindowTargetPolicy.route(practiceActive: true, practiceAvailable: true, invocation: invocation,
                                             targetIsPractice: true) == .practice)
        }
    }
    @Test func closedPracticeNeverFallsBackToARealApplication() {
        for invocation in WindowInvocation.allCases {
            for stalePracticeTarget in [false, true] {
                #expect(WindowTargetPolicy.route(practiceActive: true, practiceAvailable: false, invocation: invocation,
                                                 targetIsPractice: stalePracticeTarget) == .deny)
            }
        }
    }
    @Test func explicitlyEndingPracticePermitsRegularTargeting() {
        for invocation in WindowInvocation.allCases {
            for available in [false, true] {
                #expect(WindowTargetPolicy.route(practiceActive: false, practiceAvailable: available, invocation: invocation,
                                                 targetIsPractice: false) == .regular)
            }
        }
    }
    @Test func activePracticeHasNoRouteToRegularTargets() {
        for invocation in WindowInvocation.allCases {
            for available in [false, true] {
                for targetIsPractice in [false, true] {
                    #expect(WindowTargetPolicy.route(practiceActive: true, practiceAvailable: available, invocation: invocation,
                                                     targetIsPractice: targetIsPractice) != .regular)
                }
            }
        }
    }
}
