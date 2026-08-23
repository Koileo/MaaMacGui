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
    case noCopilot(String)
    case trainingRequired(String, [String])

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
        case .noCopilot(let stage):
            return "PRTS.plus 当前没有符合本地筛选条件的关卡 \(stage) 作业；可尝试关闭干员匹配或重新启用失败作业"
        case .trainingRequired(let stage, let operators):
            let names = operators.isEmpty ? "现有干员" : operators.joined(separator: "、")
            return "关卡 \(stage) 暂无可直接打或仅借一名干员即可打的作业；请提升：\(names)"
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
            let storedNames = Set(UserDefaults.standard.stringArray(forKey: namesKey) ?? [])
            if !storedNames.isEmpty {
                return storedNames
            }
            return Set(operators.map(\.name))
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
            if UserDefaults.standard.object(forKey: enabledKey) == nil {
                return !operators.isEmpty
            }
            return UserDefaults.standard.bool(forKey: enabledKey)
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return query.merging(other, uniquingKeysWith: { $1 })
    }
}

enum FailedCopilotStore {
    private static let idsKey = "PRTSPlus.failedCopilotIDs"

    static var ids: Set<Int> {
        get {
            Set(UserDefaults.standard.array(forKey: idsKey) as? [Int] ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: idsKey)
        }
    }

    static func markFailed(fileName: String) {
        let url = URL(fileURLWithPath: fileName)
        guard url.deletingLastPathComponent().lastPathComponent == "MAA PRTS.plus",
            let id = Int(url.deletingPathExtension().lastPathComponent)
        else { return }

        var failedIDs = ids
        failedIDs.insert(id)
        ids = failedIDs
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: idsKey)
    }
}

enum PRTSPlusClient {
    private static let apiBaseURL = URL(string: "https://prts.maa.plus")!
    private static let yituliuURL = URL(string: "https://backend.yituliu.cn/open-api/operator/info")!
    private static let maxFallbacks = 5
    private static let queryPageSize = 100
    private static let maxQueryResults = 500

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
        let uploadTime: String
        let hotScore: Double?
        let available: Bool
        let content: String

