//
//  MAACopilot.swift
//  MAA
//
//  Created by hguandl on 17/4/2023.
//

import Foundation

struct MAACopilot: Codable, Equatable {
    let stage_name: String
    let opers: [Operator]
    let groups: [Group]?
    let minimum_required: String
    let doc: Documentation?

    // MARK: SSS

    let type: String?
    let equipment: [String]?
    let strategy: String?
    let tool_men: [String: Int]?

    struct Operator: Codable, Equatable {
        let name: String
        let skill: Int?
    }

    struct Group: Codable, Equatable {
        let name: String
        let opers: [Operator]
    }

    struct Documentation: Codable, Equatable {
        let title: String?
        let title_color: String?
        let details: String?
        let details_color: String?
    }
}

extension MAACopilot.Operator: CustomStringConvertible {
    var description: String {
        if let skill {
            return "\(name) \(skill)"
        } else {
            return name
        }
    }
}

extension MAACopilot {
    var navigationStageName: String {
        Self.navigationStageName(for: stage_name)
    }

    static func navigationStageName(for stageName: String) -> String {
        if let code = stageCodes[stageName] {
            return code
        }

        // Easy-mode main story stages share their visible code with the
        // corresponding main stage, including chapters with story-only gaps.
        if stageName.hasPrefix("easy_") {
            let mainStageName = "main_" + stageName.dropFirst("easy_".count)
            if let code = stageCodes[mainStageName] {
                return code
            }
        }

        return fallbackNavigationStageName(for: stageName)
    }

    init?(url: URL) {
        do {
            let data = try Data(contentsOf: url)
            self = try JSONDecoder().decode(MAACopilot.self, from: data)
        } catch {
            return nil
        }
    }

    struct StageCode: Decodable {
        let code: String
        let stageId: String
    }

    static let stageCodes: [String: String] = {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("resource/stages.json"),
            let data = try? Data(contentsOf: url),
            let stages = try? JSONDecoder().decode([StageCode].self, from: data)
        else { return [:] }

        return Dictionary(stages.map { ($0.stageId, $0.code) }, uniquingKeysWith: { first, _ in first })
    }()

    static let stageIdByCode: [String: String] = {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("resource/stages.json"),
            let data = try? Data(contentsOf: url),
            let stages = try? JSONDecoder().decode([StageCode].self, from: data)
        else { return [:] }

        return Dictionary(stages.map { ($0.code, $0.stageId) }, uniquingKeysWith: { first, _ in first })
    }()

    private static func fallbackNavigationStageName(for stageName: String) -> String {
        guard stageName.hasPrefix("main_") else { return stageName }

        let value = String(stageName.dropFirst("main_".count))
        let parts = value.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2, let chapter = Int(parts[0]) else { return stageName }
        return "\(chapter)-\(parts[1])"
    }
}

struct MainStoryStage: Codable, Hashable, Identifiable {
    let apCost: Int
    let code: String
    let stageId: String

    var id: String { stageId }

    static let all: [Self] = {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("resource/stages.json"),
            let data = try? Data(contentsOf: url),
            let stages = try? JSONDecoder().decode([Self].self, from: data)
        else { return [] }

        return stages
            .filter {
                $0.apCost > 0
                    && ($0.stageId.range(of: #"^main_[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil
                        || $0.code.range(of: #"^S[0-9]+-[0-9]+$"#, options: .regularExpression) != nil)
            }
            .sorted { sortKey($0.code).lexicographicallyPrecedes(sortKey($1.code)) }
    }()

    private static func sortKey(_ code: String) -> [Int] {
        if code.hasPrefix("R8-") {
            let num = Int(code.dropFirst("R8-".count)) ?? Int.max
            return [8, 0, 0, num]
        }
        if code.hasPrefix("M8-") {
            let num = Int(code.dropFirst("M8-".count)) ?? Int.max
            return [8, 0, 1, num]
        }
        if code.hasPrefix("JT8-") {
            let num = Int(code.dropFirst("JT8-".count)) ?? Int.max
            return [8, 0, 2, num]
        }

        let isSideStage = code.hasPrefix("S")
        let numbers = code.trimmingCharacters(in: CharacterSet.letters)
            .split(separator: "-")
            .compactMap { Int($0) }
        let chapter = numbers.first ?? Int.max
        let stage = numbers.dropFirst().first ?? Int.max
        guard isSideStage else { return [chapter, 0, stage, 0] }

        let chapterSixInsertionPoints = [1: 10, 2: 10, 3: 15, 4: 15]
        let insertionPoint = chapter == 6 ? chapterSixInsertionPoints[stage] : nil
        return [chapter, 1, insertionPoint ?? Int.max, stage]
    }
}

struct ResourceStageLine: Identifiable, Hashable {
    struct Stage: Codable, Hashable, Identifiable {
        let code: String
        let stageId: String

        var id: String { stageId }
    }

    let id: String
    let name: String
    let stageCodes: [String]

    var stages: [Stage] {
        stageCodes.compactMap { Self.stageByCode[$0] }
    }

    static let all: [Self] = [
        .init(id: "CE", name: "龙门币", stageCodes: (1...6).map { "CE-\($0)" }),
        .init(id: "LS", name: "作战记录", stageCodes: (1...6).map { "LS-\($0)" }),
        .init(id: "AP", name: "采购凭证", stageCodes: (1...5).map { "AP-\($0)" }),
        .init(id: "CA", name: "技能概要", stageCodes: (1...5).map { "CA-\($0)" }),
        .init(id: "SK", name: "碳素材", stageCodes: (1...5).map { "SK-\($0)" }),
        .init(id: "PR-A", name: "医疗 / 重装芯片", stageCodes: (1...2).map { "PR-A-\($0)" }),
        .init(id: "PR-B", name: "术师 / 狙击芯片", stageCodes: (1...2).map { "PR-B-\($0)" }),
        .init(id: "PR-C", name: "先锋 / 辅助芯片", stageCodes: (1...2).map { "PR-C-\($0)" }),
        .init(id: "PR-D", name: "近卫 / 特种芯片", stageCodes: (1...2).map { "PR-D-\($0)" }),
    ]

    private static let stageByCode: [String: Stage] = {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("resource/stages.json"),
            let data = try? Data(contentsOf: url),
            let stages = try? JSONDecoder().decode([Stage].self, from: data)
        else { return [:] }

        return Dictionary(stages.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
    }()
}
