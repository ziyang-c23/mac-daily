import AppKit
import Combine
import MacDailyCore
import SwiftUI
import UniformTypeIdentifiers

private typealias PopoverState<Value> = SwiftUI.State<Value>

@MainActor
final class DashboardModel: ObservableObject {
    let monitor = SystemMonitorService()
    let actions = QuickActionService()
    let hardware = SystemHardwareInfo()
    @Published var settings = DashboardSettings() {
        didSet {
            guard settings != oldValue else { return }
            actions.durationMinutes = settings.awakeDurationMinutes
            actions.dockAnchorDisplayUUID = settings.dockAnchorDisplayUUID
            if !applying { onSettingsChanged?(settings) }
            updateDemand()
        }
    }
    @Published var selectedMetric: MonitorMetric?
    var onSettingsChanged: ((DashboardSettings) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenStorage: (() -> Void)?
    private var visibleSources = Set<String>()
    private var applying = false

    func apply(_ settings: DashboardSettings) {
        applying = true; self.settings = settings; applying = false
        actions.durationMinutes = settings.awakeDurationMinutes
        actions.dockAnchorDisplayUUID = settings.dockAnchorDisplayUUID
        updateDemand()
    }
    func setVisible(_ visible: Bool, source: String) {
        if visible {
            visibleSources.insert(source); actions.refresh()
            Task { await hardware.load() }
        }
        else { visibleSources.remove(source) }
        if visibleSources.isEmpty { monitor.setProcessDetail(nil) }
        else { monitor.setProcessDetail(selectedMetric) }
        updateDemand()
    }
    private func updateDemand() {
        monitor.setDemand(visible: !visibleSources.isEmpty, menuNetwork: settings.showMenuNetwork,
                          temperature: settings.cards.contains(.temperature), interface: settings.networkInterface)
    }
    func showMetric(_ metric: MonitorMetric?) {
        selectedMetric = metric
        monitor.setProcessDetail(metric)
    }
    func openStorage() { onOpenStorage?() }
    func openApp(_ app: PinnedDashboardApp) {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) ?? URL(fileURLWithPath: app.path)
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
            if let error { Task { @MainActor in self?.actions.message = error.localizedDescription } }
        }
    }
    func addApp() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("固定常用应用"); panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  !settings.pinnedApps.contains(where: { $0.bundleIdentifier == id }) else { continue }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
            settings.pinnedApps.append(.init(bundleIdentifier: id, path: url.path, name: name))
        }
    }
    func removeApp(id: UUID) { settings.pinnedApps.removeAll { $0.id == id } }
    func moveApp(from: IndexSet, to: Int) { settings.pinnedApps.move(fromOffsets: from, toOffset: to) }
    func stop() { visibleSources.removeAll(); monitor.stop(); actions.stop() }
}

/// A single transient panel hosts overview and the existing collection controller.
@MainActor
final class DashboardPanelController: NSObject {
    private var panel: DashboardPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var anchor = CGRect.zero
    private weak var model: DashboardModel?
    var isVisible: Bool { panel?.isVisible == true }

    func show(model: DashboardModel, menuBar: MenuBarRuntime, anchor: CGRect, screen: NSScreen?) {
        self.anchor = anchor; self.model = model
        guard let screen = screen ?? NSScreen.main else { return }
        let panel = self.panel ?? makePanel()
        model.showMetric(nil)
        let height = min(790, floor(screen.visibleFrame.height * 0.85))
        let width: CGFloat = 400
        let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        panel.contentView = NSHostingView(rootView: DashboardPopover(model: model, menuBar: menuBar).environment(\.locale, L10n.locale))
        let x = min(max(anchor.maxX - width, bounds.minX), bounds.maxX - width)
        let y = max(bounds.minY, min(anchor.minY - height - 5, bounds.maxY - height))
        panel.setFrame(CGRect(x: x, y: y, width: width, height: height), display: true)
        panel.makeKeyAndOrderFront(nil)
        model.setVisible(true, source: "popover")
        installMonitors()
    }
    func hide() {
        panel?.orderOut(nil)
        model?.setVisible(false, source: "popover")
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
    }
    private func makePanel() -> DashboardPanel {
        let panel = DashboardPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.title = L10n.text("MacDaily 概览面板")
        panel.level = .popUpMenu; panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.panel = panel
        return panel
    }
    private func installMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if self.panel?.attachedSheet != nil { return event }
            if event.type == .keyDown && event.keyCode == 53 { self.hide(); return nil }
            if event.type != .keyDown { self.dismissIfOutside() }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismissIfOutside() }
        }
    }
    private func dismissIfOutside() {
        guard let panel, panel.attachedSheet == nil else { return }
        let p = NSEvent.mouseLocation
        if !panel.frame.contains(p) && !anchor.contains(p) { hide() }
    }
}

private final class DashboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct DashboardPopover: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject var menuBar: MenuBarRuntime
    @PopoverState private var collection = false
    var body: some View {
        VStack(spacing: 0) {
            Picker(L10n.text("面板页面"), selection: $collection) {
                Text(L10n.text("概览")).tag(false); Text(L10n.text("收纳")).tag(true)
            }.pickerStyle(.segmented).labelsHidden().padding(12)
            Divider()
            if collection {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !menuBar.isRunning {
                            Text(L10n.text("在菜单栏设置中开启图标收纳。")).foregroundStyle(.secondary)
                            Button(L10n.text("菜单栏设置 ↗")) { menuBar.openSettingsPage() }
                        } else if menuBar.items.isEmpty {
                            Text(L10n.text("暂无收纳图标")).foregroundStyle(.secondary)
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 16) {
                                ForEach(menuBar.items) { item in
                                    Button { menuBar.activateFromDashboard(item) } label: {
                                        VStack {
                                            Image(nsImage: item.applicationURL.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!)
                                                .resizable().scaledToFit().frame(width: 30, height: 30)
                                            Text(item.title).font(.caption).lineLimit(2)
                                        }.frame(maxWidth: .infinity, minHeight: 65)
                                    }.buttonStyle(.plain).help(item.title)
                                }
                            }
                        }
                        Button(L10n.text("编辑收纳与排序 ↗")) { menuBar.openSettingsPage() }
                    }.padding(16)
                }
            } else { DashboardView(model: model, compact: true) }
        }.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
