import Foundation
import ApplicationServices
import PointerBridge
import MacDailyCore

@MainActor
enum RuntimeDiagnostics {
    static func checkConfiguration(path: String) -> Int32 {
        do {
            let url = URL(fileURLWithPath: path)
            let config = try ConfigurationStore.decode(contentsOf: url)
            let encoded = try ConfigurationStore(url: url).exportData(config)
            let original = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            let migrated = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            let keys = ["scroll", "pointer", "gestureThreshold", "bindings", "exceptions"]
            let before = NSDictionary(dictionary: original.filter { keys.contains($0.key) })
            let after = NSDictionary(dictionary: migrated.filter { keys.contains($0.key) })
            let report: [String: Any] = ["valid": true, "sourceSchema": original["schemaVersion"] ?? 0,
                "decodedSchema": config.schemaVersion, "mouseValuesPreserved": before.isEqual(after),
                "bindingCount": config.bindings.count, "windowSnappingEnabled": config.windows.enabled,
                "filesModified": false]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self)); return 0
        } catch { print("Configuration check failed: \(error.localizedDescription)"); return 1 }
    }

    /// Explicit read-only entrypoint. Never installs a tap or writes HID properties.
    static func printReport() {
        var devices: [[String: Any]] = []
        if let monitor = MDPointerMonitorCreate(nil, nil) {
            let array = MDPointerCopyDevices(monitor) as NSArray
            for case let item as NSDictionary in array {
                var value: [String: Any] = [:]
                for (key, element) in item { if let key = key as? String { value[key] = element } }
                devices.append(value)
            }
            MDPointerMonitorDestroy(monitor)
        }
        let report: [String: Any] = [
            "application": "MacDaily", "version": "1.0", "mode": "read-only diagnostics",
            "interfaceLanguage": L10n.languageCode,
            "localizationResources": L10n.resourceBundleURL.path,
            "localizedMouseTitle": L10n.text("鼠标"),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "accessibilityTrustedForThisProcess": AXIsProcessTrusted(),
            "permissionScope": "Host authorization may be inherited; the standalone app checks its own permission",
            "eventAttributionAvailable": MDPointerAttributionAvailable(),
            "devices": devices,
            "eventTapInstalled": false, "pointerSettingsModified": false
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: data, encoding: .utf8) { print(string) }
    }
}
