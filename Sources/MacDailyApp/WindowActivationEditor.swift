import MacDailyCore
import SwiftUI

private typealias ActivationViewState<Value> = SwiftUI.State<Value>

/// Changes stay in this sheet until Save; editing never moves a real window.
struct WindowActivationEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ActivationViewState private var draft: WindowSettings
    @ActivationViewState private var orientation: WindowDisplayOrientation = .landscape
    @ActivationViewState private var selectedID: UUID?
    let onSave: (WindowSettings) -> Void

    init(settings: WindowSettings, onSave: @escaping (WindowSettings) -> Void) {
        _draft = ActivationViewState(initialValue: settings)
        _selectedID = ActivationViewState(initialValue: settings.activationProfile.landscape.first?.id)
        self.onSave = onSave
    }
    private var areas: [WindowActivationArea] { draft.activationProfile.areas(for: orientation) }
    private var selected: WindowActivationArea? { areas.first { $0.id == selectedID } }
    private var valid: Bool { (try? draft.activationProfile.validated()) != nil }
    private let actions = WindowAction.allCases.filter { ![.restore, .nextDisplay, .previousDisplay].contains($0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("拖拽激活区域")).font(.title2.weight(.semibold))
                    Text(L10n.text("拖动区域或右下角调整；保存后，在窗口页选择“自定义区域”即可使用。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker(L10n.text("屏幕方向"), selection: $orientation) {
                    ForEach(WindowDisplayOrientation.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).frame(width: 160)
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("激活区域 · 按顺序匹配")).font(.headline)
                    ScrollViewReader { reader in
                        ScrollView {
                            LazyVStack(spacing: 3) {
                                ForEach(Array(areas.enumerated()), id: \.element.id) { index, area in
                                    Button { selectedID = area.id } label: {
                                        HStack(spacing: 7) {
                                            Image(systemName: area.enabled ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(area.enabled ? Color.accentColor : Color.secondary)
                                            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                                            Text(area.name).lineLimit(1)
                                            Spacer(minLength: 0)
                                        }.padding(8).contentShape(Rectangle())
                                            .background(selectedID == area.id ? Color.accentColor.opacity(0.12) : Color.clear,
                                                        in: RoundedRectangle(cornerRadius: 6))
                                    }.buttonStyle(.plain).id(area.id)
                                }
                            }
                        }.onChange(of: selectedID) { _, value in
                            if let value { reader.scrollTo(value) }
                        }
                    }
                    HStack {
                        Button { addArea() } label: { Image(systemName: "plus") }.help(L10n.text("添加区域"))
                            .disabled(areas.count >= 64)
                        Button { deleteArea() } label: { Image(systemName: "minus") }.help(L10n.text("删除所选区域"))
                            .disabled(selected == nil)
                        Spacer()
                        Button { reorder(-1) } label: { Image(systemName: "arrow.up") }.help(L10n.text("提高优先级"))
                            .disabled(selectedID == areas.first?.id || selected == nil)
                        Button { reorder(1) } label: { Image(systemName: "arrow.down") }.help(L10n.text("降低优先级"))
                            .disabled(selectedID == areas.last?.id || selected == nil)
                    }
                    Text(L10n.text("重叠时优先使用靠前的已启用区域。空列表不会触发分屏。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L10n.text("重置当前方向")) {
                        setAreas(WindowActivationProfile.recommended.areas(for: orientation))
                        selectedID = areas.first?.id
                    }.padding(.top, 4)
                }.frame(width: 220)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.text("拖到哪里触发")).font(.headline)
                        ActivationCanvas(areas: areas, selectedID: selectedID, orientation: orientation,
                                         select: { selectedID = $0 }, update: { id, rect in
                            update(id) { $0.rect = rect }
                        })
                        .frame(height: orientation == .landscape ? 230 : 340)
                        Text(L10n.text("坐标从屏幕左上角计算，拖动时吸附到网格。横竖屏按显示器比例自动选择。"))
                            .font(.caption).foregroundStyle(.secondary)
                        if let area = selected {
                            Toggle(L10n.text("启用此区域"), isOn: field(area.id, \.enabled, fallback: true))
                            TextField(L10n.text("名称"), text: field(area.id, \.name, fallback: ""))
                                .textFieldStyle(.roundedBorder)
                            rectFields(L10n.text("激活区域（屏幕百分比）"), rect: rectBinding(area.id, target: false))
                            Divider()
                            Text(L10n.text("触发后窗口放到哪里")).font(.headline)
                            Picker(L10n.text("窗口布局"), selection: Binding(get: { area.action?.rawValue ?? "custom" }, set: { value in
                                update(area.id) {
                                    $0.action = WindowAction(rawValue: value)
                                    if $0.action == nil && $0.customTarget == nil {
                                        $0.customTarget = .init(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
                                    }
                                }
                            })) {
                                ForEach(actions) { Text($0.title).tag($0.rawValue) }
                                Text(L10n.text("自定义位置与大小")).tag("custom")
                            }
                            targetPreview(area).frame(height: 90)
                            if area.action == nil {
                                rectFields(L10n.text("窗口位置（可用空间百分比）"), rect: rectBinding(area.id, target: true))
                            }
                        } else {
                            Text(L10n.text("选择一个区域，或点击 ＋ 添加。"))
                                .foregroundStyle(.secondary).padding(.vertical, 16)
                        }
                    }.padding(.trailing, 4)
                }.frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                if !valid { Text(L10n.text("请填写区域名称，并检查位置与大小。每边至少为屏幕的 1/48。"))
                    .font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button(L10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("保存区域")) { onSave(draft); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.padding(20).frame(width: 900, height: 690)
            .onChange(of: orientation) { _, _ in selectedID = areas.first?.id }
    }

    private func setAreas(_ value: [WindowActivationArea]) {
        if orientation == .landscape { draft.activationProfile.landscape = value }
        else { draft.activationProfile.portrait = value }
    }
    private func update(_ id: UUID, _ change: (inout WindowActivationArea) -> Void) {
        var value = areas
        guard let index = value.firstIndex(where: { $0.id == id }) else { return }
        change(&value[index]); setAreas(value)
    }
    private func field<Value>(_ id: UUID, _ path: WritableKeyPath<WindowActivationArea, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { areas.first { $0.id == id }?[keyPath: path] ?? fallback },
                set: { value in update(id) { $0[keyPath: path] = value } })
    }
    private func rectBinding(_ id: UUID, target: Bool) -> Binding<NormalizedWindowRect> {
        Binding(get: {
            let value = areas.first { $0.id == id }
            return (target ? value?.customTarget : value?.rect) ?? .init(x: 0, y: 0, width: 1, height: 1)
        }, set: { value in update(id) { if target { $0.customTarget = value } else { $0.rect = value } } })
    }
    private func addArea() {
        let area = WindowActivationArea(name: L10n.text("新区域"), rect: .init(x: 0.375, y: 0, width: 0.25, height: 1.0 / 12), action: .maximize)
        setAreas(areas + [area]); selectedID = area.id
    }
    private func deleteArea() {
        setAreas(areas.filter { $0.id != selectedID }); selectedID = areas.first?.id
    }
    private func reorder(_ offset: Int) {
        var value = areas
        guard let index = value.firstIndex(where: { $0.id == selectedID }), value.indices.contains(index + offset) else { return }
        value.swapAt(index, index + offset); setAreas(value)
    }
    private func rectFields(_ title: String, rect: Binding<NormalizedWindowRect>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                percentage(L10n.text("左"), path: \.x, rect: rect)
                percentage(L10n.text("上"), path: \.y, rect: rect)
                percentage(L10n.text("宽"), path: \.width, rect: rect)
                percentage(L10n.text("高"), path: \.height, rect: rect)
            }
        }
    }
    private func percentage(_ title: String, path: WritableKeyPath<NormalizedWindowRect, Double>, rect: Binding<NormalizedWindowRect>) -> some View {
        HStack(spacing: 3) {
            Text(title).font(.caption)
            TextField(title, value: Binding(get: { rect.wrappedValue[keyPath: path] * 100 }, set: { number in
                guard number.isFinite else { return }
                var value = rect.wrappedValue
                value[keyPath: path] = max(0, min(100, number)) / 100
                let minimum = 1.0 / 48
                value.width = max(minimum, min(1, value.width))
                value.height = max(minimum, min(1, value.height))
                value.x = min(value.x, 1 - value.width); value.y = min(value.y, 1 - value.height)
                rect.wrappedValue = value
            }), format: .number.precision(.fractionLength(0...1)))
            .textFieldStyle(.roundedBorder).accessibilityLabel(L10n.text("%@百分比", String(describing: title)))
        }
    }
    private func targetPreview(_ area: WindowActivationArea) -> some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width, 180.0)
            let height = 86.0
            let screen = CGRect(x: 0, y: 0, width: width, height: height)
            let frame = area.action.flatMap { WindowGeometry.frame(for: $0, in: screen, current: screen.insetBy(dx: width * 0.2, dy: height * 0.2), gap: 0) }
                ?? area.customTarget?.frame(in: screen)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5).fill(.secondary.opacity(0.07))
                RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.35))
                if let frame {
                    RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.3))
                        .frame(width: frame.width, height: frame.height).offset(x: frame.minX, y: frame.minY)
                }
            }.frame(width: width, height: height)
        }.accessibilityLabel(L10n.text("窗口布局预览"))
    }
}

