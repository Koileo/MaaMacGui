//
//  CopilotsView.swift
//  MAA
//
//  Created by hguandl on 17/4/2023.
//

import SwiftUI

struct CopilotContent: View {
    @EnvironmentObject private var viewModel: MAAViewModel
    @Binding var selection: URL?

    @State private var copilots = Set<URL>()
    @State private var copilotQueue = [URL]()
    @State private var useCopilotQueue = false
    @State private var downloading = false
    @State private var expanded = false

    var body: some View {
        List(selection: $selection) {
            Section {
                Toggle("连续作战", isOn: $useCopilotQueue)
            }

            if useCopilotQueue {
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
        .onAppear(perform: loadUserCopilots)
        .onDrop(of: [.fileURL], isTargeted: .none, perform: addCopilots)
        .onReceive(viewModel.$copilotDetailMode, perform: deselectCopilot)
        .onReceive(viewModel.$downloadCopilot, perform: downloadCopilot)
        .onReceive(viewModel.$videoRecoginition, perform: selectNewCopilot)
        .fileImporter(
            isPresented: $viewModel.showImportCopilot,
            allowedContentTypes: [.json],
            allowsMultipleSelection: true,
            onCompletion: addCopilots)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private func listToolbar() -> some ToolbarContent {
        ToolbarItemGroup {
            if useCopilotQueue {
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
            switch viewModel.status {
            case .pending:
                Button(action: {}) {
                    ProgressView().controlSize(.small)
                }
                .disabled(true)
            case .busy:
                Button(action: stop) {
                    Label("停止", systemImage: "stop.fill")
                }
                .help("停止")
            case .idle:
                Button(action: start) {
                    Label("开始", systemImage: "play.fill")
                }
                .help("开始")
                .disabled(useCopilotQueue && copilotQueue.isEmpty)
            }
        }
    }

    // MARK: - Actions

    private func stop() {
        Task {
            try await viewModel.stop()
        }
    }

    private func start() {
        Task {
            do {
                if useCopilotQueue {
                    let items = copilotQueue.compactMap { url -> RegularCopilotConfiguration.CopilotItem? in
                        guard let copilot = MAACopilot(url: url), copilot.type != "SSS" else { return nil }
                        return .init(filename: url.path, stage_name: copilot.navigationStageName, is_raid: false)
                    }

                    guard items.count == copilotQueue.count else { return }

                    var configuration = viewModel.regularCopilotConfiguration()
                    configuration.copilot_list = items
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
