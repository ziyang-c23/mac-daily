import Foundation
import Testing
@testable import MacDailyCore

struct MenuBarConfigurationTests {
    @Test func schemaFourKeepsExistingModulesAndStartsMenuBarOff() throws {
        var original = MouseConfiguration()
        original.scroll.speed = 1.7
        original.bindings[0].enabled = true
        original.windows.enabled = true
        original.windows.activationMode = .custom
        original.storage.minimumLargeFileBytes = 250_000_000
        original.storage.excludedPaths = ["/Users/example/Keep"]
        original.menuBar.enabled = true
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["schemaVersion"] = 4
        object.removeValue(forKey: "menuBar")
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let restored = try ConfigurationStore.decode(bytes)
        #expect(restored.schemaVersion == 9)
        #expect(restored.bindings == original.bindings)
        #expect(restored.scroll == original.scroll)
        #expect(restored.windows == original.windows)
        #expect(restored.storage == original.storage)
        #expect(restored.menuBar == MenuBarSettings())
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tmp/menubar-layout/configuration/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigurationStore(url: root.appendingPathComponent("configuration.json"))
        try bytes.write(to: store.url)
        try store.save(restored)
        #expect(try Data(contentsOf: store.backupURL(forSchema: 4)) == bytes)
        #expect(try store.load() == restored)
    }

    @Test func menuBarDelayOptionsRoundTrip() throws {
        for delay in [0.0, 5, 10, 15, 30] {
            var configuration = MouseConfiguration()
            configuration.menuBar.enabled = true
            configuration.menuBar.autoHideDelay = delay
            #expect(try ConfigurationStore.decode(JSONEncoder().encode(configuration)) == configuration)
        }
        var settings = MenuBarSettings()
        settings.autoHideDelay = 7
        #expect(throws: (any Error).self) { try settings.validated() }
    }

    @Test func narrowedDisplayDeterminesPusherLength() {
        #expect(MenuBarLayoutGeometry.collapsedLength(screenWidths: [1512]) == 736)
        #expect(MenuBarLayoutGeometry.collapsedLength(screenWidths: [2560, 1470]) == 715)
    }
}
