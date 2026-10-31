import AppKit
import Combine
import MacDailyCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

private typealias AppsState<Value> = SwiftUI.State<Value>

@MainActor
final class ApplicationsModel: ObservableObject {
    @Published var applications: [InstalledApplication] = []
    @Published var selectedPaths = Set<String>()
    @Published var focusedPath: String?
    @Published var related: [ApplicationRelatedItem] = []
    @Published var leftovers: [ApplicationRelatedItem] = []
    @Published var preview: [ApplicationRelatedItem] = []
    @Published var selectedItems = Set<String>()
    @Published var results: [ApplicationCleanupResult] = []
    @Published var isLoading = false
    @Published var isScanningInventory = false
    @Published var isRemoving = false
    @Published var message: String?
    @Published var previewOpen = false
    private var scanWork: Task<[InstalledApplication], Error>?
    private var relatedWork: Task<[ApplicationRelatedItem], Error>?
    private var requestID: UUID?
    private(set) var loaded = false

    func cancel() {
        scanWork?.cancel(); relatedWork?.cancel(); requestID = nil; isLoading = false; isScanningInventory = false
        message = L10n.text("已取消")
    }
    func load(settings: ApplicationsSettings, focusPath: String? = nil) {
        cancel(); let id = UUID(); requestID = id; isLoading = true; isScanningInventory = true; message = nil; applications = []
        let roots = ApplicationInventory.defaultRoots + settings.extraScanDirectories.map { URL(fileURLWithPath: $0) }
        let work = Task.detached(priority: .utility) { [weak self] in
            try ApplicationInventory.scan(roots: roots, includeSystem: settings.showSystemApps, isCancelled: { Task.isCancelled }) { app in
                Task { @MainActor [weak self] in
                    guard let self, self.requestID == id, self.isLoading, !self.applications.contains(where: { $0.path == app.path }) else { return }
                    self.applications.append(app)
                }
            }
        }
        scanWork = work
        Task {
            do {
                let apps = try await work.value
                guard requestID == id else { return }
                applications = apps; loaded = true
                selectedPaths.formIntersection(Set(apps.map(\.path)))
            } catch is CancellationError {} catch { if requestID == id { message = error.localizedDescription } }
            if requestID == id {
                isLoading = false; isScanningInventory = false
                if let focusPath, applications.contains(where: { $0.path == focusPath }) {
                    focusedPath = focusPath; selectedPaths.insert(focusPath)
                }
                if let path = focusedPath, applications.contains(where: { $0.path == path }) {
                    inspect(paths: [path], settings: settings, openPreview: false)
                }
            }
        }
    }
    func inspect(paths: Set<String>, settings: ApplicationsSettings, openPreview: Bool) {
        relatedWork?.cancel(); let id = UUID(); requestID = id; isLoading = true; message = nil
        let apps = applications
        let work = Task.detached(priority: .utility) {
            try ApplicationAssociationResolver.resolve(applications: apps, selectedPaths: paths,
                                                      ignoredPaths: settings.ignoredPaths, isCancelled: { Task.isCancelled })
        }
        relatedWork = work
        Task {
            do {
                let items = try await work.value
                guard requestID == id else { return }
                if openPreview {
                    preview = items; selectedItems = Set(items.filter(\.defaultSelected).map(\.id)); results = []; previewOpen = true
                } else { related = items }
            } catch is CancellationError {} catch { if requestID == id { message = error.localizedDescription } }
            if requestID == id { isLoading = false }
        }
    }
    func scanLeftovers(settings: ApplicationsSettings) {
        relatedWork?.cancel(); let id = UUID(); requestID = id; isLoading = true; message = nil
        let apps = applications
        let work = Task.detached(priority: .utility) {
            try ApplicationAssociationResolver.scanLeftovers(applications: apps, ignoredPaths: settings.ignoredPaths, isCancelled: { Task.isCancelled })
        }
        relatedWork = work
        Task {
            do { let items = try await work.value; if requestID == id { leftovers = items } }
            catch is CancellationError {} catch { if requestID == id { message = error.localizedDescription } }
            if requestID == id { isLoading = false }
        }
    }
    func previewLeftovers() {
        preview = leftovers.filter { selectedItems.contains($0.id) }; results = []; previewOpen = true
    }
    var effectiveSelection: [ApplicationRelatedItem] { ApplicationCleanupService.preview(items: preview, selectedIDs: selectedItems) }
    func remove() {
        let items = effectiveSelection
        guard !items.isEmpty, !isRemoving else { return }
        isRemoving = true
        Task {
            results = await ApplicationCleanupService.execute(items: items, quit: { path in
                await Self.quitApplication(at: path)
            })
            let moved = Set(results.filter { $0.status == .moved }.map(\.path))
            selectedItems.subtract(moved)
            preview.removeAll { moved.contains($0.path) }
            leftovers.removeAll { moved.contains($0.path) }
            applications.removeAll { moved.contains($0.path) }
            related.removeAll { moved.contains($0.path) }
            selectedPaths.subtract(moved)
            isRemoving = false
        }
    }
    private static func quitApplication(at path: String) async -> Bool {
        let running = await MainActor.run { NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL.path == path } }
        if running.isEmpty { return true }
        let own = await MainActor.run { Bundle.main.bundleURL.standardizedFileURL.path }
        guard path != own else { return false }
        await MainActor.run { for app in running { _ = app.terminate() } }
        for _ in 0..<30 {
            let ended = await MainActor.run { running.allSatisfy(\.isTerminated) }
            if ended { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}

struct ApplicationsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var apps = ApplicationsModel()
    @AppsState private var tab = 0
    @AppsState private var search = ""
    @AppsState private var dropTargeted = false
    @AppsState private var foldersOpen = false
    private var settings: ApplicationsSettings { model.configuration.applications }
    private var shown: [InstalledApplication] {
        let filtered = apps.applications.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.bundleIdentifier.localizedCaseInsensitiveContains(search) || $0.path.localizedCaseInsensitiveContains(search) }
        return filtered.sorted {
            switch settings.sort {
            case .name: return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            case .size: return $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes
            case .lastUsed: return ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast)
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.text("应用")).font(.largeTitle.bold())
                Spacer()
                if apps.isLoading { ProgressView().controlSize(.small); Button(L10n.text("取消")) { apps.cancel() } }
                Button { addFolder() } label: { Label(L10n.text("添加目录或应用"), systemImage: "plus") }.disabled(apps.isLoading || apps.isRemoving)
                Button { apps.load(settings: settings) } label: { Label(L10n.text("刷新"), systemImage: "arrow.clockwise") }.disabled(apps.isLoading || apps.isRemoving)
            }
            Picker("", selection: $tab) {
                Text(L10n.text("应用")).tag(0); Text(L10n.text("残留")).tag(1); Text(L10n.text("启动项")).tag(2)
            }.pickerStyle(.segmented)
            if let message = apps.message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            if tab == 0 { inventory }
            else if tab == 1 { leftovers }
            else { StartupItemsView(model: model) }
        }.padding(22)
        .onAppear { if !apps.loaded && !apps.isLoading { apps.load(settings: settings) } }
        .onDisappear { if apps.isLoading { apps.cancel() } }
        .sheet(isPresented: $apps.previewOpen) { cleanupPreview }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in addLocation(url) }
                }
            }
            return !providers.isEmpty
        }
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 12).stroke(.blue, lineWidth: 3).allowsHitTesting(false) } }
    }
    private var inventory: some View {
        VStack(spacing: 10) {
            HStack {
                TextField(L10n.text("搜索名称、标识或路径"), text: $search).textFieldStyle(.roundedBorder)
                Picker(L10n.text("排序"), selection: Binding(get: { settings.sort }, set: { model.configuration.applications.sort = $0 })) {
                    ForEach(ApplicationSort.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(width: 155)
                Toggle(L10n.text("系统应用"), isOn: Binding(get: { settings.showSystemApps }, set: { model.configuration.applications.showSystemApps = $0; apps.load(settings: settings) }))
                    .toggleStyle(.checkbox).disabled(apps.isLoading)
                Button { foldersOpen.toggle() } label: { Image(systemName: "folder.badge.gearshape") }.help(L10n.text("扫描目录"))
            }
            if foldersOpen { scanFolders }
            HSplitView {
                List(selection: $apps.focusedPath) {
                    ForEach(shown) { app in
                        HStack(spacing: 9) {
                            Toggle("", isOn: Binding(get: { apps.selectedPaths.contains(app.path) }, set: { value in if value { apps.selectedPaths.insert(app.path) } else { apps.selectedPaths.remove(app.path) } }))
                                .labelsHidden().toggleStyle(.checkbox).disabled(app.isSystem || app.path == Bundle.main.bundlePath || app.caskToken != nil || app.uninstallerPath != nil)
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 30, height: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack { Text(app.name).lineLimit(1); if running(app) { Circle().fill(.green).frame(width: 6, height: 6) } }
                                Text(app.version).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 3)
                            Text(bytes(app.bytes)).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 3).tag(app.path)
                    }
                }.frame(minWidth: 280, idealWidth: 350)
                ScrollView {
                    if let app = apps.applications.first(where: { $0.path == apps.focusedPath }) { detail(app) }
                    else { ContentUnavailableView(L10n.text("选择应用查看详情"), systemImage: "app.dashed") }
                }.frame(minWidth: 280)
            }
            .onChange(of: apps.focusedPath) { _, path in
                apps.related = []
                if let path, !apps.isScanningInventory { apps.inspect(paths: [path], settings: settings, openPreview: false) }
            }
            HStack {
                Text(L10n.text("%@ 个应用", String(apps.applications.count))).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(L10n.text("已选 %@ 个", String(apps.selectedPaths.count))).font(.caption)
                Button(L10n.text("查看卸载项目")) { apps.inspect(paths: apps.selectedPaths, settings: settings, openPreview: true) }
                    .buttonStyle(.borderedProminent).disabled(apps.selectedPaths.isEmpty || apps.isLoading)
            }
        }
    }
    private var scanFolders: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("默认：/Applications 与 ~/Applications")).font(.caption).foregroundStyle(.secondary)
            ForEach(settings.extraScanDirectories, id: \.self) { path in
                HStack { Text(path).font(.caption).textSelection(.enabled); Spacer(); Button { model.configuration.applications.extraScanDirectories.removeAll { $0 == path }; apps.load(settings: settings) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain) }
            }
        }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
    private func detail(_ app: InstalledApplication) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack { Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 48, height: 48); Text(app.name).font(.title2.bold()) }
            field("版本", app.version); field("Bundle ID", app.bundleIdentifier); field("开发者", app.developer)
            field("架构", app.architecture.isEmpty ? L10n.text("无记录") : app.architecture == "Universal" ? L10n.text("通用") : app.architecture)
            field("上次使用", app.lastUsed.map { $0.formatted(.dateTime.year().month().day().hour().minute().locale(L10n.locale)) } ?? L10n.text("无记录"))
            field("安装路径", app.path); field("应用本体", bytes(app.bytes))
            if apps.applications.filter({ $0.bundleIdentifier == app.bundleIdentifier && !$0.bundleIdentifier.isEmpty }).count > 1 {
                Label(L10n.text("多个安装副本"), systemImage: "square.on.square").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(L10n.text("在 Finder 中显示")) { reveal(app.path) }
                Button(L10n.text("复制路径")) { copy(app.path) }
                Button(L10n.text("固定到概览")) {
                    guard !model.dashboard.settings.pinnedApps.contains(where: { $0.path == app.path }) else { return }
                    model.dashboard.settings.pinnedApps.append(.init(bundleIdentifier: app.bundleIdentifier, path: app.path, name: app.name))
                }.disabled(app.bundleIdentifier.isEmpty || model.dashboard.settings.pinnedApps.contains(where: { $0.path == app.path }))
            }.controlSize(.small)
            if let token = app.caskToken {
                GroupBox(L10n.text("由 Homebrew 管理")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(app.caskCommand ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        HStack {
                            Button(L10n.text("复制卸载命令")) { copy(app.caskCommand ?? "") }
                            Link(L10n.text("打开 Cask 页面"), destination: URL(string: "https://formulae.brew.sh/cask/\(token)")!)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let path = app.uninstallerPath { Button(L10n.text("打开厂商卸载器")) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } }
            Divider()
            HStack { Text(L10n.text("关联文件")).font(.headline); Spacer(); Text(bytes(apps.related.filter { $0.category != .application }.reduce(0) { $0 + max(0, $1.bytes) })).font(.caption) }
            ForEach(apps.related.filter { $0.category != .application }) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack { Text(URL(fileURLWithPath: item.path).lastPathComponent).lineLimit(1); Spacer(); Text(bytes(item.bytes)) }
                    Text(item.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(L10n.text(item.reason)).font(.caption2).foregroundStyle(.secondary)
                }.font(.caption)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func field(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(L10n.text(key)).font(.caption).foregroundStyle(.secondary); Text(value.isEmpty ? L10n.text("无记录") : value).font(.callout).textSelection(.enabled) }
    }
    private var leftovers: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("未找到对应应用的资料库项目")).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("扫描残留")) { apps.selectedItems = []; apps.scanLeftovers(settings: settings) }.disabled(apps.isLoading || !apps.loaded)
            }
            if apps.leftovers.isEmpty { ContentUnavailableView(L10n.text("点击扫描残留查看项目"), systemImage: "tray") }
            else {
                List {
                    ForEach(Dictionary(grouping: apps.leftovers, by: { $0.ownerIDs.first ?? "" }).keys.sorted(), id: \.self) { owner in
                        Section(owner) {
                            ForEach(apps.leftovers.filter { $0.ownerIDs.first == owner }) { item in
                                HStack {
                                    itemCheckbox(item)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.path).font(.callout).textSelection(.enabled)
                                        Text(L10n.text(item.reason)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(); Text(bytes(item.bytes)).font(.caption)
                                    Button(L10n.text("忽略")) { model.configuration.applications.ignoredPaths.append(item.path); apps.leftovers.removeAll { $0.id == item.id }; apps.selectedItems.remove(item.id) }.controlSize(.small)
                                }
                            }
                        }
                    }
                }
            }
            HStack {
                if !settings.ignoredPaths.isEmpty {
                    Button(L10n.text("管理忽略项")) { showIgnored() }
                }
                Spacer()
                Button(L10n.text("查看整理项目")) { apps.previewLeftovers() }.buttonStyle(.borderedProminent)
                    .disabled(!apps.leftovers.contains { apps.selectedItems.contains($0.id) })
            }
        }
    }
    private var cleanupPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(L10n.text("卸载与整理预览")).font(.title2.bold()); Spacer(); Button(L10n.text("完成")) { apps.previewOpen = false }.disabled(apps.isRemoving) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(ApplicationFileCategory.allCases, id: \.self) { category in
                        let items = apps.preview.filter { $0.category == category }
                        if !items.isEmpty {
                            Text(categoryTitle(category)).font(.headline)
                            ForEach(items) { item in
                                HStack(alignment: .top, spacing: 10) {
                                    itemCheckbox(item).disabled(!item.canTrash || apps.isRemoving)
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack { Text(item.path).textSelection(.enabled); Spacer(); Text(bytes(item.bytes)) }
                                        Text(L10n.text(item.reason)).font(.caption).foregroundStyle(.secondary)
                                        if !item.ownerIDs.isEmpty { Text(item.ownerIDs.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
                                        if item.ownerPaths.count > 1 {
                                            ForEach(item.ownerPaths, id: \.self) { path in Text(path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
                                        }
                                    }
                                    Button { reveal(item.path) } label: { Image(systemName: "folder") }.buttonStyle(.plain).help(L10n.text("在 Finder 中显示"))
                                }.font(.callout)
                            }
                            Divider()
                        }
                    }
                    if !apps.results.isEmpty {
                        Text(L10n.text("处理结果")).font(.headline)
                        Text(L10n.text("已移入废纸篓：%@", bytes(apps.results.reduce(0) { $0 + max(0, $1.movedBytes) }))).font(.callout)
                        ForEach(apps.results) { result in
                            VStack(alignment: .leading, spacing: 3) {
                                Label(L10n.text(result.message), systemImage: result.status == .moved ? "checkmark.circle" : "minus.circle").foregroundStyle(result.status == .moved ? .green : .secondary)
                                Text(result.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }.padding(4)
            }
            HStack {
                if apps.isRemoving { ProgressView().controlSize(.small) }
                Text(L10n.text("所选 %@ 项，共 %@", String(apps.effectiveSelection.count), bytes(apps.effectiveSelection.reduce(0) { $0 + max(0, $1.bytes) }))).font(.callout)
                Spacer()
                Button(L10n.text("移入废纸篓")) { apps.remove() }.buttonStyle(.borderedProminent).disabled(apps.effectiveSelection.isEmpty || apps.isRemoving)
            }
        }.padding(22).frame(width: 760, height: 600).interactiveDismissDisabled(apps.isRemoving)
    }
    private func itemCheckbox(_ item: ApplicationRelatedItem) -> some View {
        Toggle("", isOn: Binding(get: { apps.selectedItems.contains(item.id) }, set: { value in if value { apps.selectedItems.insert(item.id) } else { apps.selectedItems.remove(item.id) } })).labelsHidden().toggleStyle(.checkbox)
    }
    private func addFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.treatsFilePackagesAsDirectories = false; panel.allowsMultipleSelection = true
        panel.title = L10n.text("添加目录或应用"); panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addLocation(url, reload: false) }
        apps.load(settings: settings)
    }
    private func addLocation(_ url: URL, reload: Bool = true) {
        let path = url.standardizedFileURL.path
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { return }
        if !model.configuration.applications.extraScanDirectories.contains(path) { model.configuration.applications.extraScanDirectories.append(path) }
        if reload { apps.load(settings: settings, focusPath: url.pathExtension.lowercased() == "app" ? path : nil) }
    }
    private func showIgnored() {
        let alert = NSAlert(); alert.messageText = L10n.text("忽略项"); alert.informativeText = settings.ignoredPaths.joined(separator: "\n")
        alert.addButton(withTitle: L10n.text("保留")); alert.addButton(withTitle: L10n.text("清除忽略项"))
        if alert.runModal() == .alertSecondButtonReturn { model.configuration.applications.ignoredPaths = [] }
    }
    private func running(_ app: InstalledApplication) -> Bool { NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL.path == app.path } }
    private func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    private func bytes(_ value: Int64) -> String { value < 0 ? L10n.text("未读取") : ByteCountFormatStyle(style: .file, spellsOutZero: false, locale: L10n.locale).format(value) }
    private func categoryTitle(_ category: ApplicationFileCategory) -> String {
        switch category {
        case .application: L10n.text("应用本体")
        case .cache: L10n.text("缓存")
        case .log: L10n.text("日志")
        case .preference: L10n.text("偏好设置")
        case .data: L10n.text("应用数据")
        case .shared: L10n.text("共享项目")
        }
    }
}

