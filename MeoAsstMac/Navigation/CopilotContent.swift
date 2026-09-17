//
//  CopilotsView.swift
//  MAA
//
//  Created by hguandl on 17/4/2023.
//

import Security
import SwiftUI
import UniformTypeIdentifiers

struct CopilotContent: View {
    @Environment(NewViewModel.self) var newModel
    @EnvironmentObject private var viewModel: MAAViewModel

    struct Item: FileTreeItem {
        let url: URL
        let id: CopilotContext.ItemID

        init(url: URL) {
            self.url = url
            self.id = .init(url: url, isRaid: nil)
        }

        var children: [Item]?

        var name: String {
            url.deletingPathExtension().lastPathComponent
        }
    }

    private struct QueuedCopilot: Identifiable, Equatable {
        let id: UUID
        let url: URL
        let stageName: String
        let filename: String

        init(url: URL, id: UUID = UUID()) {
            self.id = id
            self.url = url
            self.filename = url.lastPathComponent
            self.stageName = MAACopilot(url: url)?.navigationStageName ?? url.lastPathComponent
        }
    }

    private enum BattleMode: String, CaseIterable, Identifiable {
        case single = "普通战斗"
        case queue = "连续作战"
        case mainStory = "全主线推进"
        case resources = "资源获取"

        var id: Self { self }
    }

    @State private var bundledRoot = Item(url: .bundledCopilotDirectory)
    @State private var externalRoot = Item(url: .externalCopilotDirectory)
    @State private var tracker = FileTreeTracker()
    @State private var copilotQueue = [QueuedCopilot]()
    @State private var battleMode = BattleMode.single
    @State private var useAutomaticFallbacks = false
    @State private var showOperatorSettings = false
    @State private var operatorToken = ""
    @State private var ownedOperatorNames = Set<String>()
    @State private var operatorMatchingEnabled = false
    @State private var operatorSyncError: String?
    @State private var failedCopilotCount = 0
    @State private var copilotSetCode = ""
    @State private var copilotSetStatus: String?
    @State private var importingCopilotSet = false
    @State private var barkTestStatus: String?
    @State private var testingBark = false
    @AppStorage("MAAMainStoryStart") private var mainStoryStart = "main_05-01"
    @AppStorage("MAAMainStoryEnd") private var mainStoryEnd = MainStoryStage.all.last?.id ?? ""
    @AppStorage("MAAResourceStageLine") private var resourceStageLine = ResourceStageLine.all.first?.id ?? "CE"
    @AppStorage("MAAResourceStageStart") private var resourceStageStart = "CE-1"
    @AppStorage("MAAResourceStageEnd") private var resourceStageEnd = "CE-6"
    @AppStorage("MAAAutomaticStageBattleCount") private var automaticStageBattleCount = 1
    @AppStorage("MAAMainStoryBarkEndpoint") private var barkEndpoint = ""
    @State private var mainStoryProgress = ""
    @State private var mainStoryTask: Task<Void, Never>?