        enum CodingKeys: String, CodingKey {
            case id
            case type
            case uploadTime = "upload_time"
            case hotScore = "hot_score"
            case available
            case content
        }
    }

    private struct SetResponse: Decodable {
        let statusCode: Int?
        let message: String?
        let data: SetData?

        enum CodingKeys: String, CodingKey {
            case statusCode = "status_code"
            case message
            case data
        }
    }

    private struct SetData: Decodable {
        let copilotIds: [Int]

        enum CodingKeys: String, CodingKey {
            case copilotIds = "copilot_ids"
        }
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
        let actions: [Action]?

        enum CodingKeys: String, CodingKey {
            case stageName = "stage_name"
            case opers
            case groups
            case actions
        }

        struct Action: Decodable {}

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

    private struct MatchEvaluation {
        let mode: MatchMode
        let training: [String]
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
        try await candidates(
            for: copilot.stage_name,
            excluding: excluding,
            ownedOperatorNames: ownedOperatorNames,
            limit: maxFallbacks)
    }

    static func candidates(
        for stageName: String,
        excluding: Set<Int> = [],
        ownedOperatorNames: Set<String>,
        limit: Int = 2
    ) async throws -> [URL] {
        let requestedCode = MAACopilot.stageCodes[stageName]
        var summaries: [Summary] = []
        var seenIDs = Set<Int>()
        let keywords = searchKeywords(for: stageName)
        for keyword in keywords {
            var page = 1
            while page <= 5 && summaries.count < maxQueryResults {
                let queryData = try await query(stageName: stageName, keyword: keyword, page: page)
                guard !queryData.data.isEmpty else { break }
                if page == 1 && !queryData.data.contains(where: { item in
                    item.content.localizedCaseInsensitiveContains(keyword)
                        || (requestedCode != nil && item.content.localizedCaseInsensitiveContains(requestedCode!))
                }) {
                    break
                }
                for item in queryData.data {
                    guard seenIDs.insert(item.id).inserted else { continue }
                    summaries.append(item)
                }
                page += 1
            }
        }

        struct CandidateSummary {
            let summary: Summary
            let content: Content
            let stageRank: Int
        }

        var validCandidates: [CandidateSummary] = []
        for summary in summaries.prefix(maxQueryResults) {
            guard summary.available,
                summary.type == "PRTS",
                let content = try? JSONDecoder().decode(Content.self, from: Data(summary.content.utf8)),
                let stageRank = stageCompatibilityRank(candidate: content.stageName, requested: stageName),
                Self.hasFormation(content)
            else {
                continue
            }
            validCandidates.append(CandidateSummary(summary: summary, content: content, stageRank: stageRank))
        }

        // If filtering out failed copilots yields no results, fall back to all valid candidates.
        let nonExcluded = validCandidates.filter { !excluding.contains($0.summary.id) }
        let targetCandidates = nonExcluded.isEmpty ? validCandidates : nonExcluded

        let ownedMap = ownedOperatorNames.isEmpty ? nil : Self.ownedOperatorMap
        var ranked: [(id: Int, stageRank: Int, mode: MatchMode, hotScore: Double, uploadTime: String, training: [String])] = []
        for item in targetCandidates {
            let evaluation = ownedMap.map { Self.matchEvaluation(for: item.content, owned: $0) }
                ?? MatchEvaluation(mode: .ready, training: [])
            guard evaluation.mode != .blocked else {
                continue
            }
            ranked.append((item.summary.id, item.stageRank, evaluation.mode, item.summary.hotScore ?? 0, item.summary.uploadTime, evaluation.training))
        }

        ranked.sort { lhs, rhs in
            if lhs.stageRank != rhs.stageRank {
                return lhs.stageRank < rhs.stageRank
            }
            if lhs.mode != rhs.mode {
                return lhs.mode.rawValue < rhs.mode.rawValue
            }
            if lhs.hotScore != rhs.hotScore {
                return lhs.hotScore > rhs.hotScore
            }
            if lhs.uploadTime != rhs.uploadTime {
                return lhs.uploadTime > rhs.uploadTime
            }
            return lhs.id > rhs.id
        }

        var urls: [URL] = []
        for mode in [MatchMode.ready, .borrow] {
            for candidate in ranked where candidate.mode == mode {
                guard let url = try await downloadPlayable(id: candidate.id, stageName: stageName) else {
                    continue
                }
                urls.append(url)
                if urls.count >= limit {
                    return urls
                }
            }
        }
        if urls.isEmpty {
            let training = ranked
                .filter { $0.mode == .train }
                .flatMap(\.training)
            if !training.isEmpty {
                throw PRTSPlusError.trainingRequired(stageName, Array(Set(training)).sorted())
            }
        }
        return urls
    }

    private static func query(stageName: String, keyword: String, page: Int) async throws -> QueryData {
        var components = URLComponents(string: "https://prts.maa.plus/copilot/query")!
        components.queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "limit", value: String(queryPageSize)),
            URLQueryItem(name: "level_keyword", value: keyword),
            URLQueryItem(name: "order_by", value: "hot_score"),
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
        return queryData
    }

    private static func hasFormation(_ content: Content) -> Bool {
        let formationCount = (content.opers?.count ?? 0) + (content.groups?.count ?? 0)
        return formationCount > 0
    }

    private static func hasPlayableContent(_ content: Content) -> Bool {
        hasFormation(content) && !(content.actions?.isEmpty ?? true)
    }

    private static func searchKeywords(for stageName: String) -> [String] {
        var keywords: [String] = []

        // 1. Stage ID and its difficulty variants
        if stageName.hasPrefix("main_") {
            let suffix = String(stageName.dropFirst("main_".count))
            keywords.append(contentsOf: [stageName, "tough_" + suffix, "easy_" + suffix])
        } else {
            keywords.append(stageName)
        }

        // 2. Visible Stage Code (e.g. 12-10, S5-3, R8-1, CE-6)
        if let code = MAACopilot.stageCodes[stageName] {
            keywords.append(code)
            keywords.append(contentsOf: ["\(code)-NORMAL", "\(code)-HARD"])
        } else if let id = MAACopilot.stageIdByCode[stageName] {
            if id.hasPrefix("main_") {
                let suffix = String(id.dropFirst("main_".count))
                keywords.append(contentsOf: [id, "tough_" + suffix, "easy_" + suffix])
            } else {
                keywords.append(id)
            }
        }

        // Deduplicate while preserving insertion order
        var seen = Set<String>()
        return keywords.filter { seen.insert($0).inserted }
    }

    private static func stageCompatibilityRank(candidate: String, requested: String) -> Int? {
        if candidate == requested {
            return 0
        }

        // 1. Check matching prefix variants (main_ / tough_ / easy_)
        let prefixes = ["main_", "tough_", "easy_"]
        if let requestedPrefix = prefixes.first(where: requested.hasPrefix),
            let candidatePrefix = prefixes.first(where: candidate.hasPrefix),
            requested.dropFirst(requestedPrefix.count) == candidate.dropFirst(candidatePrefix.count)
        {
            if candidate.hasPrefix("main_") {
                return 1
            }
            if candidate.hasPrefix("tough_") {
                return 2
            }
            return 3
        }

        // 2. Check matching visible stage code
        let requestedCode = MAACopilot.stageCodes[requested] ?? requested
        let candidateCode = MAACopilot.stageCodes[candidate] ?? candidate
        let cleanCandidateCode = candidateCode
            .replacingOccurrences(
                of: #"-?(NORMAL|HARD|EASY|磨难|标准|险地|常规)$"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleanCandidateCode.caseInsensitiveCompare(requestedCode) == .orderedSame {
            if candidateCode.localizedCaseInsensitiveContains("HARD")
                || candidateCode.contains("磨难")
                || candidateCode.contains("险地")
            {
                return 2
            }
            return 1
        }

        return nil
    }

    private static func downloadPlayable(id: Int, stageName: String) async throws -> URL? {
        let url = try await download(id: id)
        guard let data = try? Data(contentsOf: url),
            let content = try? JSONDecoder().decode(Content.self, from: data),
            stageCompatibilityRank(candidate: content.stageName, requested: stageName) != nil,
            hasPlayableContent(content)
        else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
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

    static func copilotSetID(from input: String) -> Int? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"^(?:prts://)?s(\d+)$"#,
            #"^https?://[^/]+/(?:set|copilot/set)/(\d+)/?$"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                let range = Range(match.range(at: 1), in: value)
            else {
                continue
            }
            return Int(value[range])
        }
        return nil
    }

    static func downloadCopilotSet(id: Int) async throws -> [URL] {
        var components = URLComponents(url: apiBaseURL.appendingPathComponent("set/get"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "id", value: String(id))]

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: components.url!)
        }
        catch {
            throw PRTSPlusError.network(error)
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PRTSPlusError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let payload = try? JSONDecoder().decode(SetResponse.self, from: data) else {
            throw PRTSPlusError.invalidResponse
        }
        guard payload.statusCode == 200, let set = payload.data else {
            throw PRTSPlusError.api(payload.message ?? "作业集不存在")
        }

        var urls: [URL] = []
        for copilotID in set.copilotIds {
            urls.append(try await download(id: copilotID))
        }
        return urls
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
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
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

    private static func matchEvaluation(for content: Content, owned: [String: OwnedOperator]) -> MatchEvaluation {
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
            return MatchEvaluation(mode: .blocked, training: trainingSlots)
        }
        if missingSlots.count == 1 {
            return MatchEvaluation(mode: trainingSlots.isEmpty ? .borrow : .train, training: trainingSlots)
        }
        if trainingSlots.isEmpty {
            return MatchEvaluation(mode: totalSlots == 13 ? .borrow : .ready, training: [])
        }
        return MatchEvaluation(mode: .train, training: trainingSlots)
    }
}

