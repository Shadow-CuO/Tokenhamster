//
//  ZaiPlanSource.swift
//  TokenHamster
//
//  Z.ai / 智谱 GLM Coding Plan 数据源 — **只读官方 API**（需 Coding Plan API Key）。
//
//  历史沿革：本文件原为 `ZCodeLogSource`，读 ZCode 桌面版的本地 SQLite 账本
//  （`~/.zcode/cli/db/db.sqlite`）并按官方 credit 公式**折算**额度。
//  现在的做法是直接读官方接口拿到**真实百分比**，因此：
//    - 删除了 SQLite 读取（连带 `SQLiteReadOnly.swift`）
//    - 删除了 credit 折算（`ZaiCreditCalculator`）与套餐档位（`ZaiPlanTier`）
//      —— 官方响应直接给出 `usage` 上限与 `planName`，无需用户手选档位、也不再漏算 MCP 消耗
//
//  ------------------------------------------------------------------
//  三个数据来源与优先级
//  ------------------------------------------------------------------
//  1. **额度**：`api/monitor/usage/quota/limit`（必需，失败即报错——没 Key 就没数据）
//  2. **模型用量**：`api/monitor/usage/model-usage`（可选，失败不影响额度显示）
//  3. **账户余额**：`www.bigmodel.cn/api/biz/account/query-customer-account-report`
//     （可选；**仅国内站**有，国际站返回 nil）
//
//  ------------------------------------------------------------------
//  本地历史（热力图延长的关键）
//  ------------------------------------------------------------------
//  官方 model-usage 的查询上限是 30 天，而热力图默认铺 24 周 → 单次响应永远填不满。
//  因此把每次拿到的「模型 × 日期」合并进 `ZaiUsageHistory` 并落盘（同日期取 max），
//  历史随使用自然增长。首次使用只有 30 天，**用得越久热力图越长**。
//

import Foundation

// ============================================================
// MARK: - 数据源
// ============================================================

/// Z.ai Coding Plan 数据源。
struct ZaiPlanSource: AgentDataSource {

    let id: String
    let name: String
    let iconName: String
    let assetName: String?
    /// 订阅制额度来源 —— 与 Copilot 同类（远程 API + 额度窗口）
    let sourceType: AgentSourceType = .subscription
    let semantics: UsageSemantics = .cumulative

    private let fetcher: ZaiPlanQuotaFetcher
    /// 站点分区（国内 / 国际）—— 决定币种与是否有余额
    private let region: ZaiRegion
    /// 历史落盘（nil = 不持久化，测试可省）
    private let storage: AppStoring?
    private let historyKey: String
    /// 可注入时钟（测试用）
    private let now: () -> Date
    private let calendar: Calendar

    init(
        id: String,
        name: String,
        iconName: String,
        assetName: String? = nil,
        fetcher: ZaiPlanQuotaFetcher,
        region: ZaiRegion? = nil,
        storage: AppStoring? = nil,
        historyKey: String = AppConstants.zaiUsageHistoryKey,
        now: @escaping () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.assetName = assetName
        self.fetcher = fetcher
        // 未显式指定时由 base host 推断（api.z.ai → 国际站）
        self.region = region ?? ZaiRegion.detect(base: fetcher.base)
        self.storage = storage
        self.historyKey = historyKey
        self.now = now
        self.calendar = calendar
    }

    // ============================================================
    // MARK: 拉取
    // ============================================================

    func fetchSnapshot() async throws -> AgentSnapshot {
        let current = now()

        // 额度（必需）与模型用量（可选）并行；余额独立（另一台主机）
        async let quotaTask = Self.safeQuota(fetcher, now: current)
        async let usageTask = Self.safeModelUsage(fetcher, now: current, calendar: calendar)
        async let balanceTask = fetcher.fetchBalance()

        let quotaResult = await quotaTask
        let usage = await usageTask
        let balance = await balanceTask

        // ★ 先落盘历史，再判额度成败 —— 额度偶发失败时也不丢已拿到的用量
        let history = mergeAndPersist(usage: usage)

        guard case .success(let quota) = quotaResult else {
            if case .failure(let error) = quotaResult { throw error }
            throw QuotaError.invalidResponse(L("Failed to fetch quota"))
        }
        return Self.buildSnapshot(
            id: id, name: name, iconName: iconName, assetName: assetName,
            quota: quota, history: history, balance: balance, region: region, now: current
        )
    }

