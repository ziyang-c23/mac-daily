import Foundation
import Testing
@testable import MacDailyCore

struct MouseSchemaNineMigrationTests {
    @Test func schemaEightPreservesModulesAndBacksUpOriginalRules() throws {
        var original = MouseConfiguration()
        original.bindings[0].enabled = true
        original.bindings[0].windowAction = .leftHalf
        original.applications.extraScanDirectories = ["/Volumes/Applications"]
        original.storage.excludedPaths = ["/Users/example/Data"]
        var value = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        value["schemaVersion"] = 8
        var bindings = try #require(value["bindings"] as? [[String: Any]])
        for index in bindings.indices { bindings[index].removeValue(forKey: "action") }
        value["bindings"] = bindings
        let data = try JSONSerialization.data(withJSONObject: value)
        let restored = try ConfigurationStore.decode(data)
        #expect(restored.schemaVersion == 9)
        #expect(restored.bindings[0].effectiveAction == .window(.leftHalf))
        #expect(restored.bindings[0].enabled)
        #expect(restored.bindings[1].effectiveAction == .shortcut(original.bindings[1].shortcut))
        #expect(restored.applications == original.applications)
        #expect(restored.trackpad == original.trackpad)
        #expect(restored.windows == original.windows)
        #expect(restored.storage == original.storage)
        #expect(restored.dashboard == original.dashboard)
        #expect(restored.menuBar == original.menuBar)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tmp/gesture-integration/config/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigurationStore(url: root.appendingPathComponent("configuration.json"))
        try data.write(to: store.url)
        try store.save(restored)
        #expect(try Data(contentsOf: store.backupURL(forSchema: 8)) == data)
        #expect(try store.load().bindings[0].effectiveAction == .window(.leftHalf))
    }
}
