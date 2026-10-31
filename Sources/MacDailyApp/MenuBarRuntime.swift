import AppKit
import ApplicationServices
import Combine
import MacDailyCore

@MainActor
final class MenuBarRuntime: NSObject, ObservableObject, NSMenuDelegate {
    @Published private(set) var status = L10n.text("菜单栏管理尚未开启")
    @Published private(set) var items: [MenuBarItem] = []
    @Published private(set) var visibleItems: [MenuBarItem] = []
    @Published private(set) var isEditing = false
    @Published private(set) var isRunning = false

    private weak var model: AppModel?
    private var entry: NSStatusItem?
    private var layout: MenuBarLayoutController?
    private let catalog = MenuBarCatalog()
    private let panel = MenuBarPanelController()
    private let dashboardPanel = DashboardPanelController()
    private var settings = MenuBarSettings()
    private var observers: [NSObjectProtocol] = []
    private var modelSubscription: AnyCancellable?
    private var scanTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private let orderController = MenuBarOrderController()
    private var orderTask: Task<Void, Never>?
    private var tracking: MenuBarTrackingObservation?
    private var activeItem: MenuBarItem?
    private var originalMenuOpen = false
    private var catalogNeedsRefresh = true
    private var catalogBoundary: CGRect?
    private var toolsMenuOpen = false
    private var autoHideTimer: Timer?
    private let toolsMenu = NSMenu()
    private var menuActions: [MenuBarMenuAction] = []

