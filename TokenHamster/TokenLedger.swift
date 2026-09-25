//
//  TokenLedger.swift
//  TokenHamster
//
//  ★ 所有模型总用量的本地账本 — day / month / total 三维度 + 软重置
//
//  设计要点：
//  1. 与额度板块完全独立：账本只受用户手动重置截断，不受额度周期影响。
//  2. 存储粒度为「模型 × 日期」，day / month / total 均可由它推导，
//     且能按重置时刻做严格截断。
//  3. 写入分两种模式：
//     - 明细型源（本地日志 / OpenAI 等返回真实每日历史）→ upsert 覆盖式（取 max）
//       ★ 因为每次返回的是全量历史，累加会重复计算
//     - 汇总型源（Anthropic org 总量 / Copilot / Custom 只有累计值）→ 差值累加
//  4. 重置为「软重置」：记录重置时刻 + 重置当日快照，汇总时对重置当天扣除快照，
//     这样日志全量重扫后该日值增长的部分自然成为「重置后的增量」。
//

import Foundation

// ============================================================
// MARK: - 三维用量
// ============================================================

/// 三维 Token 用量（自然日 / 自然月 / 全时段累积）
struct TokenTotals: Codable, Equatable {
    var day: Int = 0
    var month: Int = 0
    var total: Int = 0

    static let zero = TokenTotals()

    static func + (lhs: TokenTotals, rhs: TokenTotals) -> TokenTotals {
        TokenTotals(day: lhs.day + rhs.day, month: lhs.month + rhs.month, total: lhs.total + rhs.total)
    }
}

/// 单个「模型 × 来源通道」的用量汇总（供前端分两个子区块展示 / 按模型重置）
struct ModelTokenTotals: Identifiable, Equatable {
    /// 同名模型来自不同来源通道时算两条，故 id 需含通道
    var id: String { "\(origin.rawValue)|\(modelName)" }
    var modelName: String
    var origin: ModelOrigin
    var totals: TokenTotals
    /// 该模型是否有独立重置点（前端据此显示「已重置」标记）
    var hasCustomReset: Bool
}

// ============================================================
// MARK: - 重置点
// ============================================================

/// 重置点 — 软重置语义。
/// `daySnapshot` 是重置时刻所在日的账本原始值，汇总时从该日扣除，
/// 得到「重置之后新增的部分」（严格截断）。
struct ResetPoint: Codable, Equatable {
    var resetAt: Date
    var daySnapshot: Int
}

// ============================================================
// MARK: - 账本键（数据源 + 模型）
// ============================================================

/// 账本条目的复合键编码。
/// JSON 对象的键必须是字符串，因此用不可见分隔符把两个字段拼成一个键。
enum LedgerKey {
    static let separator: Character = "\u{1F}"   // Unit Separator

    static func encode(sourceID: String, model: String) -> String {
        "\(sourceID)\(separator)\(model)"
    }

    static func decode(_ key: String) -> (sourceID: String, model: String)? {
        guard let index = key.firstIndex(of: separator) else { return nil }
        let sourceID = String(key[key.startIndex..<index])
        let model = String(key[key.index(after: index)...])
        return (sourceID, model)
    }

    static func model(of key: String) -> String? { decode(key)?.model }
    static func sourceID(of key: String) -> String? { decode(key)?.sourceID }
}

/// 本地时区「当日序号」— 用 startOfDay 的 epoch / 86400，避免时区漂移
func tokenDayKey(for date: Date, calendar: Calendar = .current) -> Int {
    Int(calendar.startOfDay(for: date).timeIntervalSince1970 / 86_400)
}

// ============================================================
// MARK: - 模型 × 日期 账本
// ============================================================

/// 模型 × 日期 账本（本地持久化）。
/// buckets: "sourceID␟modelName" → [当日序号: token]
/// ★ 以「来源 + 模型」为键，保证：同一源重复扫描幂等，不同源同名模型相加。
struct ModelTokenLedger: Codable, Equatable {

    /// ★ 口径版本 — 不同数据源 / 不同口径的 token 合计**不可混算**。
    ///
    /// 各来源的 total 口径并不一致（例如 DSH 走 dsh-usage-stats 的四桶折叠值，
    /// 而会话日志型来源是累计求和），换源或插件改桶定义时数字会整体跳变。
    /// 递增此版本 → 旧账本在加载时被**丢弃**，宁可重算也不把两种口径相加。
    static let currentMetricVersion = 1

