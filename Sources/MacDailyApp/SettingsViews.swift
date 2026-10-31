import AppKit
import MacDailyCore
import SwiftUI

// Spell the property-wrapper type explicitly: the macOS 27 SDK also exports a
// same-named State macro whose plugin is not included in Command Line Tools.
private typealias ViewState<Value> = SwiftUI.State<Value>

enum ToolPage: String, CaseIterable, Identifiable {
    case dashboard = "概览", mouse = "鼠标", trackpad = "触控板", windows = "窗口", menuBar = "菜单栏", applications = "应用", storage = "空间", settings = "设置"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.50percent"
        case .mouse: "computermouse"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .windows: "rectangle.split.2x1"
        case .menuBar: "menubar.rectangle"
        case .applications: "square.grid.2x2"
        case .storage: "internaldrive"
        case .settings: "gearshape"
        }
    }
    var isPlanned: Bool { false }
}
private enum MousePane: String, CaseIterable, Identifiable {
    case scroll = "滚动", pointer = "指针", bindings = "按键与手势", exceptions = "应用例外"
    var id: String { rawValue }
}

struct SettingsRootView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("MacDaily").font(.title2.weight(.semibold))
                    Text(L10n.text("日常操作，简单集中")).font(.caption).foregroundStyle(.secondary)
                }.padding(20)
                List(selection: $model.selectedToolPage) {
                    Section(L10n.text("日常工具")) {
                        sidebarRow(.dashboard)
                        sidebarRow(.mouse)
                        sidebarRow(.trackpad)
                        sidebarRow(.windows)
                        sidebarRow(.menuBar)
                        sidebarRow(.storage)
                        sidebarRow(.applications)
                    }
                    Section { sidebarRow(.settings) }
                }.listStyle(.sidebar)
                Text("v1.0").font(.caption).foregroundStyle(.tertiary).padding(20)
            }.navigationSplitViewColumnWidth(min: 190, ideal: 205, max: 240)
        } detail: {
            VStack(spacing: 0) {
                if let error = model.errorMessage {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(error).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(L10n.text("关闭提示"))
                    }.padding(14).background(.orange.opacity(0.08))
                }
                switch model.selectedToolPage ?? .dashboard {
                case .dashboard: DashboardView(model: model.dashboard, compact: false)
                case .mouse: MouseSettingsView(model: model)
                case .trackpad: TrackpadSettingsView(model: model)
                case .windows: WindowSettingsView(model: model)
                case .menuBar: MenuBarSettingsView(model: model)
                case .applications:
                    ApplicationsView(model: model)
                case .storage:
                    StorageSettingsView(model: model)
                case .settings: GeneralSettingsView(model: model)
                }
            }
        }
        .onAppear {
            let action = openWindow
            AppDelegate.openSettings = {
                action(id: "settings")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            model.refreshEnvironment()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MacDaily.showWindows"))) { _ in model.selectedToolPage = .windows }
    }

    private func sidebarRow(_ item: ToolPage) -> some View {
        HStack(spacing: 8) {
            Label(L10n.text(item.rawValue), systemImage: item.symbol)
            Spacer(minLength: 4)
            if item.isPlanned { Text(L10n.text("未实现")).font(.caption2).foregroundStyle(.tertiary) }
        }
        .foregroundStyle(item.isPlanned ? .secondary : .primary)
        .padding(.vertical, 5)
        .tag(item)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.isPlanned ? L10n.text("%@，尚未实现", L10n.text(item.rawValue)) : L10n.text(item.rawValue))
    }
}

private struct PlannedModuleView: View {
    let symbol: String
    let title: String
    let description: String
    let detail: String
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol).font(.system(size: 46, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.largeTitle.weight(.semibold))
            Text(description).font(.body)
            Text(L10n.text("尚未实现")).font(.caption.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 5).background(.quaternary, in: Capsule())
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }
}

