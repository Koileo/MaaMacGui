//
//  CopilotsView.swift
//  MAA
//
//  Created by hguandl on 17/4/2023.
//

import SwiftUI
import Security

struct CopilotContent: View {
    private struct QueuedCopilot: Identifiable, Equatable {
        let id: UUID
        let url: URL
        let stageName: String
        let filename: String

        init(url: URL, id: UUID = UUID()) {
            self.id = id
            self.url = url
            self.filename = url.lastPathComponent
            if let copilot = MAACopilot(url: url) {
                self.stageName = copilot.navigationStageName
            } else {
                self.stageName = url.lastPathComponent
            }
        }
    }

    private enum BattleMode: String, CaseIterable, Identifiable {
        case single = "普通战斗"
        case queue = "连续作战"
        case mainStory = "全主线推进"
        case resources = "资源获取"

        var id: Self { self }
    }

    @EnvironmentObject private var viewModel: MAAViewModel
    @Binding var selection: URL?

    @State private var copilots = Set<URL>()
    @State private var copilotQueue = [QueuedCopilot]()
    @State private var battleMode = BattleMode.single
    @State private var useAutomaticFallbacks = false
    @State private var showOperatorSettings = false
    @State private var operatorToken = ""
    @State private var ownedOperatorNames = Set<String>()
    @State private var operatorMatchingEnabled = false
    @State private var operatorSyncError: String?
    @State private var failedCopilotCount = 0
    @State private var downloading = false
    @State private var copilotSetCode = ""
    @State private var copilotSetStatus: String?
    @State private var importingCopilotSet = false
    @State private var barkTestStatus: String?
    @State private var testingBark = false
    @State private var expanded = false
    @AppStorage("MAAMainStoryStart") private var mainStoryStart = "main_05-01"
    @AppStorage("MAAMainStoryEnd") private var mainStoryEnd = MainStoryStage.all.last?.id ?? ""
    @AppStorage("MAAResourceStageLine") private var resourceStageLine = ResourceStageLine.all.first?.id ?? "CE"
    @AppStorage("MAAResourceStageStart") private var resourceStageStart = "CE-1"
    @AppStorage("MAAResourceStageEnd") private var resourceStageEnd = "CE-6"
    @AppStorage("MAAAutomaticStageBattleCount") private var automaticStageBattleCount = 1
    @State private var mainStoryProgress = ""
    @State private var mainStoryTask: Task<Void, Never>?
    @AppStorage("MAAMainStoryBarkEndpoint") private var barkEndpoint = ""

    var body: some View {
        VStack(spacing: 0) {
            battleModeControls
            Divider()

            List(selection: $selection) {

            if battleMode == .queue {
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
                        .tag(item.url)
                    }
                }
            }

                DisclosureGroup(isExpanded: $expanded) {
                    ForEach(bundledCopilots, id: \.self) { url in
                        Text(url.lastPathComponent)
                    }
                } label: {
                    Text("内置作业")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation {
                                expanded.toggle()
                            }
                        }
                }

                Section {
                    ForEach(copilots.urls, id: \.self) { url in
                        Text(url.lastPathComponent)
                    }
                } header: {
                    HStack {
                        Text("外部作业（可拖入文件）")
                        if downloading {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            }
        }
        .toolbar(content: listToolbar)
        .animation(.default, value: copilots)
        .animation(.default, value: downloading)
        .onAppear {
            loadUserCopilots()
            ownedOperatorNames = OperatorRosterStore.names
            operatorMatchingEnabled = OperatorRosterStore.matchingEnabled
            failedCopilotCount = FailedCopilotStore.ids.count
        }
        .onDrop(of: [.fileURL], isTargeted: .none, perform: addCopilots)
        .onReceive(viewModel.$copilotDetailMode, perform: deselectCopilot)
        .onReceive(viewModel.$downloadCopilot, perform: downloadCopilot)
        .onReceive(viewModel.$videoRecoginition, perform: selectNewCopilot)
        .fileImporter(
            isPresented: $viewModel.showImportCopilot,
            allowedContentTypes: [.json],
            allowsMultipleSelection: true,
            onCompletion: addCopilots)
        .sheet(isPresented: $showOperatorSettings, content: operatorSettings)
    }

