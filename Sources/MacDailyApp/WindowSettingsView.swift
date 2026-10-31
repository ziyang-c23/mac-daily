import AppKit
import MacDailyCore
import SwiftUI

private typealias WindowViewState<Value> = SwiftUI.State<Value>

struct WindowSettingsView: View {
    @ObservedObject var model: AppModel
    @WindowViewState private var showExceptions = false
    @WindowViewState private var showActivationEditor = false
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("窗口")).font(.largeTitle.weight(.semibold))
                Text(L10n.text("把窗口拖到激活区域，预览后松手完成分屏。"))
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 16)
            if !model.accessibilityGranted {
                HStack(spacing: 12) {
                    Image(systemName: "hand.raised").foregroundStyle(.tint)
                    Text(L10n.text("允许辅助功能权限后，即可调整其他应用的窗口。"))
                        .font(.callout)
                    Spacer()
                    Button(L10n.text("前往授权")) { model.requestAccessibility() }
                    Button(L10n.text("重新检查")) { model.refreshEnvironment() }
                }.padding(12).background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 24).padding(.bottom, 8)
            }
            Form {
                Section(L10n.text("拖拽分屏")) {
                    Toggle(L10n.text("拖拽吸附"), isOn: Binding(get: { model.windowSnappingRequested }, set: { model.setWindowSnapping($0) }))
                        .disabled(!model.accessibilityGranted || model.configurationNeedsRecovery)
                    HStack(spacing: 10) {
                        Image(systemName: model.windowRunning ? "checkmark.circle.fill" : "pause.circle")
                            .foregroundStyle(model.windowRunning ? Color.accentColor : Color.secondary)
                        Text(model.windowStatus).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Picker(L10n.text("激活方式"), selection: $model.configuration.windows.activationMode) {
                        Text(L10n.text("默认边缘")).tag(WindowActivationMode.standard)
                        Text(L10n.text("自定义区域")).tag(WindowActivationMode.custom)
                    }.pickerStyle(.segmented)
                    HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.text("分别设置横屏、竖屏的触发位置与窗口布局。"))
                                Text(L10n.text("区域重叠时，列表中靠前的已启用区域优先。"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(L10n.text("自定义激活区域")) { showActivationEditor = true }
                                .disabled(model.configurationNeedsRecovery)
                        }
                    if model.configuration.windows.activationMode == .custom {
                        Toggle(L10n.text("拖拽时标出激活区域"), isOn: $model.configuration.windows.highlightActivationAreas)
                    } else {
                    HStack(spacing: 20) {
                        dragHint(L10n.text("左右边缘"), detail: L10n.text("半屏"), action: .leftHalf)
                        dragHint(L10n.text("四个角落"), detail: L10n.text("四分屏"), action: .topLeft)
                        dragHint(L10n.text("顶部"), detail: L10n.text("填满屏幕"), action: .maximize)
                        dragHint(L10n.text("底部"), detail: L10n.text("三分屏"), action: .centerThird)
                    }.padding(.vertical, 6)
                    Text(L10n.text("沿底边横移可扩展到三分之二。"))
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .center, spacing: 12) {
                        Text(L10n.text("松手前按 Esc 可取消。"))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button(model.windowPracticeActive ? L10n.text("重新打开练习窗口") : L10n.text("打开练习窗口")) { model.openWindowPractice() }
                            .help(L10n.text("用独立练习窗口试用分屏，不移动正在处理的内容"))
                        if model.windowPracticeActive {
                            Button(L10n.text("结束练习")) { model.endWindowPractice() }
                        }
                    }
                    if model.windowPracticeActive {
                        Label(L10n.text("练习目标已固定"), systemImage: "scope")
                            .font(.callout.weight(.medium)).foregroundStyle(Color.accentColor)
                        Text(L10n.text("切换应用不会改变练习目标；结束练习后恢复原来的吸附设置。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section(L10n.text("快速排列")) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "macwindow").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.windowTarget).font(.callout.weight(.medium)).lineLimit(2)
                            Text(model.windowPracticeActive ? L10n.text("仅调整练习窗口。") : L10n.text("布局按钮作用于上方目标窗口。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.padding(.bottom, 6)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(layoutActions) { action in
                            layoutButton(action)
                        }
                    }
                }
                Section(L10n.text("使用偏好")) {
                    HStack(spacing: 14) {
                        Text(L10n.text("窗口间距")).frame(width: 86, alignment: .leading)
                        Slider(value: $model.configuration.windows.gap, in: 0...32, step: 1)
                            .accessibilityLabel(L10n.text("窗口间距"))
                        Text("\(Int(model.configuration.windows.gap)) pt")
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    }
                    Toggle(L10n.text("拖拽时显示布局预览"), isOn: $model.configuration.windows.previewEnabled)
                    Toggle(L10n.text("拖离分屏位置时恢复原大小"), isOn: $model.configuration.windows.restoreOnDrag)
                    Text(L10n.text("间距同时留在屏幕边缘。若已使用其他拖拽分屏工具，建议只启用其中一个。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    DisclosureGroup(L10n.text("不参与拖拽的应用"), isExpanded: $showExceptions) {
                        Text(L10n.text("这些应用保留原生拖拽行为，仍可使用上方按钮或鼠标绑定调整窗口。"))
                            .font(.caption).foregroundStyle(.secondary).padding(.bottom, 5)
                        if model.configuration.windows.excludedApps.isEmpty {
                            Text(L10n.text("尚未添加应用")).foregroundStyle(.secondary)
                        }
                        ForEach(model.configuration.windows.excludedApps) { app in
                            HStack {
                                Label(app.name, systemImage: "app")
                                Spacer()
                                Button { model.removeWindowException(app.id) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).accessibilityLabel(L10n.text("移除 %@ 窗口例外", String(describing: app.name)))
                            }.padding(.vertical, 4)
                        }
                        Button { model.addWindowException() } label: { Label(L10n.text("添加应用"), systemImage: "plus") }
                            .disabled(model.configuration.windows.excludedApps.count >= 128)
                            .padding(.top, 5)
                    }
                }
                Section {
                    Label(L10n.text("也可以在「鼠标 → 按键与手势」中，将侧键或方向手势绑定为窗口动作。"), systemImage: "computermouse")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }
        .sheet(isPresented: $showActivationEditor) {
            WindowActivationEditor(settings: model.configuration.windows) { updated in
                model.applyWindowActivationSettings(updated)
            }
        }
    }

    private var layoutActions: [WindowAction] {
        [.leftHalf, .rightHalf, .topHalf, .bottomHalf,
         .topLeft, .topRight, .bottomLeft, .bottomRight,
         .leftThird, .centerThird, .rightThird, .leftTwoThirds,
         .rightTwoThirds, .maximize, .center, .restore,
         .previousDisplay, .nextDisplay]
    }

    private func layoutButton(_ action: WindowAction) -> some View {
        Button { model.performWindowAction(action) } label: {
            VStack(spacing: 7) {
                WindowLayoutGlyph(action: action).frame(width: 44, height: 28)
                Text(action.title).font(.caption).lineLimit(1).minimumScaleFactor(0.85)
            }.frame(maxWidth: .infinity).frame(height: 66)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .disabled(!model.accessibilityGranted || model.configurationNeedsRecovery)
        .accessibilityLabel(action.title)
        .help(L10n.text("对目标窗口执行：%@", String(describing: action.title)))
    }

    private func dragHint(_ title: String, detail: String, action: WindowAction) -> some View {
        VStack(spacing: 5) {
            WindowLayoutGlyph(action: action).frame(width: 40, height: 26)
            Text(title).font(.caption.weight(.medium))
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

/// Small layout illustrations share the actual layout geometry, including the
/// Quartz top-left coordinate convention used by SwiftUI's drawing space.
struct WindowLayoutGlyph: View {
    let action: WindowAction
    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.55), lineWidth: 1)
                if let rect = WindowGeometry.frame(for: action, in: bounds.insetBy(dx: 3, dy: 3), current: CGRect(x: 6, y: 5, width: bounds.width * 0.58, height: bounds.height * 0.62), gap: 0) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor.opacity(0.7))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                } else {
                    Image(systemName: action == .restore ? "arrow.uturn.backward" : action == .previousDisplay ? "arrow.left" : "arrow.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: bounds.width, height: bounds.height)
                }
            }
        }.accessibilityHidden(true)
    }
}
