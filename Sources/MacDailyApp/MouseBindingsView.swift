import AppKit
import MacDailyCore
import SwiftUI

private typealias MouseBindingsState<Value> = SwiftUI.State<Value>

@MainActor
final class MouseBindingsPresentationState: ObservableObject {
    @Published var editor: MouseBinding?
    @Published var importReport: MouseImportReport?
    @Published var importError: String?
    @Published var practiceOpen = false
    @Published var inspectionOpen = false
}

struct MouseBindingsPresentationHost: ViewModifier {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: MouseBindingsPresentationState
    func body(content: Content) -> some View {
        content
        .sheet(item: $presentation.editor) { binding in MouseBindingSheet(model: model, binding: binding) }
        .sheet(isPresented: Binding(get: { presentation.importReport != nil }, set: { if !$0 { presentation.importReport = nil } })) {
            if let report = presentation.importReport { MouseImportSheet(model: model, report: report) }
        }
        .sheet(isPresented: $presentation.practiceOpen) {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text(L10n.text("识别练习")).font(.title2.bold()); Spacer(); Button(L10n.text("完成")) { presentation.practiceOpen = false }.keyboardShortcut(.cancelAction) }
                SafeGestureTestView(model: model)
            }.padding(24).frame(width: 650)
        }
        .sheet(isPresented: $presentation.inspectionOpen) {
            MouseInspectionSheet(model: model)
        }

    }
}

