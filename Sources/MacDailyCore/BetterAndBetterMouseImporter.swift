import Foundation

public struct MouseImportRow: Identifiable, Sendable {
    public var id = UUID()
    public var sourceGesture: String
    public var note: String
    public var scope: String
    public var binding: MouseBinding?
    public var unsupportedReason: String?
    public init(sourceGesture: String, note: String = "", scope: String = "All Applications", binding: MouseBinding? = nil, unsupportedReason: String? = nil) {
        self.sourceGesture = sourceGesture; self.note = note; self.scope = scope
        self.binding = binding; self.unsupportedReason = unsupportedReason
    }
}

public struct MouseImportReport: Sendable {
    public var rows: [MouseImportRow]
    public init(rows: [MouseImportRow]) { self.rows = rows }
    public func applying(selectedIDs: Set<UUID>, to configuration: MouseConfiguration, enabledButtons: Set<Int>) -> MouseConfiguration {
        var result = configuration
        for row in rows where selectedIDs.contains(row.id) {
            guard var binding = row.binding else { continue }
            binding.enabled = enabledButtons.contains(binding.button)
            let matching = result.bindings.indices.filter {
                result.bindings[$0].button == binding.button && result.bindings[$0].trigger == binding.trigger && result.bindings[$0].modifiers == binding.modifiers
            }
            if let index = matching.first {
                binding.id = result.bindings[index].id
                result.bindings[index] = binding
                for duplicate in matching.dropFirst() { result.bindings[duplicate].enabled = false }
            } else { result.bindings.append(binding) }
        }
        return result
    }
}

public enum BetterAndBetterMouseImporter {
    public static var localURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/4K6FWZU8C4.group.cn.better365.BetterAndBetter/Library/Preferences/4K6FWZU8C4.group.cn.better365.BetterAndBetter.plist")
    }
    public static func readLocal() throws -> MouseImportReport { try read(contentsOf: localURL) }
    public static func read(contentsOf url: URL) throws -> MouseImportReport { try decode(Data(contentsOf: url)) }
    public static func decode(_ data: Data) throws -> MouseImportReport {
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let root = plist as? [String: Any], let groups = root["ruleOfNormalMouse"] as? [[String: Any]] else {
            throw ConfigurationError.invalid(L10n.text("未找到 BetterAndBetter 普通鼠标规则"))
        }
        var rows: [MouseImportRow] = []
        for group in groups {
            let scope = group["AppName"] as? String ?? ""
            for rule in group["All Rules"] as? [[String: Any]] ?? [] {
                let gesture = rule["Gesture"] as? String ?? ""
                var row = MouseImportRow(sourceGesture: gesture, note: rule["Note"] as? String ?? "", scope: scope)
                guard scope == "All Applications" else {
                    row.unsupportedReason = "应用专属规则未转换为全局规则"; rows.append(row); continue
                }
                guard let (button, trigger) = trigger(gesture), rule["Data"] == nil else {
                    row.unsupportedReason = "字母、自定义轨迹或按钮间组合未导入"; rows.append(row); continue
                }
                guard let modifier = modifiers(rule["Modifier"] as? String ?? " -") else {
                    row.unsupportedReason = "无法转换此修饰键"; rows.append(row); continue
                }
                let definition = rule["Action"] as? [String: Any] ?? [:]
                guard let action = action(definition) else {
                    row.unsupportedReason = "此动作尚未支持导入"; rows.append(row); continue
                }
                let shortcut: Shortcut
                if case .shortcut(let value) = action { shortcut = value }
                else { shortcut = .init(keyCode: 0, modifiers: 0, label: action.title) }
                let enabled = (rule["Enable"] as? NSNumber)?.boolValue ?? (rule["Enable"] as? String == "1")
                row.binding = MouseBinding(enabled: enabled, button: button, trigger: trigger, modifiers: modifier, shortcut: shortcut, action: action)
                rows.append(row)
            }
        }
        return MouseImportReport(rows: rows)
    }
    private static func trigger(_ value: String) -> (Int, MouseTrigger)? {
        let text = value.trimmingCharacters(in: .whitespaces)
        let button: Int
        if text.hasSuffix("Of2Key") { button = 1 }
        else if text.hasSuffix("Of3Key") { button = 2 }
        else { return nil }
        let name = String(text.dropLast(6)).trimmingCharacters(in: .whitespaces)
        let mapping: [String: MouseTrigger] = [
            "←": .swipeLeft, "→": .swipeRight, "↑": .swipeUp, "↓": .swipeDown,
            "I": .swipeUp, "!I": .swipeDown,
            "↖": .swipeUpLeft, "↗": .swipeUpRight, "↙": .swipeDownLeft, "↘": .swipeDownRight,
            "Scroll Up": .scrollUp, "Scroll Down": .scrollDown
        ]
        guard let trigger = mapping[name] else { return nil }
        return (button, trigger)
    }
    private static func modifiers(_ text: String) -> UInt64? {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value.isEmpty || value == "-" { return 0 }
        var remainder = value; var flags: UInt64 = 0
        for (names, flag) in [(["⌘", "Command", "command"], Shortcut.command), (["⌃", "Control", "control"], Shortcut.control), (["⌥", "Option", "option"], Shortcut.option), (["⇧", "Shift", "shift"], Shortcut.shift)] {
            for name in names where remainder.contains(name) { flags |= flag; remainder = remainder.replacingOccurrences(of: name, with: "") }
        }
        remainder = remainder.trimmingCharacters(in: CharacterSet(charactersIn: " -+"))
        return remainder.isEmpty ? flags : nil
    }
    private static func action(_ definition: [String: Any]) -> InputAction? {
        if definition["ActionType"] as? String == "Shortcut Keys", let value = definition["Action"] as? [String: Any],
           let code = value["keyCode"] as? NSNumber, code.intValue >= 0, code.intValue < 128,
           let flags = value["modifierFlags"] as? NSNumber {
            return .shortcut(.init(keyCode: UInt16(code.intValue), modifiers: flags.uint64Value & Shortcut.modifierMask,
                                   label: value["ShortcutName"] as? String ?? ""))
        }
        guard definition["ActionType"] as? String == "Preset", let name = definition["Action"] as? String else { return nil }
        switch name {
        case "Minimization": return .system(.minimize)
        case "Minimization Recovery": return .system(.restoreMinimized)
        case "Window Enter/Exit Full Screen": return .system(.toggleFullScreen)
        case "BrightnessUp": return .system(.brightnessUp)
        case "BrightnessDown": return .system(.brightnessDown)
        default: return nil
        }
    }
}