    var body: some View {
        @Bindable var context = newModel.copilot
        VStack(spacing: 0) {
            battleModeControls
            Divider()

            List(selection: $context.selection) {
                if battleMode == .queue {
                    queueSection
                }

                switch context.category {
                case .bundled:
                    FileTreeRoot(item: $bundledRoot, tracker: tracker) {
                        Text($0.name)
                    }
                case .external:
                    FileTreeRoot(item: $externalRoot, tracker: tracker) {
                        Text($0.name)
                    }
                case .list:
                    CopilotListContent(context: context)
                }
            }
            .contextMenu(forSelectionType: CopilotContext.ItemID.self) { _ in
                EmptyView()
            } primaryAction: { ids in
                if context.category == .list {
                    context.selection = nil
                    return
                }
                if let url = ids.first?.url {
                    tracker.sendURLAction(of: url)
                }
            }
            .safeAreaInset(edge: .top, spacing: 6) {
                CapsulePicker(CopilotCategory.allCases, selection: $context.category, color: \.color) {
                    Image(systemName: $0.systemImage)
                } text: {
                    Text($0.title)
                } action: {
                    context.selection = nil
                }
                .padding(.horizontal)
                .padding(.top, 6)
                .background(.background)
            }
            .safeAreaInset(edge: .bottom) {
                if context.category == .list {
                    CopilotListControls(context: context)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(.background)
                }
            }
        }
        .toolbar {
            if battleMode == .queue {
                ToolbarItemGroup {
                    Button(action: addSelectedCopilotToQueue) {
                        Label("添加到战斗列表", systemImage: "text.badge.plus")
                    }
                    .help("添加到战斗列表")
                    .disabled(!canAddSelectedCopilotToQueue)

                    Button(action: { copilotQueue.removeAll() }) {
                        Label("清空战斗列表", systemImage: "clear")
                    }
                    .help("清空战斗列表")
                    .disabled(copilotQueue.isEmpty)
                }
            }
            CopilotListToolbar(
                externalRoot: $externalRoot,
                isAutomaticRunning: mainStoryTask != nil,
                canStart: canStart,
                startAction: start,
                stopAction: stop)
        }
        .task(id: context.category) {
            switch context.category {
            case .bundled:
                await refreshItem(at: \.$bundledRoot)
            case .external:
                await refreshItem(at: \.$externalRoot)
            case .list:
                break
            }
        }
        .task(id: newModel.lastImportedCopilot) {
            guard let url = newModel.lastImportedCopilot else { return }
            defer { newModel.lastImportedCopilot = nil }
            context.selection = .init(url: url, isRaid: nil)
            if url.isDirectory {
                await context.updateSet(at: url)
                context.category = .list
            } else {
                await refreshItem(at: \.$externalRoot)
                context.category = .external
            }
        }
        .onChange(of: context.copilotList.isEmpty, initial: true) {
            if $1, context.category == .list {
                context.category = .external
                context.selection = nil
            }
        }
        .onAppear {
            ownedOperatorNames = OperatorRosterStore.names
            operatorMatchingEnabled = OperatorRosterStore.matchingEnabled
            failedCopilotCount = FailedCopilotStore.ids.count
        }
        .onDrop(of: [.json], isTargeted: .none, perform: addCopilots)
        .sheet(isPresented: $showOperatorSettings, content: operatorSettings)
    }

