import AppKit
import MacDailyCore
import SwiftUI
import UniformTypeIdentifiers

private typealias StorageViewState<Value> = SwiftUI.State<Value>

struct StorageSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var storage: StorageModel
    @StorageViewState private var showIgnored = false
    @StorageViewState private var showCoverage = false
    @StorageViewState private var showExpandedMap = false
    @StorageViewState private var mapShare: CGFloat = 0.62
    @StorageViewState private var mapDragStart: CGFloat?
    @StorageViewState private var mapCoordinateSpace = UUID()
    @StorageViewState private var largeMegabytes = 100

    init(model: AppModel) {
        self.model = model
        _storage = ObservedObject(wrappedValue: model.storage)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = storage.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button { storage.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(10).background(.orange.opacity(0.08)).padding(.horizontal, 24)
            }
            capacity
            HStack {
                Picker(L10n.text("空间工具"), selection: $storage.pane) {
                    ForEach(StoragePane.allCases) { Text(L10n.text($0.rawValue)).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 480)
                Spacer()
                Button { showIgnored = true } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                    .help(L10n.text("忽略列表与扫描权限"))
            }.padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 12)
            switch storage.pane {
            case .overview, .large: fileExplorer
            case .duplicates: duplicateExplorer
            case .caches: cacheExplorer
            }
            Divider()
            footer
        }
        .onAppear {
            storage.prepare(settings: model.configuration.storage)
            largeMegabytes = Int(model.configuration.storage.minimumLargeFileBytes / 1_000_000)
        }
        .onChange(of: model.configuration.storage) { _, value in storage.applySettings(value) }
        .onChange(of: storage.pane) { _, _ in storage.reloadRows(resetPage: true) }
        .onChange(of: storage.search) { _, _ in storage.reloadRows(resetPage: true) }
        .onChange(of: storage.fileExtension) { _, _ in storage.reloadRows(resetPage: true) }
        .onChange(of: storage.modifiedFilter) { _, _ in storage.reloadRows(resetPage: true) }
        .onChange(of: storage.sort) { _, _ in storage.reloadRows(resetPage: true) }
        .sheet(isPresented: $storage.showingReview) { StorageReviewView(storage: storage) }
        .sheet(isPresented: $showIgnored) { ignoredSheet }
        .sheet(isPresented: $showExpandedMap) { expandedMap }
        .onDisappear { storage.shutdown() }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("空间")).font(.title2.weight(.semibold))
                    Text(L10n.text("看清占用，逐项预览后整理。扫描与比较仅在你点击时运行。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if storage.busy {
                    Button(L10n.text("取消")) { storage.cancel() }
                } else {
                    Button(L10n.text("扫描")) { storage.startScan() }
                        .buttonStyle(.borderedProminent)
                        .disabled(storage.selectedRoot == nil || model.configurationNeedsRecovery)
                }
            }
            HStack(spacing: 8) {
                Picker(L10n.text("磁盘"), selection: Binding(get: { storage.selectedVolumeID }, set: { storage.selectVolume($0) })) {
                    if storage.selectedVolumeID.isEmpty { Text(L10n.text("自选文件夹")).tag("") }
                    ForEach(storage.volumes) { volume in Text(volume.name).tag(volume.id) }
                }.labelsHidden().frame(maxWidth: 220)
                Button(L10n.text("选择文件夹…")) { storage.chooseFolder() }.disabled(storage.busy)
                Spacer()
                Button { storage.refreshVolumes() } label: { Image(systemName: "arrow.clockwise") }.help(L10n.text("刷新磁盘容量"))
            }.disabled(model.configurationNeedsRecovery)
            Text(storage.selectedRoot.map { StorageModel.displayPath($0.path) } ?? L10n.text("正在读取磁盘列表…"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }.padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 8)
    }
    @ViewBuilder private var capacity: some View {
        if let volume = storage.selectedVolume {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(L10n.text("磁盘总容量 %@", String(describing: StorageModel.bytes(volume.totalBytes))))
                    Spacer()
                    Text(L10n.text("可用 %@", String(describing: StorageModel.bytes(volume.availableBytes))))
                }.font(.caption).foregroundStyle(.secondary)
                ProgressView(value: Double(max(0, volume.totalBytes - volume.availableBytes)), total: Double(max(1, volume.totalBytes)))
                    .tint(.secondary).accessibilityLabel(L10n.text("磁盘已用容量"))
                Text(L10n.text("容量来自系统；下方地图是可访问文件的占用估算，不包含所有系统占用。"))
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.horizontal, 24).padding(.bottom, 5)
        }
    }
    private var fileExplorer: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                TextField(L10n.text("搜索名称或路径"), text: $storage.search).textFieldStyle(.roundedBorder)
                Picker(L10n.text("排序"), selection: $storage.sort) {
                    ForEach(StorageSort.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 150)
                Picker(L10n.text("大小口径"), selection: $model.configuration.storage.sizeMetric) {
                    ForEach(StorageSizeMetric.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 180).disabled(model.configurationNeedsRecovery)
            }
            if storage.pane == .large {
                HStack(spacing: 8) {
                    Text(L10n.text("至少")).font(.caption)
                    TextField("MB", value: $largeMegabytes, format: .number).frame(width: 78).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L10n.text("大文件门槛 MB")).disabled(model.configurationNeedsRecovery)
                        .onSubmit { updateThreshold() }
                    Text("MB").font(.caption).foregroundStyle(.secondary)
                    Button(L10n.text("应用筛选")) { updateThreshold() }.disabled(model.configurationNeedsRecovery)
                    TextField(L10n.text("扩展名，如 zip"), text: $storage.fileExtension).textFieldStyle(.roundedBorder).frame(width: 150)
                    Picker(L10n.text("修改时间"), selection: $storage.modifiedFilter) {
                        Text(L10n.text("全部时间")).tag(0); Text(L10n.text("30天前")).tag(30); Text(L10n.text("90天前")).tag(90); Text(L10n.text("一年前")).tag(365)
                    }.labelsHidden().frame(width: 120)
                    Spacer()
                }
            }
            if let result = storage.result {
                if storage.pane == .overview {
                    GeometryReader { geometry in
                        let available = max(295, geometry.size.height - 16)
                        let mapHeight = min(available - 135, max(160, available * mapShare))
                        VStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    breadcrumbBar
                                    Button { showExpandedMap = true } label: {
                                        Label(L10n.text("放大查看"), systemImage: "arrow.up.left.and.arrow.down.right")
                                    }.help(L10n.text("打开大幅空间地图，保留当前目录与选择"))
                                }
                                StorageTreemap(storage: storage).frame(maxWidth: .infinity, maxHeight: .infinity)
                                mapLegend
                            }.frame(height: mapHeight)
                            HStack(spacing: 5) {
                                Rectangle().fill(.secondary.opacity(0.2)).frame(height: 1)
                                Image(systemName: "arrow.up.and.down").font(.system(size: 9))
                                Text(L10n.text("拖动调整地图大小")).font(.system(size: 9))
                                Rectangle().fill(.secondary.opacity(0.2)).frame(height: 1)
                            }.foregroundStyle(.secondary).frame(height: 16).contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(mapCoordinateSpace))
                                    .onChanged { value in
                                        if mapDragStart == nil { mapDragStart = mapHeight }
                                        let height = min(available - 135, max(160, (mapDragStart ?? mapHeight) + value.translation.height))
                                        mapShare = height / available
                                    }.onEnded { _ in mapDragStart = nil })
                                .accessibilityLabel(L10n.text("地图大小"))
                                .accessibilityAdjustableAction { direction in
                                    switch direction {
                                    case .increment: mapShare = min((available - 135) / available, mapShare + 0.05)
                                    case .decrement: mapShare = max(160 / available, mapShare - 0.05)
                                    @unknown default: break
                                    }
                                }
                            VStack(alignment: .leading, spacing: 8) {
                                coverage(result)
                                fileTable
                                pagination
                            }.frame(height: available - mapHeight)
                        }.coordinateSpace(name: mapCoordinateSpace)
                    }.frame(minHeight: 311)

                } else {
                    coverage(result)
                    fileTable.frame(minHeight: 150)
                    pagination
                }
            } else {
                ContentUnavailableView(L10n.text("先扫描一个位置"), systemImage: "internaldrive",
                    description: Text(L10n.text("默认从整盘概览开始，也可选择单个文件夹。扫描只读取元数据，不比较内容或自动清理。")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(.horizontal, 24).padding(.bottom, 10)
    }
    private var pagination: some View {
        HStack {
            Text(L10n.text("%@ 项 · 第 %@ 页", String(describing: storage.rowCount.formatted()), String(describing: storage.pageIndex + 1)))
                .font(.caption).foregroundStyle(.secondary)
            if storage.querying { ProgressView().controlSize(.small) }
            Spacer()
            Button(L10n.text("上一页")) { storage.changePage(-1) }.disabled(storage.pageIndex == 0 || storage.querying)
            Button(L10n.text("下一页")) { storage.changePage(1) }.disabled(!storage.hasNextPage || storage.querying)
        }
    }
    private var mapLegend: some View {
        HStack(spacing: 12) {
            legend(L10n.text("目录"), .blue); legend(L10n.text("图像／视频"), .purple)
            legend(L10n.text("文档"), .orange); legend(L10n.text("代码／其他"), .teal)
            Spacer()
        }.font(.caption2).foregroundStyle(.secondary)
    }
    private var expandedMap: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.text("空间地图")).font(.title2.weight(.semibold))
                Spacer()
                Button(L10n.text("完成")) { showExpandedMap = false }.keyboardShortcut(.cancelAction)
            }
            breadcrumbBar
            StorageTreemap(storage: storage).frame(maxWidth: .infinity, maxHeight: .infinity)
            mapLegend
            Text(L10n.text("双击目录进入，点击上方路径返回。关闭后继续使用原来的文件列表。"))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 960, height: 640)
    }
    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(Array(storage.breadcrumbs.enumerated()), id: \.element.path) { index, url in
                    if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    Button(index == 0 ? (storage.selectedVolume?.name ?? url.lastPathComponent) : url.lastPathComponent) { storage.navigate(url) }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(index == storage.breadcrumbs.count - 1 ? .primary : .secondary)
                }
            }
        }
    }
    private var fileTable: some View {
        Table(storage.rows, selection: $storage.selectedPath) {
            TableColumn(L10n.text("名称")) { item in
                HStack(spacing: 7) {
                    Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill").foregroundStyle(StorageTreemap.color(item))
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    if item.entry.isCloudPlaceholder { Image(systemName: "icloud").foregroundStyle(.secondary) }
                    if item.entry.isSymlink { Image(systemName: "arrow.turn.up.right").foregroundStyle(.secondary) }
                }.contentShape(Rectangle())
                    .onTapGesture(count: 2) { storage.enter(item) }
                    .contextMenu { itemMenu(item) }
            }.width(min: 110, ideal: 180, max: 260)
            TableColumn(L10n.text("文件大小")) { item in Text(StorageModel.bytes(item.logicalBytes)).monospacedDigit().font(.caption) }.width(72)
            TableColumn(L10n.text("磁盘占用估算")) { item in Text(StorageModel.bytes(item.allocatedBytes)).monospacedDigit().font(.caption) }.width(100)
            TableColumn(L10n.text("路径")) { item in Text(StorageModel.displayPath(item.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(StorageModel.displayPath(item.path)) }.width(min: 80, ideal: 130, max: 220)
            TableColumn(L10n.text("整理")) { item in
                Button { storage.toggleManual(item) } label: {
                    Image(systemName: storage.isPending(item.path) ? "checkmark.square.fill" : "square")
                }.buttonStyle(.plain)
                    .disabled(storage.busy || model.configurationNeedsRecovery || item.entry.isCloudPlaceholder || item.entry.isSymlink || item.entry.isPackage)
                    .accessibilityLabel("\(storage.isPending(item.path) ? L10n.text("取消选择") : L10n.text("加入待整理")) \(item.name)")
            }.width(42)
        }
        .onKeyPress(.space) {
            guard let item = storage.selectedItem else { return .ignored }
            storage.quickLook(item.entry); return .handled
        }
        .frame(minHeight: 80)
    }
    @ViewBuilder private func itemMenu(_ item: StorageItem) -> some View {
        if item.isDirectory && !item.entry.isPackage { Button(L10n.text("打开目录")) { storage.navigate(item.url) } }
        Button(L10n.text("快速预览")) { storage.quickLook(item.entry) }.disabled(item.entry.isCloudPlaceholder || item.entry.isSymlink)
        Button(L10n.text("在 Finder 中显示")) { storage.reveal(item.entry) }
        Button(L10n.text("复制路径")) { storage.copyPath(item.entry) }
        Divider()
        Button(L10n.text("忽略此位置")) { ignore(item.path) }.disabled(model.configurationNeedsRecovery || model.configuration.storage.excludedPaths.count >= 128)
        Button(storage.isPending(item.path) ? L10n.text("从待整理移除") : L10n.text("加入待整理")) { storage.toggleManual(item) }
            .disabled(storage.busy || model.configurationNeedsRecovery || item.entry.isCloudPlaceholder || item.entry.isSymlink || item.entry.isPackage)
    }
    private func coverage(_ result: StorageScanResult) -> some View {
        DisclosureGroup(isExpanded: $showCoverage) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("跳过 %@ 个忽略位置、%@ 个挂载点；%@ 处不可访问或读取失败。%@", String(describing: result.coverage.skippedExcluded), String(describing: result.coverage.skippedMounts), String(describing: result.coverage.errors), String(describing: result.coverage.cancelled ? L10n.text("结果不完整。") : "")))
                Text(L10n.text("云端占位 %@ 项、符号链接 %@ 项；硬链接已去重，共享克隆块未精确去重。", String(describing: result.coverage.skippedCloudFiles), String(describing: result.coverage.skippedSymlinks)))
                ForEach(result.coverage.errorSamples, id: \.self) { Text(StorageModel.displayPath($0)).textSelection(.enabled).lineLimit(2) }
            }
        } label: {
            HStack {
                Text(L10n.text("已扫描 %@ 个文件 · %@ · %@", String(describing: result.coverage.files.formatted()), String(describing: StorageModel.bytes(result.totalAllocatedBytes)), String(describing: result.coverage.cancelled ? L10n.text("已取消／部分结果") : (result.coverage.hasOmissions ? L10n.text("部分范围未扫描") : L10n.text("扫描完成")))))
                Spacer()
                Text(result.finishedAt, format: .dateTime.hour().minute())
            }
        }.font(.caption2).foregroundStyle(.secondary)
    }

    private var duplicateExplorer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("内容完全相同才归为一组；每组保留至少一个有效副本。"))
                    Text(L10n.text("跳过系统、应用与资料库包、环境、缓存及云端占位文件。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("添加文件夹…")) { storage.addDuplicateFolder() }.disabled(storage.busy)
                Button(L10n.text("开始比较")) { storage.startDuplicates() }.buttonStyle(.borderedProminent)
                    .disabled(storage.busy || storage.duplicateRoots.isEmpty || model.configurationNeedsRecovery)
            }
            ScrollView(.horizontal) {
                HStack {
                    ForEach(storage.duplicateRoots, id: \.path) { url in
                        HStack(spacing: 6) {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(StorageModel.displayPath(url.path)).lineLimit(1).font(.caption)
                            Button { storage.removeDuplicateRoot(url) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).disabled(storage.busy)
                        }.padding(7).background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in storage.addDuplicateRoots(urls); return !urls.isEmpty }
            HStack {
                Text(L10n.text("可拖入文件夹；支持本地外置盘。"))
                Spacer()
                Button(L10n.text("优先保留目录…")) { choosePreferredFolder() }.disabled(storage.busy || model.configurationNeedsRecovery)
            }.font(.caption).foregroundStyle(.secondary)
            if !model.configuration.storage.preferredKeepPaths.isEmpty {
                Text(L10n.text("优先保留：") + model.configuration.storage.preferredKeepPaths.joined(separator: "、"))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(storage.duplicateGroups) { group in duplicateGroup(group) }
                    if storage.duplicateGroups.isEmpty {
                        ContentUnavailableView(L10n.text("尚无重复文件结果"), systemImage: "doc.on.doc",
                            description: Text(L10n.text("点击“开始比较”读取文件内容；磁盘扫描不会自动进行内容比较。")))
                            .frame(maxWidth: .infinity).padding(.top, 24)
                    }
                    if !storage.duplicateIssues.isEmpty {
                        DisclosureGroup(L10n.text("跳过或未完成的项目（%@）", String(describing: storage.duplicateIssues.count))) {
                            ForEach(storage.duplicateIssues, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                    }
                }.padding(.trailing, 5)
            }
        }.padding(.horizontal, 24).padding(.bottom, 10)
    }
    private func duplicateGroup(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("%@ 个相同文件 · 每个 %@", String(describing: group.members.count), String(describing: StorageModel.bytes(group.members.first?.logicalBytes ?? 0))))
                .font(.callout.weight(.medium))
            ForEach(group.members) { entry in
                HStack(spacing: 8) {
                    let keeper = (storage.duplicateKeepers[group.id] ?? group.preferredKeepPath) == entry.path
                    Button { storage.setKeeper(entry.path, group: group) } label: {
                        Image(systemName: keeper ? "largecircle.fill.circle" : "circle")
                    }.buttonStyle(.plain).accessibilityLabel(L10n.text("保留 %@", String(describing: entry.name))).disabled(storage.busy)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).lineLimit(1)
                        Text(StorageModel.displayPath(entry.path)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if keeper { Text(L10n.text("保留")).font(.caption).foregroundStyle(.secondary) }
                    Button { storage.quickLook(entry) } label: { Image(systemName: "eye") }.buttonStyle(.borderless).help(L10n.text("快速预览"))
                    Button { storage.reveal(entry) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help(L10n.text("在 Finder 中显示"))
                    Button { storage.toggleDuplicate(entry, group: group) } label: {
                        Image(systemName: storage.isPending(entry.path) ? "checkmark.square.fill" : "square")
                    }.buttonStyle(.plain).disabled(keeper || storage.busy || model.configurationNeedsRecovery)
                        .accessibilityLabel(L10n.text("加入待整理 %@", String(describing: entry.name)))
                }.padding(.vertical, 3)
            }
        }.padding(12).background(.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
    }
    private var cacheExplorer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("按内置规则识别，先看用途和代价，再选择。"))
                    Text(L10n.text("不把模型、数据集、虚拟环境和项目产物列为垃圾；相关工具运行时会跳过。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("检查缓存")) { storage.startCaches() }.buttonStyle(.borderedProminent)
                    .disabled(storage.busy || model.configurationNeedsRecovery)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(StorageCacheKind.allCases, id: \.self) { kind in
                        let candidates = storage.cacheCandidates.filter { $0.rule.kind == kind }
                        if !candidates.isEmpty {
                            Text(kind.title).font(.headline).padding(.top, 5)
                            ForEach(candidates) { candidate in cacheRow(candidate) }
                        }
                    }
                    if storage.cacheCandidates.isEmpty {
                        ContentUnavailableView(L10n.text("尚无缓存检查结果"), systemImage: "shippingbox",
                            description: Text(L10n.text("支持已识别应用的用户缓存、30天前旧日志、Xcode DerivedData、pip 和 npm。uv、pnpm 仅分析。")))
                            .frame(maxWidth: .infinity).padding(.top, 24)
                    }
                }.padding(.trailing, 5)
            }
        }.padding(.horizontal, 24).padding(.bottom, 10)
    }
    private func cacheRow(_ candidate: StorageCacheCandidate) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button { storage.toggleCache(candidate) } label: {
                Image(systemName: storage.isPending(candidate.entry.path) ? "checkmark.square.fill" : "square")
            }.buttonStyle(.plain).disabled(!candidate.canClean || storage.busy || model.configurationNeedsRecovery)
                .accessibilityLabel(L10n.text("加入待整理 %@", String(describing: candidate.title)))
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text(candidate.title).font(.callout.weight(.medium)); if !candidate.canClean { Text(L10n.text("仅分析")).font(.caption).foregroundStyle(.secondary) } }
                Text(candidate.reason).font(.caption).foregroundStyle(.secondary)
                Text(StorageModel.displayPath(candidate.entry.path)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(StorageModel.bytes(candidate.bytes)).font(.caption).monospacedDigit()
            Button { storage.reveal(candidate.entry) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help(L10n.text("在 Finder 中显示"))
        }.padding(10).background(.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
    }
    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(storage.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if !storage.progressText.isEmpty { Text(storage.progressText).font(.caption2).foregroundStyle(.secondary).monospacedDigit() }
            }
            if storage.busy { ProgressView().controlSize(.small) }
            Spacer(minLength: 5)
            if !storage.pending.isEmpty { Button(L10n.text("清空选择")) { storage.clearPending() }.disabled(storage.busy) }
            Button(L10n.text("预览待整理（%@）", String(describing: storage.pendingCount))) { storage.beginReview() }
                .disabled(storage.busy || storage.pending.isEmpty || model.configurationNeedsRecovery)
        }.padding(.horizontal, 24).padding(.vertical, 12)
    }
    private var ignoredSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("忽略列表与权限")).font(.title2.weight(.semibold))
            Text(L10n.text("无完全磁盘访问权限仍可分析可访问位置。仅在需要查看受限目录时前往系统设置；不会提升管理员权限。"))
                .font(.callout).foregroundStyle(.secondary)
            Button(L10n.text("前往完全磁盘访问设置")) { storage.openDiskPermissionSettings() }
            Divider()
            Text(L10n.text("忽略的位置")).font(.headline)
            List {
                ForEach(model.configuration.storage.excludedPaths, id: \.self) { path in
                    HStack {
                        Text(path).font(.caption).lineLimit(2).textSelection(.enabled)
                        Spacer()
                        Button { model.configuration.storage.excludedPaths.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                            .disabled(model.configurationNeedsRecovery)
                    }
                }
                if model.configuration.storage.excludedPaths.isEmpty { Text(L10n.text("尚未添加。可在文件列表的右键菜单中忽略位置。")) .foregroundStyle(.secondary).font(.caption) }
            }
            HStack {
                Button(L10n.text("清除优先保留目录")) { model.configuration.storage.preferredKeepPaths = [] }
                    .disabled(model.configuration.storage.preferredKeepPaths.isEmpty || model.configurationNeedsRecovery)
                Spacer()
                Button(L10n.text("完成")) { showIgnored = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 620, height: 430)
    }
    private func updateThreshold() {
        let bounded = max(1, min(10_000_000, largeMegabytes))
        largeMegabytes = bounded
        model.configuration.storage.minimumLargeFileBytes = Int64(bounded) * 1_000_000
    }
    private func ignore(_ path: String) {
        let logical = StorageModel.displayPath(path)
        guard !model.configuration.storage.excludedPaths.contains(logical) else { return }
        model.configuration.storage.excludedPaths.append(logical)
    }
    private func choosePreferredFolder() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择优先保留副本的目录"); panel.canChooseFiles = false; panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path
        if !model.configuration.storage.preferredKeepPaths.contains(path) { model.configuration.storage.preferredKeepPaths.append(path) }
    }
    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 6, height: 6); Text(title) }
    }
}

