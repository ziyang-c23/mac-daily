import Foundation
import Testing
@testable import MacDailyCore

struct ScrollAndConfigurationTests {
    private func transform(_ settings: ScrollSettings = ScrollSettings(), modifiers: UInt64 = 0, continuous: Bool = false, mouse: Bool = true, excluded: Bool = false, synthetic: Bool = false) -> ScrollTransform {
        ScrollMath.transform(deltaX: 2, deltaY: 3, isContinuous: continuous, isMouse: mouse, modifiers: modifiers, settings: settings, excluded: excluded, synthetic: synthetic)
    }
    @Test func testDefaultScrollInvertsOnlyVerticalAxis() {
        let result = transform()
        #expect(result.x == 2); #expect(result.y == -3); #expect(result.smooth)
    }
    @Test func testContinuousMomentumTrackpadAndSyntheticAreUntouched() {
        for result in [transform(continuous: true), transform(mouse: false), transform(excluded: true), transform(synthetic: true)] {
            #expect(!(result.handled)); #expect(!(result.smooth))
            #expect(result.x == 2); #expect(result.y == 3)
        }
    }
    @Test func testModifierBypassDisablesOnlySmooth() {
        for modifier in [Shortcut.command, Shortcut.control, Shortcut.option] {
            let result = transform(modifiers: modifier)
            #expect(!(result.smooth)); #expect(result.y == -3)
        }
        #expect(transform(modifiers: Shortcut.shift).smooth)
    }
    @Test func testDisabledSmoothStillAppliesDirectionAndSpeed() {
        var settings = ScrollSettings(); settings.smoothEnabled = false; settings.reverseHorizontal = true; settings.speed = 2
        let result = transform(settings)
        #expect(!(result.smooth)); #expect(result.x == -4); #expect(result.y == -6)
    }
    @Test func testAccumulatorConservesDistanceAndEventuallyStops() {
        var accumulator = SmoothScrollAccumulator(); accumulator.add(x: 17.5, y: -91.25)
        var x = 0.0, y = 0.0
        for _ in 0..<300 {
            let step = accumulator.step(deltaTime: 1 / 120, duration: 0.16)
            x += step.x; y += step.y
        }
        #expect(abs((x) - (17.5)) <= 0.00001); #expect(abs((y) - (-91.25)) <= 0.00001)
        #expect(!(accumulator.isActive))
    }
    @Test func testAccumulatorOppositeDirectionCancelsPriorTail() {
        var accumulator = SmoothScrollAccumulator(); accumulator.add(x: 30, y: 40); accumulator.add(x: -3, y: 2)
        #expect(accumulator.pendingX == -3); #expect(accumulator.pendingY == 42)
        accumulator.reset(); #expect(!(accumulator.isActive))
    }
    @Test func testAccumulatorRejectsNonFiniteDeltas() {
        var accumulator = SmoothScrollAccumulator(); accumulator.add(x: .nan, y: 2)
        #expect(!(accumulator.isActive))
    }
    @Test func testConfigurationRoundTrip() throws {
        var config = MouseConfiguration(); config.bindings[0].enabled = true
        config.exceptions = [.init(bundleIdentifier: "org.example.Test", name: "测试")]
        let store = ConfigurationStore(url: URL(fileURLWithPath: "/unused"))
        #expect(try store.importData(store.exportData(config)) == config)
    }
    @Test func testBadVersionsAndBoundsRejected() {
        var config = MouseConfiguration(); config.schemaVersion = 99
        #expect(throws: (any Error).self) { try config.validated() }
        config.schemaVersion = 9; config.scroll.speed = .infinity
        #expect(throws: (any Error).self) { try config.validated() }
        config.scroll.speed = 1; config.pointer.speed = -1
        #expect(throws: (any Error).self) { try config.validated() }
    }
    @Test func testDuplicateActiveBindingsRejected() {
        var config = MouseConfiguration(); config.bindings[0].enabled = true
        var duplicate = config.bindings[0]; duplicate.id = UUID(); config.bindings.append(duplicate)
        #expect(throws: (any Error).self) { try config.validated() }
    }
    @Test func testMalformedAndOversizedDataRejected() {
        #expect(throws: (any Error).self) { try ConfigurationStore.decode(Data("not json".utf8)) }
        #expect(throws: (any Error).self) { try ConfigurationStore.decode(Data(repeating: 0x20, count: ConfigurationStore.maximumBytes + 1)) }
    }
    @Test func testFileStoreDoesNotOverwriteCorruptFileOnLoad() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("tmp/mouse-core-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let file = fixture.appendingPathComponent("config.json"), store = ConfigurationStore(url: fixture.appendingPathComponent("config.json"))
        #expect(try store.load().scroll == ScrollSettings())
        let config = MouseConfiguration(); try store.save(config)
        #expect(try store.load() == config)
        let corrupt = Data("{broken".utf8); try corrupt.write(to: file)
        #expect(throws: (any Error).self) { try store.load() }; #expect(try Data(contentsOf: file) == corrupt)
    }
}
