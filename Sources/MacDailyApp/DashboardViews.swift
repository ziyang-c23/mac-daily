import AppKit
import MacDailyCore
import SwiftUI
import UniformTypeIdentifiers

private typealias DashboardViewState<Value> = SwiftUI.State<Value>

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject private var monitor: SystemMonitorService
    @ObservedObject private var actions: QuickActionService
    @ObservedObject private var hardware: SystemHardwareInfo
    let compact: Bool
    @DashboardViewState private var editing = false
    @DashboardViewState private var editorPage: DashboardEditorPage = .instruments
    @DashboardViewState private var informationExpanded: Bool
    @DashboardViewState private var draggingApp: UUID?

    init(model: DashboardModel, compact: Bool = false) {
        self.model = model; self.compact = compact
        _monitor = ObservedObject(wrappedValue: model.monitor)
        _actions = ObservedObject(wrappedValue: model.actions)
        _hardware = ObservedObject(wrappedValue: model.hardware)
        _informationExpanded = DashboardViewState(initialValue: !compact)
    }
    private var source: String { compact ? "dashboardCompact" : "dashboardWindow" }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let metric = model.selectedMetric {
                    Button { model.showMetric(nil) } label: { Label(L10n.text("返回"), systemImage: "chevron.left") }
                    Text(metric.title).font(.headline)
                } else {
                    Text(L10n.text("概览")).font(compact ? .headline : .largeTitle.weight(.semibold))
                }
                Spacer()
                Button { editorPage = .instruments; editing = true } label: { Image(systemName: "slider.horizontal.3") }
                    .help(L10n.text("编辑面板")).accessibilityLabel(L10n.text("编辑面板"))
            }.padding(compact ? 14 : 24)
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? 16 : 24) {
                    if let metric = model.selectedMetric {
                        metricDetail(metric)
                    } else {
                        machineInformation
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: compact ? 12 : 18) {
                            ForEach(model.settings.cards) { card in
                                Button { model.showMetric(MonitorMetric(rawValue: card.rawValue)) } label: {
                                    metricCard(card)
                                }.buttonStyle(.plain).accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton).accessibilityLabel(L10n.text("查看%@详情", String(describing: card.title)))
                            }
                        }
                        pinnedApps
                        quickActions
                    }
                    if let message = actions.message {
                        HStack(alignment: .top) {
                            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Spacer(minLength: 0)
                            Button { actions.message = nil } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).accessibilityLabel(L10n.text("关闭操作结果"))
                        }
                    }
                }.padding(.horizontal, compact ? 14 : 24).padding(.bottom, 18)
            }
            Divider()
            HStack {
                Text(L10n.text("开机时间：%@", String(describing: uptime(monitor.snapshot.uptime))))
                Spacer()
                if compact {
                    Button { model.onOpenSettings?() } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.plain).help(L10n.text("MacDaily 设置")).accessibilityLabel(L10n.text("打开 MacDaily 设置"))
                }
            }.font(.caption).foregroundStyle(.secondary).padding(compact ? 12 : 18)
        }
        .sheet(isPresented: $editing) { DashboardEditor(model: model, initialPage: editorPage) }
        .onAppear { if !compact { model.setVisible(true, source: source) } }
        .onDisappear { if !compact { model.setVisible(false, source: source) } }
        .background { if !compact { DashboardVisibilityObserver(model: model).frame(width: 0, height: 0) } }
    }

    private func metricCard(_ card: DashboardCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(card.title, systemImage: card.symbol).font(.system(size: compact ? 14 : 17, weight: .semibold))
            cardContent(card)
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 142 : 190, alignment: .topLeading)
        .padding(compact ? 12 : 18)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: compact ? 16 : 20))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
    @ViewBuilder private func cardContent(_ card: DashboardCard) -> some View {
        let s = monitor.snapshot
        switch card {
        case .cpu:
            HStack(spacing: 4) {
                Text(s.chipName).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Text(percent(s.cpuUser + s.cpuSystem)).fontWeight(.semibold).monospacedDigit()
            }.font(.caption)
            chart(.cpu, height: compact ? 42 : 75)
            valueRow(L10n.text("用户"), percent(s.cpuUser), color: .blue)
            valueRow(L10n.text("系统"), percent(s.cpuSystem), color: .red)
            valueRow(L10n.text("闲置"), percent(max(0, 100 - s.cpuUser - s.cpuSystem)), color: .gray)
        case .gpu:
            Text(s.gpuCores.map { L10n.text("%@ 核", String(describing: $0)) } ?? s.chipName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            chart(.gpu, height: compact ? 42 : 75)
            valueRow(L10n.text("利用率"), optionalPercent(s.gpu), color: .blue)
            valueRow(L10n.text("渲染"), optionalPercent(s.gpuRenderer), color: .red)
            valueRow("Tiler", optionalPercent(s.gpuTiler), color: .teal)
        case .memory:
            Text("\(memoryBytes(s.memoryUsed)) / \(memoryBytes(s.memoryTotal))").font(.system(size: compact ? 12 : 17, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
            ProgressView(value: ratio(s.memoryUsed, s.memoryTotal)).tint(pressureColor(s.memoryPressure))
            chart(.memory, height: compact ? 38 : 65)
            valueRow(L10n.text("压力"), L10n.text(s.memoryPressure))
        case .disk:
            Text(L10n.text("可用 %@", String(describing: bytes(s.diskFree)))).font(.system(size: compact ? 12 : 17, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
            ProgressView(value: s.diskTotal > s.diskFree ? ratio(s.diskTotal - s.diskFree, s.diskTotal) : 0)
            Text(L10n.text("共 %@", String(describing: bytes(s.diskTotal)))).font(.caption).foregroundStyle(.secondary)
            valueRow(L10n.text("读"), rate(s.diskReadRate)); valueRow(L10n.text("写"), rate(s.diskWriteRate))
        case .network:
            valueRow(L10n.text("↓ 下载"), rate(s.downloadRate), color: .blue)
            valueRow(L10n.text("↑ 上传"), rate(s.uploadRate), color: .orange)
            chart(.network, height: compact ? 42 : 75)
            Text(s.localIP.isEmpty ? L10n.text("尚无 IP 地址") : s.localIP).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        case .battery:
            Text(optionalPercent(s.batteryLevel)).font(.system(size: compact ? 25 : 36, weight: .semibold, design: .rounded))
            Text(s.batteryLevel == nil ? L10n.text("未读取到电池") : s.charging ? L10n.text("正在充电") : s.onAC ? L10n.text("电源适配器") : L10n.text("电池供电"))
                .font(.caption).foregroundStyle(.secondary)
            if let health = s.batteryHealth { valueRow(L10n.text("健康"), percent(health)) }
            if let level = s.batteryLevel { ProgressView(value: min(1, max(0, level / 100))).tint(s.charging ? .green : .blue) }
        case .temperature:
            valueRow("CPU", temperature(s.cpuTemperature), color: .orange)
            valueRow("GPU", temperature(s.gpuTemperature), color: .cyan)
            if s.cpuTemperature == nil && s.gpuTemperature == nil {
                Text(L10n.text("未读取到温度")).font(.caption).foregroundStyle(.secondary)
            } else {
                chart(.temperature, height: compact ? 42 : 75)
            }
        }
    }

    private var pinnedApps: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text("固定应用")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { model.addApp() } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).help(L10n.text("添加固定应用")).accessibilityLabel(L10n.text("添加固定应用"))
            }
            if model.settings.pinnedApps.isEmpty {
                Button(L10n.text("添加常用应用")) { model.addApp() }.buttonStyle(.bordered).controlSize(.small)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                    ForEach(model.settings.pinnedApps) { app in
                        Button { model.openApp(app) } label: {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                                .resizable().scaledToFit().frame(width: compact ? 32 : 42, height: compact ? 32 : 42)
                                .frame(maxWidth: .infinity, minHeight: compact ? 42 : 54)
                        }
                        .buttonStyle(.plain).help(app.name).accessibilityLabel(L10n.text("打开%@", String(describing: app.name)))
                        .contextMenu { Button(L10n.text("移除%@", String(describing: app.name))) { model.removeApp(id: app.id) } }
                        .onDrag { draggingApp = app.id; return NSItemProvider(object: app.id.uuidString as NSString) }
                        .onDrop(of: [.text], delegate: PinnedAppDropDelegate(target: app.id, dragged: $draggingApp, model: model))
                    }
                }
            }
        }
    }
    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("快捷功能")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("全部功能")) { editorPage = .actions; editing = true }
                    .font(.caption).buttonStyle(.plain).foregroundStyle(.tint)
                    .accessibilityLabel(L10n.text("查看全部快捷功能"))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: compact ? 4 : 5), spacing: 18) {
                ForEach(model.settings.actions) { action in
                    Button { actions.perform(action) } label: {
                        VStack(spacing: 7) {
                            Image(systemName: action.symbol)
                                .font(.system(size: compact ? 19 : 24))
                                .foregroundStyle(actions.states[action] == true ? Color.white : Color.primary)
                                .frame(width: compact ? 48 : 56, height: compact ? 48 : 56)
                                .background(actions.states[action] == true ? Color.accentColor : Color.primary.opacity(0.07), in: Circle())
                                .overlay(alignment: .bottomTrailing) {
                                    if action.isLink {
                                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
                                            .padding(4).background(.regularMaterial, in: Circle())
                                    }
                                }
                            Text(action.title).font(.system(size: compact ? 11 : 13)).multilineTextAlignment(.center).lineLimit(2)
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(.plain).help(action.description).accessibilityLabel(action.title)
                }
            }
        }
    }

    @ViewBuilder private func metricDetail(_ metric: MonitorMetric) -> some View {
        let s = monitor.snapshot
        chart(metric, height: compact ? 130 : 240)
            .padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
        Text(L10n.text("最近 10 分钟 · 查看期间每 2 秒刷新")).font(.caption).foregroundStyle(.secondary)
        switch metric {
        case .cpu:
            detailValues([(L10n.text("芯片"), s.chipName), (L10n.text("核心"), String(s.cpuCores)), (L10n.text("用户"), percent(s.cpuUser)), (L10n.text("系统"), percent(s.cpuSystem)), (L10n.text("闲置"), percent(max(0, 100 - s.cpuUser - s.cpuSystem)))])
            processList(memory: false)
        case .gpu:
            detailValues([(L10n.text("芯片"), s.chipName), (L10n.text("核心"), s.gpuCores.map(String.init) ?? "—"), (L10n.text("利用率"), optionalPercent(s.gpu)), (L10n.text("渲染"), optionalPercent(s.gpuRenderer)), ("Tiler", optionalPercent(s.gpuTiler))])
        case .memory:
            detailValues([(L10n.text("已用"), memoryBytes(s.memoryUsed)), (L10n.text("总量"), memoryBytes(s.memoryTotal)), (L10n.text("压力"), L10n.text(s.memoryPressure)), (L10n.text("压缩"), memoryBytes(s.memoryCompressed)), (L10n.text("交换"), memoryBytes(s.swapUsed))])
            processList(memory: true)
        case .disk:
            detailValues([(L10n.text("总容量"), bytes(s.diskTotal)), (L10n.text("可用"), bytes(s.diskFree)), (L10n.text("读取"), rate(s.diskReadRate)), (L10n.text("写入"), rate(s.diskWriteRate))])
            Button(L10n.text("打开空间检查 ↗")) { model.openStorage() }.buttonStyle(.borderedProminent)
        case .network:
            interfacePicker
            detailValues([(L10n.text("接口"), s.interface.isEmpty ? "—" : L10n.text(s.interface)), (L10n.text("本地 IP"), s.localIP.isEmpty ? "—" : s.localIP), (L10n.text("下载"), rate(s.downloadRate)), (L10n.text("上传"), rate(s.uploadRate))])
        case .battery:
            detailValues([(L10n.text("电量"), optionalPercent(s.batteryLevel)), (L10n.text("健康"), optionalPercent(s.batteryHealth)), (L10n.text("电源"), s.onAC ? L10n.text("电源适配器") : L10n.text("电池")), (L10n.text("充电"), s.charging ? L10n.text("正在充电") : L10n.text("未充电"))])
            Button(L10n.text("电池与省电设置 ↗")) { actions.perform(.lowPower) }
        case .temperature:
            detailValues([("CPU", temperature(s.cpuTemperature)), ("GPU", temperature(s.gpuTemperature)), (L10n.text("传感器"), s.temperatureSource.isEmpty ? L10n.text("未读取到温度") : s.temperatureSource)])
        }
    }
    private var interfacePicker: some View {
        Picker(L10n.text("网络接口"), selection: Binding(get: { model.settings.networkInterface ?? "" }, set: { model.settings.networkInterface = $0.isEmpty ? nil : $0 })) {
            Text(L10n.text("自动选择物理接口")).tag("")
            ForEach(monitor.interfaces, id: \.self) { Text($0).tag($0) }
        }
    }
    private func processList(memory: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(memory ? L10n.text("内存占用较高的进程") : L10n.text("CPU 占用较高的进程")).font(.headline)
                Spacer()
                Button { actions.perform(.activityMonitor) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.plain).help(L10n.text("打开活动监视器"))
            }
            ForEach(monitor.processes) { process in
                HStack {
                    Text(process.name).lineLimit(1)
                    Spacer()
                    Text(memory ? memoryBytes(process.memory) : percent(process.cpu)).monospacedDigit().foregroundStyle(.secondary)
                }.font(.callout)
            }
        }.padding(.vertical, 8)
    }
    private func detailValues(_ values: [(String, String)]) -> some View {
        VStack(spacing: 12) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, pair in valueRow(pair.0, pair.1) }
        }.padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }
    private func valueRow(_ name: String, _ value: String, color: Color? = nil) -> some View {
        HStack(spacing: 5) {
            if let color { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7) }
            Text(name).foregroundStyle(.secondary)
            Spacer(minLength: 3)
            Text(value).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }.font(.system(size: compact ? 11 : 14))
    }
    private var machineInformation: some View {
        DisclosureGroup(isExpanded: $informationExpanded) {
            VStack(spacing: 9) {
                ForEach(hardware.rows) { row in
                    HStack(alignment: .top, spacing: 10) {
                        Text(row.title).foregroundStyle(.secondary).frame(width: compact ? 64 : 100, alignment: .leading)
                        Text(row.value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.system(size: compact ? 11 : 13))
                }
                HStack {
                    Text(L10n.text("开机时间")).foregroundStyle(.secondary).frame(width: compact ? 64 : 100, alignment: .leading)
                    Text(uptime(monitor.snapshot.uptime)).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(size: compact ? 11 : 13))
            }.padding(.top, 10)
        } label: {
            Label(L10n.text("本机信息"), systemImage: "desktopcomputer").font(.system(size: compact ? 13 : 16, weight: .semibold))
        }
        .padding(compact ? 12 : 18)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: compact ? 16 : 20))
    }
    @ViewBuilder private func chart(_ metric: MonitorMetric, height: CGFloat) -> some View {
        if metric == .cpu {
            DashboardStackedChart(series: [monitor.history.map(\.cpuUser), monitor.history.map(\.cpuSystem)], colors: [.blue, .red], maximum: 100)
                .frame(height: height).accessibilityLabel(L10n.text("CPU 用户、系统与闲置堆叠面积图"))
        } else if metric == .gpu {
            let samples = monitor.history.filter { $0.gpu != nil || $0.gpuRenderer != nil || $0.gpuTiler != nil }
            let components = [samples.map { $0.gpu ?? 0 }, samples.map { $0.gpuRenderer ?? 0 }, samples.map { $0.gpuTiler ?? 0 }]
            let maximum = max(100, samples.map { ($0.gpu ?? 0) + ($0.gpuRenderer ?? 0) + ($0.gpuTiler ?? 0) }.max() ?? 100)
            DashboardStackedChart(series: components, colors: [.blue, .red, .teal], maximum: maximum)
                .frame(height: height)
                .help(L10n.text("分别显示设备、渲染和 Tiler 活动，色块叠加不代表总占用"))
                .accessibilityLabel(L10n.text("GPU 设备、渲染和 Tiler 分项活动面积图"))
        } else {
            let values = monitor.history.compactMap { value($0, metric) }
            let secondary = metric == .network ? monitor.history.map(\.uploadRate) : []
            let maximum: Double = [.memory, .battery].contains(metric) ? 100 : max(1, (values + secondary).max() ?? 1)
            DashboardSparkline(values: values, secondary: secondary, maximum: maximum).frame(height: height)
        }
    }
    private func value(_ s: SystemSnapshot, _ metric: MonitorMetric) -> Double? {
        switch metric {
        case .cpu: s.cpuUser
        case .gpu: s.gpu
        case .memory: s.memoryTotal == 0 ? 0 : Double(s.memoryUsed) / Double(s.memoryTotal) * 100
        case .disk: s.diskReadRate + s.diskWriteRate
        case .network: s.downloadRate
        case .battery: s.batteryLevel
        case .temperature: s.cpuTemperature ?? s.gpuTemperature
        }
    }
}

