import Foundation
import Testing
@testable import MacDailyCore

@Suite struct TrackpadMigrationTests {
    @Test func schemaSixPreservesPersonalToolsAndBacksUpBeforeSave() throws {
        var original = MouseConfiguration()
        original.scroll.speed = 1.7
        original.bindings[0].enabled = true
        original.windows.enabled = true
        original.menuBar.enabled = true
        original.dashboard.cards = [.network, .cpu]
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["schemaVersion"] = 6; object.removeValue(forKey: "trackpad")
        let bytes = try JSONSerialization.data(withJSONObject: object)
        let loaded = try ConfigurationStore.decode(bytes)
        #expect(loaded.schemaVersion == 9)
        #expect(loaded.scroll == original.scroll)
        #expect(loaded.bindings == original.bindings)
        #expect(loaded.windows == original.windows)
        #expect(loaded.storage == original.storage)
        #expect(loaded.menuBar == original.menuBar)
        #expect(loaded.dashboard == original.dashboard)
        #expect(!loaded.trackpad.enabled); #expect(loaded.trackpad.bindings.isEmpty)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tmp/trackpad/migration/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigurationStore(url: root.appendingPathComponent("configuration.json"))
        try bytes.write(to: store.url)
        try store.save(loaded)
        #expect(try Data(contentsOf: store.backupURL(forSchema: 6)) == bytes)
        #expect(try store.load() == loaded)
    }
}
