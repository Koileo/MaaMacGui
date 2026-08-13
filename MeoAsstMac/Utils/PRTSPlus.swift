//
//  PRTSPlus.swift
//  MAA
//
//  Created by koileo on 2026/8/13.
//

import Foundation
import Security

enum PRTSPlusError: LocalizedError {
    case network(Error)
    case httpStatus(Int)
    case invalidResponse
    case api(String)
    case emptyOperatorRoster
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .network(let error):
            return "网络请求失败：\(error.localizedDescription)"
        case .httpStatus(let code):
            return "服务器返回异常状态：\(code)"
        case .invalidResponse:
            return "服务器返回的数据格式不正确"
        case .api(let message):
            return message
        case .emptyOperatorRoster:
            return "未同步到任何干员数据"
        case .keychain(let status):
            return "保存到钥匙串失败（\(status)）"
        }
    }
}

struct OwnedOperator: Codable {
    var name: String
    var rarity: Int
    var elite: Int
    var level: Int
    var mainSkillLevel: Int?
    var masteryLevels: [Int]
    var moduleLevels: [Int: Int]
}

enum OperatorRosterStore {
    private static let service = "MAA PRTS.plus"
    private static let account = "yituliu-token"
    private static let namesKey = "PRTSPlus.ownedOperatorNames"
    private static let operatorsKey = "PRTSPlus.ownedOperators"
    private static let enabledKey = "PRTSPlus.operatorMatchingEnabled"

    static var token: String? {
        let query = keychainQuery(merging: [
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ])
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let dict = item as? [String: Any],
            let data = dict[kSecValueData as String] as? Data,
            let token = String(data: data, encoding: .utf8),
            !token.isEmpty
        else {
            return nil
        }
        return token
    }

    static func setToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = keychainQuery()

        guard !trimmed.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }

        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8)
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            let addQuery = keychainQuery(merging: [
                kSecValueData as String: Data(trimmed.utf8)
            ])
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw PRTSPlusError.keychain(addStatus)
            }
        }
        else if updateStatus != errSecSuccess {
            throw PRTSPlusError.keychain(updateStatus)
        }
    }

    static var names: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: namesKey) ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: namesKey)
        }
    }

    static var operators: [OwnedOperator] {
        get {
            guard let data = UserDefaults.standard.data(forKey: operatorsKey),
                let operators = try? JSONDecoder().decode([OwnedOperator].self, from: data)
            else {
                return []
            }
            return operators
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: operatorsKey)
            }
        }
    }

    static var matchingEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }

    static func clear() {
        SecItemDelete(keychainQuery() as CFDictionary)
        for key in [namesKey, operatorsKey, enabledKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func keychainQuery(merging other: [String: Any] = [:]) -> [String: Any] {
        #if DEBUG
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #else
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: "29V29Y67P2.com.hguandl.MeoAsstMac",
            kSecAttrSynchronizable as String: true,
        ]
        #endif
        return query.merging(other, uniquingKeysWith: { $1 })
    }
}

enum PRTSPlusClient {
    private static let apiBaseURL = URL(string: "https://prts.maa.plus")!
    private static let yituliuURL = URL(string: "https://backend.yituliu.cn/open-api/operator/info")!
    private static let maxFallbacks = 5

    // MARK: - Responses

    private struct QueryResponse: Decodable {
        let statusCode: Int?
        let message: String?
        let data: QueryData?

        enum CodingKeys: String, CodingKey {
            case statusCode = "status_code"
            case message
            case data
        }
    }

    private struct QueryData: Decodable {
        let total: Int
        let data: [Summary]
    }

    private struct Summary: Decodable {
        let id: Int
        let type: String
        let available: Bool
        let content: String
    }

    private struct GetResponse: Decodable {
        let statusCode: Int?
        let message: String?
        let data: GetData?

        enum CodingKeys: String, CodingKey {
            case statusCode = "status_code"
            case message
            case data
        }
    }

    private struct GetData: Decodable {
        let content: String
    }

    private struct Content: Decodable {
        let stageName: String
        let opers: [Operator]?
        let groups: [Group]?

        enum CodingKeys: String, CodingKey {
            case stageName = "stage_name"
            case opers
            case groups
        }

        struct Operator: Decodable {
            let name: String
            let skill: Int?
            let requirements: Requirements?
        }

        struct Requirements: Decodable {
            let elite: Int?
            let level: Int?
            let skillLevel: Int?
            let module: Int?

            enum CodingKeys: String, CodingKey {
                case elite
                case level
                case skillLevel = "skill_level"
                case module
            }
        }

        struct Group: Decodable {
            let name: String?
            let opers: [Operator]?
        }
    }

    private enum MatchMode: Int {
        case ready = 0
        case borrow = 1
        case train = 2
        case blocked = 3
    }

    private enum GroupStatus {
        case ready
        case train
        case missing
    }

