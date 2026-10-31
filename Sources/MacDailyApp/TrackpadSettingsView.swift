import AppKit
import MacDailyCore
import SwiftUI
import UniformTypeIdentifiers

private typealias TrackpadViewState<Value> = SwiftUI.State<Value>

private enum TrackpadPane: String, CaseIterable, Identifiable {
    case gestures = "手势与动作", native = "系统手势", testing = "试用"
    var id: String { rawValue }
}

struct TrackpadSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var runtime: TrackpadRuntime
    @ObservedObject private var native: NativeTrackpadSettingsReader
    @TrackpadViewState private var pane: TrackpadPane = .gestures
    @TrackpadViewState private var editing: TrackpadBinding?

    init(model: AppModel) {
        self.model = model
        _runtime = ObservedObject(wrappedValue: model.trackpad)
        _native = ObservedObject(wrappedValue: model.trackpad.nativeSettings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("触控板")).font(.largeTitle.weight(.semibold))
                    Text(L10n.text("用内建触控板切换标签页、排列窗口和执行常用操作。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(L10n.text("启用触控板增强"), isOn: $model.configuration.trackpad.enabled)
                    .toggleStyle(.switch).fixedSize()
                    .disabled(model.configurationNeedsRecovery || (!model.configuration.trackpad.enabled && !model.configuration.trackpad.bindings.contains(where: \.enabled)))
            }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 12)
            HStack(spacing: 8) {
                Image(systemName: runtime.running ? "checkmark.circle.fill" : "trackpad")
                    .foregroundStyle(runtime.running ? Color.green : Color.secondary)
                Text(runtime.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("重新检查")) { runtime.refresh(); model.refreshEnvironment() }.controlSize(.small)
            }.padding(.horizontal, 24).padding(.bottom, 12)
            if !model.accessibilityGranted {
                HStack {
                    Text(L10n.text("辅助功能权限用于执行快捷键与窗口操作。"))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("前往授权")) { model.requestAccessibility() }
                }.padding(12).background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 24).padding(.bottom, 12)
            }
            Picker(L10n.text("触控板设置"), selection: $pane) {
                ForEach(TrackpadPane.allCases) { Text(L10n.text($0.rawValue)).tag($0) }
            }.pickerStyle(.segmented).padding(.horizontal, 24).padding(.bottom, 6)
            Form {
                switch pane {
                case .gestures: gestureSections
                case .native: nativeSections
                case .testing: testingSections
                }
            }.formStyle(.grouped)
        }
        .sheet(item: $editing) { rule in
            TrackpadRuleEditor(model: model, native: native, rule: rule)
        }
        .onAppear { runtime.refresh() }
        .onChange(of: pane) { _, value in if value != .testing && runtime.testing { runtime.endTesting() } }
        .onDisappear { if runtime.testing { runtime.endTesting() } }
    }

    @ViewBuilder private var gestureSections: some View {
        Section(L10n.text("手势规则")) {
            HStack {
                Text(L10n.text("%@ 条启用 · %@ 条规则", String(describing: model.configuration.trackpad.bindings.filter(\.enabled).count), String(describing: model.configuration.trackpad.bindings.count)))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.configuration.trackpad.bindings.isEmpty ? L10n.text("使用推荐预设") : L10n.text("补充推荐预设")) {
                    model.configuration.trackpad.installRecommendedBindings()
                }
                Button(L10n.text("添加规则")) { editing = TrackpadBinding(gesture: .threeTap) }
            }
            if model.configuration.trackpad.bindings.isEmpty {
                Text(L10n.text("推荐预设包含三指中键、标签页切换、窗口排列、四指面板及组合四角分屏。"))
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            }
            ForEach(model.configuration.trackpad.bindings) { rule in ruleRow(rule) }
        }
        Section(L10n.text("手感与区域")) {
            HStack {
                Text(L10n.text("四角区域大小"))
                Slider(value: $model.configuration.trackpad.cornerSize, in: 0.10...0.30, step: 0.01)
                    .accessibilityLabel(L10n.text("四角区域大小"))
                Text(model.configuration.trackpad.cornerSize, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 42)
            }
            HStack {
                Text(L10n.text("滑动触发距离"))
                Slider(value: $model.configuration.trackpad.swipeDistance, in: 0.05...0.20, step: 0.01)
                    .accessibilityLabel(L10n.text("滑动触发距离"))
                Text(model.configuration.trackpad.swipeDistance, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 42)
            }
            Text(L10n.text("百分比相对于触控板尺寸。窗口手势达到距离后显示预览，松手执行。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        Section(L10n.text("应用例外")) {
            ForEach(model.configuration.trackpad.excludedApps) { app in
                HStack {
                    Text(app.name)
                    Spacer()
                    Button { model.configuration.trackpad.excludedApps.removeAll { $0.id == app.id } } label: {
                        Image(systemName: "minus.circle")
                    }.accessibilityLabel(L10n.text("移除%@的触控板例外", String(describing: app.name)))
                }
            }
            Button(L10n.text("添加不启用增强的应用…")) { addException() }
        }
    }

    private func ruleRow(_ rule: TrackpadBinding) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: rule.gesture.symbol).font(.system(size: 18)).foregroundStyle(.tint)
                .frame(width: 24).padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(trackpadModifierTitle(rule.modifiers) + rule.gesture.title).font(.callout.weight(.medium))
                Text("\(rule.action.title) · \(applicationName(rule.bundleIdentifier))")
                    .font(.caption).foregroundStyle(.secondary)
                if rule.enabled, let conflict = native.status.conflict(for: rule.gesture) {
                    Text(conflict).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            Toggle(L10n.text("启用%@", String(describing: rule.gesture.title)), isOn: ruleEnabled(rule.id)).labelsHidden().toggleStyle(.switch)
                .accessibilityLabel(L10n.text("启用%@%@，%@", String(describing: trackpadModifierTitle(rule.modifiers)), String(describing: rule.gesture.title), String(describing: applicationName(rule.bundleIdentifier))))
            Button { editing = rule } label: { Image(systemName: "pencil") }
                .accessibilityLabel(L10n.text("编辑%@，%@", String(describing: rule.gesture.title), String(describing: applicationName(rule.bundleIdentifier))))
            Button { model.configuration.trackpad.bindings.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle") }
                .accessibilityLabel(L10n.text("删除%@，%@", String(describing: rule.gesture.title), String(describing: applicationName(rule.bundleIdentifier))))
        }.padding(.vertical, 5)
    }

    private func ruleEnabled(_ id: UUID) -> Binding<Bool> {
        Binding(get: { model.configuration.trackpad.bindings.first { $0.id == id }?.enabled ?? false }, set: { value in
            if let index = model.configuration.trackpad.bindings.firstIndex(where: { $0.id == id }) {
                model.configuration.trackpad.bindings[index].enabled = value
            }
        })
    }

    @ViewBuilder private var nativeSections: some View {
        Section {
            Text(L10n.text("系统四指手势负责调度中心和空间切换，MacDaily 三指手势负责标签页和窗口。"))
                .font(.callout)
            Button(L10n.text("刷新系统配置")) { native.refresh() }
        }
        ForEach(native.rows, id: \.id) { row in
            Section(row.title) {
                HStack {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            Text(L10n.text("当前：%@", String(describing: row.current)))
                            if row.hasConflict { Text(L10n.text("需要调整")).font(.caption).foregroundStyle(.orange) }
                        }
                        Text(L10n.text("建议：%@", String(describing: row.recommended))).font(.callout).foregroundStyle(.secondary)
                        Text(row.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button(L10n.text("打开设置 ↗")) { native.open(row) }.accessibilityLabel(L10n.text("打开%@的系统设置", String(describing: row.title)))
                }.padding(.vertical, 3)
            }
        }
    }

    @ViewBuilder private var testingSections: some View {
        Section(L10n.text("识别试用")) {
            HStack {
                Text(runtime.testing ? L10n.text("试用中") : L10n.text("开始后，用内建触控板进行操作"))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(runtime.testing ? L10n.text("结束试用") : L10n.text("开始试用")) {
                    runtime.testing ? runtime.endTesting() : runtime.beginTesting()
                }.buttonStyle(.borderedProminent)
            }
            TrackpadTouchBoard(contacts: runtime.contacts, cornerSize: model.configuration.trackpad.cornerSize)
                .frame(height: 225).padding(.vertical, 10)
            HStack {
                Label(L10n.text("%@ 指", String(describing: runtime.contacts.count)), systemImage: "hand.point.up.left")
                Spacer()
                Text(runtime.lastGesture?.title ?? L10n.text("尚未识别手势")).foregroundStyle(.secondary)
            }.font(.callout)
            Text(runtime.feedback).font(.callout).textSelection(.enabled)
            Text(L10n.text("试用显示触点与识别结果，不执行快捷键或窗口动作。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        Section(L10n.text("分屏练习")) {
            Text(L10n.text("结束识别试用后，可在专用练习窗口验证布局预览、分屏和还原。"))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(L10n.text("打开分屏练习窗口")) { model.openWindowPractice() }
                if model.windowPracticeActive { Button(L10n.text("结束分屏练习")) { model.endWindowPractice() } }
            }
        }
    }

    private func addException() {
        guard let app = chooseTrackpadApplication(title: L10n.text("选择不启用触控板增强的应用")),
              !model.configuration.trackpad.excludedApps.contains(where: { $0.bundleIdentifier == app.id }) else { return }
        model.configuration.trackpad.excludedApps.append(.init(bundleIdentifier: app.id, name: app.name))
    }
}