    var metricVersion: Int = ModelTokenLedger.currentMetricVersion
    var buckets: [String: [Int: Int]] = [:]
    /// 模型级重置点（按模型名，跨全部来源生效）
    var modelResets: [String: ResetPoint] = [:]
    /// 全局重置点（「清空全部」时记录；此时会清空 modelResets 避免叠加）
    var globalReset: ResetPoint? = nil

    init() {}

    private enum CodingKeys: String, CodingKey {
        case metricVersion, buckets, modelResets, globalReset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        // 口径不一致 → 保留空账本（不迁移、不合并）
        let storedVersion = try container.decodeIfPresent(Int.self, forKey: .metricVersion) ?? 0
        guard storedVersion == Self.currentMetricVersion else { return }
        buckets = try container.decodeIfPresent([String: [Int: Int]].self, forKey: .buckets) ?? [:]
        modelResets = try container.decodeIfPresent([String: ResetPoint].self, forKey: .modelResets) ?? [:]
        globalReset = try container.decodeIfPresent(ResetPoint.self, forKey: .globalReset)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentMetricVersion, forKey: .metricVersion)
        try container.encode(buckets, forKey: .buckets)
        try container.encode(modelResets, forKey: .modelResets)
        try container.encodeIfPresent(globalReset, forKey: .globalReset)
    }

    // ============================================================
    // MARK: 写入
    // ============================================================

    /// 明细型源写入 — 覆盖式取 max。
    /// ★ 明细型源每次返回的是全量历史，累加会重复计算，因此必须幂等。
    mutating func upsert(sourceID: String, model: String, dayKey: Int, value: Int) {
        guard !model.isEmpty, value > 0 else { return }
        let key = LedgerKey.encode(sourceID: sourceID, model: model)
        var dayMap = buckets[key] ?? [:]
        dayMap[dayKey] = max(dayMap[dayKey] ?? 0, value)
        buckets[key] = dayMap
    }

    /// 汇总型源写入 — 只知累计值变化量，累加到当天。
    mutating func accumulate(sourceID: String, model: String, dayKey: Int, delta: Int) {
        guard !model.isEmpty, delta > 0 else { return }
        let key = LedgerKey.encode(sourceID: sourceID, model: model)
        var dayMap = buckets[key] ?? [:]
        dayMap[dayKey, default: 0] += delta
        buckets[key] = dayMap
    }

    /// 明细型源按天批量写入
    mutating func upsertDaily(sourceID: String, model: String, dayValues: [Int: Int]) {
        for (dayKey, value) in dayValues {
            upsert(sourceID: sourceID, model: model, dayKey: dayKey, value: value)
        }
    }

    // ============================================================
    // MARK: 重置（与额度板块无关）
    // ============================================================

    /// 重置单个模型 — 记重置时刻 + 当日快照（跨全部来源求和）
    mutating func resetModel(_ model: String, at date: Date = Date(), calendar: Calendar = .current) {
        guard !model.isEmpty else { return }
        let dayKey = tokenDayKey(for: date, calendar: calendar)
        modelResets[model] = ResetPoint(
            resetAt: date,
            daySnapshot: rawDailyTotals(forModel: model)[dayKey] ?? 0
        )
    }

    /// 重置全部模型 — 记全局重置点；清空模型级重置点避免叠加
    mutating func resetAll(at date: Date = Date(), calendar: Calendar = .current) {
        let dayKey = tokenDayKey(for: date, calendar: calendar)
        var snapshot = 0
        for dayMap in buckets.values { snapshot += dayMap[dayKey] ?? 0 }
        globalReset = ResetPoint(resetAt: date, daySnapshot: snapshot)
        modelResets.removeAll()
    }

    /// 移除某模型的重置点（保留数据，仅恢复正常累计）
    mutating func clearReset(for model: String) {
        modelResets.removeValue(forKey: model)
    }

    /// 某模型当前生效的重置点（模型级优先，回退全局）
    func effectiveReset(for model: String) -> ResetPoint? {
        modelResets[model] ?? globalReset
    }

    // ============================================================
    // MARK: 汇总（严格截断）
    // ============================================================

    /// 某模型（跨全部来源）按日的原始用量（未做重置截断）
    func rawDailyTotals(forModel model: String) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for (key, dayMap) in buckets where LedgerKey.model(of: key) == model {
            for (dayKey, value) in dayMap {
                result[dayKey, default: 0] += value
            }
        }
        return result
    }

    /// 单个「来源 + 模型」条目的三维用量（已按该模型的重置点截断）
    func totals(
        sourceID: String, model: String,
        now: Date = Date(), calendar: Calendar = .current
    ) -> TokenTotals {
        let key = LedgerKey.encode(sourceID: sourceID, model: model)
        guard let dayMap = buckets[key] else { return .zero }
        return summarize(dayMap, model: model, now: now, calendar: calendar)
    }

    /// 某模型跨全部来源的三维用量（已按重置点截断）
    func totals(forModel model: String, now: Date = Date(), calendar: Calendar = .current) -> TokenTotals {
        summarize(rawDailyTotals(forModel: model), model: model, now: now, calendar: calendar)
    }

    /// 所有模型相加的总用量（★ 不分来源通道，只要有数据就相加）
    func allTotals(now: Date = Date(), calendar: Calendar = .current) -> TokenTotals {
        allModelNames().reduce(TokenTotals.zero) {
            $0 + totals(forModel: $1, now: now, calendar: calendar)
        }
    }

    /// 全部模型名（去重）
    func allModelNames() -> [String] {
        Array(Set(buckets.keys.compactMap { LedgerKey.model(of: $0) }))
    }

    /// 全部来源 ID（去重）
    func allSourceIDs() -> [String] {
        Array(Set(buckets.keys.compactMap { LedgerKey.sourceID(of: $0) }))
    }

    /// 按「模型 × 来源通道」拆分的用量明细（供前端两个子区块分别渲染）。
    /// - Parameter originBySource: 数据源 ID → 来源通道（未知按 .directAPI）
    func modelTotals(
        originBySource: [String: ModelOrigin] = [:],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ModelTokenTotals] {
        // (模型, 通道) → [日: 值]；同名模型来自不同通道时分行展示
        var grouped: [String: [Int: Int]] = [:]
        var meta: [String: (model: String, origin: ModelOrigin)] = [:]

        for (key, dayMap) in buckets {
            guard let parsed = LedgerKey.decode(key) else { continue }
            let origin = originBySource[parsed.sourceID] ?? .directAPI
            let groupKey = "\(origin.rawValue)|\(parsed.model)"
            meta[groupKey] = (parsed.model, origin)
            var merged = grouped[groupKey] ?? [:]
            for (dayKey, value) in dayMap { merged[dayKey, default: 0] += value }
            grouped[groupKey] = merged
        }

        return grouped.compactMap { groupKey, dayMap -> ModelTokenTotals? in
            guard let info = meta[groupKey] else { return nil }
            return ModelTokenTotals(
                modelName: info.model,
                origin: info.origin,
                totals: summarize(dayMap, model: info.model, now: now, calendar: calendar),
                hasCustomReset: modelResets[info.model] != nil
            )
        }
        .sorted { $0.totals.total > $1.totals.total }
    }

    // ============================================================
    // MARK: 内部
    // ============================================================

    /// 严格截断 + 三维求和
    private func summarize(
        _ dayValues: [Int: Int],
        model: String,
        now: Date,
        calendar: Calendar
    ) -> TokenTotals {
        let todayKey = tokenDayKey(for: now, calendar: calendar)
        let monthAnchor = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let monthKey = tokenDayKey(for: monthAnchor, calendar: calendar)

        var result = TokenTotals()
        for (dayKey, raw) in dayValues {
            let value = effectiveValue(model: model, dayKey: dayKey, rawValue: raw)
            guard value > 0 else { continue }
            result.total += value
            if dayKey == todayKey { result.day += value }
            if dayKey >= monthKey { result.month += value }
        }
        return result
    }

    /// 单个日期桶在截断后的有效值
    /// - 重置日之前 → 0
    /// - 重置日当天 → max(0, 原始值 − 快照)
    /// - 重置日之后 → 原始值
    func effectiveValue(model: String, dayKey: Int, rawValue: Int) -> Int {
        guard let reset = effectiveReset(for: model) else { return rawValue }
        let resetKey = tokenDayKey(for: reset.resetAt)
        if dayKey < resetKey { return 0 }
        if dayKey == resetKey { return max(0, rawValue - reset.daySnapshot) }
        return rawValue
    }
}
