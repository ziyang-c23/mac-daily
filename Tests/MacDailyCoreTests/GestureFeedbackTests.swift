import Foundation
import Testing
@testable import MacDailyCore

struct GestureFeedbackTests {
    private let shortcut = Shortcut(keyCode: 126, modifiers: Shortcut.control, label: "测试动作")
    private let directions: [MouseTrigger] = [.swipeUp, .swipeDown, .swipeLeft, .swipeRight]

    private func configuration(_ triggers: [MouseTrigger], button: Int = 2) -> MouseConfiguration {
        var config = MouseConfiguration()
        config.bindings = triggers.map { .init(enabled: true, button: button, trigger: $0, shortcut: shortcut) }
        return config
    }
    private func event(_ kind: MouseInput.Kind, x: Double = 0, y: Double = 0, time: Double = 1,
                       button: Int = 2, app: String = "org.macdaily.fixture", modifiers: UInt64 = 0,
                       wheel: Double = 0) -> MouseInput {
        .init(kind: kind, button: button, x: x, y: y, timestamp: time, modifiers: modifiers,
              bundleIdentifier: app, deltaY: wheel)
    }
    @Test func fourDirectionsReportRecognitionOnlyOnRelease() {
        let cases: [(Double, Double, MouseTrigger)] = [(5,-70,.swipeUp),(-4,70,.swipeDown),(-70,6,.swipeLeft),(70,-5,.swipeRight)]
        for (x,y,expected) in cases {
            var engine = MouseEngine(configuration: configuration(directions))
            let down = engine.process(event(.buttonDown))
            #expect(down.feedback?.contains("已按住") == true)
            let move = engine.process(event(.move,x:x,y:y,time:1.1))
            #expect(move.feedback?.contains("已就绪") == true)
            #expect(move.shortcuts.isEmpty && move.windowActions.isEmpty)
            let up = engine.process(event(.buttonUp,x:x,y:y,time:1.2))
            #expect(up.shortcuts == [shortcut]); #expect(up.replay.isEmpty)
            #expect(up.feedback == "已识别：\(GestureDirectionRecognizer.title(for:expected))")
        }
    }
    @Test func partialProfileAllowsInitialWrongDirectionWithinGrace() {
        var engine = MouseEngine(configuration: configuration([.swipeUp]))
        _ = engine.process(event(.buttonDown))
        let wobble = engine.process(event(.move,x:48,y:0,time:1.1))
        #expect(wobble.replay.isEmpty && wobble.consumed)
        #expect(wobble.feedback == "向右尚未配置")
        let upward = engine.process(event(.move,x:24,y:-90,time:1.2))
        #expect(upward.replay.isEmpty)
        let up = engine.process(event(.buttonUp,x:24,y:-90,time:1.3))
        #expect(up.shortcuts == [shortcut]); #expect(up.feedback == "已识别：向上")
    }
    @Test func unsupportedDirectionBeyondGraceReplaysAndExplains() {
        var engine = MouseEngine(configuration: configuration([.swipeUp]))
        let down = event(.buttonDown), move = event(.move,x:80,time:1.1)
        _ = engine.process(down)
        let result = engine.process(move)
        #expect(result.replay == [down,move]); #expect(result.feedback?.contains("未设置向右") == true)
        #expect(!engine.isCapturing)
        #expect(!engine.process(event(.buttonUp,x:80,time:1.2)).consumed)
    }
    @Test func diagonalReleaseExplainsWithoutFiring() {
        var engine = MouseEngine(configuration: configuration(directions))
        _ = engine.process(event(.buttonDown))
        let move = engine.process(event(.move,x:60,y:-60,time:1.1))
        #expect(move.feedback == "未设置右上，保留原生拖动")
        #expect(move.replay.count == 2)
        let result = engine.process(event(.buttonUp,x:60,y:-60,time:1.2))
        #expect(result.shortcuts.isEmpty && result.windowActions.isEmpty)
        #expect(!result.consumed)
    }
    @Test func shortStrokeReportsThreshold() {
        var engine = MouseEngine(configuration: configuration([.swipeUp]))
        _ = engine.process(event(.buttonDown))
        let result = engine.process(event(.buttonUp,y:-12,time:1.1))
        #expect(result.shortcuts.isEmpty)
        #expect(result.feedback == "距离不足（12 / 36 pt）")
    }
    @Test func directionAtExactThresholdIsAccepted() {
        var engine = MouseEngine(configuration: configuration([.swipeUp]))
        _ = engine.process(event(.buttonDown))
        let result = engine.process(event(.buttonUp,y:-36,time:1.1))
        #expect(result.shortcuts == [shortcut]); #expect(result.feedback == "已识别：向上")
    }
    @Test func outAndBackDoesNotBecomeClick() {
        var engine = MouseEngine(configuration: configuration([.click,.swipeUp]))
        _ = engine.process(event(.buttonDown))
        _ = engine.process(event(.move,y:-60,time:1.1))
        let result = engine.process(event(.buttonUp,time:1.2))
        #expect(result.shortcuts.isEmpty)
        #expect(result.feedback == "已回到起点，未触发手势")
    }
    @Test func feedbackDoesNotRepeatForEveryMovePacket() {
        var engine = MouseEngine(configuration: configuration([.swipeUp]))
        _ = engine.process(event(.buttonDown))
        #expect(engine.process(event(.move,y:-40,time:1.1)).feedback != nil)
        for i in 1...100 {
            let next = engine.process(event(.move,y:-40-Double(i)/10,time:1.1+Double(i)/1000))
            #expect(next.feedback == nil)
        }
    }
    @Test func disabledRulesRemainNativeAndSilent() {
        var config = configuration(directions)
        for i in config.bindings.indices { config.bindings[i].enabled = false }
        var engine = MouseEngine(configuration:config)
        let down = engine.process(event(.buttonDown))
        let up = engine.process(event(.buttonUp,y:-80,time:1.2))
        #expect(!down.consumed && down.feedback == nil)
        #expect(!up.consumed && up.shortcuts.isEmpty && up.feedback == nil)
    }
    @Test func cancellationReasonSurvivesBalancedRelease() {
        var engine = MouseEngine(configuration:configuration(directions))
        _ = engine.process(event(.buttonDown))
        let cancellation = engine.cancel(reason:"测试已结束")
        #expect(cancellation.feedback == "测试已结束")
        #expect(engine.pendingReleaseButtons == [2])
        let up = engine.process(event(.buttonUp,y:-80,time:1.2))
        #expect(up.consumed && up.shortcuts.isEmpty)
        #expect(engine.pendingReleaseButtons.isEmpty)
    }
    @Test func applicationSwitchExplainsCancellation() {
        var engine = MouseEngine(configuration:configuration(directions))
        _ = engine.process(event(.buttonDown))
        let result = engine.process(event(.buttonUp,y:-80,time:1.2,app:"other.app"))
        #expect(result.shortcuts.isEmpty)
        #expect(result.feedback?.contains("应用已切换") == true)
    }
    @Test func modifierChangeExplainsCancellation() {
        var engine = MouseEngine(configuration:configuration(directions))
        _ = engine.process(event(.buttonDown))
        let result = engine.process(event(.buttonUp,y:-80,time:1.2,modifiers:Shortcut.shift))
        #expect(result.shortcuts.isEmpty)
        #expect(result.feedback?.contains("修饰键已变化") == true)
    }
    @Test func longHoldCannotTriggerGestureOnReleaseWithoutMovePacket() {
        var engine = MouseEngine(configuration:configuration(directions))
        _ = engine.process(event(.buttonDown))
        let result = engine.process(event(.buttonUp,y:-80,time:7))
        #expect(result.shortcuts.isEmpty && result.replay.count == 2)
        #expect(result.feedback == "按住时间过长，未触发手势")
    }
    @Test func wheelComboCooldownReportsOnceAndDoesNotDuplicateAction() {
        var engine = MouseEngine(configuration:configuration([.scrollUp]))
        _ = engine.process(event(.buttonDown))
        let first = engine.process(event(.scroll,time:1.1,wheel:1))
        #expect(first.shortcuts == [shortcut]); #expect(first.feedback?.contains("滚轮向上") == true)
        let cooldown = engine.process(event(.scroll,time:1.11,wheel:1))
        #expect(cooldown.shortcuts.isEmpty && cooldown.feedback?.contains("间隔过短") == true)
        #expect(engine.process(event(.scroll,time:1.12,wheel:1)).feedback == nil)
        #expect(engine.process(event(.scroll,time:1.3,wheel:1)).shortcuts == [shortcut])
        let up = engine.process(event(.buttonUp,time:1.4))
        #expect(up.feedback == "滚轮组合结束"); #expect(up.shortcuts.isEmpty && up.replay.isEmpty)
    }
    @Test func unusedWheelOnlyBindingDoesNotAskForGestureDistance() {
        var engine = MouseEngine(configuration:configuration([.scrollUp,.scrollDown],button:1))
        _ = engine.process(event(.buttonDown,button:1))
        let up = engine.process(event(.buttonUp,time:1.2,button:1))
        #expect(up.shortcuts.isEmpty && up.replay.count == 2)
        #expect(up.feedback == "未触发滚轮组合，保留原生操作")
    }
    @Test func windowActionFeedbackIsRecognitionNotExecutionClaim() {
        var config = configuration([.swipeUp])
        config.bindings[0].windowAction = .maximize
        var engine = MouseEngine(configuration:config)
        _ = engine.process(event(.buttonDown))
        let result = engine.process(event(.buttonUp,y:-80,time:1.1))
        #expect(result.windowActions == [.maximize] && result.shortcuts.isEmpty)
        #expect(result.feedback == "已识别：向上")
        #expect(result.feedback?.contains("完成") != true)
    }
    @Test func directionHelperRejectsInvalidAndAmbiguousVectors() {
        #expect(GestureDirectionRecognizer.direction(dx:.nan,dy:100) == nil)
        #expect(GestureDirectionRecognizer.direction(dx:100,dy:.infinity) == nil)
        #expect(GestureDirectionRecognizer.direction(dx:40,dy:40) == .swipeDownRight)
        #expect(GestureDirectionRecognizer.direction(dx:0,dy:0) == nil)
        #expect(GestureDirectionRecognizer.isDirectional(.swipeUp))
        #expect(!GestureDirectionRecognizer.isDirectional(.scrollUp))
    }
}
