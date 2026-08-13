//
//  CopilotsView.swift
//  MAA
//
//  Created by hguandl on 17/4/2023.
//

import SwiftUI
import Security

struct CopilotContent: View {
    private enum BattleMode: String, CaseIterable, Identifiable {
        case single = "普通战斗"
        case queue = "连续作战"
        case mainStory = "全主线推进"

        var id: Self { self }
    }

    @EnvironmentObject private var viewModel: MAAViewModel
    @Binding var selection: URL?

    @State private var copilots = Set<URL>()
    @State private var copilotQueue = [URL]()
    @State private var battleMode = BattleMode.single
    @State private var useAutomaticFallbacks = false
    @State private var showOperatorSettings = false
    @State private var operatorToken = ""
    @State private var ownedOperatorNames = Set<String>()
    @State private var operatorMatchingEnabled = false
    @State private var operatorSyncError: String?
    @State private var downloading = false
    @State private var expanded = false
    @AppStorage("MAAMainStoryStart") private var mainStoryStart = "main_05-01"
    @AppStorage("MAAMainStoryEnd") private var mainStoryEnd = MainStoryStage.all.last?.id ?? ""
    @State private var mainStoryProgress = ""
    @State private var mainStoryTask: Task<Void, Never>?
    @AppStorage("MAAMainStoryBarkEndpoint") private var barkEndpoint = ""

