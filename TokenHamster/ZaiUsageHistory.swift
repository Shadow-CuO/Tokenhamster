//
//  ZaiUsageHistory.swift
//  TokenHamster
//
//  Z.ai Coding Plan 用量的**本地累积存储**。
//
//  为什么需要它：
//  官方 `api/monitor/usage/model-usage` 的查询范围上限是 30 天
//  （实测可用 1 天逐小时 / 30 天逐日），而仪表盘热力图默认铺 24 周（`heatmapWeeks`）。
//  只靠单次响应永远填不满热力图，所以把每次拿到的「模型 × 日期」按天合并落盘，
//  历史随使用自然增长 → **热力图越用越长**。
//
//  合并语义：同一 (模型, 日期) 取 **max**。
//  - 官方对已过去的日期返回终值、对当天返回递增中的值 → max 保证单调不回退
//  - 重复抓取幂等，不会重复累加（与「明细型源」的语义一致，见 `ModelTokenLedger.upsert`）
//
//  ⚠️ 日期键用**当地零时的 epoch 秒**，而不是 `tokenDayKey` 那种「epoch / 86400」的日序号。
//     后者无法精确反推日期：在 UTC+8 下 `dayKey * 86400` 会落回**前一天**（差一天）。
//     存当地零时 epoch 则 `Date(timeIntervalSince1970:)` 可精确往返。
//

import Foundation

// ============================================================
// MARK: - 单源历史
// ============================================================

/// 单个 Z.ai 数据源的用量历史（模型 × 日期）
struct ZaiUsageHistory: Codable, Equatable {

    /// ★ 口径版本 — 解析方式变化导致数值含义改变时递增，旧数据**丢弃**而非迁移。
    ///   （与 `ModelTokenLedger.metricVersion` 同一思路：宁可重算也不混算两种口径）
    static let currentVersion = 1

    var version: Int = ZaiUsageHistory.currentVersion
    /// 模型 → [当地零时 epoch 秒: token]
    var modelDays: [String: [Int: Int]] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey { case version, modelDays }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        let stored = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        guard stored == Self.currentVersion else { return }   // 口径不符 → 留空重算
        modelDays = try container.decodeIfPresent([String: [Int: Int]].self, forKey: .modelDays) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(modelDays, forKey: .modelDays)
    }

    // ---- 日期键（精确往返） ----

    /// 当地零时的 epoch 秒
    nonisolated static func dayKey(for date: Date, calendar: Calendar = .current) -> Int {
        Int(calendar.startOfDay(for: date).timeIntervalSince1970)
    }

    nonisolated static func date(forDayKey key: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(key))
    }

    // ---- 写入 ----

    /// 合并一个模型的「日期 → 用量」（同日期取 max）
    mutating func merge(model: String, dayValues: [Int: Int]) {
        guard !model.isEmpty, !dayValues.isEmpty else { return }
        var days = modelDays[model] ?? [:]
        for (day, value) in dayValues where value > 0 {
            days[day] = max(days[day] ?? 0, value)
        }
        // ★ 全是 0/负值时不留空条目 —— 否则「无数据的模型」也会在历史里占一个键
        guard !days.isEmpty else { return }
        modelDays[model] = days
    }

    // ---- 读取 ----

    /// 逐日总量（跨模型求和）— 热力图数据源
    var dailyTotals: [Int: Int] {
        var result: [Int: Int] = [:]
        for days in modelDays.values {
            for (day, value) in days { result[day, default: 0] += value }
        }
        return result
    }

    /// 每模型累计 — MODELS 栏数据源
    func totalsByModel() -> [String: Int] {
        modelDays.mapValues { $0.values.reduce(0, +) }
    }

    var totalTokens: Int { dailyTotals.values.reduce(0, +) }

    /// 非空日期数（= 热力图有值的格子数）
    var activeDays: Int { dailyTotals.count }

    /// 转成 `DailyUsage`（升序，已按当地零时归位）
    func dailyUsages() -> [DailyUsage] {
        dailyTotals
            .compactMap { day, tokens -> DailyUsage? in
                guard tokens > 0 else { return nil }
                return DailyUsage(
                    date: Self.date(forDayKey: day),
                    tokenCount: tokens,
                    level: heatmapLevel(for: tokens)
                )
            }
            .sorted { $0.date < $1.date }
    }

    /// 模型 × 日期 明细（喂全局 Token 账本，走它的 upsert 幂等分支）
    func modelDailyTokens() -> [ModelDailyToken] {
        modelDays.flatMap { model, days in
            days.compactMap { day, tokens -> ModelDailyToken? in
                guard tokens > 0 else { return nil }
                return ModelDailyToken(
                    modelName: model,
                    date: Self.date(forDayKey: day),
                    tokens: tokens
                )
            }
        }
    }
}

// ============================================================
// MARK: - 多源集合
// ============================================================

/// 多个 Z.ai 数据源的历史（按数据源 ID 分组）。
/// 每个数据源一个独立历史 —— 避免两份配置的用量互相污染。
struct ZaiUsageHistoryStore: Codable, Equatable {

    static let currentVersion = 1

    var version: Int = ZaiUsageHistoryStore.currentVersion
    var sources: [String: ZaiUsageHistory] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey { case version, sources }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        let stored = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        guard stored == Self.currentVersion else { return }
        sources = try container.decodeIfPresent([String: ZaiUsageHistory].self, forKey: .sources) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(sources, forKey: .sources)
    }

    subscript(sourceID: String) -> ZaiUsageHistory {
        get { sources[sourceID] ?? ZaiUsageHistory() }
        set { sources[sourceID] = newValue }
    }
}