struct MouseBindingsSections: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: MouseBindingsPresentationState

    var body: some View {
        Group {
            Section {
                Text(L10n.text("按住按钮，向一个方向移动，松手执行一次。右键和中键分别设置。"))
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Text(L10n.text("手势触发距离"))
                    Slider(value: $model.configuration.gestureThreshold, in: 12...160)
                    Text("\(Int(model.configuration.gestureThreshold)) pt").monospacedDigit().frame(width: 62)
                }
                if model.configuration.bindings.allSatisfy({ !$0.enabled }) {
                    Label(L10n.text("没有启用的规则"), systemImage: "pause.circle").foregroundStyle(.secondary)
                } else {
                    Text(L10n.text("已启用 %@ 条规则", String(model.configuration.bindings.filter(\.enabled).count))).font(.caption).foregroundStyle(.secondary)
                }
                Label(model.gestureFeedback, systemImage: "hand.draw").font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("gesture-runtime-feedback")
                Text(model.mouseExecutionFeedback).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("mouse-execution-feedback")
                if !model.mouseInspectionMatches.isEmpty {
                    DisclosureGroup(L10n.text("最近一次真实检查")) {
                        ForEach(model.mouseInspectionMatches.keys.sorted(), id: \.self) { key in
                            Text("\(key) ×\(model.mouseInspectionMatches[key] ?? 0)").font(.caption).textSelection(.enabled)
                        }
                    }
                }
                DisclosureGroup(L10n.text("系统导航快捷键")) {
                    Text(model.mouseSystemShortcuts).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    Button(L10n.text("从 BetterAndBetter 读取设置")) {
                        do { presentation.importReport = try BetterAndBetterMouseImporter.readLocal() }
                        catch { presentation.importError = error.localizedDescription }
                    }
                    Spacer()
                }
                if let importError = presentation.importError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(importError).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Button(L10n.text("选择 BetterAndBetter 配置文件…")) {
                            let panel = NSOpenPanel()
                            panel.title = L10n.text("选择 BetterAndBetter 配置文件")
                            panel.canChooseDirectories = false
                            panel.directoryURL = BetterAndBetterMouseImporter.localURL.deletingLastPathComponent()
                            panel.nameFieldStringValue = BetterAndBetterMouseImporter.localURL.lastPathComponent
                            guard panel.runModal() == .OK, let url = panel.url else { return }
                            let scoped = url.startAccessingSecurityScopedResource()
                            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            do { presentation.importReport = try BetterAndBetterMouseImporter.read(contentsOf: url); presentation.importError = nil }
                            catch { presentation.importError = error.localizedDescription }
                        }
                    }
                }
            }
            if model.windowPracticeActive {
                Section {
                    HStack {
                        Text(L10n.text("窗口练习仍在锁定，窗口手势只对练习窗口生效。"))
                        Spacer()
                        Button(L10n.text("结束窗口练习")) { model.endWindowPractice() }
                    }.font(.caption)
                }
            }
            ForEach([1, 2], id: \.self) { button in
                Section {
                    HStack {
                        Text(MouseBinding.buttonName(button)).font(.headline)
                        Text(L10n.text("已启用 %@/%@", String(rules(button).filter(\.enabled).count), String(rules(button).count))).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        let enabled = rules(button).contains(where: \.enabled)
                        Button(L10n.text(enabled ? "停用本组" : "启用已配置规则")) { setGroup(button, enabled: !enabled) }
                            .disabled(rules(button).isEmpty || model.gestureTesting || model.mouseInspectionActive)
                    }
                    HStack {
                        Text(L10n.text("点击动作"))
                        Spacer()
                        if button == 1 {
                            Text(L10n.text("原生右键菜单")).foregroundStyle(.secondary)
                        } else { triggerButton(button, .click) }
                    }
                    directionGrid(button)
                    HStack {
                        Text(L10n.text("按住按钮＋滚轮")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        triggerButton(button, .scrollUp)
                        triggerButton(button, .scrollDown)
                    }
                    let extra = rules(button).filter { $0.modifiers != 0 }
                    ForEach(extra) { rule in ruleRow(rule) }
                }
            }
            Section(L10n.text("侧键与其他按钮")) {
                ForEach(model.configuration.bindings.filter { $0.button > 2 }) { rule in ruleRow(rule) }
                Button { presentation.editor = blank(button: 3, trigger: .click) } label: { Label(L10n.text("添加规则"), systemImage: "plus") }
                    .disabled(model.configuration.bindings.count >= 128)
            }
            Section(L10n.text("检查与练习")) {
                HStack {
                    Button(L10n.text("识别练习")) { presentation.practiceOpen = true }
                    Button(L10n.text("真实鼠标检查")) { presentation.inspectionOpen = true }
                        .disabled(!model.accessibilityGranted || !model.conflicts.isEmpty || model.configurationNeedsRecovery)
                }
                Text(L10n.text("识别练习只检查画布中的方向；真实鼠标检查使用正式设备识别、配置和输入链。两种模式均不执行动作。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func rules(_ button: Int) -> [MouseBinding] { model.configuration.bindings.filter { $0.button == button } }
    private func setGroup(_ button: Int, enabled: Bool) {
        var config = model.configuration
        var keys = Set<String>()
        for index in config.bindings.indices where config.bindings[index].button == button {
            let rule = config.bindings[index]
            let key = "\(rule.trigger.rawValue):\(rule.modifiers)"
            config.bindings[index].enabled = enabled && keys.insert(key).inserted
        }
        model.configuration = config
    }
    private func blank(button: Int, trigger: MouseTrigger) -> MouseBinding {
        .init(button: button, trigger: trigger, shortcut: .init(keyCode: 48, modifiers: Shortcut.command, label: "⌘Tab"))
    }
    private func rule(_ button: Int, _ trigger: MouseTrigger) -> MouseBinding? {
        rules(button).first { $0.trigger == trigger && $0.modifiers == 0 }
    }
    private func triggerButton(_ button: Int, _ trigger: MouseTrigger) -> some View {
        let existing = rule(button, trigger)
        return Button { presentation.editor = existing ?? blank(button: button, trigger: trigger) } label: {
            VStack(spacing: 4) {
                Text(trigger == .click ? L10n.text("点击") : trigger == .scrollUp ? L10n.text("滚轮向上") : L10n.text("滚轮向下")).font(.caption)
                Text(existing?.effectiveAction.title ?? L10n.text("原生操作")).lineLimit(1).font(.callout)
            }
        }.buttonStyle(.bordered).tint(existing?.enabled == true ? .accentColor : .secondary)
            .accessibilityLabel("\(MouseBinding.buttonName(button)) · \(trigger.title) · \(existing?.effectiveAction.title ?? L10n.text("原生操作"))")
    }
    private func directionGrid(_ button: Int) -> some View {
        let positions: [MouseTrigger?] = [.swipeUpLeft, .swipeUp, .swipeUpRight, .swipeLeft, nil, .swipeRight, .swipeDownLeft, .swipeDown, .swipeDownRight]
        let symbols = ["↖", "↑", "↗", "←", "", "→", "↙", "↓", "↘"]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(0..<9, id: \.self) { index in
                if let trigger = positions[index] {
                    let existing = rule(button, trigger)
                    Button { presentation.editor = existing ?? blank(button: button, trigger: trigger) } label: {
                        VStack(spacing: 5) {
                            HStack { Text(symbols[index]).font(.title2); Spacer(); if existing?.enabled == true { Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.tint) } }
                            Text(existing?.effectiveAction.title ?? L10n.text("未设置")).font(.caption).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(9).frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
                    }.buttonStyle(.plain)
                        .background(existing?.enabled == true ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary))
                        .accessibilityLabel("\(MouseBinding.buttonName(button)) · \(trigger.title) · \(existing?.effectiveAction.title ?? L10n.text("未设置"))")
                } else {
                    VStack(spacing: 5) { Image(systemName: "computermouse").font(.title2); Text(MouseBinding.buttonName(button)).font(.caption) }
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 68)
                }
            }
        }
    }
    private func ruleRow(_ rule: MouseBinding) -> some View {
        HStack {
            Toggle("", isOn: Binding(get: { model.configuration.bindings.first { $0.id == rule.id }?.enabled ?? false }, set: { enabled in
                if let i = model.configuration.bindings.firstIndex(where: { $0.id == rule.id }) { model.configuration.bindings[i].enabled = enabled }
            })).labelsHidden().toggleStyle(.switch).controlSize(.small)
            Text("\(MouseBinding.buttonName(rule.button)) · \(rule.trigger.title)").font(.callout)
            if rule.modifiers != 0 { Text(mouseModifierTitle(rule.modifiers)).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button(rule.effectiveAction.title) { presentation.editor = rule }.buttonStyle(.borderless)
        }
    }
}

private enum MouseActionKind: String, CaseIterable {
    case shortcut = "快捷键", window = "窗口动作", system = "系统动作", quick = "快捷功能", dashboard = "MacDaily 面板", middle = "中键点按"
}

struct MouseInputActionEditor: View {
    @Binding var action: InputAction
    let onBeginRecording: () -> Void
    let onEndRecording: () -> Void
    private var kind: MouseActionKind {
        switch action {
        case .shortcut: .shortcut
        case .window: .window
        case .system: .system
        case .quick: .quick
        case .showDashboard: .dashboard
        case .middleClick: .middle
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L10n.text("执行动作"), selection: Binding(get: { kind }, set: changeKind)) {
                ForEach(MouseActionKind.allCases, id: \.self) { Text(L10n.text($0.rawValue)).tag($0) }
            }
            switch action {
            case .shortcut(let shortcut):
                ShortcutRecorder(shortcut: Binding(get: { shortcut }, set: { action = .shortcut($0) }), onBegin: onBeginRecording, onEnd: onEndRecording).frame(width: 240, height: 30)
            case .window(let window):
                Picker(L10n.text("窗口动作"), selection: Binding(get: { window }, set: { action = .window($0) })) { ForEach(WindowAction.allCases) { Text($0.title).tag($0) } }
            case .system(let system):
                Picker(L10n.text("系统动作"), selection: Binding(get: { system }, set: { action = .system($0) })) { ForEach(MouseSystemAction.allCases, id: \.self) { Text($0.title).tag($0) } }
            case .quick(let quick):
                Picker(L10n.text("快捷功能"), selection: Binding(get: { quick }, set: { action = .quick($0) })) { ForEach(DashboardAction.allCases) { Text($0.title).tag($0) } }
            case .middleClick, .showDashboard: EmptyView()
            }
        }
    }
    private func changeKind(_ kind: MouseActionKind) {
        switch kind {
        case .shortcut: action = .shortcut(.init(keyCode: 48, modifiers: Shortcut.command, label: "⌘Tab"))
        case .window: action = .window(.leftHalf)
        case .system: action = .system(.minimize)
        case .quick: action = .quick(.lockScreen)
        case .dashboard: action = .showDashboard
        case .middle: action = .middleClick
        }
    }
}

