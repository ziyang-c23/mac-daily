import Foundation
import Testing
@testable import MacDailyCore

struct ApplicationsMigrationTests {
    @Test func schemaSevenPreservesModulesAndBacksUpBeforeSaving() throws {
        var original = MouseConfiguration()
        original.scroll.speed = 1.6
        original.trackpad.enabled = true
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["schemaVersion"] = 7
        object.removeValue(forKey: "applications")
        let data = try JSONSerialization.data(withJSONObject: object)
        let migrated = try ConfigurationStore.decode(data)
        #expect(migrated.schemaVersion == 9)
        #expect(migrated.scroll == original.scroll)
        #expect(migrated.trackpad == original.trackpad)
        #expect(migrated.windows == original.windows)
        #expect(migrated.storage == original.storage)
        #expect(migrated.menuBar == original.menuBar)
        #expect(migrated.dashboard == original.dashboard)
        #expect(migrated.applications == ApplicationsSettings())
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tmp/tests/apps-migration/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigurationStore(url: root.appendingPathComponent("configuration.json"))
        try data.write(to: store.url)
        try store.save(migrated)
        #expect(try Data(contentsOf: store.backupURL(forSchema: 7)) == data)
        var updated = migrated
        updated.applications.extraScanDirectories = ["/Volumes/Tools"]
        updated.applications.ignoredPaths = ["/Users/example/Library/Caches/com.example.app"]
        updated.applications.sort = .size
        try store.save(updated)
        #expect(try store.load() == updated)
        #expect(try Data(contentsOf: store.backupURL(forSchema: 7)) == data)
    }
}
