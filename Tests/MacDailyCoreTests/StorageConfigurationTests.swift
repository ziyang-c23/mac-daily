import Foundation
import Testing
@testable import MacDailyCore

struct StorageConfigurationTests {
    @Test func schemaThreePreservesExistingRulesAndAddsIdleStorageDefaults() throws {
        var original = MouseConfiguration()
        original.bindings[0].enabled = true
        original.scroll.speed = 1.7
        original.windows.enabled = true
        original.windows.activationMode = .custom
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json["schemaVersion"] = 3
        json.removeValue(forKey: "storage")
        let data = try JSONSerialization.data(withJSONObject: json)
        let loaded = try ConfigurationStore.decode(data)
        #expect(loaded.schemaVersion == 9)
        #expect(loaded.bindings == original.bindings)
        #expect(loaded.scroll == original.scroll)
        #expect(loaded.pointer == original.pointer)
        #expect(loaded.windows == original.windows)
        #expect(loaded.storage == StorageSettings())
        #expect(loaded.storage.minimumLargeFileBytes == 100_000_000)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tmp/storage-integration/config-fixtures/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigurationStore(url: root.appendingPathComponent("configuration.json"))
        try data.write(to: store.url)
        try store.save(loaded)
        #expect(try Data(contentsOf: store.backupURL(forSchema: 3)) == data)
        #expect(try store.load() == loaded)
    }
    @Test func storageRoundTripAndStrictBounds() throws {
        var configuration = MouseConfiguration()
        configuration.storage.minimumLargeFileBytes = 200_000_000
        configuration.storage.excludedPaths = ["/Users/example/work"]
        configuration.storage.preferredKeepPaths = ["/Volumes/Keep"]
        #expect(try ConfigurationStore.decode(JSONEncoder().encode(configuration)) == configuration)
        configuration.storage.minimumLargeFileBytes = -1
        #expect(throws: (any Error).self) { try configuration.validated() }
        var settings = StorageSettings()
        settings.excludedPaths = ["relative"]
        #expect(throws: (any Error).self) { try settings.validated() }
        settings.excludedPaths = ["/same", "/same"]
        #expect(throws: (any Error).self) { try settings.validated() }
        settings.excludedPaths = ["/bad\0path"]
        #expect(throws: (any Error).self) { try settings.validated() }
    }
    @Test func newSchemaCannotSilentlyLoseStorageSettings() throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(MouseConfiguration())) as? [String: Any])
        json.removeValue(forKey: "storage")
        #expect(throws: (any Error).self) { try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: json)) }
        json["schemaVersion"] = 8
        #expect(throws: (any Error).self) { try ConfigurationStore.decode(JSONSerialization.data(withJSONObject: json)) }
    }
}
