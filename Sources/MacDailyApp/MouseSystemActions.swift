import AppKit
import ApplicationServices
import Darwin
import MacDailyCore

@MainActor
enum MouseDisplayBrightness {
    private typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (UInt32, Float) -> Int32
    private static let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    static func adjust(by delta: Float) -> String {
        guard let library, let getSymbol = dlsym(library, "DisplayServicesGetBrightness"),
              let setSymbol = dlsym(library, "DisplayServicesSetBrightness") else { return L10n.text("当前系统无法调节显示器亮度") }
        let get = unsafeBitCast(getSymbol, to: Get.self), set = unsafeBitCast(setSymbol, to: Set.self)
        let builtIn = NSScreen.screens.compactMap { screen -> UInt32? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = number.uint32Value
            return CGDisplayIsBuiltin(id) != 0 ? id : nil
        }.first
        guard let display = builtIn else { return L10n.text("没有可调节亮度的内建显示器") }
        var before: Float = 0, after: Float = 0
        guard get(display, &before) == 0, set(display, min(1, max(0, before + delta))) == 0,
              get(display, &after) == 0 else { return L10n.text("未能调节显示器亮度") }
        return L10n.text("亮度 %@%%", String(Int((after * 100).rounded())))
    }
}

/// The four semantic navigation shortcuts are user-editable in macOS. An
/// explicitly disabled matching entry cannot be made to work by posting keys.
enum NativeMouseShortcutReader {
    struct Entry {
        let name: String
        let shortcut: Shortcut
        let enabled: Bool
    }
    static func entries() -> [Entry] {
        let stored = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys")?["AppleSymbolicHotKeys"] as? [String: Any] ?? [:]
        let defaults: [(String, String, UInt16)] = [("32", "调度中心", 126), ("33", "应用窗口", 125), ("79", "上一个桌面", 123), ("81", "下一个桌面", 124)]
        return defaults.map { id, name, key in
            let item = stored[id] as? [String: Any]
            let parameters = (item?["value"] as? [String: Any])?["parameters"] as? [NSNumber]
            let code = parameters.flatMap { $0.count >= 3 ? $0[1].uint16Value : nil } ?? key
            let modifiers = (parameters.flatMap { $0.count >= 3 ? $0[2].uint64Value : nil } ?? Shortcut.control) & Shortcut.modifierMask
            let glyphs = [(Shortcut.control, "⌃"), (Shortcut.option, "⌥"), (Shortcut.shift, "⇧"), (Shortcut.command, "⌘")].filter { modifiers & $0.0 != 0 }.map(\.1).joined()
            let known: [UInt16: String] = [123: "←", 124: "→", 125: "↓", 126: "↑", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 99: "F3"]
            let character = parameters.flatMap { values -> String? in
                guard let value = values.first?.uint32Value, value >= 32, value < 0xffff, let scalar = UnicodeScalar(value) else { return nil }
                return String(scalar).uppercased()
            }
            let label = glyphs + (known[code] ?? character ?? "[\(code)]")
            return Entry(name: name, shortcut: .init(keyCode: code, modifiers: modifiers, label: label), enabled: item?["enabled"] as? Bool ?? true)
        }
    }
    static func problem(for shortcut: Shortcut) -> String? {
        guard let entry = entries().first(where: { !$0.enabled && $0.shortcut.keyCode == shortcut.keyCode && $0.shortcut.modifiers == shortcut.modifiers }) else { return nil }
        return L10n.text("系统中的“%@”快捷键已关闭，请在键盘快捷键 → 调度中心中设置", L10n.text(entry.name))
    }
    static var summary: String {
        entries().map { L10n.text($0.name) + " · " + $0.shortcut.displayLabel + " · " + ($0.enabled ? L10n.text("已启用") : L10n.text("已关闭")) }.joined(separator: "；")
    }
}