private struct DashboardVisibilityObserver: NSViewRepresentable {
    let model: DashboardModel
    func makeNSView(context: Context) -> DashboardVisibilityView {
        let view = DashboardVisibilityView()
        view.changed = { [weak model] visible in model?.setVisible(visible, source: "dashboardWindow") }
        return view
    }
    func updateNSView(_ view: DashboardVisibilityView, context: Context) {}
    static func dismantleNSView(_ view: DashboardVisibilityView, coordinator: ()) { view.detach() }
}

private final class DashboardVisibilityView: NSView {
    var changed: ((Bool) -> Void)?
    private var tokens: [NSObjectProtocol] = []
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detach()
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification] {
            tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.changed?(true)
            })
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.changed?(false)
            })
        }
        changed?(window.isVisible && !window.isMiniaturized)
    }
    func detach() {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
        tokens.removeAll(); changed?(false)
    }
}

private struct DashboardStackedChart: View {
    let series: [[Double]]
    let colors: [Color]
    let maximum: Double
    var body: some View {
        Canvas { context, size in
            let count = series.map(\.count).max() ?? 0
            guard count > 0 else { return }
            var lower = Array(repeating: 0.0, count: count)
            for (index, samples) in series.enumerated() {
                let upper = lower.enumerated().map { offset, value in value + (offset < samples.count ? max(0, samples[offset]) : 0) }
                func point(_ sample: Int, _ value: Double) -> CGPoint {
                    CGPoint(x: count == 1 ? 0 : CGFloat(sample) / CGFloat(count - 1) * size.width,
                            y: size.height * (1 - min(1, max(0, value / max(1, maximum)))))
                }
                let area = Path { path in
                    path.move(to: point(0, lower[0]))
                    if count == 1 {
                        path.addLine(to: point(0, upper[0]))
                        path.addLine(to: CGPoint(x: size.width, y: point(0, upper[0]).y))
                        path.addLine(to: CGPoint(x: size.width, y: point(0, lower[0]).y))
                    } else {
                        for sample in 0..<count { path.addLine(to: point(sample, upper[sample])) }
                        for sample in (0..<count).reversed() { path.addLine(to: point(sample, lower[sample])) }
                    }
                    path.closeSubpath()
                }
                context.fill(area, with: .color(colors[index % colors.count]))
                lower = upper
            }
        }
        .background(Color(white: 0.16))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct DashboardSparkline: View {
    let values: [Double]
    var secondary: [Double] = []
    let maximum: Double
    var body: some View {
        Canvas { context, size in
            let count = max(values.count, secondary.count)
            guard count > 1 else { return }
            func path(_ samples: [Double]) -> Path {
                Path { p in
                    for (index, value) in samples.enumerated() {
                        let point = CGPoint(x: CGFloat(index) / CGFloat(count - 1) * size.width,
                                            y: size.height * (1 - min(1, max(0, value / max(1, maximum)))))
                        if index == 0 { p.move(to: point) } else { p.addLine(to: point) }
                    }
                }
            }
            let line = path(values)
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height)); area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [.blue.opacity(0.3), .blue.opacity(0.03)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(.blue), lineWidth: 1.6)
            if !secondary.isEmpty { context.stroke(path(secondary), with: .color(.orange), lineWidth: 1.4) }
        }.accessibilityLabel(L10n.text("最近采样曲线"))
    }
}

