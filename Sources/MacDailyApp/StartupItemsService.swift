import AppKit
import Combine
import Foundation
import MacDailyCore
import ServiceManagement

enum StartupScope: String, Sendable, CaseIterable {
    case userAgent, globalAgent, daemon
    var title: String {
        switch self {
        case .userAgent: L10n.text("用户启动代理")
        case .globalAgent: L10n.text("全局启动代理")
        case .daemon: L10n.text("系统守护进程")
        }
    }
}

struct StartupItem: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let label: String
    let executable: String
    let scope: StartupScope
    let title: String
    let isEnabled: Bool
    let isLoaded: Bool
    let isRunning: Bool
    var canToggle: Bool { scope == .userAgent }
}

/// Queries are on demand. launchd's enable override and loaded process state
/// are separate: a one-shot agent may be enabled and loaded without a PID.
@MainActor
final class StartupItemsService: ObservableObject {
    @Published private(set) var items: [StartupItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var unreadableCount = 0
    @Published var error: String?
    private let userAgentsDirectory: URL

    init(userAgentsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")) {
        self.userAgentsDirectory = userAgentsDirectory
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        do {
            let directory = userAgentsDirectory
            let snapshot = try await Task.detached(priority: .utility) { try StartupReader.read(userAgentsDirectory: directory) }.value
            items = snapshot.items
            unreadableCount = snapshot.unreadableCount
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func setEnabled(_ enabled: Bool, for item: StartupItem) async {
        guard item.canToggle, !isLoading else { return }
        isLoading = true
        error = nil
        do {
            try await Task.detached(priority: .utility) {
                let domain = "gui/\(getuid())"
                let target = "\(domain)/\(item.label)"
                let toggle = try StartupReader.run([enabled ? "enable" : "disable", target])
                guard toggle.status == 0 else { throw StartupOperationError.failed(toggle.output) }
                let loaded = try StartupReader.run(["print", target]).status == 0
                if enabled && !loaded {
                    let result = try StartupReader.run(["bootstrap", domain, item.path])
                    guard result.status == 0 else { throw StartupOperationError.failed(result.output) }
                } else if !enabled && loaded {
                    let result = try StartupReader.run(["bootout", target])
                    guard result.status == 0 else { throw StartupOperationError.failed(result.output) }
                }
            }.value
        } catch {
            self.error = error.localizedDescription
        }
        // Read the actual state even when only part of an operation succeeded.
        do {
            let directory = userAgentsDirectory
            let snapshot = try await Task.detached(priority: .utility) { try StartupReader.read(userAgentsDirectory: directory) }.value
            items = snapshot.items
            unreadableCount = snapshot.unreadableCount
        } catch {
            if self.error == nil { self.error = error.localizedDescription }
        }
        isLoading = false
    }

    func systemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

private enum StartupOperationError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .failed(let details): L10n.text("启动项操作失败：%@", details.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

private enum StartupReader {
    struct CommandResult { let status: Int32; let output: String }
    struct Snapshot { let items: [StartupItem]; let unreadableCount: Int }

    static func run(_ arguments: [String]) throws -> CommandResult {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return CommandResult(status: task.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    static func read(userAgentsDirectory: URL) throws -> Snapshot {
        let fm = FileManager.default
        let guiDomain = "gui/\(getuid())"
        let locations: [(URL, StartupScope, String)] = [
            (userAgentsDirectory, .userAgent, guiDomain),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .globalAgent, guiDomain),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .daemon, "system")
        ]
        var overrides: [String: [String: Bool]] = [:]
        for domain in [guiDomain, "system"] {
            let result = try run(["print-disabled", domain])
            guard result.status == 0 else { throw StartupOperationError.failed(result.output) }
            overrides[domain] = disabledOverrides(result.output)
        }
        var result: [StartupItem] = []
        var unreadableCount = 0
        for (directory, scope, domain) in locations {
            guard fm.fileExists(atPath: directory.path) else { continue }
            let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            for url in files where url.pathExtension == "plist" {
                let plist: [String: Any]
                do {
                    let data = try Data(contentsOf: url)
                    guard let parsed = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                          let label = parsed["Label"] as? String, !label.isEmpty else {
                        unreadableCount += 1
                        continue
                    }
                    plist = parsed
                } catch {
                    unreadableCount += 1
                    continue
                }
                let label = plist["Label"] as! String
                let arguments = plist["ProgramArguments"] as? [String] ?? []
                let executable = plist["Program"] as? String ?? arguments.first ?? ""
                let loaded = try run(["print", "\(domain)/\(label)"])
                let isRunning = loaded.status == 0 && loaded.output.split(separator: "\n").contains {
                    let line = $0.trimmingCharacters(in: .whitespaces)
                    return line.hasPrefix("pid = ") && (Int(line.dropFirst(6)) ?? 0) > 0
                }
                let disabled = overrides[domain]?[label] ?? (plist["Disabled"] as? Bool ?? false)
                result.append(StartupItem(path: url.path, label: label, executable: executable, scope: scope,
                                          title: applicationName(for: executable) ?? label,
                                          isEnabled: !disabled, isLoaded: loaded.status == 0, isRunning: isRunning))
            }
        }
        let sorted = result.sorted {
            if $0.scope != $1.scope {
                return (StartupScope.allCases.firstIndex(of: $0.scope) ?? 0) < (StartupScope.allCases.firstIndex(of: $1.scope) ?? 0)
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        return Snapshot(items: sorted, unreadableCount: unreadableCount)
    }

    static func disabledOverrides(_ output: String) -> [String: Bool] {
        var values: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = parts[1].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ";,")))
            if value == "true" || value == "disabled" { values[label] = true }
            if value == "false" || value == "enabled" { values[label] = false }
        }
        return values
    }

    static func applicationName(for executable: String) -> String? {
        var url = URL(fileURLWithPath: executable)
        while url.path != "/" && !url.path.isEmpty {
            if url.pathExtension == "app" {
                let bundle = Bundle(url: url)
                return bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
            }
            url.deleteLastPathComponent()
        }
        return nil
    }
}