private struct ActivationCanvas: View {
    let areas: [WindowActivationArea]
    let selectedID: UUID?
    let orientation: WindowDisplayOrientation
    let select: (UUID) -> Void
    let update: (UUID, NormalizedWindowRect) -> Void
    @ActivationViewState private var coordinateSpaceID = UUID()
    var body: some View {
        GeometryReader { proxy in
            let ratio = orientation == .landscape ? 2.0 : 0.5
            let width = min(proxy.size.width - 12, (proxy.size.height - 12) * ratio)
            let height = width / ratio
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5).fill(.secondary.opacity(0.055))
                Path { path in
                    for col in 0...orientation.gridColumns {
                        let x = width * Double(col) / Double(orientation.gridColumns)
                        path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: height))
                    }
                    for row in 0...orientation.gridRows {
                        let y = height * Double(row) / Double(orientation.gridRows)
                        path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: width, y: y))
                    }
                }.stroke(.secondary.opacity(0.18), lineWidth: 0.5)
                ForEach(areas.reversed()) { area in
                    ActivationRegionHandle(area: area, selected: selectedID == area.id,
                                           size: CGSize(width: width, height: height), orientation: orientation,
                                           coordinateSpaceID: coordinateSpaceID,
                                           select: { select(area.id) }, update: { update(area.id, $0) })
                        .zIndex(selectedID == area.id ? 2 : 1)
                }
                RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.4)).allowsHitTesting(false)
            }.frame(width: width, height: height).coordinateSpace(name: coordinateSpaceID).padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ActivationRegionHandle: View {
    let area: WindowActivationArea
    let selected: Bool
    let size: CGSize
    let orientation: WindowDisplayOrientation
    let coordinateSpaceID: UUID
    let select: () -> Void
    let update: (NormalizedWindowRect) -> Void
    @ActivationViewState private var startRect: NormalizedWindowRect?
    @ActivationViewState private var resizeStart: NormalizedWindowRect?
    var body: some View {
        let width = area.rect.width * size.width
        let height = area.rect.height * size.height
        ZStack(alignment: .bottomTrailing) {
            Rectangle().fill(Color.accentColor.opacity(area.enabled ? (selected ? 0.48 : 0.22) : 0.06))
            Rectangle().strokeBorder(selected ? Color.accentColor : Color.accentColor.opacity(0.35), lineWidth: selected ? 2 : 1)
            if selected {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 8, weight: .bold)).padding(3)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 2)).foregroundStyle(.white)
                    .contentShape(Rectangle())
                    .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpaceID)).onChanged { value in
                        select()
                        if resizeStart == nil { resizeStart = area.rect }
                        guard var rect = resizeStart else { return }
                        rect.width = snapped(rect.width + value.translation.width / size.width, cells: orientation.gridColumns)
                        rect.height = snapped(rect.height + value.translation.height / size.height, cells: orientation.gridRows)
                        rect.width = min(1 - rect.x, max(1.0 / 48, rect.width))
                        rect.height = min(1 - rect.y, max(1.0 / 48, rect.height))
                        update(rect)
                    }.onEnded { _ in resizeStart = nil })
            }
        }.frame(width: width, height: height).contentShape(Rectangle())
            .onTapGesture { select() }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(coordinateSpaceID)).onChanged { value in
                select()
                if startRect == nil { startRect = area.rect }
                guard var rect = startRect else { return }
                rect.x = min(1 - rect.width, max(0, snapped(rect.x + value.translation.width / size.width, cells: orientation.gridColumns)))
                rect.y = min(1 - rect.height, max(0, snapped(rect.y + value.translation.height / size.height, cells: orientation.gridRows)))
                update(rect)
            }.onEnded { _ in startRect = nil })
            .offset(x: area.rect.x * size.width, y: area.rect.y * size.height)
            .accessibilityLabel(L10n.text("%@，%@", area.name, area.enabled ? L10n.text("已启用") : L10n.text("已停用")))
            .help(area.name)
    }
    private func snapped(_ value: Double, cells: Int) -> Double { (value * Double(cells)).rounded() / Double(cells) }
}