private struct MouseSettingsView: View {
    @ObservedObject var model: AppModel
    @ViewState private var pane: MousePane = .scroll
    @ViewState private var localEvent = L10n.text("可在这里试用滚轮、普通点击与拖动")
    @ViewState private var showTest = false
    @StateObject private var mousePresentations = MouseBindingsPresentationState()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("鼠标")).font(.largeTitle.weight(.semibold))
                    Text(L10n.text("调整滚动手感，设置按键与方向手势。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.isPaused ? L10n.text("启用鼠标增强") : L10n.text("暂停鼠标增强")) { model.togglePaused() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.accessibilityGranted || !model.conflicts.isEmpty || model.configurationNeedsRecovery || model.gestureTesting || model.mouseInspectionActive)
                    .controlSize(.large)
            }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 16)
            if !model.accessibilityGranted {
                HStack(spacing: 12) {
                    Image(systemName: "hand.raised").foregroundStyle(.tint)
                    Text(L10n.text("授权辅助功能后，MacDaily 才能调整鼠标输入。"))
                        .font(.callout)
                    Spacer()
                    Button(L10n.text("前往授权")) { model.requestAccessibility() }
                    Button(L10n.text("重新检查")) { model.refreshEnvironment() }
                }.padding(12).background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 24).padding(.bottom, 12)
            }
            else if !model.conflicts.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "pause.circle").foregroundStyle(.orange)
                    Text(L10n.text("检测到 %@。请先退出它们，再启用 MacDaily，避免重复处理鼠标。", String(describing: model.conflicts.joined(separator: "、"))))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("重新检查")) { model.refreshEnvironment() }
                }.padding(12).background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 24).padding(.bottom, 12)
            } else {
                Label(model.status, systemImage: model.isPaused ? "pause.circle" : "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 24).padding(.bottom, 12)
            }
            Picker(L10n.text("鼠标设置"), selection: $pane) {
                ForEach(MousePane.allCases) { value in Text(L10n.text(value.rawValue)).tag(value) }
            }.pickerStyle(.segmented).padding(.horizontal, 24).padding(.bottom, 4)
            Form {
                switch pane {
                case .scroll: scrollSection
                case .pointer: pointerSection
                case .bindings: bindingsSection
                case .exceptions: exceptionsSection
                }
                Section {
                    DisclosureGroup(L10n.text("试用鼠标"), isExpanded: $showTest) {
                        MouseTestArea(eventLabel: $localEvent).frame(height: 78)
                        HStack {
                            Text(localEvent).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(model.lastAction).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.padding(.top, 5)
                    }
                }
            }.formStyle(.grouped)
        }
        .modifier(MouseBindingsPresentationHost(model: model, presentation: mousePresentations))
    }

    @ViewBuilder private var scrollSection: some View {
        Section(L10n.text("滚动手感")) {
            Toggle(L10n.text("平滑滚动"), isOn: $model.configuration.scroll.smoothEnabled)
            ValueSlider(title: L10n.text("滚动速度"), value: $model.configuration.scroll.speed, range: 0.2...4, valueLabel: String(format: "%.1f×", model.configuration.scroll.speed))
            ValueSlider(title: L10n.text("平滑时长"), value: $model.configuration.scroll.smoothing, range: 0.04...0.5, valueLabel: "\(Int(model.configuration.scroll.smoothing * 1000)) ms")
                .disabled(!model.configuration.scroll.smoothEnabled)
            Text(L10n.text("较短的时长更跟手，较长的时长更柔和。只增强普通鼠标滚轮，触控板保持原有行为。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        Section(L10n.text("方向与修饰键")) {
            Toggle(L10n.text("垂直滚动反向"), isOn: $model.configuration.scroll.reverseVertical)
            Toggle(L10n.text("水平滚动反向"), isOn: $model.configuration.scroll.reverseHorizontal)
            Toggle(L10n.text("按住 Control、Option 或 Command 时暂时关闭平滑"), isOn: $model.configuration.scroll.bypassWithModifiers)
        }
    }

    @ViewBuilder private var pointerSection: some View {
        Section(L10n.text("指针控制")) {
            Toggle(L10n.text("接管鼠标指针设置"), isOn: $model.configuration.pointer.enabled)
            Text(L10n.text("关闭时保持系统值。启用后会先保存原值，暂停或正常退出时恢复。"))
                .font(.caption).foregroundStyle(.secondary)
            ValueSlider(title: L10n.text("指针速度"), value: $model.configuration.pointer.speed, range: 0.2...4, valueLabel: String(format: "%.1f×", model.configuration.pointer.speed))
                .disabled(!model.configuration.pointer.enabled)
            Toggle(L10n.text("关闭指针加速"), isOn: $model.configuration.pointer.disableAcceleration)
                .disabled(!model.configuration.pointer.enabled)
            ValueSlider(title: L10n.text("指针加速"), value: $model.configuration.pointer.acceleration, range: 0...3, valueLabel: String(format: "%.2f", model.configuration.pointer.acceleration))
                .disabled(!model.configuration.pointer.enabled || model.configuration.pointer.disableAcceleration)
            Text(model.pointerStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        Section(L10n.text("已识别的鼠标")) {
            if model.deviceNames.isEmpty {
                Text(model.isPaused ? L10n.text("启用鼠标增强后显示已连接设备。") : L10n.text("暂未识别到外接鼠标。"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.deviceNames, id: \.self) { name in Label(name, systemImage: "computermouse") }
            }
            Text(L10n.text("设备不支持高级指针设置时，滚轮和按键功能仍可独立使用。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var bindingsSection: some View {
        MouseBindingsSections(model: model, presentation: mousePresentations)
    }

    @ViewBuilder private var exceptionsSection: some View {
        Section {
            Text(L10n.text("为设计软件、远程桌面或游戏保留原生鼠标行为。每个开关表示在该应用中停用对应增强。"))
                .font(.callout).foregroundStyle(.secondary)
        }
        Section(L10n.text("应用例外")) {
            if model.configuration.exceptions.isEmpty {
                Text(L10n.text("尚未添加应用例外")).foregroundStyle(.secondary)
            }
            ForEach($model.configuration.exceptions) { $exception in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(exception.name).fontWeight(.medium)
                            Text(exception.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { model.removeException(exception.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).accessibilityLabel(L10n.text("移除 %@ 例外", String(describing: exception.name)))
                    }
                    HStack(spacing: 18) {
                        Toggle(L10n.text("停用滚轮增强"), isOn: $exception.disableScrolling)
                        Toggle(L10n.text("停用按键组合"), isOn: $exception.disableBindings)
                        Toggle(L10n.text("停用方向手势"), isOn: $exception.disableGestures)
                    }.toggleStyle(.checkbox).font(.caption)
                }.padding(.vertical, 4)
            }
            Button { model.addApplicationException() } label: { Label(L10n.text("添加应用"), systemImage: "plus") }
                .disabled(model.configuration.exceptions.count >= 128)
        }
    }
}

private struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let valueLabel: String
    var body: some View {
        HStack(spacing: 16) {
            Text(title).frame(width: 110, alignment: .leading)
            Slider(value: $value, in: range).accessibilityLabel(title)
            Text(valueLabel).monospacedDigit().foregroundStyle(.secondary).frame(width: 58, alignment: .trailing)
        }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section(L10n.text("语言")) {
                Picker(L10n.text("界面语言"), selection: $model.appLanguage) {
                    Text(L10n.text("跟随系统")).tag(AppLanguage.system)
                    Text("简体中文").tag(AppLanguage.simplifiedChinese)
                    Text("English").tag(AppLanguage.english)
                }
                Text(L10n.text("重新打开 MacDaily 后应用所选语言。"))
                    .font(.caption).foregroundStyle(.secondary)
                if model.languageNeedsReopen {
                    Button(L10n.text("重新打开应用")) { model.reopenForLanguage() }
                }
            }
            Section("MacDaily") {
                Text(L10n.text("统一常用操作，保持简洁和轻量。"))
                Text(L10n.text("鼠标、窗口与空间独立设置，应用管理功能正在规划中。"))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L10n.text("开机启动"), isOn: Binding(get: { model.startupEnabled }, set: model.setStartup))
            }
            Section(L10n.text("权限")) {
                LabeledContent(L10n.text("辅助功能"), value: model.accessibilityGranted ? L10n.text("已授权") : L10n.text("未授权"))
                HStack {
                    Button(L10n.text("打开权限设置")) { model.requestAccessibility() }
                    Button(L10n.text("重新检查")) { model.refreshEnvironment() }
                }
                Text(L10n.text("鼠标增强与窗口控制共用辅助功能权限。空间按需读取文件；完全磁盘访问权限仅用于扩大可扫描范围。应用模块不申请权限。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.text("配置")) {
                HStack {
                    Button(L10n.text("导入…")) { model.importConfiguration() }
                    Button(L10n.text("导出…")) { model.exportConfiguration() }
                    Spacer()
                    Button(L10n.text("恢复默认…")) { model.restoreDefaults() }
                }
                Text(L10n.text("导入前会校验配置，并暂停输入增强，检查后再启用。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.text("本地处理")) {
                Text(L10n.text("配置仅保存在本机。不记录日常键鼠输入，不建立全盘索引。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).navigationTitle(L10n.text("设置"))
    }
}

private func modifierTitle(_ value: UInt64) -> String {
    [(Shortcut.control,"⌃"),(Shortcut.option,"⌥"),(Shortcut.shift,"⇧"),(Shortcut.command,"⌘")]
        .filter { value & $0.0 != 0 }.map(\.1).joined()
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut
    let onBegin: () -> Void
    let onEnd: () -> Void
    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton(frame: .zero)
        button.onRecord = { shortcut = $0 }
        button.onBegin = onBegin; button.onEnd = onEnd
        button.setShortcut(shortcut)
        return button
    }
    func updateNSView(_ button: RecorderButton, context: Context) {
        button.onRecord = { shortcut = $0 }
        button.onBegin = onBegin; button.onEnd = onEnd
        button.setShortcut(shortcut)
    }
    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) { button.finish() }
}

final class RecorderButton: NSButton {
    var onRecord: ((Shortcut) -> Void)?
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    private var recording = false
    private var current: Shortcut?
    override var acceptsFirstResponder: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        controlSize = .regular
        target = self; action = #selector(begin)
        font = .systemFont(ofSize: 12)
        setAccessibilityLabel(L10n.text("录制输出快捷键"))
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
        onBegin?()
        window?.makeFirstResponder(self)
    }
    func finish() {
        guard recording else { return }
        recording = false
        title = current?.displayLabel ?? L10n.text("录制快捷键")
        onEnd?()
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
        let symbols: [UInt16:String] = [36:"Return",48:"Tab",49:"Space",51:"⌫",53:"Esc",76:"Enter",117:"⌦",123:"←",124:"→",125:"↓",126:"↑"]
        let key = symbols[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        let value = Shortcut(keyCode: event.keyCode, modifiers: modifiers, label: modifierTitle(modifiers) + key)
        current = value
        onRecord?(value)
        finish()
    }
}

private struct MouseTestArea: NSViewRepresentable {
    @Binding var eventLabel: String
    func makeNSView(context: Context) -> MouseTestNSView {
        let view = MouseTestNSView()
        view.onEvent = { eventLabel = $0 }
        return view
    }
    func updateNSView(_ nsView: MouseTestNSView, context: Context) { nsView.onEvent = { eventLabel = $0 } }
}
private final class MouseTestNSView: NSView {
    var onEvent: ((String) -> Void)?
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        path.lineWidth = 1; path.stroke()
        let text = L10n.text("将指针放在这里，试用鼠标") as NSString
        let attrs: [NSAttributedString.Key:Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width)/2, y: (bounds.height - size.height)/2), withAttributes: attrs)
    }
    override func mouseDown(with event: NSEvent) { onEvent?(L10n.text("左键按下")) }
    override func mouseUp(with event: NSEvent) { onEvent?(L10n.text("左键释放")) }
    override func rightMouseDown(with event: NSEvent) { onEvent?(L10n.text("右键按下")) }
    override func rightMouseUp(with event: NSEvent) { onEvent?(L10n.text("右键释放")) }
    override func otherMouseDown(with event: NSEvent) { onEvent?(L10n.text("%@ 按下", String(describing: MouseBinding.buttonName(event.buttonNumber)))) }
    override func otherMouseUp(with event: NSEvent) { onEvent?(L10n.text("%@ 释放", String(describing: MouseBinding.buttonName(event.buttonNumber)))) }
    override func mouseDragged(with event: NSEvent) { onEvent?(L10n.text("普通拖动")) }
    override func rightMouseDragged(with event: NSEvent) { onEvent?(L10n.text("右键拖动")) }
    override func otherMouseDragged(with event: NSEvent) { onEvent?(L10n.text("%@ 拖动", String(describing: MouseBinding.buttonName(event.buttonNumber)))) }
    override func scrollWheel(with event: NSEvent) {
        let axis = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? L10n.text("垂直") : L10n.text("水平")
        onEvent?(L10n.text("%@滚动 · %@", String(describing: axis), String(describing: event.hasPreciseScrollingDeltas ? L10n.text("连续") : L10n.text("刻度"))))
    }
}
