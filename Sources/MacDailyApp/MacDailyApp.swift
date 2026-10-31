import AppKit
import Darwin
import MacDailyCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var openSettings: (() -> Void)?
    static var didPresentInitialWindow = false

    static func showSettings() {
        if let openSettings { openSettings() }
        else if let window = NSApplication.shared.windows.first(where: { $0.title == "MacDaily" }) {
            window.makeKeyAndOrderFront(nil)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        AppModel.shared.applicationDidLaunch()
    }
    func applicationWillTerminate(_ notification: Notification) { AppModel.shared.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.showSettings()
        return true
    }
}

@main
@MainActor
struct MacDailyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel

    init() {
        _ = L10n.languageCode
        if CommandLine.arguments.contains("--diagnostics") {
            RuntimeDiagnostics.printReport()
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--check-config"), index + 1 < CommandLine.arguments.count {
            exit(RuntimeDiagnostics.checkConfiguration(path: CommandLine.arguments[index + 1]))
        }
        _model = StateObject(wrappedValue: AppModel.shared)
    }

    var body: some Scene {
        Window("MacDaily", id: "settings") {
            SettingsRootView(model: model)
                .environment(\.locale, L10n.locale)
                .frame(minWidth: 850, minHeight: 650)
        }
        .defaultSize(width: 960, height: 740)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L10n.text("MacDaily 设置…")) {
                    AppDelegate.showSettings()
                }.keyboardShortcut(",")
            }
        }
    }
}
