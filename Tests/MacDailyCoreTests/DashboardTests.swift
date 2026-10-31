import Foundation
import Testing
@testable import MacDailyCore

@Suite struct DashboardTests {
    @Test func legacyMigrationPreservesAllToolsAndCreatesDashboard() throws {
        var original = MouseConfiguration()
        original.scroll.speed = 1.75
        original.menuBar.enabled = true
        original.menuBar.autoHideDelay = 15
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["schemaVersion"] = 5
        object.removeValue(forKey: "dashboard")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let loaded = try ConfigurationStore.decode(legacy)
        #expect(loaded.schemaVersion == 9)
        #expect(loaded.scroll == original.scroll)
        #expect(loaded.bindings == original.bindings)
        #expect(loaded.windows == original.windows)
        #expect(loaded.storage == original.storage)
        #expect(loaded.menuBar == original.menuBar)
        #expect(loaded.dashboard == DashboardSettings())

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tmp/dashboard/tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigurationStore(url: root.appendingPathComponent("configuration.json"))
        try legacy.write(to: store.url)
        try store.save(loaded)
        #expect(try Data(contentsOf: store.backupURL(forSchema: 5)) == legacy)
    }

    @Test func panelOrderingAndApplicationsRoundTrip() throws {
        var configuration = MouseConfiguration()
        configuration.dashboard.cards = [.network, .cpu, .temperature]
        configuration.dashboard.actions = [.cleanKeyboard, .keepDisplayAwake, .trash]
        configuration.dashboard.networkInterface = "en7"
        configuration.dashboard.showMenuNetwork = true
        configuration.dashboard.pinnedApps = [.init(bundleIdentifier: "com.apple.finder", path: "/System/Library/CoreServices/Finder.app", name: "Finder")]
        let loaded = try ConfigurationStore.decode(JSONEncoder().encode(configuration))
        #expect(loaded == configuration)
    }

    @Test func networkRateDoesNotSpikeAcrossInterfacesAndCounterResets() {
        var rate = MonitorCounterRate()
        let first = rate.sample(identity: "en0", value: 1000, time: 10)
        let second = rate.sample(identity: "en0", value: 3000, time: 12)
        let changed = rate.sample(identity: "en7", value: 900000, time: 14)
        let reset = rate.sample(identity: "en7", value: 100, time: 16)
        #expect(first == 0); #expect(second == 1000); #expect(changed == 0); #expect(reset == 0)
        rate.reset()
        let wake = rate.sample(identity: "en7", value: 90000000, time: 50)
        #expect(wake == 0)
    }

    @Test func keyboardCleaningRetainsOriginalResumeIntent() {
        var state = InputSuspensionState()
        state.begin(.keyboardCleaning, wasRunning: true)
        state.begin(.shortcutRecording, wasRunning: false)
        let earlyEnd = state.end(.keyboardCleaning)
        let finalEnd = state.end(.shortcutRecording)
        #expect(!earlyEnd); #expect(finalEnd)
        state.begin(.keyboardCleaning, wasRunning: false)
        let pausedEnd = state.end(.keyboardCleaning)
        #expect(!pausedEnd)
    }

    @Test func initialEightActionsUpgradeButCustomSelectionStays() throws {
        var configuration = MouseConfiguration()
        configuration.dashboard.actions = DashboardSettings.legacyActions
        var decoded = try ConfigurationStore.decode(JSONEncoder().encode(configuration))
        #expect(decoded.dashboard.actions == DashboardSettings.defaultActions)
        #expect(decoded.dashboard.actions.contains(.cleanScreen))
        #expect(decoded.dashboard.actions.contains(.cleanKeyboard))
        configuration.dashboard.actions = [.hideDesktop, .storage]
        configuration.dashboard.dockAnchorDisplayUUID = "selected-display"
        decoded = try ConfigurationStore.decode(JSONEncoder().encode(configuration))
        #expect(decoded.dashboard.actions == [.hideDesktop, .storage])
        #expect(decoded.dashboard.dockAnchorDisplayUUID == "selected-display")
    }
}