enum BarkClient {
    private struct Response: Decodable {
        let code: Int
        let message: String?
    }

    static func notify(endpoint: String, title: String, body: String) async throws {
        let value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpointURL = URL(string: value), endpointURL.scheme == "https" else {
            throw PRTSPlusError.api("Bark 地址无效，请填写 https:// 开头的推送地址")
        }

        let pathComponents = endpointURL.pathComponents.filter { $0 != "/" }
        guard let deviceKey = pathComponents.last, deviceKey != "push" else {
            throw PRTSPlusError.api("Bark 地址缺少设备码")
        }
        var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false)!
        components.path = "/" + (pathComponents.dropLast() + ["push"]).joined(separator: "/")
        components.query = nil
        components.fragment = nil
        guard let pushURL = components.url else {
            throw PRTSPlusError.api("Bark 地址无效")
        }

        var request = URLRequest(url: pushURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_key": deviceKey,
            "title": title,
            "body": body,
            "group": "MAA 连续作战",
        ])
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        }
        catch {
            throw PRTSPlusError.network(error)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PRTSPlusError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let payload = try? JSONDecoder().decode(Response.self, from: data) else {
            throw PRTSPlusError.invalidResponse
        }
        guard payload.code == 200 else {
            throw PRTSPlusError.api(payload.message ?? "Bark 推送失败（\(payload.code)）")
        }
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