private enum DashboardEditorPage: String, CaseIterable, Identifiable {
    case instruments = "仪表", actions = "快捷功能", applications = "快捷应用", preferences = "偏好"
    var id: String { rawValue }
}

private struct DashboardEditor: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject private var monitor: SystemMonitorService
    @ObservedObject private var actions: QuickActionService
    @DashboardViewState private var page: DashboardEditorPage
    @Environment(\.dismiss) private var dismiss
    init(model: DashboardModel, initialPage: DashboardEditorPage = .instruments) {
        self.model = model
        _monitor = ObservedObject(wrappedValue: model.monitor)
        _actions = ObservedObject(wrappedValue: model.actions)
        _page = DashboardViewState(initialValue: initialPage)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(L10n.text("编辑面板")).font(.title2.weight(.semibold)); Spacer(); Button(L10n.text("完成")) { dismiss() }.keyboardShortcut(.defaultAction) }.padding(20)
            Picker(L10n.text("编辑分类"), selection: $page) {
                ForEach(DashboardEditorPage.allCases) { Text(L10n.text($0.rawValue)).tag($0) }
            }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 12)
            Form {
                switch page {
                case .instruments: instrumentSection
                case .actions: actionSection
                case .applications: applicationSection
                case .preferences: preferenceSection
                }
            }.formStyle(.grouped)
        }.frame(width: 540, height: 650)
    }
    private var instrumentSection: some View {
        Section(L10n.text("显示的仪表与顺序")) {
            ForEach(model.settings.cards + DashboardCard.allCases.filter { !model.settings.cards.contains($0) }) { card in
                HStack {
                    Toggle(isOn: Binding(get: { model.settings.cards.contains(card) }, set: { enabled in
                        if enabled { model.settings.cards.append(card) } else { model.settings.cards.removeAll { $0 == card } }
                    })) { Label(card.title, systemImage: card.symbol) }
                    .toggleStyle(.switch).accessibilityLabel(L10n.text("在面板显示%@", String(describing: card.title)))
                    if model.settings.cards.contains(card) {
                        orderButton(L10n.text("上移%@", String(describing: card.title)), symbol: "chevron.up", disabled: model.settings.cards.first == card) { moveCard(card, offset: -1) }
                        orderButton(L10n.text("下移%@", String(describing: card.title)), symbol: "chevron.down", disabled: model.settings.cards.last == card) { moveCard(card, offset: 1) }
                    }
                }
            }
        }
    }
    private var actionSection: some View {
        Section(L10n.text("所有快捷功能")) {
            ForEach(model.settings.actions + DashboardAction.allCases.filter { !model.settings.actions.contains($0) }) { action in
                HStack(spacing: 10) {
                    Toggle(isOn: Binding(get: { model.settings.actions.contains(action) }, set: { enabled in
                        if enabled { model.settings.actions.append(action) } else { model.settings.actions.removeAll { $0 == action } }
                    })) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: action.symbol).frame(width: 20).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(action.title)
                                Text(action.description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }.toggleStyle(.switch).accessibilityLabel(L10n.text("在面板显示%@", String(describing: action.title))).help(action.description)
                    if model.settings.actions.contains(action) {
                        orderButton(L10n.text("上移%@", String(describing: action.title)), symbol: "chevron.up", disabled: model.settings.actions.first == action) { moveAction(action, offset: -1) }
                        orderButton(L10n.text("下移%@", String(describing: action.title)), symbol: "chevron.down", disabled: model.settings.actions.last == action) { moveAction(action, offset: 1) }
                    }
                }.padding(.vertical, 3)
            }
        }
    }
    private var applicationSection: some View {
        Section(L10n.text("固定应用与顺序")) {
            ForEach(model.settings.pinnedApps) { app in
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 24, height: 24)
                    Text(app.name); Spacer()
                    orderButton(L10n.text("上移%@", String(describing: app.name)), symbol: "chevron.up", disabled: model.settings.pinnedApps.first?.id == app.id) { moveApp(app, offset: -1) }
                    orderButton(L10n.text("下移%@", String(describing: app.name)), symbol: "chevron.down", disabled: model.settings.pinnedApps.last?.id == app.id) { moveApp(app, offset: 1) }
                    Button { model.removeApp(id: app.id) } label: { Image(systemName: "minus.circle") }.accessibilityLabel(L10n.text("移除%@", String(describing: app.name)))
                }
            }
            Button(L10n.text("添加应用…")) { model.addApp() }
        }
    }
    private var preferenceSection: some View {
        Section(L10n.text("显示与采样")) {
            Toggle(L10n.text("菜单栏显示网速"), isOn: $model.settings.showMenuNetwork)
            Picker(L10n.text("网络接口"), selection: Binding(get: { model.settings.networkInterface ?? "" }, set: { model.settings.networkInterface = $0.isEmpty ? nil : $0 })) {
                Text(L10n.text("自动选择物理接口")).tag("")
                ForEach(monitor.interfaces, id: \.self) { Text($0).tag($0) }
            }
            Picker(L10n.text("固定 Dock 显示器"), selection: Binding(get: { model.settings.dockAnchorDisplayUUID ?? "" }, set: { model.settings.dockAnchorDisplayUUID = $0.isEmpty ? nil : $0 })) {
                Text(L10n.text("主显示器")).tag("")
                ForEach(actions.availableDockDisplays) { display in Text(display.name).tag(display.id) }
            }
            Picker(L10n.text("保持唤醒／亮屏时长"), selection: $model.settings.awakeDurationMinutes) {
                Text(L10n.text("15 分钟")).tag(15); Text(L10n.text("30 分钟")).tag(30); Text(L10n.text("60 分钟")).tag(60); Text(L10n.text("手动关闭")).tag(0)
            }
        }
    }
    private func orderButton(_ label: String, symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }.disabled(disabled).accessibilityLabel(label)
    }
    private func moveCard(_ card: DashboardCard, offset: Int) {
        guard let i = model.settings.cards.firstIndex(of: card), model.settings.cards.indices.contains(i + offset) else { return }
        model.settings.cards.swapAt(i, i + offset)
    }
    private func moveAction(_ action: DashboardAction, offset: Int) {
        guard let i = model.settings.actions.firstIndex(of: action), model.settings.actions.indices.contains(i + offset) else { return }
        model.settings.actions.swapAt(i, i + offset)
    }
    private func moveApp(_ app: PinnedDashboardApp, offset: Int) {
        guard let i = model.settings.pinnedApps.firstIndex(where: { $0.id == app.id }), model.settings.pinnedApps.indices.contains(i + offset) else { return }
        model.settings.pinnedApps.swapAt(i, i + offset)
    }
}