    func start(model: AppModel) {
        guard entry == nil else { return }
        self.model = model
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "MacDaily.Main"
        item.button?.target = self
        item.button?.action = #selector(entryClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.setAccessibilityLabel("MacDaily")
        item.button?.setAccessibilityIdentifier("MacDaily.Main")
        entry = item
        layout = MenuBarLayoutController(trigger: item)
        toolsMenu.autoenablesItems = false
        toolsMenu.delegate = self
        panel.onSelect = { [weak self] item in self?.activate(item) }
        panel.onDismiss = { [weak self] in self?.status = L10n.text("点击 MacDaily 图标查看收纳项目") }
        modelSubscription = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateIcon() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.catalogNeedsRefresh = true
                    if self.layout?.isExpanded == true { self.refreshCatalog() }
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.panel.hide(); self.layout?.invalidateLayoutForScreens()
                self.catalogNeedsRefresh = true
                if self.layout?.isExpanded == true { self.refreshCatalog() }
            }
        })
        updateIcon()
        model.dashboard.monitor.onSnapshot = { [weak self] in self?.updateIcon() }
        update(settings: model.configuration.menuBar)
    }

    func update(settings: MenuBarSettings) {
        let wasEnabled = self.settings.enabled
        self.settings = settings
        guard entry != nil else { return }
        guard #available(macOS 27.0, *) else { status = L10n.text("菜单栏收纳适用于 macOS 27"); return }
        let shouldRun = settings.enabled && AXIsProcessTrusted()
        isRunning = shouldRun
        layout?.setEnabled(shouldRun)
        if !shouldRun {
            scanTask?.cancel(); activationTask?.cancel(); panel.hide()
            autoHideTimer?.invalidate(); tracking?.stop(); tracking = nil
            orderTask?.cancel(); orderController.cancel(); isEditing = false
            items = []; visibleItems = []
            status = settings.enabled ? L10n.text("需要辅助功能权限读取菜单栏项目") : L10n.text("菜单栏管理尚未开启")
        } else if !wasEnabled || items.isEmpty {
            // Capture native order while the bar is expanded, before the pusher changes its geometry.
            layout?.expand()
            refreshCatalog(collapseAfter: true)
        } else if layout?.isExpanded == true { scheduleAutoHide() }
    }

    func refreshPermission() {
        guard settings.enabled, entry != nil else { return }
        if AXIsProcessTrusted() != isRunning { update(settings: settings) }
    }

    func refreshCatalog() {
        guard isRunning else { return }
        let restoreCollapsed = layout?.isExpanded == false
        if restoreCollapsed { layout?.expand() }
        refreshCatalog(collapseAfter: restoreCollapsed)
    }

    private func refreshCatalog(collapseAfter: Bool, showPanelAfter: Bool = false) {
        guard isRunning else { return }
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            // AppKit applies changed status-item lengths on the next run-loop turn.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !Task.isCancelled else { return }
            guard let values = try? await self.expandedCatalog(), !Task.isCancelled, self.isRunning else { return }
            self.publishCatalog(values)
            self.catalogNeedsRefresh = false
            if collapseAfter { self.layout?.collapse() }
            if !self.isEditing {
                self.status = L10n.text("%@ 个收纳项目 · 点击 MacDaily 图标展开", String(describing: self.items.count))
            }
            if showPanelAfter { self.presentPanel() }
        }
    }

    private func publishCatalog(_ values: [MenuBarItem]) {
        if let boundary = catalogBoundary {
                let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
                let displays = NSScreen.screens.map { CGRect(x: $0.frame.minX, y: primaryTop - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
                let display = displays.first { $0.contains(CGPoint(x: boundary.midX, y: boundary.midY)) }
                let sameDisplay = values.filter { display?.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) == true }
                if layout?.isExpanded == true {
                    items = sameDisplay.filter { $0.frame.midX < boundary.minX }
                    visibleItems = sameDisplay.filter { $0.frame.midX >= boundary.maxX }
                } else {
                    // Keep the known section for items whose hidden frames no longer reflect native order.
                    let current = Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    let running = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
                    items = items.filter { running.contains($0.processIdentifier) }.map { current[$0.id] ?? $0 }
                    let hiddenIDs = Set(items.map(\.id))
                    visibleItems = sameDisplay.filter { !hiddenIDs.contains($0.id) }
                }
            }
    }

    /// Read the boundary and app icons from one expanded AX snapshot. macOS 27
    /// may keep the collapsed (hundreds of points wide) AppKit frame briefly.
    private func expandedCatalog() async throws -> [MenuBarItem] {
        for _ in 0..<6 {
            try Task.checkCancellation()
            let values = await catalog.scan(excluding: -1)
            if let boundary = values.first(where: {
                $0.processIdentifier == getpid() && $0.id.hasSuffix(":MacDaily.CollectionBoundary") && $0.frame.width <= 40
            }) {
                catalogBoundary = boundary.frame
                return values.filter { $0.processIdentifier != getpid() }
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        status = L10n.text("菜单栏位置尚未更新，请展开后重试")
        throw MenuBarPlacementError.geometryPending
    }

    func move(itemID: String, toHidden: Bool, beforeItemID: String? = nil) {
        performMove(itemID: itemID, toHidden: toHidden, beforeItemID: beforeItemID, afterItemID: nil)
    }

    func reorder(itemID: String, offset: Int) {
        let hidden = items.contains { $0.id == itemID }
        let group = hidden ? items : visibleItems
        guard let index = group.firstIndex(where: { $0.id == itemID }), group.indices.contains(index + offset) else { return }
        let neighbor = group[index + offset]
        performMove(itemID: itemID, toHidden: hidden,
                    beforeItemID: offset < 0 ? neighbor.id : nil,
                    afterItemID: offset > 0 ? neighbor.id : nil)
    }

    private func performMove(itemID: String, toHidden: Bool, beforeItemID: String?, afterItemID: String?) {
        guard isRunning, !isEditing, itemID != beforeItemID, itemID != afterItemID else { return }
        panel.hide(); scanTask?.cancel(); activationTask?.cancel(); autoHideTimer?.invalidate()
        tracking?.stop(); tracking = nil; activeItem = nil; originalMenuOpen = false
        isEditing = true; layout?.expand()
        status = L10n.text("正在调整菜单栏排列…")
        orderTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isEditing = false; self.orderTask = nil }
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
                let values = try await self.expandedCatalog()
                try Task.checkCancellation()
                guard let source = values.first(where: { $0.id == itemID }),
                      let boundary = self.catalogBoundary else { throw MenuBarPlacementError.geometryPending }
                let target: CGPoint
                if let beforeItemID, let before = values.first(where: { $0.id == beforeItemID }) {
                    target = CGPoint(x: before.frame.minX - max(8, before.frame.width * 0.25), y: source.frame.midY)
                } else if let afterItemID, let after = values.first(where: { $0.id == afterItemID }) {
                    target = CGPoint(x: after.frame.maxX + max(8, after.frame.width * 0.25), y: source.frame.midY)
                } else {
                    target = CGPoint(x: toHidden ? boundary.minX - 8 : boundary.maxX + 8, y: source.frame.midY)
                }
                let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
                let display = NSScreen.screens.first { screen in
                    let f = screen.frame
                    return CGRect(x: f.minX, y: primaryTop - f.maxY, width: f.width, height: f.height).contains(CGPoint(x: boundary.midX, y: boundary.midY))
                }
                guard let display else { throw MenuBarPlacementError.geometryPending }
                let f = display.frame
                let quartz = CGRect(x: f.minX, y: primaryTop - f.maxY, width: f.width, height: f.height)
                guard quartz.contains(CGPoint(x: source.frame.midX, y: source.frame.midY)), quartz.contains(target) else {
                    throw MenuBarPlacementError.geometryPending
                }
                try await self.orderController.move(from: source.frame, to: target)
                try await Task.sleep(nanoseconds: 250_000_000)
                let moved = try await self.expandedCatalog()
                try Task.checkCancellation()
                self.publishCatalog(moved); self.catalogNeedsRefresh = false
                self.layout?.collapse()
                self.status = L10n.text("%@ 个收纳项目 · 点击 MacDaily 图标展开", String(describing: self.items.count))
            } catch is CancellationError {
                self.layout?.collapse()
            } catch {
                self.layout?.collapse(); self.status = error.localizedDescription
            }
        }
    }

    func showPanel() {
        guard isRunning else { return }
        if panel.isVisible { panel.hide(); return }
        if isEditing { return }
        if catalogNeedsRefresh {
            layout?.expand()
            refreshCatalog(collapseAfter: true, showPanelAfter: true)
        } else { presentPanel() }
    }

    private func presentPanel() {
        guard let button = entry?.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        panel.show(items: items, anchor: anchor, screen: window.screen)
    }

    func expandInline() {
        guard isRunning else { return }
        panel.hide(); layout?.expand(); refreshCatalog()
        status = L10n.text("原菜单栏已展开")
        scheduleAutoHide()
    }

    func collapseInline() {
        guard isRunning, !isEditing, !originalMenuOpen else { return }
        autoHideTimer?.invalidate(); layout?.collapse()
        status = L10n.text("%@ 个收纳项目 · 点击 MacDaily 图标展开", String(describing: items.count))
    }

    private func activate(_ item: MenuBarItem) {
        dashboardPanel.hide()
        panel.hide(); autoHideTimer?.invalidate()
        tracking?.stop(); tracking = nil; activeItem = nil; originalMenuOpen = false
        layout?.expand()
        activationTask?.cancel()
        activationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled, self.isRunning else { return }
            let expandedItems = await self.catalog.scan(excluding: getpid())
            guard !Task.isCancelled else { return }
            guard let target = expandedItems.first(where: { $0.id == item.id }) else {
                self.status = L10n.text("%@的菜单栏项目已变化，请重新展开", String(describing: item.applicationName))
                self.scheduleAutoHide(); return
            }
            self.activeItem = target
            self.tracking = self.catalog.observeMenu(of: target) { [weak self] open in
                guard let self else { return }
                self.originalMenuOpen = open
                if open { self.autoHideTimer?.invalidate() }
                else { self.scheduleAutoHide() }
            }
            let result = await self.catalog.activate(target)
            self.status = result.message
            if await self.catalog.isMenuOpen(for: target) { self.originalMenuOpen = true }
            if !self.originalMenuOpen { self.scheduleAutoHide() }
        }
    }

    private func scheduleAutoHide() {
        autoHideTimer?.invalidate()
        guard isRunning, !isEditing, !originalMenuOpen, !toolsMenuOpen, settings.autoHideDelay > 0 else { return }
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: settings.autoHideDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isEditing, !self.toolsMenuOpen else { return }
                if let item = self.activeItem, await self.catalog.isMenuOpen(for: item) {
                    self.originalMenuOpen = true
                    return
                }
                self.collapseInline()
            }
        }
    }

    @objc private func entryClicked() {
        guard let button = entry?.button else { return }
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            dashboardPanel.hide()
            panel.hide()
            NSMenu.popUpContextMenu(toolsMenu, with: event, for: button)
        } else {
            toggleDashboard()
        }
    }

    func toggleDashboard() {
        guard let model, let button = entry?.button, let window = button.window else { return }
        if dashboardPanel.isVisible { dashboardPanel.hide(); return }
        panel.hide()
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        dashboardPanel.show(model: model.dashboard, menuBar: self, anchor: anchor, screen: window.screen)
    }

    func hideDashboard() { dashboardPanel.hide() }
    func openSettingsPage() { model?.showTool(.menuBar) }
    func activateFromDashboard(_ item: MenuBarItem) { activate(item) }

    private func updateIcon() {
        guard let model else { return }
        let active = !model.isPaused || model.windowRunning
        entry?.button?.image = NSImage(systemSymbolName: active ? "square.grid.2x2.fill" : "square.grid.2x2", accessibilityDescription: "MacDaily")
        entry?.button?.toolTip = "MacDaily"
        let showNetwork = model.dashboard.settings.showMenuNetwork
        entry?.length = showNetwork ? NSStatusItem.variableLength : NSStatusItem.squareLength
        entry?.button?.imagePosition = showNetwork ? .imageLeading : .imageOnly
        if showNetwork {
            let snapshot = model.dashboard.monitor.snapshot
            func rate(_ value: Double) -> String {
                value >= 1_000_000 ? String(format: "%.1fM", value / 1_000_000) : String(format: "%.0fK", value / 1_000)
            }
            entry?.button?.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            entry?.button?.title = " ↑\(rate(snapshot.uploadRate)) ↓\(rate(snapshot.downloadRate))"
        } else { entry?.button?.title = "" }
        model.dashboard.actions.states[.mousePause] = model.isPaused
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === toolsMenu, let model else { return }
        menu.removeAllItems(); menuActions.removeAll()
        func add(_ title: String, enabled: Bool = true, checked: Bool = false, action: @escaping () -> Void) {
            let target = MenuBarMenuAction(action)
            menuActions.append(target)
            let item = NSMenuItem(title: title, action: #selector(MenuBarMenuAction.invoke), keyEquivalent: "")
            item.target = target; item.isEnabled = enabled; item.state = checked ? .on : .off
            menu.addItem(item)
        }
        let statusItem = NSMenuItem(title: L10n.text("鼠标：%@", String(describing: model.status)), action: nil, keyEquivalent: "")
        statusItem.isEnabled = false; menu.addItem(statusItem)
        add(model.isPaused ? L10n.text("启用鼠标增强") : L10n.text("暂停鼠标增强"), enabled: model.accessibilityGranted && model.conflicts.isEmpty && !model.configurationNeedsRecovery && !model.gestureTesting) { [weak model] in model?.togglePaused() }
        menu.addItem(.separator())
        let windows = NSMenu(title: L10n.text("排列窗口"))
        windows.autoenablesItems = false
        let targetLabel = NSMenuItem(title: model.windowTarget, action: nil, keyEquivalent: "")
        targetLabel.isEnabled = false; windows.addItem(targetLabel); windows.addItem(.separator())
        for action in WindowAction.allCases {
            let target = MenuBarMenuAction { [weak model] in model?.performWindowAction(action) }
            menuActions.append(target)
            let item = NSMenuItem(title: action.title, action: #selector(MenuBarMenuAction.invoke), keyEquivalent: "")
            item.target = target; item.isEnabled = model.accessibilityGranted && !model.configurationNeedsRecovery
            windows.addItem(item)
        }
        let windowMenu = NSMenuItem(title: L10n.text("排列窗口"), action: nil, keyEquivalent: "")
        windowMenu.submenu = windows; menu.addItem(windowMenu)
        add(L10n.text("拖拽吸附"), enabled: model.accessibilityGranted && !model.configurationNeedsRecovery, checked: model.windowSnappingRequested) { [weak model] in
            guard let model else { return }; model.setWindowSnapping(!model.windowSnappingRequested)
        }
        if settings.enabled {
            menu.addItem(.separator())
            add(layout?.isExpanded == true ? L10n.text("收起原菜单栏") : L10n.text("展开原菜单栏"), enabled: isRunning && !isEditing) { [weak self] in
                guard let self else { return }
                if self.layout?.isExpanded == true { self.collapseInline() } else { self.expandInline() }
            }

        }
        add(L10n.text("菜单栏设置…")) { [weak model] in model?.selectedToolPage = .menuBar; AppDelegate.showSettings() }
        menu.addItem(.separator())
        add(L10n.text("打开 MacDaily…")) { AppDelegate.showSettings() }
        if !model.accessibilityGranted { add(L10n.text("设置辅助功能权限…")) { [weak model] in model?.requestAccessibility() } }
        menu.addItem(.separator())
        add(L10n.text("退出 MacDaily")) { [weak model] in model?.shutdown(); NSApplication.shared.terminate(nil) }
    }
    func menuWillOpen(_ menu: NSMenu) { toolsMenuOpen = true; autoHideTimer?.invalidate() }
    func menuDidClose(_ menu: NSMenu) { toolsMenuOpen = false; scheduleAutoHide() }

    func stop() {
        dashboardPanel.hide()
        scanTask?.cancel(); activationTask?.cancel(); autoHideTimer?.invalidate()
        panel.hide(); tracking?.stop(); tracking = nil
        orderTask?.cancel(); orderController.cancel(); layout?.stop(); layout = nil
        if let entry { NSStatusBar.system.removeStatusItem(entry) }; entry = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll(); modelSubscription = nil; isRunning = false
    }
}

@MainActor
private final class MenuBarMenuAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}

private enum MenuBarPlacementError: LocalizedError {
    case geometryPending
    var errorDescription: String? { L10n.text("菜单栏位置尚未更新，请原位展开后重试") }
}
