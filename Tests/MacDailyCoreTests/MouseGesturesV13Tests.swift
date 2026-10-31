import Foundation
import Testing
@testable import MacDailyCore

struct MouseGesturesV13Tests {
    @Test func eightEqualSectorsRecognizeAndFireOnceOnRelease() {
        let directions: [MouseTrigger] = [.swipeRight, .swipeDownRight, .swipeDown, .swipeDownLeft, .swipeLeft, .swipeUpLeft, .swipeUp, .swipeUpRight]
        for index in directions.indices {
            for offset in [-22.49, 0, 22.49] {
                let angle = (Double(index) * 45 + offset) * .pi / 180
                let x = cos(angle) * 80, y = sin(angle) * 80
                #expect(GestureDirectionRecognizer.direction(dx: x, dy: y) == directions[index])
                var config = MouseConfiguration()
                let binding = MouseBinding(enabled: true, button: 1, trigger: directions[index], shortcut: .init(keyCode: 0, modifiers: 0, label: "unused"), action: .system(.minimize))
                config.bindings = [binding]
                var engine = MouseEngine(configuration: config)
                _ = engine.process(.init(kind: .buttonDown, button: 1, timestamp: 1))
                let move = engine.process(.init(kind: .move, button: 1, x: x, y: y, timestamp: 1.1))
                #expect(move.actions.isEmpty)
                let release = engine.process(.init(kind: .buttonUp, button: 1, x: x, y: y, timestamp: 1.2))
                #expect(release.actions == [.system(.minimize)])
                #expect(release.shortcuts.isEmpty && release.windowActions.isEmpty)
                #expect(engine.process(.init(kind: .buttonUp, button: 1, timestamp: 1.3)).actions.isEmpty)
            }
        }
    }
    @Test func typedActionHasOneExecutionSourceAndLegacyMigrationKeepsBehavior() throws {
        var config = MouseConfiguration()
        var binding = config.bindings[0]
        binding.enabled = true
        binding.windowAction = .maximize
        binding.action = .system(.brightnessUp)
        config.bindings = [binding]
        var engine = MouseEngine(configuration: config)
        _ = engine.process(.init(kind: .buttonDown, button: binding.button, timestamp: 1))
        let result = engine.process(.init(kind: .buttonUp, button: binding.button, timestamp: 1.1))
        #expect(result.actions == [.system(.brightnessUp)])
        #expect(result.shortcuts.isEmpty && result.windowActions.isEmpty)
        var old = config
        old.bindings[0].action = nil
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object["schemaVersion"] = 8
        let migrated = try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: object))
        #expect(migrated.schemaVersion == 9)
        #expect(migrated.bindings[0].effectiveAction == .window(.maximize))
        #expect(migrated.applications == old.applications)
    }
    @Test func attributionDoesNotTreatUnknownDownOrTrackpadAsMouse() {
        var adapter = MouseEventAdapter()
        let down = MouseInput(kind: .buttonDown, button: 1, x: 200, y: 100, timestamp: 1)
        #expect(!adapter.adapt(down, device: .unknown, senderID: 0).isMouse)
        #expect(adapter.adapt(down, device: .mouse, senderID: 42).isMouse)
        let drag = MouseInput(kind: .move, button: 1, x: 205, y: 100, timestamp: 1.1, deltaX: 5)
        let admitted = adapter.adapt(drag, device: .unknown, senderID: 0)
        #expect(admitted.isMouse && admitted.x == 205 && admitted.deltaX == 5)
        #expect(!adapter.adapt(drag, device: .trackpad, senderID: 0).isMouse)
        #expect(!adapter.adapt(drag, device: .unknown, senderID: 99).isMouse)
        #expect(!adapter.adapt(.init(kind: .scroll, deltaY: 1), device: .unknown, senderID: 0).isMouse)
        #expect(adapter.adapt(.init(kind: .buttonUp, button: 1), device: .unknown, senderID: 0).isMouse)
        #expect(adapter.admittedButtons.isEmpty)
        adapter.reset()
    }
    @Test func importerPreservesActualShortcutsAndReportsUnsupportedScopesAndShapes() throws {
        func rule(_ gesture: String, _ action: [String: Any], note: String = "") -> [String: Any] {
            ["Gesture": gesture, "Modifier": " -", "Enable": 1, "Note": note, "Action": action]
        }
        let shortcut: [String: Any] = ["ActionType": "Shortcut Keys", "Action": ["keyCode": 30, "modifierFlags": 1048840, "ShortcutName": "⌘]"]]
        let root: [String: Any] = ["ruleOfNormalMouse": [
            ["AppName": "All Applications", "All Rules": [rule(" ←Of2Key", shortcut, note: "前进"), rule("↘Of2Key", ["ActionType": "Preset", "Action": "Minimization"]), rule("Scroll UpOf3Key", ["ActionType": "Preset", "Action": "BrightnessUp"]), rule("BOf2Key", shortcut), rule("RightMouse ClickOf3Key", shortcut)]],
            ["AppName": "com.example.editor", "All Rules": [rule("→Of2Key", shortcut)]]
        ]]
        let report = try BetterAndBetterMouseImporter.decode(PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0))
        #expect(report.rows.count == 6)
        #expect(report.rows.compactMap(\.binding).count == 3)
        let first = try #require(report.rows[0].binding)
        #expect(first.button == 1 && first.trigger == .swipeLeft)
        #expect(first.effectiveAction == .shortcut(.init(keyCode: 30, modifiers: Shortcut.command, label: "⌘]")))
        #expect(report.rows[1].binding?.effectiveAction == .system(.minimize))
        #expect(report.rows[2].binding?.effectiveAction == .system(.brightnessUp))
        #expect(report.rows[5].unsupportedReason == "应用专属规则未转换为全局规则")
        var existing = MouseConfiguration()
        existing.bindings[0].enabled = true
        let originalSide = existing.bindings[0]
        let applied = report.applying(selectedIDs: Set(report.rows.map(\.id)), to: existing, enabledButtons: [1])
        #expect(applied.bindings.first { $0.id == originalSide.id } == originalSide)
        #expect(applied.bindings.first { $0.button == 1 && $0.trigger == .swipeLeft }?.effectiveAction == first.effectiveAction)
        #expect(applied.bindings.first { $0.button == 2 && $0.trigger == .scrollUp }?.enabled == false)
        #expect(try applied.validated() == applied)
    }
}
