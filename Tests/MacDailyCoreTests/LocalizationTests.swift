import Foundation
import Testing
@testable import MacDailyCore

@Suite struct LocalizationTests {
    @Test func bothLanguagesResolveVisibleNames() {
        #expect(L10n.render("触控板", language: .english) == "Trackpad")
        #expect(L10n.render("空间", language: .english) == "Storage")
        #expect(L10n.render("触控板", language: .simplifiedChinese) == "触控板")
        #expect(AppLanguage.english.resolvedCode(preferredLanguages: ["zh-Hans"]) == "en")
        #expect(AppLanguage.system.resolvedCode(preferredLanguages: ["zh-CN", "en"]) == "zh-Hans")
        #expect(AppLanguage.system.resolvedCode(preferredLanguages: ["en-GB", "zh-Hans"]) == "en")
    }

    @Test func translatedMessagesPreserveUserValues() {
        let path = "文稿/研究结果 100%.csv"
        #expect(L10n.render("导出失败：%@", language: .english, arguments: [path]) == "Export failed: \(path)")
        #expect(L10n.render("导出失败：%@", language: .simplifiedChinese, arguments: [path]) == "导出失败：\(path)")
    }

    @Test func shippedCatalogsHaveMatchingKeys() throws {
        let bundle = try #require(Bundle(url: L10n.resourceBundleURL))
        func catalog(_ language: String) throws -> [String: String] {
            let url = try #require(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language))
            return try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
        }
        let english = try catalog("en"), chinese = try catalog("zh-Hans")
        #expect(Set(english.keys) == Set(chinese.keys))
        #expect(english.values.allSatisfy { !$0.isEmpty })
        #expect(chinese.allSatisfy { $0.key == $0.value })
    }

    @Test func persistedDefaultsKeepTheirCanonicalNames() {
        let configuration = MouseConfiguration()
        #expect(configuration.bindings.first?.shortcut.label == "⌘[ 后退")
        #expect(configuration.windows.activationProfile.landscape.first?.name == "左半屏")
        #expect(configuration.schemaVersion == 9)
    }
}