    private static func safeQuota(
        _ fetcher: ZaiPlanQuotaFetcher, now: Date
    ) async -> Result<QuotaSnapshot, Error> {
        do { return .success(try await fetcher.fetchQuota(now: now)) }
        catch { return .failure(error) }
    }

    private static func safeModelUsage(
        _ fetcher: ZaiPlanQuotaFetcher, now: Date, calendar: Calendar
    ) async -> [String: [Int: Int]]? {
        let start = calendar.date(
            byAdding: .day, value: -ZaiPlanQuotaFetcher.maxQueryDays, to: now
        ) ?? now
        return try? await fetcher.fetchModelUsage(from: start, to: now, calendar: calendar)
    }

    // ============================================================
    // MARK: 历史合并 / 落盘
    // ============================================================

    /// 合并官方用量进历史并落盘，返回合并后的本源历史。
    /// 无新数据时不写盘（避免每次轮询都产生磁盘写）。
    func mergeAndPersist(usage: [String: [Int: Int]]?) -> ZaiUsageHistory {
        var store = loadStore()
        var history = store[id]
        var changed = false

        if let usage, !usage.isEmpty {
            for (model, dayValues) in usage {
                let before = history.modelDays[model]
                history.merge(model: model, dayValues: dayValues)
                if history.modelDays[model] != before { changed = true }
            }
        }

        if changed {
            store[id] = history
            storage?.save(store, forKey: historyKey)
        }
        return history
    }

    private func loadStore() -> ZaiUsageHistoryStore {
        storage?.load(ZaiUsageHistoryStore.self, forKey: historyKey) ?? ZaiUsageHistoryStore()
    }

    // ============================================================
    // MARK: 快照组装（纯函数，可单测）
    // ============================================================

    static func buildSnapshot(
        id: String,
        name: String,
        iconName: String,
        assetName: String?,
        quota: QuotaSnapshot,
        history: ZaiUsageHistory,
        balance: ZaiAccountBalance?,
        region: ZaiRegion,
        now: Date
    ) -> AgentSnapshot {

        // 模型排行 / 热力图 / 合计全部来自**历史累计**，保证三者口径一致
        let modelTotals = history.totalsByModel()
        let total = history.totalTokens

        let modelUsages = modelTotals
            .sorted { $0.value > $1.value }
            .enumerated()
            .map { index, item in
                ModelUsageItem(
                    id: "model_\(index)",
                    modelName: item.key,
                    tokenAmount: item.value,
                    usagePercent: total > 0 ? Double(item.value) / Double(total) : 0
                )
            }

        let dailyHeatmap = history.dailyUsages()

        // 主窗口（5h 优先）驱动卡片上的百分比；无窗口时退化为 0
        let primary = quota.primaryWindow
        let planName = quota.planName ?? "GLM Coding Plan"

        return AgentSnapshot(
            id: id,
            name: name,
            iconName: iconName,
            assetName: assetName,
            sourceType: .subscription,
            quotaUsed: Int(round(clampPercent(primary?.usedPercent ?? 0))),
            quotaTotal: 100,
            quotaUnit: "%",
            resetTimeString: resetText(quota: quota, planName: planName),
            currency: balance?.currency ?? region.currency,
            quotaWindows: quota.windows,
            cycleStart: quota.window(.cycle)?.cycleStart,
            origin: .ideTool,
            totalTokens: total,
            totalCost: balance?.available ?? 0,
            modelUsages: modelUsages,
            sevenDayTrend: computeSevenDayTrend(from: dailyHeatmap),
            dailyHeatmap: dailyHeatmap,
            activityDays: dailyHeatmap.count,
            modelDailyTokens: history.modelDailyTokens(),
            status: .ok,
            lastUpdated: now,
            errorMessage: ""
        )
    }

    /// 底部信息行文案：`<套餐> · 5h credit · 距重置 4h 24m`
    /// 无重置时刻时退化为 `<套餐> · <窗口名>`，再退化到套餐名。
    static func resetText(quota: QuotaSnapshot, planName: String) -> String {
        guard let primary = quota.primaryWindow else { return planName }
        let text = quotaResetText(
            from: primary.resetsAt, windowLabel: primary.label, kind: primary.kind
        )
        guard !text.isEmpty else { return "\(planName) · \(primary.label)" }
        return "\(planName) · \(text)"
    }
}
