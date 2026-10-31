import Foundation

public struct ConfigurationStore: Sendable {
    public let url: URL
    public static let maximumBytes = 1_048_576
    public init(url: URL) { self.url = url }
    public var legacyBackupURL: URL { url.deletingPathExtension().appendingPathExtension("schema1-backup.json") }
    public func backupURL(forSchema version: Int) -> URL { url.deletingPathExtension().appendingPathExtension("schema\(version)-backup.json") }
    /// Only absence means defaults. Corrupt files throw and remain untouched.
    public func load() throws -> MouseConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return MouseConfiguration() }
        return try Self.decode(contentsOf: url)
    }
    public func save(_ configuration: MouseConfiguration) throws {
        let data = try exportData(configuration)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Back up a valid legacy source before its first replacement. Loading
        // itself remains read-only; failed backup writes leave the source intact.
        if let legacy = try? Self.boundedData(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: legacy) as? [String: Any],
           let version = object["schemaVersion"] as? Int, (1...8).contains(version), (try? Self.decode(legacy)) != nil {
            let backupURL = backupURL(forSchema: version)
            if !FileManager.default.fileExists(atPath: backupURL.path) {
                try legacy.write(to: backupURL, options: .withoutOverwriting)
            } else {
                let existing = try Self.boundedData(contentsOf: backupURL)
                _ = try Self.decode(existing)
            }
        }
        try data.write(to: url, options: [.atomic])
    }
    public func importData(_ data: Data) throws -> MouseConfiguration { try Self.decode(data) }
    public func exportData(_ configuration: MouseConfiguration) throws -> Data {
        _ = try configuration.validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        guard data.count <= Self.maximumBytes else { throw ConfigurationError.invalid(L10n.text("配置文件过大")) }
        return data
    }
    public static func decode(_ data: Data) throws -> MouseConfiguration {
        guard data.count <= maximumBytes else { throw ConfigurationError.invalid(L10n.text("配置文件过大")) }
        return try JSONDecoder().decode(MouseConfiguration.self, from: data).validated()
    }
    public static func decode(contentsOf url: URL) throws -> MouseConfiguration {
        try decode(boundedData(contentsOf: url))
    }
    private static func boundedData(contentsOf url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= maximumBytes else {
            throw ConfigurationError.invalid(L10n.text("请选择不超过 1 MB 的 JSON 配置文件"))
        }
        // Bounded read also handles a file growing after the metadata check.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw ConfigurationError.invalid(L10n.text("配置文件过大")) }
        return data
    }
}