    var body: some View {
        List(selection: $selection) {
            Section {
                Picker("作战模式", selection: $battleMode) {
                    ForEach(BattleMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if battleMode == .mainStory {
                    Picker("起始关卡", selection: $mainStoryStart) {
                        ForEach(MainStoryStage.all) { stage in
                            Text(stage.code).tag(stage.id)
                        }
                    }
                    Picker("结束关卡", selection: $mainStoryEnd) {
                        ForEach(MainStoryStage.all) { stage in
                            Text(stage.code).tag(stage.id)
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

                if battleMode != .single {
                    Toggle("从 PRTS.plus 自动搜索备用作业", isOn: $useAutomaticFallbacks)
                        .help("按热度下载同关卡作业；当前作业失败或漏怪时自动切换。")
                    if useAutomaticFallbacks || battleMode == .mainStory {
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

            if battleMode == .queue {
                Section("战斗列表（从关卡地图开始）") {
                    if copilotQueue.isEmpty {
                        Text("请从下方选择作业并点按添加")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(Array(copilotQueue.enumerated()), id: \.element) { index, url in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(MAACopilot(url: url)?.navigationStageName ?? url.lastPathComponent)
                                Text(url.lastPathComponent)
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
                                copilotQueue.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("从战斗列表移除")
                        }
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
        .toolbar(content: listToolbar)
        .animation(.default, value: copilots)
        .animation(.default, value: downloading)
        .onAppear {
            loadUserCopilots()
            ownedOperatorNames = OperatorRosterStore.names
            operatorMatchingEnabled = OperatorRosterStore.matchingEnabled
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
        if battleMode == .mainStory {
            mainStoryTask?.cancel()
            mainStoryTask = Task { await runMainStory() }
            return
        }

        Task {
            do {
                if battleMode == .queue {
                    let urls = useAutomaticFallbacks
                        ? try await automaticFallbacks(for: copilotQueue)
                        : copilotQueue
                    let items = urls.compactMap { url -> RegularCopilotConfiguration.CopilotItem? in
                        guard let copilot = MAACopilot(url: url), copilot.type != "SSS" else { return nil }
                        return .init(filename: url.path, stage_name: copilot.navigationStageName, is_raid: false)
                    }

                    guard items.count == urls.count else { return }

                    var configuration = viewModel.regularCopilotConfiguration()
                    configuration.copilot_list = items
                    configuration.switch_copilot_on_failure = useAutomaticFallbacks
                    viewModel.copilot = .regular(configuration)
                } else if let selection, MAACopilot(url: selection)?.type != "SSS" {
                    viewModel.copilot = .regular(viewModel.regularCopilotConfiguration(filename: selection.path))
                }

                viewModel.copilotDetailMode = .log
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

            let stages = Array(MainStoryStage.all[start...end])
            let names = operatorMatchingEnabled ? ownedOperatorNames : []
            for (index, stage) in stages.enumerated() {
                try Task.checkCancellation()
                mainStoryProgress = "正在获取作业：\(stage.code)（\(index + 1)/\(stages.count)）"
                let urls = try await PRTSPlusClient.candidates(
                    for: stage.id,
                    ownedOperatorNames: names,
                    limit: useAutomaticFallbacks ? 2 : 1)
                guard !urls.isEmpty else { throw PRTSPlusError.noCopilot(stage.code) }

                var configuration = viewModel.regularCopilotConfiguration()
                configuration.copilot_list = urls.map {
                    .init(filename: $0.path, stage_name: stage.code, is_raid: false)
                }
                configuration.switch_copilot_on_failure = true
                viewModel.copilot = .regular(configuration)
                viewModel.copilotDetailMode = .log
                mainStoryProgress = "正在作战：\(stage.code)（\(index + 1)/\(stages.count)）"
                try await viewModel.startCopilot()

                for await status in viewModel.$status.values where status == .idle {
                    try Task.checkCancellation()
                    break
                }
                guard viewModel.lastCopilotRunSucceeded == true else {
                    throw PRTSPlusError.api("关卡 \(stage.code) 自动战斗失败")
                }
            }

            mainStoryProgress = "已完成 \(stages.count) 个主线关卡"
            mainStoryTask = nil
        } catch {
            if Task.isCancelled {
                mainStoryProgress = "主线推进已停止"
                mainStoryTask = nil
                return
            }
            mainStoryProgress = "主线推进已停止：\(error.localizedDescription)"
            await notifyMainStoryFailure(error)
            viewModel.logError("主线推进失败：\(error.localizedDescription)")
            viewModel.resetStatus()
            mainStoryTask = nil
        }
    }

    @MainActor private func notifyMainStoryFailure(_ failure: Error) async {
        guard !barkEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try await BarkClient.notify(
                endpoint: barkEndpoint,
                title: "MAA 主线推进需要处理",
                body: failure.localizedDescription)
        } catch {
            viewModel.logError("Bark 通知发送失败：\(error.localizedDescription)")
        }
    }

    @ViewBuilder private func operatorSettings() -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("干员匹配设置").font(.headline)
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
            TextField("Bark 推送地址（https://api.day.app/设备码）", text: $barkEndpoint)
                .textFieldStyle(.roundedBorder)
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
        }
        .onChange(of: operatorMatchingEnabled) { value in
            OperatorRosterStore.matchingEnabled = value
        }
    }

    private var operatorSettingsLabel: String {
        ownedOperatorNames.isEmpty ? "干员匹配设置" : "干员匹配（\(ownedOperatorNames.count)）"
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

    private func automaticFallbacks(for seeds: [URL]) async throws -> [URL] {
        var result = [URL]()
        for seed in seeds {
            guard let copilot = MAACopilot(url: seed), copilot.type != "SSS" else { continue }
            result.append(seed)
            let fallbacks = try await PRTSPlusClient.fallbacks(
                for: copilot,
                excluding: Set(result.compactMap { Int($0.deletingPathExtension().lastPathComponent) }),
                ownedOperatorNames: operatorMatchingEnabled ? ownedOperatorNames : [])
            result.append(contentsOf: fallbacks)
        }
        return result
    }

    private func addSelectedCopilotToQueue() {
        guard let selection, canAddSelectedCopilotToQueue else { return }
        copilotQueue.append(selection)
    }

    private func moveQueuedCopilot(at index: Int, offset: Int) {
        let destination = index + offset
        guard copilotQueue.indices.contains(index), copilotQueue.indices.contains(destination) else { return }
        copilotQueue.swapAt(index, destination)
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
        guard canDelete(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func deleteSelectedCopilot() {
        guard let selection, let index = copilots.urls.firstIndex(of: selection) else { return }

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
        selection == nil || isBundled(selection)
    }

    private var canAddSelectedCopilotToQueue: Bool {
        guard let selection,
            battleMode == .queue,
            !copilotQueue.contains(selection),
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