private struct PinnedAppDropDelegate: DropDelegate {
    let target: UUID
    @Binding var dragged: UUID?
    let model: DashboardModel
    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != target,
              let from = model.settings.pinnedApps.firstIndex(where: { $0.id == dragged }),
              let to = model.settings.pinnedApps.firstIndex(where: { $0.id == target }) else { return }
        model.moveApp(from: IndexSet(integer: from), to: to > from ? to + 1 : to)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragged = nil; return true }
}

private func bytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
}
private func memoryBytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
}
private func rate(_ value: Double) -> String { value < 1 ? "0 B/s" : bytes(UInt64(max(0, value.isFinite ? value : 0))) + "/s" }
private func percent(_ value: Double) -> String { String(format: "%.0f%%", value) }
private func optionalPercent(_ value: Double?) -> String { value.map(percent) ?? "—" }
private func temperature(_ value: Double?) -> String { value.map { String(format: "%.1f °C", $0) } ?? "—" }
private func ratio(_ value: UInt64, _ total: UInt64) -> Double { total == 0 ? 0 : min(1, Double(value) / Double(total)) }
private func pressureColor(_ value: String) -> Color { value == "较高" || value.contains("严重") ? .red : value.contains("偏高") || value.contains("警") ? .orange : .green }
private func uptime(_ value: Double) -> String {
    let minutes = max(0, Int(value / 60)); let hours = minutes / 60
    return hours >= 24 ? L10n.text("%@ 天 %@ 小时", String(describing: hours / 24), String(describing: hours % 24)) : L10n.text("%@ 小时 %@ 分钟", String(describing: hours), String(describing: minutes % 60))
}
