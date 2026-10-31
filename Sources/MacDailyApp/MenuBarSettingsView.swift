import AppKit
import MacDailyCore
import SwiftUI
import UniformTypeIdentifiers

struct MenuBarSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var runtime: MenuBarRuntime
    init(model: AppModel) {
        self.model = model
        _runtime = ObservedObject(wrappedValue: model.menuBar)
    }
    private var supported: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("菜单栏")).font(.largeTitle.weight(.semibold))
                Text(L10n.text("常用图标留在菜单栏，其余点击 MacDaily 查看。"))
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 16)
            Form {
                Section(L10n.text("图标收纳")) {
                    Toggle(L10n.text("启用菜单栏管理"), isOn: $model.configuration.menuBar.enabled)
                        .disabled(!supported || model.configurationNeedsRecovery || runtime.isEditing)
                    Text(runtime.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if !supported { Text(L10n.text("菜单栏管理适用于 macOS 27。")).font(.caption).foregroundStyle(.secondary) }
                    if supported && !model.accessibilityGranted {
                        HStack {
                            Text(L10n.text("读取和操作其他应用的菜单栏图标需要辅助功能权限。"))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(L10n.text("前往授权")) { model.requestAccessibility() }
                            Button(L10n.text("重新检查")) { model.refreshEnvironment() }
                        }
                    }
                    Text(L10n.text("左键打开概览与收纳面板，右键打开 MacDaily 工具菜单。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.text("排列图标")) {
                    Text(L10n.text("拖动图标改变顺序或移到另一分组，也可以使用每项右侧的按钮。"))
                        .font(.callout)
                    HStack {
                        Button(L10n.text("刷新图标")) { runtime.refreshCatalog() }
                        Button(L10n.text("查看收纳面板")) { runtime.showPanel() }
                        Button(L10n.text("原位展开")) { runtime.expandInline() }
                        Button(L10n.text("收起")) { runtime.collapseInline() }
                        if runtime.isEditing { ProgressView().controlSize(.small) }
                    }.disabled(!canEdit)
                }
                Section(L10n.text("收纳 · %@", String(describing: runtime.items.count))) {
                    itemList(runtime.items, hidden: true)
                }
                Section(L10n.text("常显 · %@", String(describing: runtime.visibleItems.count))) {
                    itemList(runtime.visibleItems, hidden: false)
                }
                Section(L10n.text("使用偏好")) {
                    Picker(L10n.text("原位展开后收起"), selection: $model.configuration.menuBar.autoHideDelay) {
                        Text(L10n.text("保持展开")).tag(0.0)
                        ForEach([5, 10, 15, 30], id: \.self) { Text(L10n.text("%@ 秒后", String(describing: $0))).tag(Double($0)) }
                    }.disabled(model.configurationNeedsRecovery)
                    Text(L10n.text("原应用菜单打开时保持展开，完成菜单操作后再计时收起。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }
    }

    private var canEdit: Bool { runtime.isRunning && !runtime.isEditing && !model.configurationNeedsRecovery }

    @ViewBuilder private func itemList(_ items: [MenuBarItem], hidden: Bool) -> some View {
        if items.isEmpty {
            Text(hidden ? L10n.text("将图标拖到这里收纳") : L10n.text("将图标拖到这里常显"))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
                .onDrop(of: [UTType.text], isTargeted: nil) { drop($0, hidden: hidden) }
        } else {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 10) {
                    Image(nsImage: item.applicationURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
                        ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!)
                        .resizable().scaledToFit().frame(width: 25, height: 25)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.callout)
                        if item.applicationName != item.title {
                            Text(item.applicationName).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 5)
                    Button { runtime.reorder(itemID: item.id, offset: -1) } label: { Image(systemName: "arrow.up") }
                        .disabled(!canEdit || index == 0)
                        .help(L10n.text("上移")).accessibilityLabel(L10n.text("上移 %@", String(describing: item.title)))
                    Button { runtime.reorder(itemID: item.id, offset: 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(!canEdit || index == items.count - 1)
                        .help(L10n.text("下移")).accessibilityLabel(L10n.text("下移 %@", String(describing: item.title)))
                    Button(hidden ? L10n.text("移到常显") : L10n.text("移到收纳")) {
                        runtime.move(itemID: item.id, toHidden: !hidden)
                    }.disabled(!canEdit)
                        .accessibilityLabel(L10n.text("将%@%@", String(describing: item.title), String(describing: hidden ? L10n.text("移到常显") : L10n.text("移到收纳"))))
                }.padding(.vertical, 4).contentShape(Rectangle())
                    .onDrag { canEdit ? NSItemProvider(object: item.id as NSString) : NSItemProvider() }
                    .onDrop(of: [UTType.text], isTargeted: nil) { drop($0, hidden: hidden, before: item.id) }
            }
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.to.line")
                Text(L10n.text("拖到这里移入分组"))
            }.font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
                .contentShape(Rectangle())
                .onDrop(of: [UTType.text], isTargeted: nil) { drop($0, hidden: hidden) }
        }
    }

    private func drop(_ providers: [NSItemProvider], hidden: Bool, before: String? = nil) -> Bool {
        guard canEdit, let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let id = object as? String else { return }
            Task { @MainActor in runtime.move(itemID: id, toHidden: hidden, beforeItemID: before) }
        }
        return true
    }
}