    @ViewBuilder private var queueSection: some View {
        Section("战斗列表（从关卡地图开始）") {
            if copilotQueue.isEmpty {
                Text("请从下方选择作业并点按添加")
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(copilotQueue.enumerated()), id: \.element.id) { index, item in
                HStack {
                    VStack(alignment: .leading) {
                        Text(item.stageName)
                        Text(item.filename)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        moveQueuedCopilot(at: index, offset: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .help("上移")
                    .disabled(index == copilotQueue.startIndex)

                    Button {
                        moveQueuedCopilot(at: index, offset: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .help("下移")
                    .disabled(index == copilotQueue.index(before: copilotQueue.endIndex))

                    Button {
                        removeQueuedCopilot(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("从战斗列表移除")
                }
                .tag(CopilotContext.ItemID(url: item.url, isRaid: nil))
            }
        }
    }

    @ViewBuilder private var battleModeControls: some View {
        @Bindable var context = newModel.copilot
        VStack(alignment: .leading, spacing: 10) {
            Picker("作战模式", selection: $battleMode) {
                ForEach(BattleMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if battleMode == .mainStory {
                HStack {
                    Picker("起始", selection: $mainStoryStart) {
                        ForEach(MainStoryStage.all) { stage in
                            Text(stage.code).tag(stage.id)
                        }
                    }
                    Picker("结束", selection: $mainStoryEnd) {
                        ForEach(MainStoryStage.all) { stage in
                            Text(stage.code).tag(stage.id)
                        }
                    }
                }
                Text("从所选起点开始推进；不会读取账号的历史通关记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if battleMode == .resources {
                Picker("资源类别", selection: $resourceStageLine) {
                    ForEach(ResourceStageLine.all) { line in
                        Text(line.name).tag(line.id)
                    }
                }
                .onChange(of: resourceStageLine) { resetResourceStageRange() }

                HStack {
                    Picker("起始", selection: $resourceStageStart) {
                        ForEach(selectedResourceLine.stages) { stage in
                            Text(stage.code).tag(stage.code)
                        }
                    }
                    Picker("结束", selection: $resourceStageEnd) {
                        ForEach(selectedResourceLine.stages) { stage in
                            Text(stage.code).tag(stage.code)
                        }
                    }
                }
                Text("资源线独立推进；当天未开放或尚未解锁时会停止并提示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if battleMode == .mainStory || battleMode == .resources {
                Stepper(value: $automaticStageBattleCount, in: 1...99) {
                    Text("每关战斗次数：\(automaticStageBattleCount)")
                }
                .help("当前关卡成功完成指定次数后，再进入下一关。")
            }

            if !mainStoryProgress.isEmpty, battleMode == .mainStory || battleMode == .resources {
                Text(mainStoryProgress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if battleMode != .single {
                if battleMode == .queue {
                    HStack {
                        TextField("作业集神秘代码（prts://s...）", text: $copilotSetCode)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { importCopilotSet() }
                        Button(action: importCopilotSet) {
                            if importingCopilotSet {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("导入作业集", systemImage: "square.and.arrow.down")
                            }
                        }
                        .disabled(importingCopilotSet || PRTSPlusClient.copilotSetID(from: copilotSetCode) == nil)
                    }
                    if let copilotSetStatus {
                        Text(copilotSetStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("自动搜索备用作业", isOn: $useAutomaticFallbacks)
                    .help("从 PRTS.plus 按热度下载同关卡作业；当前作业失败或漏怪时自动切换。")
                Button {
                    operatorToken = OperatorRosterStore.token ?? ""
                    showOperatorSettings = true
                } label: {
                    Label(operatorSettingsLabel, systemImage: "person.2")
                }
                .buttonStyle(.plain)
                Toggle(
                    "漏怪时退出并重试",
                    isOn: Binding(
                        get: { context.config.retry_on_leak ?? false },
                        set: { context.config.retry_on_leak = $0 })
                )
                .help("检测到目标生命降低时退出当前作战，并重试一次。允许战术漏怪的作业请勿启用。")
            }
        }
        .padding(12)
    }

    // MARK: - Actions

    private func refreshItem(at keyPath: KeyPath<Self, Binding<Item>>) async {
        let binding = self[keyPath: keyPath]
        let newChildren = try? await binding.wrappedValue.children()
        binding.wrappedValue.children = newChildren ?? []
    }

    private func addCopilots(_ providers: [NSItemProvider]) -> Bool {
        let canLoadAll = providers.allSatisfy {
            $0.hasItemConformingToTypeIdentifier(UTType.json.identifier)
        }
        guard !providers.isEmpty, canLoadAll else { return false }

        let (stream, continuation) = AsyncStream<Result<URL, Error>>.makeStream()
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.json.identifier) { item, error in
                if let error {
                    continuation.yield(.failure(error))
                } else if let url = item as? URL {
                    continuation.yield(.success(url))
                } else {
                    continuation.yield(.failure(CocoaError(.fileReadUnknown)))
                }
            }
        }

        Task.detached { [total = providers.count] in
            var count = 0
            for await result in stream {
                count += 1
                if count == total { continuation.finish() }
                do {
                    let url = try result.get()
                    try await addCopilot(url: url)
                } catch {
                    print(error)
                }
            }
        }
        return true
    }

    private func addCopilot(url: URL) async throws {
        guard url.isFileURL, let type = url.contentType else { return }
        switch type {
        case _ where type.conforms(to: .json):
            async let dest = try FileManager.default.copyCopilotToExternalDirectory(at: url)
            newModel.lastImportedCopilot = try await dest
        case _ where type.conforms(to: .movie):
            try await newModel.recognizeVideo(url: url)
        default:
            break
        }
    }

    private func stop() {
        mainStoryTask?.cancel()
        guard viewModel.status != .idle else { return }
        Task { try await newModel.stop() }
    }

    private func start() {
        viewModel.markPending()
        if battleMode == .mainStory || battleMode == .resources {
            mainStoryTask?.cancel()
            mainStoryTask = Task {
                if battleMode == .mainStory {
                    await runMainStory()
                } else {
                    await runResourceStages()
                }
            }
            return
        }

        Task {
            do {
                if battleMode == .queue {
                    try await runQueue()
                } else {
                    try await newModel.startCopilot()
                }
            } catch {
                viewModel.logError("启动自动战斗失败：\(error.localizedDescription)")
                viewModel.resetStatus()
            }
        }
    }

    private func runQueue() async throws {
        if useAutomaticFallbacks {
            viewModel.logInfo("正在从 PRTS.plus 检索候选备用作业...")
        }
        let seeds = copilotQueue.map(\.url)
        let urls = useAutomaticFallbacks ? try await automaticFallbacks(for: seeds) : seeds
        let items = urls.compactMap { url -> CopilotConfiguration.CopilotItem? in
            guard let copilot = MAACopilot(url: url), copilot.type != "SSS" else { return nil }
            return .init(
                filename: url.path(percentEncoded: false),
                nav_name_override: copilot.navigationStageName,
                is_raid: false)
        }
        guard items.count == urls.count else {
            throw PRTSPlusError.api("队列中存在无法读取或格式不支持的作业")
        }

        var configuration = newModel.copilot.config
        configuration.filename = nil
        configuration.copilot_list = items
        configuration.switch_copilot_on_failure = useAutomaticFallbacks
        try await startCopilot(configuration)
    }

    @MainActor private func runMainStory() async {
        do {
            guard let start = MainStoryStage.all.firstIndex(where: { $0.id == mainStoryStart }),
                let end = MainStoryStage.all.firstIndex(where: { $0.id == mainStoryEnd }),
                start <= end
            else {
                throw PRTSPlusError.api("主线关卡范围无效")
            }

            let stages = Array(MainStoryStage.all[start...end]).map { ($0.stageId, $0.code) }
            let battleCount = automaticStageBattleCount
            try await runAutomaticStages(stages, battleCount: battleCount)
            mainStoryProgress = "已完成 \(stages.count) 个主线关卡，共 \(stages.count * battleCount) 次战斗"
            mainStoryTask = nil
        } catch {
            if Task.isCancelled {
                mainStoryProgress = "主线推进已停止"
                mainStoryTask = nil
                return
            }
            mainStoryProgress = "主线推进已停止：\(error.localizedDescription)"
            await notifyAutomaticFailure(error)
            viewModel.logError("主线推进失败：\(error.localizedDescription)")
            viewModel.resetStatus()
            mainStoryTask = nil
        }
    }

    @MainActor private func runResourceStages() async {
        do {
            let line = selectedResourceLine
            guard let start = line.stages.firstIndex(where: { $0.code == resourceStageStart }),
                let end = line.stages.firstIndex(where: { $0.code == resourceStageEnd }),
                start <= end
            else {
                throw PRTSPlusError.api("资源关卡范围无效")
            }

            let stages = Array(line.stages[start...end]).map { ($0.stageId, $0.code) }
            let battleCount = automaticStageBattleCount
            try await runAutomaticStages(stages, battleCount: battleCount)
            mainStoryProgress = "已完成 \(line.name)资源线（\(stages.count) 关，共 \(stages.count * battleCount) 次战斗）"
            mainStoryTask = nil
        } catch {
            if Task.isCancelled {
                mainStoryProgress = "资源获取已停止"
                mainStoryTask = nil
                return
            }
            mainStoryProgress = "资源获取已停止：\(error.localizedDescription)"
            await notifyAutomaticFailure(error)
            viewModel.logError("资源获取失败：\(error.localizedDescription)")
            viewModel.resetStatus()
            mainStoryTask = nil
        }
    }

    @MainActor private func runAutomaticStages(
        _ stages: [(id: String, code: String)],
        battleCount: Int
    ) async throws {
        let names = operatorMatchingEnabled ? ownedOperatorNames : []
        for (index, stage) in stages.enumerated() {
            try Task.checkCancellation()
            mainStoryProgress = "正在获取作业：\(stage.code)（\(index + 1)/\(stages.count)）"
            var urls: [URL] = []
            do {
                urls = try await PRTSPlusClient.candidates(
                    for: stage.id,
                    excluding: FailedCopilotStore.ids,
                    ownedOperatorNames: names,
                    limit: 5)
            } catch let error as PRTSPlusError {
                if operatorMatchingEnabled && newModel.copilot.config.ignore_requirements {
                    urls =
                        (try? await PRTSPlusClient.candidates(
                            for: stage.id,
                            excluding: FailedCopilotStore.ids,
                            ownedOperatorNames: [],
                            limit: 5)) ?? []
                    if !urls.isEmpty {
                        viewModel.logWarn("关卡 \(stage.code) 本地干员匹配未完全满足，已按「忽视干员属性要求」降级使用候选作业")
                    }
                }
                if urls.isEmpty { throw error }
            }
            guard !urls.isEmpty else { throw PRTSPlusError.noCopilot(stage.code) }

            if urls.count == 1 {
                viewModel.logWarn("关卡 \(stage.code) 找到 1 份可用作业，未找到备用作业")
            } else {
                viewModel.logInfo("关卡 \(stage.code) 找到 \(urls.count) 份候选作业")
            }

            var completedBattles = 0
            var candidateIndex = 0
            while completedBattles < battleCount && candidateIndex < urls.count {
                try Task.checkCancellation()
                let url = urls[candidateIndex]
                var configuration = newModel.copilot.config
                configuration.filename = nil
                configuration.copilot_list = [
                    .init(
                        filename: url.path(percentEncoded: false),
                        nav_name_override: stage.code,
                        is_raid: false)
                ]
                configuration.switch_copilot_on_failure = true
                mainStoryProgress =
                    "正在作战：\(stage.code)（第 \(completedBattles + 1)/\(battleCount) 次，作业 \(candidateIndex + 1)/\(urls.count)）"
                try await startCopilot(configuration)

                if try await viewModel.waitUntilCopilotCompleted() {
                    completedBattles += 1
                    viewModel.logInfo("关卡 \(stage.code) 已完成 \(completedBattles)/\(battleCount) 次")
                    continue
                }
                FailedCopilotStore.markFailed(fileName: url.path)
                candidateIndex += 1
                if candidateIndex < urls.count {
                    mainStoryProgress = "作业不可用，正在切换：\(stage.code)（已完成 \(completedBattles)/\(battleCount) 次）"
                    viewModel.logWarn("关卡 \(stage.code) 当前作业不可用，正在切换下一份作业")
                } else {
                    mainStoryProgress = "作业不可用，已无其他候选：\(stage.code)"
                    viewModel.logError("关卡 \(stage.code) 当前作业不可用，已无其他可用作业")
                }
            }
            guard completedBattles == battleCount else {
                throw PRTSPlusError.api(
                    "关卡 \(stage.code) 仅完成 \(completedBattles)/\(battleCount) 次，候选作业均不可用")
            }
        }
    }

    private func startCopilot(_ configuration: CopilotConfiguration) async throws {
        guard let params = try? configuration.jsonString() else {
            throw PRTSPlusError.api("作业配置序列化失败")
        }
        try await viewModel.startCopilot(type: .Copilot, params: params)
    }

    private var selectedResourceLine: ResourceStageLine {
        ResourceStageLine.all.first(where: { $0.id == resourceStageLine }) ?? ResourceStageLine.all[0]
    }

    private func resetResourceStageRange() {
        guard let first = selectedResourceLine.stages.first, let last = selectedResourceLine.stages.last else { return }
        resourceStageStart = first.code
        resourceStageEnd = last.code
        mainStoryProgress = ""
    }

    @MainActor private func notifyAutomaticFailure(_ failure: Error) async {
        guard !barkEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try await BarkClient.notify(
                endpoint: barkEndpoint,
                title: "MAA 连续作战需要处理",
                body: failure.localizedDescription)
        } catch {
            viewModel.logError("Bark 通知发送失败：\(error.localizedDescription)")
        }
    }

    @ViewBuilder private func operatorSettings() -> some View {
        @Bindable var context = newModel.copilot
        VStack(alignment: .leading, spacing: 16) {
            Text("配队与干员匹配").font(.headline)
            Toggle("自动编队", isOn: $context.config.formation)
            if context.config.formation {
                HStack {
                    Picker("编队栏位", selection: $context.config.formation_index) {
                        Text("当前").tag(0)
                        ForEach(1...4, id: \.self) { index in
                            Text("\(index)").tag(index)
                        }
                    }
                    .pickerStyle(.menu)
                    Toggle("忽视干员属性要求", isOn: $context.config.ignore_requirements)
                }
                Toggle("补充低信赖干员", isOn: $context.config.add_trust)
                HStack {
                    Picker("助战模式", selection: $context.config.support_unit_usage) {
                        ForEach(CopilotConfiguration.SupportUnitUsage.allCases, id: \.self) { mode in
                            Text(mode.description).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    if context.config.support_unit_usage == .specific {
                        TextField("助战干员名称", text: $context.config.support_unit_name)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            Text("Token 保存到系统钥匙串，仅用于直接向明日方舟一图流同步干员数据，不会发送至 PRTS.plus。")
                .font(.callout)
                .foregroundStyle(.secondary)
            SecureField("一图流 Token", text: $operatorToken)
                .textFieldStyle(.roundedBorder)
            if !ownedOperatorNames.isEmpty {
                Toggle("启用干员匹配", isOn: $operatorMatchingEnabled)
                Text("已导入 \(ownedOperatorNames.count) 名干员数据")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let operatorSyncError {
                Text(operatorSyncError).foregroundStyle(.red).font(.callout)
            }
            if failedCopilotCount > 0 {
                HStack {
                    Text("已自动跳过 \(failedCopilotCount) 个失败作业")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("重新启用") {
                        FailedCopilotStore.clear()
                        failedCopilotCount = 0
                    }
                }
            }
            HStack {
                TextField("Bark 推送地址（https://api.day.app/设备码）", text: $barkEndpoint)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await testBark() }
                } label: {
                    if testingBark {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("测试推送", systemImage: "bell.badge")
                    }
                }
                .disabled(testingBark || barkEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let barkTestStatus {
                Text(barkTestStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("清除本地数据", role: .destructive) {
                    OperatorRosterStore.clear()
                    operatorToken = ""
                    ownedOperatorNames = []
                    operatorMatchingEnabled = false
                }
                Spacer()
                Button("取消") { showOperatorSettings = false }
                Button("同步干员数据") {
                    Task { await syncOperatorRoster() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(operatorToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onChange(of: operatorMatchingEnabled) {
            OperatorRosterStore.matchingEnabled = $1
        }
    }

    private var operatorSettingsLabel: String {
        ownedOperatorNames.isEmpty ? "配队与干员匹配" : "配队与干员匹配（\(ownedOperatorNames.count)）"
    }

    @MainActor private func syncOperatorRoster() async {
        do {
            let names = try await PRTSPlusClient.syncOperatorNames(token: operatorToken)
            guard !names.isEmpty else { throw PRTSPlusError.emptyOperatorRoster }
            try OperatorRosterStore.setToken(operatorToken)
            OperatorRosterStore.names = names
            OperatorRosterStore.matchingEnabled = true
            ownedOperatorNames = names
            operatorMatchingEnabled = true
            operatorSyncError = nil
        } catch {
            operatorSyncError = error.localizedDescription
        }
    }

    @MainActor private func testBark() async {
        testingBark = true
        defer { testingBark = false }
        do {
            try await BarkClient.notify(
                endpoint: barkEndpoint,
                title: "MAA Bark 测试",
                body: "推送配置可用")
            barkTestStatus = "测试推送已发送"
        } catch {
            barkTestStatus = "测试失败：\(error.localizedDescription)"
        }
    }

    private func automaticFallbacks(for seeds: [URL]) async throws -> [URL] {
        let validSeeds = seeds.compactMap { url -> (URL, MAACopilot)? in
            guard let copilot = MAACopilot(url: url), copilot.type != "SSS" else { return nil }
            return (url, copilot)
        }
        let names = operatorMatchingEnabled ? ownedOperatorNames : []
        return try await withThrowingTaskGroup(of: (Int, URL, [URL]).self) { group in
            for (index, (seed, copilot)) in validSeeds.enumerated() {
                group.addTask {
                    let seedID = Int(seed.deletingPathExtension().lastPathComponent)
                    let excluding: Set<Int> = seedID.map { [$0] } ?? []
                    let fallbacks =
                        (try? await PRTSPlusClient.fallbacks(
                            for: copilot,
                            excluding: excluding,
                            ownedOperatorNames: names)) ?? []
                    return (index, seed, fallbacks)
                }
            }

            var indexedResults: [(Int, [URL])] = []
            for try await (index, seed, fallbacks) in group {
                indexedResults.append((index, [seed] + fallbacks))
            }
            indexedResults.sort { $0.0 < $1.0 }
            return indexedResults.flatMap(\.1)
        }
    }

    private func addSelectedCopilotToQueue() {
        guard let url = newModel.copilot.selection?.url, canAddSelectedCopilotToQueue else { return }
        copilotQueue.append(QueuedCopilot(url: url))
    }

    private func importCopilotSet() {
        guard let id = PRTSPlusClient.copilotSetID(from: copilotSetCode) else {
            copilotSetStatus = "无法识别作业集神秘代码"
            return
        }

        importingCopilotSet = true
        copilotSetStatus = "正在导入作业集..."
        Task {
            defer { importingCopilotSet = false }
            do {
                let downloaded = try await PRTSPlusClient.downloadCopilotSet(id: id)
                let regular = downloaded.filter { MAACopilot(url: $0)?.type != "SSS" }
                guard !regular.isEmpty else {
                    throw PRTSPlusError.api("作业集中没有可用于连续作战的普通作业")
                }
                copilotQueue.append(contentsOf: regular.map { QueuedCopilot(url: $0) })
                copilotSetCode = ""
                let skipped = downloaded.count - regular.count
                copilotSetStatus =
                    skipped == 0
                    ? "已按原顺序导入 \(regular.count) 份作业"
                    : "已导入 \(regular.count) 份普通作业，跳过 \(skipped) 份保全作业"
                let children = try? await externalRoot.children()
                externalRoot.children = children ?? []
            } catch {
                copilotSetStatus = "导入失败：\(error.localizedDescription)"
            }
        }
    }

    private func moveQueuedCopilot(at index: Int, offset: Int) {
        let destination = index + offset
        guard copilotQueue.indices.contains(index), copilotQueue.indices.contains(destination) else { return }
        copilotQueue.swapAt(index, destination)
    }

    private func removeQueuedCopilot(at index: Int) {
        guard copilotQueue.indices.contains(index) else { return }
        let removed = copilotQueue.remove(at: index)
        if newModel.copilot.selection?.url == removed.url {
            let next = copilotQueue.indices.contains(index) ? copilotQueue[index] : copilotQueue.last
            newModel.copilot.selection = next.map { .init(url: $0.url, isRaid: nil) }
        }
    }

    private var canAddSelectedCopilotToQueue: Bool {
        guard battleMode == .queue,
            let url = newModel.copilot.selection?.url,
            !copilotQueue.contains(where: { $0.url == url }),
            let copilot = MAACopilot(url: url)
        else { return false }
        return copilot.type != "SSS"
    }

    private var canStart: Bool {
        switch battleMode {
        case .single:
            newModel.copilot.isReady
        case .queue:
            !copilotQueue.isEmpty
        case .mainStory, .resources:
            true
        }
    }
}

// MARK: - Toolbar

private struct CopilotListToolbar: ToolbarContent {
    @Environment(NewViewModel.self) private var newModel
    @Binding var externalRoot: CopilotContent.Item
    let isAutomaticRunning: Bool
    let canStart: Bool
    let startAction: () -> Void
    let stopAction: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Button(action: deleteSelectedCopilot) {
                Label("移除", systemImage: "trash")
            }
            .help("移除作业")
            .disabled(!canDeleteCopilot)
            .keyboardShortcut(.delete, modifiers: [.command])
        }

        ToolbarItemGroup {
            switch (newModel.status, isAutomaticRunning) {
            case (.pending, false):
                Button(action: {}) {
                    ProgressView().controlSize(.small)
                }
                .disabled(true)
            case (.pending, true), (.busy, _), (.idle, true):
                Button(action: stopAction) {
                    Label("停止", systemImage: "stop.fill")
                }
                .help("停止")
            case (.idle, false):
                Button(action: startAction) {
                    Label("开始", systemImage: "play.fill")
                }
                .help("开始")
                .disabled(!canStart)
            }
        }
    }

    private var canDeleteCopilot: Bool {
        if newModel.copilot.category == .list { return false }
        return newModel.copilot.selection?.url.isManagedCopilot ?? false
    }

    private func deleteSelectedCopilot() {
        guard let selection = newModel.copilot.selection?.url else { return }
        let nextSelection = externalRoot.possibleSibling(of: selection)

        Task.detached {
            await deleteCopilot(url: selection)
            let children = try? await externalRoot.children()
            await MainActor.run {
                externalRoot.children = children ?? []
                newModel.copilot.selection = nextSelection.map { .init(url: $0.url, isRaid: nil) }
            }
        }
    }

    @concurrent private func deleteCopilot(url: URL) async {
        guard url.isManagedCopilot else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

extension CopilotCategory: Identifiable {
    var id: String { rawValue }

    var title: String {
        switch self {
        case .bundled: String(localized: "内置")
        case .external: String(localized: "外部")
        case .list: String(localized: "列表")
        }
    }

    var systemImage: String {
        switch self {
        case .bundled: "house"
        case .external: "doc"
        case .list: "doc.on.doc"
        }
    }

    var color: Color {
        switch self {
        case .bundled: .copilotBlue
        case .external: .copilotGreen
        case .list: .copilotIndigo
        }
    }
}

struct CopilotContent_Previews: PreviewProvider {
    static var previews: some View {
        let viewModel = MAAViewModel()
        return VStack {
            CopilotContent()
        }
        .frame(maxWidth: 300)
        .environmentObject(viewModel)
        .environment(NewViewModel(parent: viewModel))
    }
}

// MARK: - File Paths

extension URL {
    static let bundledCopilotDirectory = Bundle.main.resourceURL!
        .appending(path: "resource/")
        .appending(path: "copilot/")

    static let externalCopilotDirectory = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)
        .first!
        .appending(path: "copilot/")
}

extension URL {
    fileprivate var isManagedCopilot: Bool {
        path.starts(with: URL.externalCopilotDirectory.path)
    }
}

extension CopilotContext {
    var isReady: Bool {
        if category == .list {
            return copilotSet != nil && !copilotList.isEmpty
        }
        if case .copilot = content { return true }
        return false
    }
}

extension CopilotContent.Item {
    func possibleSibling(of url: URL) -> Self? {
        if self.url == url { return nil }
        var searchStack = [self]

        while !searchStack.isEmpty {
            let current = searchStack.removeLast()
            if let children = current.children {
                for index in children.indices {
                    let item = children[index]
                    if item.url == url {
                        let nextIndex = children.index(after: index)
                        if nextIndex != children.endIndex { return children[nextIndex] }
                        if index != children.startIndex { return children[children.index(before: index)] }
                        return nil
                    }
                    if item.children != nil { searchStack.append(item) }
                }
            }
        }
        return nil
    }
}

extension FileManager {
    func copyCopilotToExternalDirectory(at url: URL) throws -> URL {
        let dest = try externalCopilotURL(for: url)
        try FileManager.default.copyItemOverwriting(at: url, to: dest)
        return dest
    }

    func moveCopilotToExternalDirectory(at url: URL) throws -> URL {
        let dest = try externalCopilotURL(for: url)
        try FileManager.default.moveItemOverwriting(at: url, to: dest)
        return dest
    }

    private func externalCopilotURL(for url: URL) throws -> URL {
        try createDirectory(at: .externalCopilotDirectory, withIntermediateDirectories: true)
        return URL.externalCopilotDirectory.appending(path: url.lastPathComponent)
    }
}