private struct MouseBindingSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @MouseBindingsState private var draft: MouseBinding
    @MouseBindingsState private var action: InputAction
    @MouseBindingsState private var error: String?
    init(model: AppModel, binding: MouseBinding) {
        self.model = model
        _draft = MouseBindingsState(initialValue: binding)
        _action = MouseBindingsState(initialValue: binding.effectiveAction)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.text("编辑鼠标规则")).font(.title2.bold()); Spacer()
                Button(L10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("保存")) { save() }.keyboardShortcut(.defaultAction)
            }
            Form {
                Toggle(L10n.text("启用规则"), isOn: $draft.enabled)
                Picker(L10n.text("按钮"), selection: $draft.button) { ForEach(1...8, id: \.self) { Text(MouseBinding.buttonName($0)).tag($0) } }
                    .onChange(of: draft.button) { _, button in if button == 1 && draft.trigger == .click { draft.trigger = .swipeUp } }
                Picker(L10n.text("操作"), selection: $draft.trigger) { ForEach(MouseTrigger.allCases.filter { !(draft.button == 1 && $0 == .click) }, id: \.self) { Text($0.title).tag($0) } }
                HStack {
                    Text(L10n.text("需按住"))
                    ForEach([(Shortcut.control,"⌃"),(Shortcut.option,"⌥"),(Shortcut.shift,"⇧"),(Shortcut.command,"⌘")], id: \.0) { bit, label in
                        Toggle(label, isOn: Binding(get: { draft.modifiers & bit != 0 }, set: { enabled in if enabled { draft.modifiers |= bit } else { draft.modifiers &= ~bit } })).toggleStyle(.checkbox)
                    }
                }
                MouseInputActionEditor(action: $action, onBeginRecording: model.beginShortcutRecording, onEndRecording: model.endShortcutRecording)
            }.formStyle(.grouped)
            if let error { Text(error).font(.callout).foregroundStyle(.secondary) }
            HStack { if model.configuration.bindings.contains(where: { $0.id == draft.id }) { Button(L10n.text("移除规则")) { model.removeBinding(draft.id); dismiss() } }; Spacer() }
        }.padding(22).frame(width: 620, height: 470)
    }
    private func save() {
        var item = draft
        item.action = action
        if case .shortcut(let shortcut) = action { item.shortcut = shortcut; item.windowAction = nil }
        else if case .window(let window) = action { item.windowAction = window }
        else { item.windowAction = nil }
        var config = model.configuration
        if let index = config.bindings.firstIndex(where: { $0.id == item.id }) { config.bindings[index] = item }
        else { config.bindings.append(item) }
        do { _ = try config.validated(); model.configuration = config; dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

private struct MouseInspectionSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(L10n.text("真实鼠标检查")).font(.title2.bold()); Spacer(); Button(L10n.text("完成")) { dismiss() }.keyboardShortcut(.cancelAction) }
            Text(L10n.text("使用外接鼠标按下、移动、滚轮和松开。这里显示正式设备识别和规则匹配，不执行映射动作。"))
                .font(.callout).foregroundStyle(.secondary)
            Label(model.mouseInspectionActive ? L10n.text("正在检查真实鼠标") : model.status, systemImage: "computermouse")
            Text(model.mouseInspectionEvent).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                .accessibilityIdentifier("mouse-inspection-event")
            Text(model.gestureFeedback).font(.callout).foregroundStyle(.secondary)
            if !model.mouseInspectionMatches.isEmpty {
                Text(L10n.text("本次已匹配")).font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(model.mouseInspectionMatches.keys.sorted(), id: \.self) { key in
                            HStack { Text(key).font(.caption); Spacer(); Text("×\(model.mouseInspectionMatches[key] ?? 0)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        }
                    }
                }.frame(maxHeight: 220)
            }
        }.padding(24).frame(width: 680)
        .onAppear { model.startMouseInspection() }
        .onDisappear { model.endMouseInspection() }
    }
}