private struct TrackpadTouchBoard: View {
    let contacts: [TrackpadContact]
    let cornerSize: Double
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                RoundedRectangle(cornerRadius: 20).fill(Color.primary.opacity(0.04))
                ForEach(0..<4, id: \.self) { corner in
                    let width = size.width * cornerSize, height = size.height * cornerSize
                    RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.12))
                        .frame(width: width, height: height)
                        .position(x: corner % 2 == 0 ? width / 2 : size.width - width / 2,
                                  y: corner < 2 ? height / 2 : size.height - height / 2)
                }
                ForEach(Array(contacts.enumerated()), id: \.element.id) { index, contact in
                    Text("\(index + 1)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 32, height: 32).background(.tint, in: Circle())
                        .position(x: min(1, max(0, contact.x)) * size.width,
                                  y: (1 - min(1, max(0, contact.y))) * size.height)
                }
                if contacts.isEmpty {
                    Text(L10n.text("触点会显示在这里")).font(.callout).foregroundStyle(.secondary)
                }
            }.overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.quaternary, lineWidth: 1))
        }.accessibilityElement(children: .ignore).accessibilityLabel(L10n.text("内建触控板试用区，%@个触点", String(describing: contacts.count)))
    }
}

private enum TrackpadActionKind: String, CaseIterable, Identifiable {
    case shortcut = "快捷键", middle = "中键点按", window = "窗口布局", quick = "快捷功能", dashboard = "MacDaily 面板", system = "系统动作"
    var id: String { rawValue }
}