private struct StartupItemsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var service = StartupItemsService()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox(L10n.text("登录与后台活动")) {
                HStack {
                    Toggle(L10n.text("MacDaily 登录时启动"), isOn: Binding(get: { model.startupEnabled }, set: model.setStartup))
                    Spacer()
                    Button(L10n.text("打开登录项与扩展")) { service.systemSettings() }
                }.padding(6)
            }
            HStack { Text(L10n.text("启动代理与守护进程")).font(.headline); Spacer(); if service.isLoading { ProgressView().controlSize(.small) }; Button(L10n.text("刷新")) { Task { await service.refresh() } }.disabled(service.isLoading) }
            if let error = service.error { Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            if service.unreadableCount > 0 { Text(L10n.text("无法读取 %@ 个启动项文件", String(service.unreadableCount))).font(.caption).foregroundStyle(.secondary) }
            List {
                ForEach(StartupScope.allCases, id: \.self) { scope in
                    Section(scope.title) {
                        ForEach(service.items.filter { $0.scope == scope }) { item in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: item.isRunning ? "circle.fill" : "circle").foregroundStyle(item.isRunning ? .green : .secondary).font(.caption).padding(.top, 4)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).font(.callout.weight(.medium))
                                    Text(item.label).font(.caption).foregroundStyle(.secondary)
                                    Text(item.executable).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                    Text(item.isEnabled ? L10n.text("自动启动已启用") : L10n.text("自动启动已停用")).font(.caption2).foregroundStyle(.secondary)
                                    Text(item.isRunning ? L10n.text("正在运行") : item.isLoaded ? L10n.text("已加载，当前未运行") : L10n.text("未加载")).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) } label: { Image(systemName: "folder") }.buttonStyle(.plain).help(L10n.text("在 Finder 中显示"))
                                if item.canToggle {
                                    Toggle(L10n.text("自动启动"), isOn: Binding(get: { item.isEnabled }, set: { enabled in Task { await service.setEnabled(enabled, for: item) } })).toggleStyle(.switch).controlSize(.small).disabled(service.isLoading)
                                } else { Button(L10n.text("系统设置")) { service.systemSettings() }.controlSize(.small) }
                            }.padding(.vertical, 5)
                        }
                    }
                }
            }
        }.task { await service.refresh() }
    }
}