private struct StorageTreemap: View {
    @ObservedObject var storage: StorageModel
    private var otherBytes: Int64 {
        guard storage.search.isEmpty else { return 0 }
        return max(0, storage.currentDirectoryBytes - storage.mapRows.reduce(0) { $0 + $1.bytes(for: storage.settings.sizeMetric) })
    }
    var body: some View {
        GeometryReader { proxy in
            let items = storage.mapRows
            let weights = items.map { TreemapWeight(id: $0.id, weight: Double($0.bytes(for: storage.settings.sizeMetric))) }
                + (otherBytes > 0 ? [TreemapWeight(id: "macdaily:other", weight: Double(otherBytes))] : [])
            let tiles = TreemapLayout.layout(items: weights, in: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 7).fill(.secondary.opacity(0.06))
                ForEach(tiles, id: \.id) { tile in
                    if let item = items.first(where: { $0.id == tile.id }) {
                        ZStack(alignment: .topLeading) {
                            Rectangle().fill(Self.color(item).opacity(storage.selectedPath == item.path ? 0.85 : 0.48))
                            if tile.frame.width > 60 && tile.frame.height > 27 {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                                    if tile.frame.height > 43 { Text(StorageModel.bytes(item.bytes(for: storage.settings.sizeMetric))).font(.caption2).lineLimit(1) }
                                }.padding(6).foregroundStyle(.primary)
                            }
                            Rectangle().strokeBorder(storage.selectedPath == item.path ? Color.primary.opacity(0.75) : .white.opacity(0.6), lineWidth: storage.selectedPath == item.path ? 2 : 1)
                        }.frame(width: tile.frame.width, height: tile.frame.height)
                            .contentShape(Rectangle()).position(x: tile.frame.midX, y: tile.frame.midY)
                            .onTapGesture(count: 2) { storage.enter(item) }
                            .onTapGesture { storage.selectedPath = item.path }
                            .help("\(item.name) · \(StorageModel.bytes(item.bytes(for: storage.settings.sizeMetric)))")
                            .accessibilityLabel("\(item.name)，\(StorageModel.bytes(item.bytes(for: storage.settings.sizeMetric)))")
                    } else {
                        ZStack { Rectangle().fill(.secondary.opacity(0.17)); if tile.frame.width > 48 && tile.frame.height > 24 { Text(L10n.text("其余项目")).font(.caption2).foregroundStyle(.secondary) } }
                            .frame(width: tile.frame.width, height: tile.frame.height).position(x: tile.frame.midX, y: tile.frame.midY)
                    }
                }
            }.clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .overlay(alignment: .bottomTrailing) {
            Text(storage.search.isEmpty ? L10n.text("本层前64项，其余合并；双击目录进入") : L10n.text("筛选结果前64项"))
                .font(.system(size: 9)).padding(4).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4)).padding(4)
                .allowsHitTesting(false)
        }
    }
    static func color(_ item: StorageItem) -> Color {
        if item.isDirectory { return .blue }
        switch item.url.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "gif", "webp", "mp4", "mov", "mkv", "avi": return .purple
        case "pdf", "doc", "docx", "txt", "md", "pptx", "xlsx", "pages": return .orange
        case "zip", "dmg", "pkg", "tar", "gz", "7z": return .indigo
        default: return .teal
        }
    }
}

