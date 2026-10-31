import Foundation
import Testing
@testable import MacDailyCore

struct WindowActivationTests {
    private let screen = CGRect(x: -1200, y: -100, width: 1200, height: 800)
    private let visible = CGRect(x: -1200, y: -76, width: 1200, height: 740)
    private let current = CGRect(x: -1100, y: 20, width: 500, height: 400)
    private func area(_ action: WindowAction? = .leftHalf, enabled: Bool = true,
                      rect: NormalizedWindowRect = .init(x: 0,y: 0,width: 0.2,height: 1),
                      target: NormalizedWindowRect? = nil) -> WindowActivationArea {
        .init(name: "测试区域", enabled: enabled, rect: rect, action: action, customTarget: target)
    }
    private func match(_ areas: [WindowActivationArea], point: CGPoint = .init(x: -1190, y: 100), gap: Double = 0) -> WindowActivationMatch? {
        WindowActivationResolver.resolve(at: point, screen: screen, visibleFrame: visible, current: current,
                                         gap: gap, profile: .init(landscape: areas))
    }
    @Test func overlapOrderAndDisabledAreas() {
        let first = area(.rightHalf), second = area(.topHalf)
        #expect(match([first, second])?.areaID == first.id)
        var disabled = first; disabled.enabled = false
        #expect(match([disabled, second])?.areaID == second.id)
        #expect(match([disabled]) == nil)
    }
    @Test func noFallbackOutsideRegionOrForEmptyProfile() {
        #expect(match([]) == nil)
        #expect(match([area()], point: .init(x: -10,y: 100)) == nil)
        #expect(match([area()], point: .init(x: -1201,y: 100)) == nil)
        #expect(match([area()], point: .init(x: CGFloat.nan,y: 100)) == nil)
    }
    @Test func presetUsesVisibleFrameAndGap() {
        let hit = match([area()], gap: 8)
        #expect(hit?.frame == WindowGeometry.frame(for: .leftHalf, in: visible, current: current, gap: 8))
        #expect(hit?.action == .leftHalf)
    }
    @Test func customTargetRespectsNegativeOriginsAndGap() {
        let custom = area(nil, target: .init(x: 0.25,y: 0.25,width: 0.5,height: 0.5))
        let hit = match([custom], gap: 10)
        #expect(hit?.frame == CGRect(x: -890,y: 119,width: 580,height: 350))
        #expect(hit?.action == nil)
        let tinyScreen = CGRect(x: 0,y: 0,width: 20,height: 20)
        #expect(WindowActivationResolver.resolve(at: .init(x: 1,y: 1), screen: tinyScreen, visibleFrame: tinyScreen,
                  current: tinyScreen, gap: 32, profile: .init(landscape: [custom])) == nil)
    }
    @Test func portraitUsesItsOwnAreas() {
        let tall = CGRect(x: -800,y: -1200,width: 800,height: 1200)
        let landscape = area(.leftHalf), portrait = area(.bottomHalf)
        let hit = WindowActivationResolver.resolve(at: .init(x: -790,y: -1000), screen: tall, visibleFrame: tall,
                   current: current, gap: 0, profile: .init(landscape: [landscape], portrait: [portrait]))
        #expect(hit?.areaID == portrait.id)
        #expect(WindowDisplayOrientation(screen: tall) == .portrait)
        #expect(WindowDisplayOrientation.portrait.gridRows == 24)
    }
    @Test func invalidRectsAndActionsAreRejected() {
        for rect in [NormalizedWindowRect(x: -.infinity,y: 0,width: 1,height: 1),
                     .init(x: 0,y: .nan,width: 1,height: 1),
                     .init(x: 0,y: 0,width: 0,height: 1),
                     .init(x: 0,y: 0,width: 0.01,height: 1),
                     .init(x: 0.9,y: 0,width: 0.2,height: 1),
                     .init(x: -0.1,y: 0,width: 0.2,height: 1)] {
            #expect(throws: (any Error).self) { try rect.validated() }
            #expect(match([area(rect: rect)]) == nil)
        }
        #expect(throws: (any Error).self) { try area(.restore).validated() }
        #expect(throws: (any Error).self) { try area(nil).validated() }
        #expect(match([area(nil, target: .init(x: 0,y: 0,width: 2,height: 1))]) == nil)
        #expect(match([area()], gap: -.infinity) == nil)
    }
    @Test func recommendedProfilesAreValidAndIndependent() throws {
        let profile = try WindowActivationProfile.recommended.validated()
        #expect(profile.landscape.count == 17); #expect(profile.portrait.count == 17)
        #expect(Set((profile.landscape + profile.portrait).map(\.id)).count == 34)
        #expect(WindowSettings().activationMode == .standard)
        #expect(WindowSettings().highlightActivationAreas)
        let duplicate = area()
        #expect(throws: (any Error).self) { try WindowActivationProfile(landscape: [duplicate],portrait: [duplicate]).validated() }
    }
    private func schema2Data() throws -> Data {
        var config = MouseConfiguration(); config.scroll.speed = 1.8; config.bindings[0].enabled = true
        config.windows.enabled = true; config.windows.gap = 7; config.windows.restoreOnDrag = false
        config.windows.excludedApps = [.init(bundleIdentifier: "org.example.keep",name: "Keep")]
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        object["schemaVersion"] = 2
        var windows = try #require(object["windows"] as? [String: Any])
        for key in ["activationMode", "activationProfile", "highlightActivationAreas"] { windows.removeValue(forKey: key) }
        object["windows"] = windows
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    @Test func schema2MigratesWithoutChangingMouseOrStandardWindows() throws {
        let data = try schema2Data(), config = try ConfigurationStore.decode(data)
        #expect(config.schemaVersion == 9); #expect(config.scroll.speed == 1.8)
        #expect(config.bindings[0].enabled); #expect(config.windows.enabled)
        #expect(config.windows.gap == 7); #expect(!config.windows.restoreOnDrag)
        #expect(config.windows.excludedApps.first?.bundleIdentifier == "org.example.keep")
        #expect(config.windows.activationMode == .standard)
        #expect(config.windows.activationProfile == .recommended)
        #expect(try ConfigurationStore.decode(JSONEncoder().encode(config)) == config)
    }
    @Test func schema2SourceIsPreservedBeforeFirstSave() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("tmp/activation-core/fixtures/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ConfigurationStore(url: folder.appendingPathComponent("configuration.json"))
        let original = try schema2Data(); try original.write(to: store.url)
        var migrated = try store.load(); migrated.windows.activationMode = .custom
        #expect(!FileManager.default.fileExists(atPath: store.backupURL(forSchema: 2).path))
        try store.save(migrated)
        #expect(try Data(contentsOf: store.backupURL(forSchema: 2)) == original)
        migrated.windows.gap = 5; try store.save(migrated)
        #expect(try Data(contentsOf: store.backupURL(forSchema: 2)) == original)
        #expect(try store.load() == migrated)
    }
    @Test func invalidSchema2BackupLeavesOriginalUntouched() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("tmp/activation-core/fixtures/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ConfigurationStore(url: folder.appendingPathComponent("configuration.json"))
        let original = try schema2Data(); try original.write(to: store.url)
        try Data("invalid".utf8).write(to: store.backupURL(forSchema: 2))
        #expect(throws: (any Error).self) { try store.save(store.load()) }
        #expect(try Data(contentsOf: store.url) == original)
    }
}
