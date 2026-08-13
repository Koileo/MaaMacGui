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
        Self.stageCodes[stage_name] ?? Self.fallbackNavigationStageName(for: stage_name)
    }

    init?(url: URL) {
        do {
            let data = try Data(contentsOf: url)
            self = try JSONDecoder().decode(MAACopilot.self, from: data)
        } catch {
            return nil
        }
    }

    private struct StageCode: Decodable {
        let code: String
        let stageId: String
    }

    private static let stageCodes: [String: String] = {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("resource/stages.json"),
            let data = try? Data(contentsOf: url),
            let stages = try? JSONDecoder().decode([StageCode].self, from: data)
        else { return [:] }

        return Dictionary(stages.map { ($0.stageId, $0.code) }, uniquingKeysWith: { first, _ in first })
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
                $0.stageId.range(of: #"^main_[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil
                    || $0.code.range(of: #"^S[0-9]+-[0-9]+$"#, options: .regularExpression) != nil
            }
            .sorted { sortKey($0.code).lexicographicallyPrecedes(sortKey($1.code)) }
    }()

    private static func sortKey(_ code: String) -> [Int] {
        let isSideStage = code.hasPrefix("S")
        let numbers = code.trimmingCharacters(in: CharacterSet.letters)
            .split(separator: "-")
            .compactMap { Int($0) }
        return [numbers.first ?? Int.max, isSideStage ? 1 : 0, numbers.dropFirst().first ?? Int.max]
    }
}
