import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    public var id: String { rawValue }
    public static let preferenceKey = "MacDaily.appLanguage"
    public func resolvedCode(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        switch self {
        case .simplifiedChinese: "zh-Hans"
        case .english: "en"
        case .system: Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: preferredLanguages).first ?? "en"
        }
    }
}

public enum L10n {
    private static let resources: Bundle = {
        if let url = Bundle.main.url(forResource: "MacDaily_MacDailyCore", withExtension: "bundle"), let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()
    public static var resourceBundleURL: URL { resources.bundleURL }
    /// Fixed for the process so cached runtime messages use the same language
    /// as AppKit controls. Changes apply to the next application launch.
    public static let launchLanguage: AppLanguage = {
        if let value = ProcessInfo.processInfo.environment["MACDAILY_LANGUAGE"], let language = AppLanguage(rawValue: value) { return language }
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--language"), args.indices.contains(index + 1), let language = AppLanguage(rawValue: args[index + 1]) { return language }
        return AppLanguage(rawValue: UserDefaults.standard.string(forKey: AppLanguage.preferenceKey) ?? "system") ?? .system
    }()
    public static let languageCode = launchLanguage.resolvedCode()
    public static var locale: Locale { Locale(identifier: languageCode) }

    public static func text(_ key: String, _ arguments: String...) -> String {
        render(key, code: languageCode, arguments: arguments)
    }
    public static func render(_ key: String, language: AppLanguage, arguments: [String] = []) -> String {
        render(key, code: language.resolvedCode(), arguments: arguments)
    }
    private static func render(_ key: String, code: String, arguments: [String]) -> String {
        let bundle = resources.path(forResource: code.lowercased(), ofType: "lproj").flatMap(Bundle.init(path:)) ?? resources
        let format = bundle.localizedString(forKey: key, value: key, table: "Localizable")
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale(identifier: code), arguments: arguments.map { $0 as CVarArg })
    }
}
