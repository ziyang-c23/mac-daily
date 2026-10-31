import Foundation
import Testing
@testable import MacDailyCore

struct WindowConfigurationTests {
    private func legacyData() throws -> Data {
        var config = MouseConfiguration()
        config.scroll.speed = 1.7; config.pointer.enabled = true; config.pointer.speed = 1.4
        config.bindings.removeAll { $0.windowAction != nil }
        config.bindings[0].enabled = true
        config.exceptions = [.init(bundleIdentifier: "org.example.keep", name: "保留", disableScrolling: false)]
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        object["schemaVersion"] = 1; object.removeValue(forKey: "windows")
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("tmp/window-core-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    @Test func legacyMigrationPreservesMouseConfigurationWithoutAddingBindings() throws {
        let data = try legacyData(), config = try ConfigurationStore.decode(data)
        #expect(config.schemaVersion == 9); #expect(config.scroll.speed == 1.7)
        #expect(config.pointer.enabled); #expect(config.pointer.speed == 1.4)
        #expect(config.bindings.count == 9); #expect(config.bindings[0].enabled)
        #expect(config.bindings.allSatisfy { $0.windowAction == nil })
        #expect(config.exceptions.first?.disableScrolling == false)
        #expect(config.windows == WindowSettings()); #expect(!config.windows.enabled)
    }
    @Test func freshDefaultsOfferDisabledWindowPresets() {
        let config = MouseConfiguration()
        #expect(config.bindings.filter { $0.windowAction != nil }.count == 4)
        #expect(config.bindings.allSatisfy { !$0.enabled }); #expect(!config.windows.enabled)
    }
    @Test func newSchemaRoundTripsWindowRules() throws {
        var config = MouseConfiguration(); config.windows.enabled = true; config.windows.gap = 8
        config.windows.excludedApps = [.init(bundleIdentifier: "org.example.ignore", name: "Ignore")]
        let index = try #require(config.bindings.firstIndex { $0.windowAction == .leftHalf })
        config.bindings[index].enabled = true
        let data = try ConfigurationStore(url: URL(fileURLWithPath: "/unused")).exportData(config)
        #expect(try ConfigurationStore.decode(data) == config)
        #expect((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["schemaVersion"] as? Int == 9)
    }
    @Test func invalidWindowSettingsAndDuplicatesAreRejected() {
        var config = MouseConfiguration(); config.windows.gap = -1
        #expect(throws: (any Error).self) { try config.validated() }
        config.windows.gap = 0; config.windows.edgeThreshold = 100
        #expect(throws: (any Error).self) { try config.validated() }
        config.windows.edgeThreshold = 20
        let id = UUID()
        config.windows.excludedApps = [.init(id: id, bundleIdentifier: "a", name: "A"), .init(id: id, bundleIdentifier: "b", name: "B")]
        #expect(throws: (any Error).self) { try config.validated() }
    }
    @Test func unsupportedSchemaAndMislabeledWindowActionsAreRejected() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(MouseConfiguration())) as? [String: Any])
        object["schemaVersion"] = 99
        #expect(throws: (any Error).self) { try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: object)) }
        object["schemaVersion"] = 1 // Contains window actions: must not silently interpret fallback shortcuts.
        #expect(throws: (any Error).self) { try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: object)) }
        object["schemaVersion"] = 2; object.removeValue(forKey: "windows")
        #expect(throws: (any Error).self) { try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: object)) }
    }
    @Test func validLegacySourceIsBackedUpOnlyOnFirstSave() throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = ConfigurationStore(url: folder.appendingPathComponent("configuration.json"))
        let original = try legacyData(); try original.write(to: store.url)
        var migrated = try store.load()
        #expect(!FileManager.default.fileExists(atPath: store.legacyBackupURL.path))
        migrated.windows.gap = 8; try store.save(migrated)
        #expect(try Data(contentsOf: store.legacyBackupURL) == original)
        migrated.windows.gap = 12; try store.save(migrated)
        #expect(try Data(contentsOf: store.legacyBackupURL) == original)
        #expect(try store.load().windows.gap == 12)
    }
    @Test func failedBackupAndInvalidReplacementLeaveLegacySourceUntouched() throws {
        let folder = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = ConfigurationStore(url: folder.appendingPathComponent("configuration.json"))
        let original = try legacyData(); try original.write(to: store.url)
        var invalid = MouseConfiguration(); invalid.windows.gap = 100
        #expect(throws: (any Error).self) { try store.save(invalid) }
        #expect(try Data(contentsOf: store.url) == original)
        try FileManager.default.createDirectory(at: store.legacyBackupURL, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try store.save(MouseConfiguration()) }
        #expect(try Data(contentsOf: store.url) == original)
    }
    private func engine(_ trigger: MouseTrigger = .click, excluded: Bool = false) -> MouseEngine {
        var config = MouseConfiguration()
        config.bindings = [.init(enabled: true, button: 2, trigger: trigger, shortcut: .init(keyCode: 33, modifiers: Shortcut.command, label: "Fallback"), windowAction: .leftHalf)]
        if excluded { config.windows.excludedApps = [.init(bundleIdentifier: "test.app", name: "Test")] }
        return MouseEngine(configuration: config)
    }
    private func input(_ kind: MouseInput.Kind, time: Double, x: Double = 100, y: Double = 100, deltaY: Double = 0, app: String = "test.app") -> MouseInput {
        .init(kind: kind, button: 2, x: x, y: y, timestamp: time, bundleIdentifier: app, deltaY: deltaY)
    }
    @Test func windowClickEmitsNoFallbackShortcut() {
        var engine = engine(); _ = engine.process(input(.buttonDown, time: 1))
        let decision = engine.process(input(.buttonUp, time: 1.1))
        #expect(decision.windowActions == [.leftHalf]); #expect(decision.shortcuts.isEmpty); #expect(decision.replay.isEmpty)
    }
    @Test func windowGestureAndWheelEmitExactlyOneOutputKind() {
        var gesture = engine(.swipeUp); _ = gesture.process(input(.buttonDown, time: 1))
        _ = gesture.process(input(.move, time: 1.1, y: 40))
        let action = gesture.process(input(.buttonUp, time: 1.2, y: 40))
        #expect(action.windowActions == [.leftHalf]); #expect(action.shortcuts.isEmpty)
        var wheel = engine(.scrollUp); _ = wheel.process(input(.buttonDown, time: 1))
        let scroll = wheel.process(input(.scroll, time: 1.1, deltaY: 1))
        #expect(scroll.windowActions == [.leftHalf]); #expect(scroll.shortcuts.isEmpty)
        #expect(wheel.process(input(.buttonUp, time: 1.2)).windowActions.isEmpty)
    }
    @Test func dragExclusionKeepsExplicitMouseActionsButAppChangeCancels() {
        var excluded = engine(excluded: true)
        #expect(excluded.process(input(.buttonDown, time: 1)).consumed)
        #expect(excluded.process(input(.buttonUp, time: 1.1)).windowActions == [.leftHalf])
        var changed = engine(); _ = changed.process(input(.buttonDown, time: 1))
        let up = changed.process(input(.buttonUp, time: 1.1, app: "other.app"))
        #expect(up.windowActions.isEmpty); #expect(up.shortcuts.isEmpty)
    }
}