private struct TrackpadRuleEditor: View {
    @ObservedObject var model: AppModel
    @ObservedObject var native: NativeTrackpadSettingsReader
    @Environment(\.dismiss) private var dismiss
    @TrackpadViewState private var draft: TrackpadBinding
    @TrackpadViewState private var kind: TrackpadActionKind
    @TrackpadViewState private var shortcut: Shortcut
    @TrackpadViewState private var windowAction: WindowAction
    @TrackpadViewState private var quickAction: DashboardAction
    @TrackpadViewState private var systemAction: MouseSystemAction
    @TrackpadViewState private var applicationOnly: Bool
    @TrackpadViewState private var selectedApplication: String?
    @TrackpadViewState private var error: String?

    init(model: AppModel, native: NativeTrackpadSettingsReader, rule: TrackpadBinding) {
        self.model = model; self.native = native
        _draft = TrackpadViewState(initialValue: rule)
        var actionKind: TrackpadActionKind = .middle
        var shortcut = Shortcut(keyCode: 48, modifiers: Shortcut.command, label: "⌘Tab")
        var window: WindowAction = .maximize
        var quick: DashboardAction = .keepAwake
        var system: MouseSystemAction = .minimize
        switch rule.action {
        case .shortcut(let value): actionKind = .shortcut; shortcut = value
        case .window(let value): actionKind = .window; window = value
        case .quick(let value): actionKind = .quick; quick = value
        case .middleClick: actionKind = .middle
        case .showDashboard: actionKind = .dashboard
        case .system(let value): actionKind = .system; system = value
        }
        _kind = TrackpadViewState(initialValue: actionKind)
        _shortcut = TrackpadViewState(initialValue: shortcut)
        _windowAction = TrackpadViewState(initialValue: window)
        _quickAction = TrackpadViewState(initialValue: quick)
        _systemAction = TrackpadViewState(initialValue: system)
        _applicationOnly = TrackpadViewState(initialValue: rule.bundleIdentifier != nil)
        _selectedApplication = TrackpadViewState(initialValue: rule.bundleIdentifier)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text("编辑触控板规则")).font(.title2.weight(.semibold))
                Spacer()
                Button(L10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("保存")) { save() }.keyboardShortcut(.defaultAction)
                    .disabled(applicationOnly && selectedApplication == nil)
            }.padding(20)
            Form {
                Section(L10n.text("触发方式")) {
                    Picker(L10n.text("手势"), selection: $draft.gesture) {
                        ForEach(TrackpadGesture.allCases) { Text($0.title).tag($0) }
                    }.onChange(of: draft.gesture) { _, gesture in draft.modifiers = gesture.requiredModifiers }
                    HStack {
                        Text(L10n.text("同时按住"))
                        Spacer()
                        modifierToggle("Control", bit: Shortcut.control)
                        modifierToggle("Option", bit: Shortcut.option)
                        modifierToggle("Shift", bit: Shortcut.shift)
                        modifierToggle("Command", bit: Shortcut.command)
                    }
                    Toggle(L10n.text("启用这条规则"), isOn: $draft.enabled)
                    if let conflict = native.status.conflict(for: draft.gesture) {
                        Text(conflict).font(.caption).foregroundStyle(.orange)
                    }
                }
                Section(L10n.text("执行动作")) {
                    Picker(L10n.text("动作类型"), selection: $kind) { ForEach(TrackpadActionKind.allCases) { Text(L10n.text($0.rawValue)).tag($0) } }
                    switch kind {
                    case .shortcut:
                        HStack {
                            Text(L10n.text("输出快捷键"))
                            Spacer()
                            TrackpadShortcutRecorder(shortcut: $shortcut, onBegin: model.beginShortcutRecording, onEnd: model.endShortcutRecording)
                                .frame(width: 210, height: 28)
                        }
                    case .window:
                        Picker(L10n.text("布局"), selection: $windowAction) { ForEach(WindowAction.allCases) { Text($0.title).tag($0) } }
                    case .quick:
                        Picker(L10n.text("功能"), selection: $quickAction) { ForEach(DashboardAction.allCases) { Text($0.title).tag($0) } }
                        Text(quickAction.description).font(.caption).foregroundStyle(.secondary)
                    case .system: Picker(L10n.text("系统动作"), selection: $systemAction) { ForEach(MouseSystemAction.allCases, id: \.self) { Text($0.title).tag($0) } }
                    case .middle: Text(L10n.text("在指针位置按下并松开中键。"))
                    case .dashboard: Text(L10n.text("打开菜单栏中的 MacDaily 概览与收纳面板。"))
                    }
                }
                Section(L10n.text("应用范围")) {
                    Toggle(L10n.text("仅在指定应用中使用"), isOn: $applicationOnly)
                    if applicationOnly {
                        HStack {
                            Text(selectedApplication.map { applicationName($0) } ?? L10n.text("选择应用"))
                            Spacer()
                            Button(L10n.text("选择应用…")) {
                                if let app = chooseTrackpadApplication(title: L10n.text("选择这条规则适用的应用")) { selectedApplication = app.id }
                            }
                        }
                    }
                    Text(L10n.text("应用专属规则优先于相同手势的全局规则。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Section { Text(error).foregroundStyle(.orange).textSelection(.enabled) } }
            }.formStyle(.grouped)
        }.frame(width: 650, height: 560)
    }

    private func modifierToggle(_ title: String, bit: UInt64) -> some View {
        Toggle(title, isOn: Binding(get: { draft.modifiers & bit != 0 }, set: { value in
            if value { draft.modifiers |= bit } else { draft.modifiers &= ~bit }
        })).toggleStyle(.checkbox).fixedSize()
    }
    private func save() {
        switch kind {
        case .shortcut: draft.action = .shortcut(shortcut)
        case .middle: draft.action = .middleClick
        case .window: draft.action = .window(windowAction)
        case .quick: draft.action = .quick(quickAction)
        case .dashboard: draft.action = .showDashboard
        case .system: draft.action = .system(systemAction)
        }
        draft.bundleIdentifier = applicationOnly ? selectedApplication : nil
        var settings = model.configuration.trackpad
        if let index = settings.bindings.firstIndex(where: { $0.id == draft.id }) { settings.bindings[index] = draft }
        else { settings.bindings.append(draft) }
        do {
            _ = try settings.validated()
            model.configuration.trackpad = settings
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct TrackpadShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut
    let onBegin: () -> Void
    let onEnd: () -> Void
    func makeNSView(context: Context) -> TrackpadRecorderButton {
        let button = TrackpadRecorderButton(frame: .zero)
        updateNSView(button, context: context)
        return button
    }
    func updateNSView(_ button: TrackpadRecorderButton, context: Context) {
        button.onRecord = { shortcut = $0 }
        button.onBegin = onBegin; button.onEnd = onEnd
        button.setShortcut(shortcut)
    }
    static func dismantleNSView(_ button: TrackpadRecorderButton, coordinator: ()) { button.finish() }
}

private final class TrackpadRecorderButton: NSButton {
    var onRecord: ((Shortcut) -> Void)?
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    private var recording = false
    private var current: Shortcut?
    override var acceptsFirstResponder: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded; controlSize = .regular
        target = self; action = #selector(begin)
        font = .systemFont(ofSize: 12)
        setAccessibilityLabel(L10n.text("录制触控板输出快捷键"))
        toolTip = L10n.text("点击后按下快捷键；Esc 取消")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setShortcut(_ shortcut: Shortcut) {
        current = shortcut
        if !recording { title = shortcut.displayLabel }
    }
    @objc private func begin() {
        guard !recording else { finish(); return }
        recording = true; title = L10n.text("按下快捷键 · Esc 取消")
        onBegin?(); window?.makeFirstResponder(self)
    }
    func finish() {
        guard recording else { return }
        recording = false; title = current?.displayLabel ?? L10n.text("录制快捷键"); onEnd?()
    }
    override func resignFirstResponder() -> Bool { finish(); return super.resignFirstResponder() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return false }
        record(event); return true
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        record(event)
    }
    private func record(_ event: NSEvent) {
        let modifiers = UInt64(event.modifierFlags.rawValue) & Shortcut.modifierMask
        if event.keyCode == 53 && modifiers == 0 { finish(); return }
        guard event.keyCode < 128, ![54,55,56,57,58,59,60,61,62,63].contains(event.keyCode) else { return }
        let symbols: [UInt16: String] = [36: "Return",48: "Tab",49: "Space",51: "⌫",53: "Esc",76: "Enter",117: "⌦",123: "←",124: "→",125: "↓",126: "↑"]
        let key = symbols[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        let shortcut = Shortcut(keyCode: event.keyCode, modifiers: modifiers, label: trackpadModifierTitle(modifiers) + key)
        current = shortcut; onRecord?(shortcut); finish()
    }
}

private func trackpadModifierTitle(_ modifiers: UInt64) -> String {
    [(Shortcut.control, "⌃"), (Shortcut.option, "⌥"), (Shortcut.shift, "⇧"), (Shortcut.command, "⌘")]
        .filter { modifiers & $0.0 != 0 }.map(\.1).joined()
}

private func applicationName(_ identifier: String?) -> String {
    guard let identifier else { return L10n.text("所有应用") }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return identifier }
    return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
}

private func chooseTrackpadApplication(title: String) -> (id: String, name: String)? {
    let panel = NSOpenPanel()
    panel.title = title; panel.allowedContentTypes = [.applicationBundle]
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
    let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
    return (id, name)
}