    @ViewBuilder private var battleModeControls: some View {
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
                if !mainStoryProgress.isEmpty {
                    Text(mainStoryProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if battleMode == .resources {
                Picker("资源类别", selection: $resourceStageLine) {
                    ForEach(ResourceStageLine.all) { line in
                        Text(line.name).tag(line.id)
                    }
                }
                .onChange(of: resourceStageLine) { _ in resetResourceStageRange() }

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
                if !mainStoryProgress.isEmpty {
                    Text(mainStoryProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if battleMode == .mainStory || battleMode == .resources {
                Stepper(value: $automaticStageBattleCount, in: 1...99) {
                    Text("每关战斗次数：\(automaticStageBattleCount)")
                }
                .help("当前关卡成功完成指定次数后，再进入下一关。")
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
                if useAutomaticFallbacks || battleMode == .mainStory || battleMode == .resources {
                    Button {
                        operatorToken = OperatorRosterStore.token ?? ""
                        showOperatorSettings = true
                    } label: {
                        Label(operatorSettingsLabel, systemImage: "person.2")
                    }
                    .buttonStyle(.plain)
                }
                Toggle(
                    "漏怪时退出并重试",
                    isOn: Binding(
                        get: { viewModel.copilotDefaults.retry_on_leak ?? false },
                        set: { viewModel.copilotDefaults.retry_on_leak = $0 }
                    )
                )
                .help("检测到目标生命降低时退出当前作战，并重试一次。允许战术漏怪的作业请勿启用。")
            }
        }
        .padding(12)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private func listToolbar() -> some ToolbarContent {
        ToolbarItemGroup {
            if battleMode == .queue {
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

            Button(action: deleteSelectedCopilot) {
                Label("移除", systemImage: "trash")
            }
            .help("移除作业")
            .disabled(shouldDisableDeletion)
            .keyboardShortcut(.delete, modifiers: [.command])
        }

        ToolbarItemGroup {
            switch (viewModel.status, mainStoryTask != nil) {
            case (.pending, false):
                Button(action: {}) {
                    ProgressView().controlSize(.small)
                }
                .disabled(true)
            case (.pending, true), (.busy, _), (.idle, true):
                Button(action: stop) {
                    Label("停止", systemImage: "stop.fill")
                }
                .help("停止")
            case (.idle, false):
                Button(action: start) {
                    Label("开始", systemImage: "play.fill")
                }
                .help("开始")
                .disabled(battleMode == .queue && copilotQueue.isEmpty)
            }
        }
    }

    // MARK: - Actions

    private func stop() {
        mainStoryTask?.cancel()
        guard viewModel.status != .idle else { return }
        Task {
            try await viewModel.stop()
        }
    }

    private func start() {
        viewModel.markPending()
        viewModel.copilotDetailMode = .log

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
                    if useAutomaticFallbacks {
                        viewModel.logInfo("正在从 PRTS.plus 检索候选备用作业...")
                    }
                    let queueUrls = copilotQueue.map(\.url)
                    let urls = useAutomaticFallbacks
                        ? try await automaticFallbacks(for: queueUrls)
                        : queueUrls
                    let items = urls.compactMap { url -> RegularCopilotConfiguration.CopilotItem? in
                        guard let copilot = MAACopilot(url: url), copilot.type != "SSS" else { return nil }
                        return .init(filename: url.path, stage_name: copilot.navigationStageName, is_raid: false)
                    }

                    guard items.count == urls.count else {
                        viewModel.logError("队列中存在无法读取或格式不支持的作业")
                        viewModel.resetStatus()
                        return
                    }

                    var configuration = viewModel.regularCopilotConfiguration()
                    configuration.copilot_list = items
                    configuration.switch_copilot_on_failure = useAutomaticFallbacks
                    viewModel.copilot = .regular(configuration)
                } else if let selection, MAACopilot(url: selection)?.type != "SSS" {
                    viewModel.copilot = .regular(viewModel.regularCopilotConfiguration(filename: selection.path))
                }

                try await viewModel.startCopilot()
            } catch {
                viewModel.logError("启动自动战斗失败：\(error.localizedDescription)")
                viewModel.resetStatus()
            }
        }
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
            mainStoryProgress =
                "已完成 \(line.name)资源线（\(stages.count) 关，共 \(stages.count * battleCount) 次战斗）"
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
                if operatorMatchingEnabled && viewModel.copilotDefaults.ignore_requirements {
                    urls = (try? await PRTSPlusClient.candidates(
                        for: stage.id,
                        excluding: FailedCopilotStore.ids,
                        ownedOperatorNames: [],
                        limit: 5)) ?? []
                    if !urls.isEmpty {
                        viewModel.logWarn("关卡 \(stage.code) 本地干员匹配未完全满足，已按「忽视干员属性要求」降级使用候选作业")
                    }
                }
                if urls.isEmpty {
                    throw error
                }
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
                var configuration = viewModel.regularCopilotConfiguration()
                configuration.copilot_list = [
                    .init(filename: url.path, stage_name: stage.code, is_raid: false)
                ]
                configuration.switch_copilot_on_failure = true
                viewModel.copilot = .regular(configuration)
                viewModel.copilotDetailMode = .log
                mainStoryProgress =
                    "正在作战：\(stage.code)（第 \(completedBattles + 1)/\(battleCount) 次，作业 \(candidateIndex + 1)/\(urls.count)）"
                try await viewModel.startCopilot()

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
        VStack(alignment: .leading, spacing: 16) {
            Text("配队与干员匹配").font(.headline)
            Toggle("自动编队", isOn: $viewModel.copilotDefaults.formation)
            if viewModel.copilotDefaults.formation {
                HStack {
                    Picker("编队栏位", selection: $viewModel.copilotDefaults.formation_index) {
                        Text("当前").tag(0)
                        ForEach(0..<RegularCopilotConfiguration.formationCount, id: \.self) { index in
                            Text("\(index + 1)").tag(index + 1)
                        }
                    }
                    .pickerStyle(.menu)
                    Toggle("忽视干员属性要求", isOn: $viewModel.copilotDefaults.ignore_requirements)
                }

                Toggle("补充低信赖干员", isOn: $viewModel.copilotDefaults.add_trust)

                HStack {
                    Picker("助战模式", selection: $viewModel.copilotDefaults.support_unit_usage) {
                        ForEach(RegularCopilotConfiguration.SupportUnitUsage.allCases, id: \.self) { mode in
                            Text(mode.description).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)

                    if viewModel.copilotDefaults.support_unit_usage == .specific {
                        TextField("助战干员名称", text: $viewModel.copilotDefaults.support_unit_name)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("指定信赖干员")
                        Spacer()
                        Button {
                            viewModel.copilotDefaults.user_additional.append(.init(name: "", skill: 1))
                        } label: {
                            Label("添加", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("添加指定干员")
                    }

                    ForEach(viewModel.copilotDefaults.user_additional.indices, id: \.self) { index in
                        HStack {
                            TextField(
                                "干员名称",
                                text: $viewModel.copilotDefaults.user_additional[index].name
                            )
                            .textFieldStyle(.roundedBorder)
                            Picker("技能", selection: $viewModel.copilotDefaults.user_additional[index].skill) {
                                Text("技能 1").tag(1)
                                Text("技能 2").tag(2)
                                Text("技能 3").tag(3)
                            }
                            .frame(width: 100)
                            Button {
                                viewModel.copilotDefaults.user_additional.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("移除指定干员")
                        }
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
        .onAppear {
            ownedOperatorNames = OperatorRosterStore.names
            operatorMatchingEnabled = OperatorRosterStore.matchingEnabled
            failedCopilotCount = FailedCopilotStore.ids.count
        }
        .onChange(of: operatorMatchingEnabled) { value in
            OperatorRosterStore.matchingEnabled = value
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
                    let fallbacks = (try? await PRTSPlusClient.fallbacks(
                        for: copilot,
                        excluding: excluding,
                        ownedOperatorNames: names)) ?? []
                    return (index, seed, fallbacks)
                }
            }

            var indexedResults: [(Int, [URL])] = []
            for try await (index, seed, fallbacks) in group {
                var list = [seed]
                list.append(contentsOf: fallbacks)
                indexedResults.append((index, list))
            }
            indexedResults.sort { $0.0 < $1.0 }
            return indexedResults.flatMap(\.1)
        }
    }

    private func addSelectedCopilotToQueue() {
        guard let selection, canAddSelectedCopilotToQueue else { return }
        copilotQueue.append(QueuedCopilot(url: selection))
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
                copilots.formUnion(regular)
                copilotQueue.append(contentsOf: regular.map { QueuedCopilot(url: $0) })
                copilotSetCode = ""
                let skipped = downloaded.count - regular.count
                copilotSetStatus = skipped == 0
                    ? "已按原顺序导入 \(regular.count) 份作业"
                    : "已导入 \(regular.count) 份普通作业，跳过 \(skipped) 份保全作业"
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
        if selection == removed.url {
            if copilotQueue.indices.contains(index) {
                selection = copilotQueue[index].url
            } else {
                selection = copilotQueue.last?.url
            }
        }
    }

    private func loadUserCopilots() {
        copilots.formUnion(externalDirectory.copilots)
        copilots.formUnion(recordingDirectory.copilots)
    }

    private func addCopilots(_ providers: [NSItemProvider]) -> Bool {
        Task {
            for provider in providers {
                if let url = try? await provider.loadURL() {
                    let value = try? url.resourceValues(forKeys: [.contentTypeKey])
                    if value?.contentType == .json {
                        copilots.insert(url)
                    } else if value?.contentType?.conforms(to: .movie) == true {
                        try? await viewModel.recognizeVideo(video: url)
                    }
                }
            }
            self.selection = self.copilots.urls.last
        }

        return true
    }

    private func addCopilots(_ results: Result<[URL], Error>) {
        if case let .success(urls) = results {
            copilots.formUnion(urls)
            selection = copilots.urls.last
        }
    }

    private func downloadCopilot(id: String?) {
        guard let id else { return }

        let file =
            externalDirectory
            .appendingPathComponent(id)
            .appendingPathExtension("json")

        let url = URL(string: "https://prts.maa.plus/copilot/get/\(id)")!
        Task {
            self.downloading = true
            do {
                let data = try await URLSession.shared.data(from: url).0
                let response = try JSONDecoder().decode(CopilotResponse.self, from: data)
                try response.data.content.write(toFile: file.path, atomically: true, encoding: .utf8)
                copilots.insert(file)
                self.selection = file
            } catch {
                print(error)
            }
            self.downloading = false
        }
    }

    private func deleteCopilot(url: URL) {
        copilots.remove(url)
        copilotQueue.removeAll { $0.url == url }
        guard canDelete(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func deleteSelectedCopilot() {
        guard let selection else { return }

        if battleMode == .queue, let queueIndex = copilotQueue.firstIndex(where: { $0.url == selection }) {
            removeQueuedCopilot(at: queueIndex)
            return
        }

        guard let index = copilots.urls.firstIndex(of: selection) else { return }

        deleteCopilot(url: selection)

        let urls = copilots.urls
        if index < urls.count {
            self.selection = urls[index]
        } else {
            self.selection = urls.last
        }
    }

    private func deselectCopilot(_ viewMode: MAAViewModel.CopilotDetailMode) {
        if viewMode != .copilotConfig {
            selection = nil
        }
    }

    private func selectNewCopilot(url: URL?) {
        if let url {
            copilots.insert(url)
            selection = copilots.urls.last
        }
    }

    // MARK: - State Wrappers

    private var shouldDisableDeletion: Bool {
        if battleMode == .queue, let selection, copilotQueue.contains(where: { $0.url == selection }) {
            return false
        }
        return selection == nil || isBundled(selection)
    }

    private var canAddSelectedCopilotToQueue: Bool {
        guard let selection,
            battleMode == .queue,
            !copilotQueue.contains(where: { $0.url == selection }),
            let copilot = MAACopilot(url: selection)
        else { return false }

        return copilot.type != "SSS"
    }

    private func isBundled(_ url: URL?) -> Bool {
        return url?.path.starts(with: bundledDirectory.path) ?? false
    }

    private func canDelete(_ url: URL?) -> Bool {
        [externalDirectory, recordingDirectory]
            .compactMap { url?.path.starts(with: $0.path) }
            .first(where: { $0 })
            ?? false
    }

    // MARK: - File Paths

    private var bundledCopilots: [URL] { bundledDirectory.copilots }

    private var bundledDirectory: URL {
        Bundle.main.resourceURL!
            .appendingPathComponent("resource")
            .appendingPathComponent("copilot")
    }

    private var externalDirectory: URL {
        let directory = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("copilot")

        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }

        return directory
    }

    private var recordingDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("cache")
            .appendingPathComponent("CombatRecord")
    }
}

struct CopilotContent_Previews: PreviewProvider {
    static var previews: some View {
        CopilotContent(selection: .constant(nil))
            .environmentObject(MAAViewModel())
    }
}

// MARK: - Value Extensions

extension URL {
    fileprivate var copilots: [URL] {
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: self,
                includingPropertiesForKeys: [.contentTypeKey],
                options: .skipsHiddenFiles)
        else { return [] }

        return urls.filter { url in
            let value = try? url.resourceValues(forKeys: [.contentTypeKey])
            return value?.contentType == .json
        }
        .sorted { lhs, rhs in
            lhs.lastPathComponent < rhs.lastPathComponent
        }
    }
}

extension Set where Element == URL {
    fileprivate var urls: [URL] { sorted { $0.lastPathComponent < $1.lastPathComponent } }
}

// MARK: - Download Model

private struct CopilotResponse: Codable {
    let data: CopilotData

    struct CopilotData: Codable {
        let content: String
    }
}

// MARK: - Convenience Methods

extension NSItemProvider {
    @MainActor fileprivate func loadURL() async throws -> URL {
        let handle = ProgressActor()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let progress = loadObject(ofClass: URL.self) { object, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let object else {
                        continuation.resume(throwing: MAAError.emptyItemObject)
                        return
                    }

                    continuation.resume(returning: object)
                }

                Task {
                    await handle.bind(progress: progress)
                }
            }
        } onCancel: {
            Task {
                await handle.cancel()
            }
        }
    }
}

private actor ProgressActor {
    private var progress: Progress?
    private var cancelled = false

    func bind(progress: Progress) {
        guard !cancelled else { return }
        self.progress = progress
        progress.resume()
    }

    func cancel() {
        cancelled = true
        progress?.cancel()
    }
}