private struct StorageReviewView: View {
    @ObservedObject var storage: StorageModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("预览待整理")).font(.title2.weight(.semibold))
            Text(L10n.text("仅移入系统废纸篓，不永久删除。文件、目录内容或保留副本变化时将跳过；相关应用运行中的缓存也会跳过。"))
                .font(.callout).foregroundStyle(.secondary)
            if !storage.cleanupResults.isEmpty {
                results
            } else {
                preview
            }
            Divider()
            HStack {
                if storage.busy { ProgressView().controlSize(.small); Text(storage.status).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if !storage.cleanupResults.isEmpty { Button(L10n.text("打开废纸篓")) { storage.openTrash() } }
                Button(L10n.text("关闭")) { storage.closeReview() }.keyboardShortcut(.cancelAction).disabled(storage.busy)
                Button(L10n.text("移入废纸篓")) { storage.executePreview() }.buttonStyle(.borderedProminent)
                    .disabled(storage.busy || storage.preview?.items.isEmpty != false || !storage.cleanupResults.isEmpty)
            }
        }.padding(20).frame(width: 760, height: 550)
            .interactiveDismissDisabled(storage.busy)
    }
    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let preview = storage.preview {
                Text(L10n.text("核对通过 %@ 项 · 占用估算 %@", String(describing: preview.items.count), String(describing: StorageModel.bytes(preview.totalBytes))))
                    .font(.headline)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(preview.items) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack { Text(item.entry.name).font(.callout.weight(.medium)); Spacer(); Text(StorageModel.bytes(item.bytes)).font(.caption).monospacedDigit() }
                                Text(StorageModel.displayPath(item.id)).font(.caption).textSelection(.enabled)
                                Text(item.reason).font(.caption).foregroundStyle(.secondary)
                            }.padding(10).background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        }
                        if !preview.issues.isEmpty {
                            Text(L10n.text("未加入本次处理")).font(.headline).padding(.top, 5)
                            ForEach(preview.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                        if preview.items.isEmpty && preview.issues.isEmpty { Text(L10n.text("没有可处理的项目。")).foregroundStyle(.secondary) }
                    }.padding(.trailing, 5)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(storage.pending) { selection in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(selection.entry.name).font(.callout.weight(.medium))
                                    Text(StorageModel.displayPath(selection.id)).font(.caption).foregroundStyle(.secondary)
                                    Text(selection.reason).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { storage.removePending(selection.id) } label: { Image(systemName: "minus.circle") }
                                    .disabled(storage.busy)
                            }.padding(8)
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private var results: some View {
        VStack(alignment: .leading, spacing: 10) {
            let moved = storage.cleanupResults.filter { $0.status == .moved }
            Text(L10n.text("已移入废纸篓 %@ 项 · %@", String(describing: moved.count), String(describing: StorageModel.bytes(moved.reduce(0) { $0 + $1.movedBytes }))))
                .font(.headline)
            Text(L10n.text("尚未清空废纸篓，不能视为已释放空间。共享块、快照和系统更新延迟也会影响容量变化。"))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    ForEach(storage.cleanupResults) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(item.status == .moved ? L10n.text("已移入废纸篓") : item.status == .skipped ? L10n.text("已跳过") : L10n.text("未完成"), systemImage: item.status == .moved ? "checkmark.circle" : "exclamationmark.circle")
                                .font(.callout.weight(.medium))
                            Text(StorageModel.displayPath(item.path)).font(.caption).textSelection(.enabled)
                            Text(item.message).font(.caption).foregroundStyle(.secondary)
                        }.padding(8)
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