    // MARK: - Operator roster sync

    static func syncOperatorNames(token: String) async throws -> Set<String> {
        var request = URLRequest(url: yituliuURL)
        request.setValue(token.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        }
        catch {
            throw PRTSPlusError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PRTSPlusError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PRTSPlusError.httpStatus(http.statusCode)
        }
        guard let payload = try? JSONDecoder().decode(YituliuResponse.self, from: data) else {
            throw PRTSPlusError.invalidResponse
        }
        guard payload.code == 200 else {
            throw PRTSPlusError.api(payload.message ?? "同步干员数据失败")
        }

        let owned = parseOwnedOperators(payload.data ?? [])
        OperatorRosterStore.operators = owned
        return Set(owned.map(\.name))
    }

    // MARK: - Fallback operations

    static func fallbacks(for copilot: MAACopilot, excluding: Set<Int>, ownedOperatorNames: Set<String>) async throws -> [URL] {
        var components = URLComponents(string: "https://prts.maa.plus/copilot/query")!
        components.queryItems = [
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "level_keyword", value: copilot.stage_name),
            URLQueryItem(name: "order_by", value: "hot"),
            URLQueryItem(name: "desc", value: "true"),
            URLQueryItem(name: "type", value: "PRTS"),
        ]

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        }
        catch {
            throw PRTSPlusError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PRTSPlusError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PRTSPlusError.httpStatus(http.statusCode)
        }
        guard let payload = try? JSONDecoder().decode(QueryResponse.self, from: data),
            payload.statusCode == 200,
            let queryData = payload.data
        else {
            throw PRTSPlusError.invalidResponse
        }

        let ownedMap = ownedOperatorNames.isEmpty ? nil : Self.ownedOperatorMap
        var ranked: [(id: Int, mode: MatchMode)] = []
        for summary in queryData.data {
            guard summary.available,
                summary.type == "PRTS",
                !excluding.contains(summary.id),
                let content = try? JSONDecoder().decode(Content.self, from: Data(summary.content.utf8)),
                content.stageName == copilot.stage_name
            else {
                continue
            }

            let mode = ownedMap.map { Self.matchMode(for: content, owned: $0) } ?? .ready
            guard mode != .blocked else {
                continue
            }
            ranked.append((summary.id, mode))
        }

        var urls: [URL] = []
        for mode in [MatchMode.ready, .borrow, .train] {
            for candidate in ranked where candidate.mode == mode {
                urls.append(try await download(id: candidate.id))
                if urls.count >= maxFallbacks {
                    return urls
                }
            }
        }
        return urls
    }

    private static func download(id: Int) async throws -> URL {
        let url = apiBaseURL.appendingPathComponent("copilot/get/\(id)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        }
        catch {
            throw PRTSPlusError.network(error)
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PRTSPlusError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let payload = try? JSONDecoder().decode(GetResponse.self, from: data),
            payload.statusCode == 200,
            let getData = payload.data,
            let copilot = try? JSONDecoder().decode(MAACopilot.self, from: Data(getData.content.utf8)),
            !copilot.stage_name.isEmpty
        else {
            throw PRTSPlusError.invalidResponse
        }

        let fileURL = cacheDirectory.appendingPathComponent("\(id).json")
        try Data(getData.content.utf8).write(to: fileURL, options: .atomic)
        return fileURL
    }

    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("MAA PRTS.plus", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Matching

    private static let maxLevelsByRarity: [Int: [Int]] = [
        0: [30, 0, 0],
        1: [30, 0, 0],
        2: [30, 0, 0],
        3: [40, 55, 0],
        4: [45, 60, 70],
        5: [50, 70, 80],
        6: [50, 80, 90],
    ]

    private static let operatorInfoById: [String: (name: String, rarity: Int)] = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("resource/battle_data.json"),
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let chars = root["chars"] as? [String: Any]
        else {
            return [:]
        }

        var result: [String: (name: String, rarity: Int)] = [:]
        for (id, value) in chars {
            guard let dict = value as? [String: Any],
                let name = dict["name"] as? String,
                let rarity = dict["rarity"] as? Int
            else {
                continue
            }
            result[id] = (name, rarity)
        }
        return result
    }()

    private static var ownedOperatorMap: [String: OwnedOperator] {
        var map: [String: OwnedOperator] = [:]
        for owned in OperatorRosterStore.operators {
            map[normalize(owned.name)] = owned
        }
        return map
    }

    private static func parseOwnedOperators(_ records: [YituliuRecord]) -> [OwnedOperator] {
        let moduleByType = ["X": 1, "Y": 2, "A": 3, "D": 4]
        var result: [OwnedOperator] = []

        for record in records {
            guard let id = record.id,
                let info = operatorInfoById[id],
                let level = record.level,
                level > 0
            else {
                continue
            }

            var moduleLevels: [Int: Int] = [:]
            for equip in record.equips ?? [] {
                guard let type = equip.type,
                    let module = moduleByType[type],
                    let equipLevel = equip.level
                else {
                    continue
                }
                moduleLevels[module] = equipLevel
            }

            result.append(OwnedOperator(
                name: info.name,
                rarity: info.rarity,
                elite: max(0, record.evolvePhase ?? 0),
                level: level,
                mainSkillLevel: record.mainSkillLevel,
                masteryLevels: (record.skills ?? []).map { max(0, $0.level ?? 0) },
                moduleLevels: moduleLevels
            ))
        }
        return result
    }

    private static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }

    private static func maxLevels(for rarity: Int) -> [Int] {
        maxLevelsByRarity[rarity] ?? maxLevelsByRarity[6]!
    }

    private static func progressScore(rarity: Int, elite: Int, level: Int) -> Int {
        let caps = maxLevels(for: rarity)
        var score = max(1, level)
        if elite > 0 {
            for index in 0..<min(elite, caps.count) {
                score += caps[index]
            }
        }
        return score
    }

    private static func inferElite(rarity: Int, level: Int, elite: Int?) -> Int {
        if let elite {
            return elite
        }
        let caps = maxLevels(for: rarity)
        var inferred = 0
        while inferred < caps.count - 1 && level > caps[inferred] {
            inferred += 1
        }
        return inferred
    }

    private static func meetsRequirement(_ oper: Content.Operator, owned: OwnedOperator) -> Bool {
        guard let requirements = oper.requirements else {
            return true
        }

        if requirements.elite != nil || requirements.level != nil {
            let requiredLevel = requirements.level ?? 1
            let requiredElite = inferElite(rarity: owned.rarity, level: requiredLevel, elite: requirements.elite)
            let ownedScore = progressScore(rarity: owned.rarity, elite: owned.elite, level: owned.level)
            let requiredScore = progressScore(rarity: owned.rarity, elite: requiredElite, level: requiredLevel)
            if ownedScore < requiredScore {
                return false
            }
        }

        if let skillLevel = requirements.skillLevel {
            if skillLevel >= 8 {
                guard let skillIndex = oper.skill, skillIndex >= 1 else {
                    return false
                }
                let mastery = owned.masteryLevels.indices.contains(skillIndex - 1) ? owned.masteryLevels[skillIndex - 1] : 0
                if mastery < skillLevel - 7 {
                    return false
                }
            }
            else if (owned.mainSkillLevel ?? 0) < skillLevel {
                return false
            }
        }

        if let module = requirements.module, module > 0, (owned.moduleLevels[module] ?? 0) < 1 {
            return false
        }

        return true
    }

    private static func groupStatus(_ group: Content.Group, owned: [String: OwnedOperator]) -> GroupStatus {
        let candidates = group.opers ?? []
        for candidate in candidates {
            guard let ownedOperator = owned[normalize(candidate.name)] else {
                continue
            }
            if meetsRequirement(candidate, owned: ownedOperator) {
                return .ready
            }
        }
        return candidates.contains(where: { owned[normalize($0.name)] != nil }) ? .train : .missing
    }

    private static func matchMode(for content: Content, owned: [String: OwnedOperator]) -> MatchMode {
        var missingSlots: [String] = []
        var trainingSlots: [String] = []

        for oper in content.opers ?? [] {
            if let ownedOperator = owned[normalize(oper.name)] {
                if !meetsRequirement(oper, owned: ownedOperator) {
                    trainingSlots.append(oper.name)
                }
            }
            else {
                missingSlots.append(oper.name)
            }
        }

        for group in content.groups ?? [] {
            let displayName = group.name ?? group.opers?.map(\.name).joined(separator: " / ") ?? "未命名分组"
            switch groupStatus(group, owned: owned) {
            case .missing:
                missingSlots.append(displayName)
            case .train:
                trainingSlots.append(displayName)
            case .ready:
                break
            }
        }

        let totalSlots = (content.opers?.count ?? 0) + (content.groups?.count ?? 0)
        if totalSlots > 13 || missingSlots.count >= 2 {
            return .blocked
        }
        if missingSlots.count == 1 {
            return trainingSlots.isEmpty ? .borrow : .train
        }
        if trainingSlots.isEmpty {
            return totalSlots == 13 ? .borrow : .ready
        }
        return .train
    }
}

private struct YituliuResponse: Decodable {
    let code: Int
    let message: String?
    let data: [YituliuRecord]?
}

private struct YituliuRecord: Decodable {
    let id: String?
    let level: Int?
    let evolvePhase: Int?
    let mainSkillLevel: Int?
    let skills: [YituliuSkill]?
    let equips: [YituliuEquip]?
}

private struct YituliuSkill: Decodable {
    let level: Int?
}

private struct YituliuEquip: Decodable {
    let type: String?
    let level: Int?
}