private struct MouseImportSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @MouseBindingsState private var report: MouseImportReport
    @MouseBindingsState private var selected = Set<UUID>()
    @MouseBindingsState private var enabledButtons: Set<Int> = []
    @MouseBindingsState private var error: String?
    init(model: AppModel, report: MouseImportReport) {
        self.model = model
        _report = MouseBindingsState(initialValue: report)
        _selected = MouseBindingsState(initialValue: Set(report.rows.filter { $0.binding != nil }.map(\.id)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.text("BetterAndBetter 鼠标设置")).font(.title2.bold()); Spacer()
                Button(L10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("应用所选规则")) { apply() }.keyboardShortcut(.defaultAction).disabled(selected.isEmpty)
            }
            HStack {
                Text(L10n.text("导入后启用"))
                ForEach([1, 2], id: \.self) { button in Toggle(MouseBinding.buttonName(button), isOn: Binding(get: { enabledButtons.contains(button) }, set: { value in if value { enabledButtons.insert(button) } else { enabledButtons.remove(button) } })).toggleStyle(.checkbox) }
                Spacer()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach($report.rows) { $row in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top) {
                                Toggle("", isOn: Binding(get: { selected.contains(row.id) }, set: { value in if value { selected.insert(row.id) } else { selected.remove(row.id) } })).labelsHidden().disabled(row.binding == nil)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.binding?.trigger.title ?? row.sourceGesture.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "Of2Key", with: "").replacingOccurrences(of: "Of3Key", with: "")).font(.callout.weight(.medium))
                                    if !row.note.isEmpty { Text(row.note).font(.caption).foregroundStyle(.secondary) }
                                    Text(row.scope == "All Applications" ? L10n.text("所有应用") : row.scope).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let binding = row.binding { Text("\(MouseBinding.buttonName(binding.button)) · \(binding.trigger.title)").font(.caption) }
                            }
                            if let binding = row.binding {
                                MouseInputActionEditor(action: Binding(get: { row.binding?.effectiveAction ?? binding.effectiveAction }, set: { action in
                                    row.binding?.action = action
                                    if case .shortcut(let shortcut) = action { row.binding?.shortcut = shortcut; row.binding?.windowAction = nil }
                                    else if case .window(let window) = action { row.binding?.windowAction = window }
                                    else { row.binding?.windowAction = nil }
                                }), onBeginRecording: model.beginShortcutRecording, onEndRecording: model.endShortcutRecording)
                                .disabled(!selected.contains(row.id))
                            } else if let reason = row.unsupportedReason { Text(L10n.text(reason)).font(.caption).foregroundStyle(.secondary) }
                            Divider()
                        }
                    }
                }.padding(5)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }.padding(22).frame(width: 780, height: 650)
    }
    private func apply() {
        let config = report.applying(selectedIDs: selected, to: model.configuration, enabledButtons: enabledButtons)
        do { _ = try config.validated(); model.configuration = config; dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

private func mouseModifierTitle(_ flags: UInt64) -> String {
    [(Shortcut.control,"⌃"),(Shortcut.option,"⌥"),(Shortcut.shift,"⇧"),(Shortcut.command,"⌘")].filter { flags & $0.0 != 0 }.map(\.1).joined()
}
