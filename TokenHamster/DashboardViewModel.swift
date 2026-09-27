//
//  DashboardViewModel.swift
//  TokenHamster
//
//  Created by Oscar Sun on 2026/7/14.
//

import Foundation
import Combine
import SwiftUI

// ============================================================
// MARK: - ★ 自适应外观配置（所有可调配参数） ★
// ============================================================

/// 仪表盘所有可调配外观 = 变量 + 后端接口
struct DashboardAppearance {

    /// 是否深色背景 — 由系统外观 / 后端下发
    var isDark: Bool = true

    // ---- 自适应文字色 ----
    var textPrimary: Color   { isDark ? .white              : Color(hex: "#3A3A3C") }
    var textSecondary: Color { isDark ? .white.opacity(0.55): Color(hex: "#6E6E73") }
    var textTertiary: Color  { isDark ? .white.opacity(0.35): Color(hex: "#8E8E93") }
    var textHeading: Color   { isDark ? .white.opacity(0.45): Color(hex: "#636366") }
    var accent: Color        { .blue }

    var divider: Color        { isDark ? .white.opacity(0.08) : .black.opacity(0.08) }
    var progressBg: Color     { isDark ? .white.opacity(0.08) : .black.opacity(0.06) }
    var pillUnselectedBg: Color   { isDark ? .clear               : .black.opacity(0.04) }
    var pillSelectedBg: Color     { isDark ? .white.opacity(0.12) : .black.opacity(0.08) }
    var pillUnselectedStroke: Color { isDark ? .white.opacity(0.06) : .black.opacity(0.06) }
    var pillSelectedStroke: Color   { isDark ? .white.opacity(0.2)  : .black.opacity(0.12) }
    var pillTextUnselected: Color { isDark ? .white.opacity(0.45) : Color(hex: "#636366") }
    var pillTextSelected: Color   { isDark ? .white              : Color(hex: "#1D1D1F") }
    var cardStroke: Color         { isDark ? .white.opacity(0.06) : .black.opacity(0.05) }

    // ---- 字号（全部可配，缩小以容纳更多内容） ----
    var fontTotalLabel: CGFloat  = 9
    var fontTotalTokens: CGFloat = 30
    var fontSectionIcon: CGFloat = 11
    var fontSectionLabel: CGFloat = 10
    var fontQuotaName: CGFloat   = 11
    var fontQuotaPercent: CGFloat = 10
    var fontQuotaReset: CGFloat  = 9
    var fontDeviceName: CGFloat  = 11
    var fontDeviceUsage: CGFloat = 9
    var fontModelName: CGFloat   = 11
    var fontModelValue: CGFloat  = 10
    var fontModelPercent: CGFloat = 9
    /// ★ 额度列的金额/状态文案字号（如 "¥88.50 left"）—— 比占比稍大，便于阅读余额
    var fontModelAmount: CGFloat = 11
    var fontTimeRange: CGFloat   = 10
    var fontActiveDays: CGFloat  = 10
    var fontPeak: CGFloat        = 10
    var fontMonthLabel: CGFloat  = 8

    // ---- 间距（缩小以容纳更多内容） ----
    var sectionGap: CGFloat    = 12
    var paddingOuter: CGFloat  = 20
    var progressHeight: CGFloat = 5
    var modelBarHeight: CGFloat = 3

    // ---- 面板圆角 ----
    var cornerRadius: CGFloat = 32

    // ---- 顶部拖拽区高度（仅此区域按住拖动可移动窗口，无视觉指示） ----
    var dragHandleZoneHeight: CGFloat = 30

    // ---- 热力图（GitHub 风格：7 行 × heatmapWeeks 列） ----
    var heatmapCellSize: CGFloat = 10
    var heatmapSpacing: CGFloat  = 4
    var heatmapCorner: CGFloat   = 2
    var heatmapWeeks: Int        = 24

    // ---- 趋势图高度 ----
    var trendChartHeight: CGFloat = 90

    // ---- 模型列宽（★ 两列：左 token 用量 / 右 额度，宽度按用户标注的框比例定） ----
    var modelNameWidth: CGFloat    = 110
    var modelBarWidth: CGFloat     = 90
    /// 左列宽：token 用量。实测最宽为 "225.3M"（10pt semibold）= 37.8pt，
    ///   但按用户标注的框保留较宽余量。
    var modelValueWidth: CGFloat   = 66
    /// 右列宽：额度。★ 实测 11pt 下 "¥1234.56 left" = 70.0pt、
    ///   "¥88.50 left" = 58.1pt → 取 72pt 可完整容纳而**不触发缩放**。
    ///   过窄会被 minimumScaleFactor 缩回原字号，导致“调大字号”失效。
    var modelQuotaWidth: CGFloat   = 72

    /// 面板尺寸（宽×高）
    var panelWidth: CGFloat  = 364
    var panelHeight: CGFloat = 640
}

// MARK: - Color hex helper

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// ============================================================
// MARK: - 时间范围
// ============================================================

enum TimeRange: String, CaseIterable, Identifiable {
    case day = "DAY"
    case month = "MONTH"
    case total = "TOTAL"

    var id: String { rawValue }
}

// MARK: - 额度项（★ 新增后端驱动字段，保留旧字段以兼容 DashboardView）

struct QuotaItem: Identifiable, Codable, Equatable {
    let id: String
    var name: String                   // e.g. "Claude", "Codex"

    // ---- 旧字段（兼容 DashboardView） ----
    var used: Int                      // 已用 tokens
    var total: Int                     // 总额度
    var resetDaysLeft: Int             // 重置剩余天数
    var resetHoursLeft: Int            // 重置剩余小时数

    // ---- ★ 新字段（后端驱动，暴露给前端 UI） ----
    var serviceName: String { name }   // ★ 与 name 统一，暴露给前端
    var hourlyUsedPercent: Int = 0     // ★ 过去一小时已用百分比 (0~100)
    var weeklyUsedPercent: Int = 0     // ★ 本周已用百分比 (0~100)
    var resetTimeString: String = ""   // ★ 重置文案，如 "5d 12h"

    /// 已用百分比 (0~1)
    var usedRatio: Double {
        guard total > 0 else { return 0 }
        return min(Double(used) / Double(total), 1.0)
    }

    /// 剩余百分比文案，如 "62% left"
    var leftPercentText: String {
        "\(Int((1 - usedRatio) * 100))% left"
    }

    /// 重置倒计时文案，如 "Weekly Reset 5d 12h"
    var resetText: String {
        if !resetTimeString.isEmpty { return resetTimeString }
        return "Weekly Reset \(resetDaysLeft)d \(resetHoursLeft)h"
    }
}

// MARK: - 模型项

struct ModelItem: Identifiable {
    let id: String
    var name: String           // e.g. "gpt-5.5"
    var tokens: Int            // 精确 token 用量
    var ratio: Double          // 占比 (0~1)

    /// 格式化 token 用量，如 "1.9B", "843.2M"（统一走 `formatCompactCount`）
    var tokenFormatted: String { tokens.formattedTokenCount }

    /// 百分比文案，如 "44.6%"
    var percentText: String {
        String(format: "%.1f%%", ratio * 100)
    }
}

// MARK: - 模型行（MODELS 栏 — 厂商 logo + 具体模型/厂商）

/// MODELS 栏单行数据：厂商 logo + 模型名（或厂商名）+ 用量 + 占比。
struct ModelRowItem: Identifiable {
    let id: String
    let assetName: String?      // 厂商品牌图名（nil = 回退 SF Symbol）
    let symbolName: String      // 回退 SF Symbol
    let name: String            // 具体模型名（如 gpt-5.6）或厂商名（余额型无明细时）
    var tokens: Int             // 精确 token 用量
    var ratio: Double           // 占全局总量比例 (0~1)
    /// 余额型源的额度文案（如 "¥88.50 left" / "已用完"）；有 token 用量时为 nil
    let valueText: String?
    /// ★ 来源通道 — 前端据此把 MODELS 栏拆成「API 直连」/「IDE 工具内」两个子区块
    let origin: ModelOrigin
    /// ★ 右列（额度列）是否展示。DSH 的模型明细只用于 token 统计 → 右列刻意留白。
    var showsQuotaColumn: Bool = true

    /// 左列 token 用量文案（统一走 `formatCompactCount`）
    var tokenFormatted: String { tokens.formattedTokenCount }

    // ------------------------------------------------------------
    // ★ 右侧两列（左：token 用量；右：额度）——
    //   原则「有 token 用量显示 token 用量，无 token 用量显示金额」的两列化表达。
    //   两列宽度由 UI 固定，**没有内容就留白，不补位**（不用 "—"，也不让另列位移）。
    // ------------------------------------------------------------

    /// 左列：token 用量文案 —— 无 token 用量时为空串（留白）
    var usageText: String {
        tokens > 0 ? tokenFormatted : ""
    }

    /// 右列：额度文案 —— 有 token 维度显示使用百分比；余额型显示余额文案；都没有则留白
    var quotaText: String {
        if tokens > 0 {
            // ★ showsQuotaColumn == false（DSH）：右列刻意留白，而不是补位显示占比
            guard showsQuotaColumn else { return "" }
            return String(format: "%.1f%%", ratio * 100)
        }
        return valueText ?? ""
    }

    /// 额度列当前展示的是金额/状态文案（而非百分比）→ UI 用稍大字号
    var quotaShowsAmount: Bool {
        tokens <= 0 && !quotaText.isEmpty
    }
}

// MARK: - DashboardViewModel

@MainActor
class DashboardViewModel: ObservableObject {

    // ============================================================
    // MARK: ★ 自适应外观（系统/后端可覆盖） ★
    // ============================================================

    @Published var appearance = DashboardAppearance()

    // ============================================================
    // MARK: ★ 旧字段 — 兼容现有 DashboardView ★
    // ============================================================

    @Published var selectedRange: TimeRange = .total

    /// ★ 暴露给前端 UI — 总 Token 消耗数
    @Published var totalTokens: Int = 0

    /// ★ 暴露给前端 UI — 总消耗金额（人民币）
    @Published var totalCostYuan: Double = 0

    /// ★ 暴露给前端 UI — 额度列表（兼容旧 DashboardView）
    @Published var quotas: [QuotaItem] = []

    /// ★ 暴露给前端 UI — 模型列表（兼容旧 DashboardView）
    @Published var models: [ModelItem] = []

    /// ★ 暴露给前端 UI — 活跃天数
    @Published var activeDays: Int = 0

    /// ★ 暴露给前端 UI — 热力图数据: 7 行 × N 列
    @Published var heatmapData: [[Int]] = []

    /// ★ 暴露给前端 UI — 趋势图数据点
    @Published var trendData: [Double] = []

    /// ★ 暴露给前端 UI — 峰值
    @Published var peakValue: Double = 0

    /// ★ 暴露给前端 UI — 加载状态（兼容旧 DashboardView）
    @Published var isLoading: Bool = false

    /// ★ 暴露给前端 UI — 最后更新时间（兼容旧 DashboardView）
    @Published var lastUpdated: Date? = nil

    // ============================================================
    // MARK: ★ 新字段 — 后端驱动，暴露给前端 UI ★
    // ============================================================

    /// ★ 暴露给前端 UI — 总消耗金额（通用货币，如 USD）
    @Published var totalCost: Double = 0

    /// ★ 暴露给前端 UI — 币种标识
    @Published var costCurrency: String = "USD"

    /// 用户偏好币种 —— **只用于数据源未提供币种时的回退**（不做汇率换算）
    private var preferredCurrencyCode: String { AppSettingsStore.shared.currency.code }

    /// ★ 暴露给前端 UI — 服务商额度集合（与 quotas 同步）
    @Published var quotaList: [QuotaItem] = []

    /// ★ 暴露给前端 UI — 模型消耗集合
    @Published var modelUsages: [ModelUsageItem] = []

    /// ★ 暴露给前端 UI — 过去 7 天每日 Token 趋势
    @Published var sevenDayTrend: [Int] = Array(repeating: 0, count: 7)

    /// ★ 暴露给前端 UI — 每日消耗记录（热力图数据源）
    @Published var dailyHeatmap: [DailyUsage] = []

    // ---- ★ 用户配置 ----
    /// ★ 暴露给前端 UI — 所有 API 配置列表
    @Published var apiConfigs: [APIConfigItem] = []

    // ---- ★ 多源聚合（综合监测） ----

    /// ★ 暴露给前端 UI — 所有数据源快照（每个启用的源一张卡片）
    @Published var agentSnapshots: [AgentSnapshot] = []

    /// ★ 暴露给前端 UI — 聚合仪表盘数据（头部汇总）
    @Published var aggregated = AggregatedDashboard()

    /// ★ 暴露给前端 UI — MODELS 栏行数据（厂商 logo + 具体模型）
    /// 从 agentSnapshots 展开：
    /// - 有模型明细（modelUsages 非空）→ 每个模型一行（带该源厂商 logo），覆盖本地 Claude Code/Codex 解析出的模型
    /// - 无明细的 API 厂商 → 厂商一行；累计型显示 token 总量，余额型（DeepSeek/Kimi）显示余额金额
    /// - 无明细的本地日志 / Copilot → 不产生行（本体留在 AGENTS 栏）
    /// 全局按 tokens 降序，占比相对全局总量重算。
    var modelRows: [ModelRowItem] {
        var rows: [ModelRowItem] = []
        for snap in agentSnapshots {
            if !snap.modelUsages.isEmpty {
                // ★ DSH 的模型明细只用于 token 统计 → 右列（额度列）刻意留白。
                //   用 apiConfigs 查 agentProvider（类型安全），不做 assetName 字符串匹配。
                let isDSH = apiConfigs.first { $0.id == snap.id }?.agentProvider == .dsh
                for (i, m) in snap.modelUsages.enumerated() {
                    // ★ 逐行按**模型名**识别厂商标（gpt-* → OpenAI、glm-* → Z.ai …），
                    //   识别不出时回退数据源自己的 logo，避免整列都是同一个标。
                    let brand = BrandMark.detect(in: m.modelName)
                    rows.append(ModelRowItem(
                        id: "\(snap.id)_model_\(i)",
                        assetName: brand?.assetName ?? snap.assetName,
                        symbolName: brand?.symbolName ?? snap.iconName,
                        name: m.modelName,
                        tokens: m.tokenAmount,
                        ratio: 0,
                        valueText: nil,
                        origin: snap.origin,
                        showsQuotaColumn: !isDSH
                    ))
                }
            } else if snap.sourceType == .api {
                // ★ 余额型 API（DeepSeek/Kimi）totalTokens 恒为 0（只有余额金额）→
                //   不再用 totalTokens > 0 过滤，否则卡片完全不可见（额度栏也只显示非 API 源）。
                //   余额文案放入**额度列**（token 列留白不补位）：
                //   已用完 → "已用完"；否则余额 > 0 → "¥88.50 left"。
                var valueText: String? = nil
                if snap.totalTokens == 0 {
                    let status = snap.resetTimeString
                    if !status.isEmpty, status != "Available" {
                        valueText = status   // "Used up"
                    } else if snap.totalCost > 0 {
                        let amount = String(format: "%.2f", snap.totalCost)
                        valueText = "\(currencySymbol(for: snap.currency))\(amount) left"
                    }
                }
                rows.append(ModelRowItem(
                    id: "\(snap.id)_provider",
                    assetName: snap.assetName ?? BrandMark.detect(in: snap.name)?.assetName,
                    symbolName: snap.iconName,
                    name: snap.name,
                    tokens: snap.totalTokens,
                    ratio: 0,
                    valueText: valueText,
                    origin: snap.origin
                ))
            }
        }
        rows.sort { $0.tokens > $1.tokens }
        let total = rows.reduce(0) { $0 + $1.tokens }
        for i in rows.indices {
            rows[i].ratio = total > 0 ? Double(rows[i].tokens) / Double(total) : 0
        }
        return rows
    }

    /// ★ 暴露给前端 UI — 模型板块「API 直连」子区块
    var directModelRows: [ModelRowItem] {
        modelRows.filter { $0.origin == .directAPI }
    }

    /// ★ 暴露给前端 UI — 模型板块「IDE 工具内」子区块
    var ideModelRows: [ModelRowItem] {
        modelRows.filter { $0.origin == .ideTool }
    }

    /// 货币符号映射（金额型行使用；有 token 用量的行走 tokenFormatted，不受影响）。
    /// ★ 数据源**没给币种**时（`code` 为空）才落到用户偏好 —— 偏好不做汇率换算。
    private func currencySymbol(for code: String) -> String {
        switch code.uppercased() {
        case "USD", "USDT": return "$"
        case "CNY":         return "¥"
        case "EUR":         return "€"
        case "GBP":         return "£"
        case "":            return AppSettingsStore.shared.currency.symbol
        default:            return "\(code.uppercased()) "
        }
    }

    // ---- ★ 刷新状态 ----
    /// ★ 暴露给前端 UI — 是否正在刷新（驱动加载指示器）
    @Published var isRefreshing: Bool = false

    /// 刷新进行中被吞掉的请求标记 — 当前刷新结束后自动补跑一次
    /// （修复：激活/取消激活触发的立即刷新在 isRefreshing 期间被 guard 丢弃的问题）
    private var needsRefresh = false

    /// ★ 暴露给前端 UI — 最后一次成功刷新时间
    @Published var lastRefreshTime: Date? = nil

    /// ★ 暴露给前端 UI — 刷新进度 (0~1)，用于环形进度条
    @Published var refreshProgress: Double = 0

    /// ★ 暴露给前端 UI — 上次刷新的错误信息（成功时清空）
    @Published var errorMessage: String? = nil

    // ============================================================
    // MARK: ★ 仓鼠状态机联动回调 ★
    // ============================================================

    /// ★ 暴露给前端 — 数据刷新成功时触发，让仓鼠做 happy/surprised
    var onDataUpdateSuccess: (() -> Void)?

    /// ★ 暴露给前端 — 数据刷新失败时触发，让仓鼠做 angry
    var onDataUpdateError: ((Error) -> Void)?

    /// ★ 暴露给前端 — 检测到 Token/额度提升时触发，让仓鼠做 happy/surprised
    var onTokenRecharge: (() -> Void)?

    /// ★ 暴露给前端 — 检测到 Token 消耗（聚合总量减少，即用户对话使用）时触发
    var onTokenUsage: (() -> Void)?

    // ============================================================
    // MARK: ★ 设置面板回调 ★
    // ============================================================

    /// ★ 暴露给前端 — 设置面板"关闭桌宠"按钮触发，由 AppDelegate 挂接 quitApp
    var onClosePet: (() -> Void)?

    // ============================================================
    // MARK: - 内部状态
    // ============================================================

    private var pollingTimer: Timer?
    /// 各数据源上次拉取的总量快照（id → totalTokens），用于按源语义检测消耗/充值。
    /// 内存态：重启后首次轮询建立基线，不产生消耗记录。
    private var previousSourceTokens: [String: Int] = [:]
    /// 各数据源上次拉取的「模型 → token」快照，用于汇总型源（无每日明细）的增量入账。
    /// 内存态：重启后首次见到该源建立基线，不产生增量。
    private var previousModelTokens: [String: [String: Int]] = [:]

    // ---- ★ 后端本地统计（热力图真实数据源） ----
    /// 本地累计的每日消耗记录 — 由每次轮询对比总量差值累加生成，持久化跨重启。
    /// 当 API 不返回每日历史时，这是热力图的真实数据来源。
    @Published private(set) var localDailyUsage: [DailyUsage] = []

    // ============================================================
    // MARK: ★ 所有模型总用量的本地账本（day / month / total + 软重置） ★
    // ============================================================

    /// ★ 暴露给前端 UI — 所有模型总用量的三维数据（汇总层只需这一个数字）
    @Published private(set) var totalTokenUsage = TokenTotals()

    /// ★ 暴露给前端 UI — 各「模型 × 来源通道」的用量明细（供两个子区块 + 单模型重置）
    @Published private(set) var modelTokenTotals: [ModelTokenTotals] = []

    /// 「模型 × 日期」账本 + 重置点（持久化）。
    /// ★ 与额度板块完全独立：只受手动重置截断，不受额度周期影响。
    private(set) var tokenLedger = ModelTokenLedger()

    // ============================================================
    // MARK: - 持久化存储
    // ============================================================

    /// 旧版 UserDefaults suite — 仅用于一次性迁移存量数据。
    /// 可通过 init(userDefaults:) 注入隔离存储（测试用）。
    private let userDefaults: UserDefaults
    /// 用量数据文件存储 — localDailyUsage / Dashboard 快照。
    /// 可通过 init(storage:) 注入隔离存储（测试用），默认 Application Support。
    private let storage: AppStoring

    /// ★ 小组件载荷的写入目录（widget 的沙箱容器）。
    /// - 生产：`WidgetSnapshotStore.defaultDirectory`
    /// - 测试宿主：默认 nil → 不写，免得把用户小组件的载荷换成 mock 数据；
    ///   测试要验证这条接线时显式注入临时目录。
    var widgetDirectory: URL? = WidgetSnapshotStore.defaultDirectory

    // ============================================================
    // MARK: - 初始化
    // ============================================================

    init(userDefaults: UserDefaults? = nil, storage: AppStoring? = nil) {
        self.userDefaults = userDefaults ?? (UserDefaults(suiteName: AppConstants.legacyUserDefaultsSuiteName) ?? .standard)
        self.storage = storage ?? FileAppStorage.default
        migrateLegacyUserDefaultsData()
        loadLocalUsage()
        loadTokenLedger()
        loadPersistedState()
        loadAPIConfigs()
        // 启动即算出一份三维总量，避免前端拿到空值直到首次刷新
        recomputeTokenTotals()
    }

    deinit {
        pollingTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // ============================================================
    // MARK: ★ 前端调用的核心方法 — 轮询 ★
    // ============================================================

    /// ★ 前端 UI 调用 — 启动定时轮询（默认使用已配置的 pollingInterval）
    func startPolling(interval: TimeInterval? = nil) {
        let effectiveInterval = interval ?? aggregatePollingInterval()
        stopPolling()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: effectiveInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                await self.performRefresh()
            }
        }
        RunLoop.current.add(pollingTimer!, forMode: .common)
        // ★ 启动立即拉取一次数据，但抑制成功回调——避免每次启动仓鼠都做开心/惊喜
        Task { await performRefresh(fireSuccessCallback: false) }
    }

    /// 聚合轮询间隔 — 取所有启用配置中最小的间隔（保证最短延迟刷新）
    private func aggregatePollingInterval() -> TimeInterval {
        let enabledIntervals = apiConfigs.filter { $0.isActive }.map { $0.pollingInterval }
        return enabledIntervals.min() ?? 300
    }

    /// ★ 前端 UI 调用 — 停止轮询
    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    // ============================================================
    // MARK: ★ 前端调用的核心方法 — 手动刷新 ★
    // ============================================================

    /// ★ 前端 UI 调用 — 点击"手动刷新"触发一次完整数据拉取
    func manualRefresh() async throws {
        await performRefresh()
    }

    /// ★ 设置面板切换语言后调用 —— 重新拉取一次，让**快照内**的文案
    ///   （重置文案、错误提示等抓取期产出）换成新语言。
    /// 抑制成功回调：切换语言不该触发仓鼠开心动画。
    func relocalizeSnapshots() {
        Task { await performRefresh(fireSuccessCallback: false) }
    }

    // ============================================================
    // MARK: ★ 前端调用的核心方法 — 设置面板 ★
    // ============================================================

    /// ★ 设置面板"关闭桌宠"按钮调用
    func closePet() {
        onClosePet?()
    }

    /// ★ 设置面板保存后调用 — 用最新的 pollingInterval 重启轮询
    func restartPolling() {
        startPolling()
    }

    /// 将 API 错误转为用户可读的中文文案
    private func friendlyError(_ error: Error) -> String {
        if let apiErr = error as? APIError {
            switch apiErr {
            case .invalidURL:
                return L("❌ Invalid endpoint URL")
            case .invalidResponse:
                return L("❌ The server returned an unexpected response")
            case .unauthorized:
                return L("❌ Invalid or unauthorized API key")
            case .httpError(let url, let code, let body):
                let preview = body.isEmpty ? "" : L("\nResponse body: %@", String(body.prefix(200)))
                if code == 404 {
                    return L("❌ Endpoint not found (404)\nRequest: %@%@\nHint: check that the protocol type is correct", url, preview)
                }
                return L("❌ Server error %@\nRequest: %@%@", code, url, preview)
            case .decodingError(let msg):
                return L("❌ Failed to parse data: %@", msg)
            case .missingKey(let key):
                return L("❌ Missing field in JSON: %@", key)
            case .networkError(let err):
                return L("❌ Network request failed: %@", err.localizedDescription)
            }
        }
        return L("❌ Unknown error: %@", error.localizedDescription)
    }

    /// 强制 HTTPS：如果用户输入 http://，升为 https://
    private func enforceHTTPS(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return trimmed }
        if components.scheme?.lowercased() == "http" {
            components.scheme = "https"
            // 保留 http 端口（如果有）
        }
        return components.string ?? trimmed
    }

    /// ★ 设置面板 — 添加 API 配置
    /// 新配置默认启用（多源聚合下可同时启用多个）
    func addAPIConfig(
        name: String,
        baseURL: String,
        apiKey: String,
        type: APIType,
        pollingInterval: TimeInterval = 300,
        customKeyPaths: [String: String] = [:],
        organizationId: String = "",
        copilotOrg: String = "",
        agentProvider: AgentProvider = .claudeCode,
        localLogPath: String = ""
    ) {
        let secureURL = enforceHTTPS(baseURL)
        let item = APIConfigItem(
            name: name,
            baseURL: secureURL,
            apiKey: apiKey,
            apiType: type,
            pollingInterval: pollingInterval,
            isActive: true,
            customKeyPaths: customKeyPaths,
            organizationId: organizationId,
            copilotOrg: copilotOrg,
            agentProvider: agentProvider,
            localLogPath: localLogPath
        )
        apiConfigs.append(item)
        saveAPIConfigs()
        restartPolling()
    }

    /// ★ 设置面板 — 删除 API 配置
    func deleteAPIConfig(id: String) {
        apiConfigs.removeAll { $0.id == id }
        saveAPIConfigs()
        restartPolling()
    }

    /// ★ 设置面板 — 切换配置的启用状态（可多选启用，勾选框点击）
    func activateAPIConfig(id: String) {
        guard let idx = apiConfigs.firstIndex(where: { $0.id == id }) else { return }
        // 整数组赋值（而非就地修改元素）：@Published 走标准 willSet 通知，
        // 避免就地修改 + 手动 send 在 ForEach 复用行等场景下 UI 不刷新的边缘情况。
        var updated = apiConfigs
        updated[idx].isActive.toggle()
        apiConfigs = updated
        saveAPIConfigs()
        restartPolling()
    }

    /// ★ 设置面板 — 编辑已有 API 配置
    func updateAPIConfig(
        id: String,
        name: String,
        baseURL: String,
        apiKey: String,
        type: APIType,
        pollingInterval: TimeInterval,
        customKeyPaths: [String: String] = [:],
        organizationId: String = "",
        copilotOrg: String = "",
        agentProvider: AgentProvider = .claudeCode,
        localLogPath: String = ""
    ) {
        guard let idx = apiConfigs.firstIndex(where: { $0.id == id }) else { return }
        let secureURL = enforceHTTPS(baseURL)
        apiConfigs[idx].name = name
        apiConfigs[idx].baseURL = secureURL
        apiConfigs[idx].apiKey = apiKey
        apiConfigs[idx].apiType = type
        apiConfigs[idx].pollingInterval = pollingInterval
        apiConfigs[idx].customKeyPaths = customKeyPaths
        apiConfigs[idx].organizationId = organizationId
        apiConfigs[idx].copilotOrg = copilotOrg
        apiConfigs[idx].agentProvider = agentProvider
        apiConfigs[idx].localLogPath = localLogPath
        if apiConfigs[idx].isActive { restartPolling() }
        saveAPIConfigs()
        // 就地修改不触发 @Published 通知 → 手动发送，编辑保存后列表立即刷新
        objectWillChange.send()
    }

    /// ★ 设置面板 — 更新 Custom 类型的 JSONPath 映射
    func updateAPIConfigKeyPaths(id: String, keyPaths: [String: String]) {
        guard let idx = apiConfigs.firstIndex(where: { $0.id == id }) else { return }
        apiConfigs[idx].customKeyPaths = keyPaths
        saveAPIConfigs()
        // 就地修改不触发 @Published 通知 → 手动发送，编辑保存后列表立即刷新
        objectWillChange.send()
    }

    // ============================================================
    // MARK: ★ 兼容旧 DashboardView 的方法 ★
    // ============================================================

    func fetchDashboard() async {
        await performRefresh()
    }

    func selectRange(_ range: TimeRange) {
        selectedRange = range
        // 延迟到下一个 run loop 避免 "Publishing changes during view update"
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Task { await self.performRefresh() }
        }
    }

    // ============================================================
    // MARK: - 后端本地统计（热力图真实数据源）
    // ============================================================

    /// 加载本地累计的每日消耗记录
    private func loadLocalUsage() {
        if let saved: [DailyUsage] = storage.load([DailyUsage].self, forKey: AppConstants.localUsageKey) {
            localDailyUsage = saved
        }
    }

    /// 持久化本地累计的每日消耗记录
    private func saveLocalUsage() {
        storage.save(localDailyUsage, forKey: AppConstants.localUsageKey)
    }

    // ============================================================
    // MARK: - ★ Token 账本（所有模型总用量 + 三维度 + 软重置）
    // ============================================================

    /// 加载本地账本
    private func loadTokenLedger() {
        if let saved: ModelTokenLedger = storage.load(ModelTokenLedger.self, forKey: AppConstants.modelTokenLedgerKey) {
            tokenLedger = saved
        }
    }

    /// 持久化账本
    private func saveTokenLedger() {
        storage.save(tokenLedger, forKey: AppConstants.modelTokenLedgerKey)
    }

    /// 把本轮各数据源的用量写入账本。
    /// ★ 三种源的写法不同，取决于它能否给出「带日期的明细」：
    /// 1. 有 modelDailyTokens（本地日志 / OpenAI 每日历史）→ **覆盖式 upsert**（幂等，重扫不翻倍）
    /// 2. 只有 modelUsages（汇总型，但带模型明细）→ 按模型**增量累加**到当天
    /// 3. 只有 totalTokens（无模型明细，如 Anthropic org / Copilot）→ 以来源名作为一行增量累加
    private func ingestTokenLedger(from snapshots: [AgentSnapshot]) {
        let calendar = Calendar.current
        let todayKey = tokenDayKey(for: Date(), calendar: calendar)

        for snap in snapshots where snap.status == .ok {
            if !snap.modelDailyTokens.isEmpty {
                // ── 1. 明细型：覆盖式（取 max），重复扫描幂等 ──
                for item in snap.modelDailyTokens {
                    tokenLedger.upsert(
                        sourceID: snap.id,
                        model: item.modelName,
                        dayKey: tokenDayKey(for: item.date, calendar: calendar),
                        value: item.tokens
                    )
                }
                previousModelTokens[snap.id] = Dictionary(
                    uniqueKeysWithValues: snap.modelUsages.map { ($0.modelName, $0.tokenAmount) }
                )
            } else if !snap.modelUsages.isEmpty {
                // ── 2. 汇总型 + 有模型明细：按模型增量累加 ──
                var current: [String: Int] = [:]
                for item in snap.modelUsages { current[item.modelName] = item.tokenAmount }
                let previous = previousModelTokens[snap.id] ?? [:]
                for (model, amount) in current {
                    // 首次见到该模型 → 建立基线，不补记历史增量
                    let before = previous[model] ?? amount
                    tokenLedger.accumulate(
                        sourceID: snap.id, model: model,
                        dayKey: todayKey, delta: amount - before
                    )
                }
                previousModelTokens[snap.id] = current
            } else if snap.totalTokens > 0 {
                // ── 3. 汇总型 + 无模型明细：以来源名作为一行 ──
                let model = snap.name
                let before = previousModelTokens[snap.id]?[model] ?? snap.totalTokens
                tokenLedger.accumulate(
                    sourceID: snap.id, model: model,
                    dayKey: todayKey, delta: snap.totalTokens - before
                )
                previousModelTokens[snap.id] = [model: snap.totalTokens]
            }
        }
    }

    /// 重算对外暴露的三维总量与模型明细
    private func recomputeTokenTotals() {
        let origins = Dictionary(uniqueKeysWithValues: agentSnapshots.map { ($0.id, $0.origin) })
        totalTokenUsage = tokenLedger.allTotals()
        modelTokenTotals = tokenLedger.modelTotals(originBySource: origins)
    }

    /// ★ 前端 UI 调用 — 重置单个模型的总用量（只影响该模型，与额度板块无关）
    func resetModelTokenUsage(_ modelName: String) {
        tokenLedger.resetModel(modelName)
        saveTokenLedger()
        recomputeTokenTotals()
    }

    /// ★ 前端 UI 调用 — 重置所有模型的总用量
    func resetAllTokenUsage() {
        tokenLedger.resetAll()
        saveTokenLedger()
        recomputeTokenTotals()
    }

    /// ★ 前端 UI 调用 — 撤销某模型的重置标记（保留数据，恢复正常累计）
    func clearModelTokenReset(_ modelName: String) {
        tokenLedger.clearReset(for: modelName)
        saveTokenLedger()
        recomputeTokenTotals()
    }

    /// 某模型是否已被独立重置过
    func hasTokenReset(for modelName: String) -> Bool {
        tokenLedger.modelResets[modelName] != nil
    }

    /// 将两次刷新之间的消耗量累加到当天（后端统计核心）。
    /// `delta` > 0 表示消耗（总量减少）；<= 0 表示充值/持平，跳过。
    private func accumulateLocalUsage(delta: Int) {
        guard delta > 0 else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // 当天已有记录则累加，否则新建
        if let idx = localDailyUsage.firstIndex(where: { calendar.startOfDay(for: $0.date) == today }) {
            localDailyUsage[idx].tokenCount += delta
        } else {
            localDailyUsage.append(DailyUsage(date: today, tokenCount: delta, level: 0))
        }
        saveLocalUsage()
    }

    /// 把 7 天趋势映射为最近 7 天的 DailyUsage（当 API 不返回每日历史时兜底）。
    private func dailyUsageFromTrend(_ trend: [Int]) -> [DailyUsage] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let count = trend.count
        guard count > 0 else { return [] }
        let maxVal = max(trend.max() ?? 0, 1)
        return trend.enumerated().compactMap { i, tokens in
            guard let date = calendar.date(byAdding: .day, value: i - (count - 1), to: today) else { return nil }
            return DailyUsage(
                date: date,
                tokenCount: tokens,
                level: level(fromCount: tokens, max: maxVal)
            )
        }
    }

    /// 三层合并热力图：API 返回的历史（优先）⊕ 本地累计统计（兜底）⊕ 7 天趋势兜底。
    /// API 有数据的天以 API 为准，避免与本地增量统计叠加双倍计数；重算 level。
    func mergeHeatmapSources(
        apiHeatmap: [DailyUsage],
        trend: [Int],
        local: [DailyUsage]
    ) -> [DailyUsage] {
        // API 返回的真实每日总量最可靠 → 优先（覆盖本地统计，避免同一天叠加双倍）
        var dayDict: [String: (date: Date, count: Int)] = [:]
        for usage in apiHeatmap {
            let key = "\(Int(usage.date.timeIntervalSince1970 / 86_400))"
            dayDict[key] = (usage.date, usage.tokenCount)
        }

        // 本地累计统计（增量消耗）→ 仅当 API 无该天数据时兜底
        for usage in local {
            let key = "\(Int(usage.date.timeIntervalSince1970 / 86_400))"
            if dayDict[key] == nil {
                dayDict[key] = (usage.date, usage.tokenCount)
            }
        }

        // 7 天趋势兜底：只在某天没有数据时填充（不重复累加趋势）
        let trendUsages = dailyUsageFromTrend(trend)
        for usage in trendUsages {
            let key = "\(Int(usage.date.timeIntervalSince1970 / 86_400))"
            if dayDict[key] == nil {
                dayDict[key] = (usage.date, usage.tokenCount)
            }
        }

        let maxDayCount = max(dayDict.values.map { $0.count }.max() ?? 0, 1)
        return dayDict.values.map { date, count in
            DailyUsage(
                date: date,
                tokenCount: count,
                level: level(fromCount: count, max: maxDayCount)
            )
        }
    }

    /// 构造本地 / Agent 类数据源 — 按 `AgentProvider` 注册表分发。
    /// ★ 只构造「已接入」的源；未接入的 provider 一律返回 `UnavailableAgentSource`，
    ///   不去探测用户机器上可能不存在的路径。
    private func buildLocalAgentSource(for config: APIConfigItem) -> AgentDataSource {
        let spec = config.agentProvider.spec
        switch spec.kind {
        case .claudeCodeLog:
            return LocalLogSource(
                id: config.id, name: config.name,
                iconName: iconName(for: config.apiType), assetName: spec.assetName,
                kind: .claudeCode
            )
        case .codexLog:
            return LocalLogSource(
                id: config.id, name: config.name,
                iconName: iconName(for: config.apiType), assetName: spec.assetName,
                kind: .codex
            )
        case .customPath:
            return LocalLogSource(
                id: config.id, name: config.name,
                iconName: iconName(for: config.apiType), assetName: spec.assetName,
                kind: .customPath, customPath: config.localLogPath
            )
        case .cursorWeb:
            // Cursor：cookie 存在 apiKey 字段（随配置进 Keychain）
            return CursorSource(
                id: config.id, name: config.name,
                iconName: spec.symbolName, assetName: spec.assetName,
                rawCookie: config.apiKey
            )
        case .dshUsageStats:
            // DeepSeek Harness：读 dsh-usage-stats 插件的落盘缓存
            return DSHUsageStatsSource(
                id: config.id, name: config.name,
                iconName: spec.symbolName, assetName: spec.assetName
            )
        case .zaiPlan:
            // Z.ai Coding Plan：只读官方 API（额度 + 模型用量；国内站另有账户余额）。
            // ★ Key 必需 —— 没 Key 就拿不到任何数据（不再读本地账本）。
            //   历史落盘在 `storage` 里（同日期取 max）→ 热力图可超过官方 30 天上限。
            //   老配置的 baseURL 为空 → 默认按构建分区（国际站 api.z.ai / 国内站 open.bigmodel.cn）。
            let zaiHost = config.baseURL.trimmingCharacters(in: .whitespaces).isEmpty
                ? ZaiRegion.global.defaultBaseURL
                : config.baseURL
            guard let fetcher = ZaiPlanQuotaFetcher(
                rawBaseURL: zaiHost, apiKey: config.apiKey
            ) else {
                // 未填 Key / 地址非法 → 明确报错，不静默给一张空卡
                return UnavailableAgentSource(
                    id: config.id, name: config.name,
                    iconName: spec.symbolName, assetName: spec.assetName,
                    reason: L("Enter a Coding Plan API key (required by the official usage API)")
                )
            }
            return ZaiPlanSource(
                id: config.id, name: config.name,
                iconName: spec.symbolName, assetName: spec.assetName,
                fetcher: fetcher,
                region: ZaiRegion.detect(base: zaiHost),
                storage: storage
            )
        }
    }

    // ============================================================
    // MARK: - 核心刷新逻辑（多源聚合）
    // ============================================================

    /// 构建所有启用的数据源 — 每个启用的 API 配置 = 一个数据源
    private func buildDataSources() -> [AgentDataSource] {
        apiConfigs
            .filter { $0.isActive }
            .map { config in
                // 本地 / Agent 类源：按 AgentProvider 注册表分发
                if config.apiType == .localLog {
                    return buildLocalAgentSource(for: config)
                }
                // GitHub Copilot 订阅源：org 用量 API
                if config.apiType == .copilot {
                    return SubscriptionSource(
                        id: config.id,
                        name: config.name,
                        iconName: iconName(for: config.apiType),
                        assetName: config.apiType.brandAssetName,
                        kind: .copilot,
                        token: config.apiKey,
                        org: config.copilotOrg
                    )
                }
                let service = APIServiceFactory.create(
                    type: config.apiType,
                    baseURL: config.baseURL,
                    apiKey: config.apiKey,
                    keyPathMap: config.customKeyPaths,
                    organizationId: config.organizationId
                )
                return APISource(
                    id: config.id,
                    name: config.name,
                    iconName: iconName(for: config.apiType),
                    // ★ 自定义（OpenAI 兼容）源没有品牌图 → 退一步按用户起的名猜厂商标，
                    //   例如名称里带 "Qwen" / "Grok" 也能拿到 logo，猜不出才回退 SF Symbol。
                    assetName: config.apiType.brandAssetName ?? BrandMark.detect(in: config.name)?.assetName,
                    service: service
                )
            }
    }

    /// 根据 API 协议类型映射 SF Symbol 图标（品牌图映射见 APIType.brandAssetName）
    private func iconName(for type: APIType) -> String {
        type.brandSymbolName
    }

    /// 若刷新期间有被吞掉的刷新请求（needsRefresh 已置位），在此补跑一次。
    /// 补跑前先重置标记，因此不会再次触发、不会形成循环。
    private func scheduleCatchUpRefresh() {
        guard needsRefresh else { return }
        needsRefresh = false
        Task { @MainActor in
            await self.performRefresh(fireSuccessCallback: false)
        }
    }

    /// 并行拉取所有启用的数据源，产出聚合结果
    /// - Parameter fireSuccessCallback: 是否触发 onDataUpdateSuccess（启动静默拉取传 false）
    private func performRefresh(fireSuccessCallback: Bool = true) async {
        guard !isRefreshing else {
            needsRefresh = true   // 刷新进行中 → 排队补刷，不丢弃本次请求
            return
        }

        let sources = buildDataSources()

        // 所有现存配置的 id（含停用）— 用于区分"已删除"与"已停用"：
        // 停用配置的旧快照应保留（置灰卡片，可重新激活），已删除配置的快照应移除。
        let existingIDs = Set(apiConfigs.map { $0.id })

        // 无启用的数据源 → 保留停用源的旧快照（卡片仍在，可重新激活），聚合清空；
        // 已删除配置的快照同步移除（防止"全删后刷新"仍残留卡片）。
        guard !sources.isEmpty else {
            agentSnapshots = agentSnapshots.filter { existingIDs.contains($0.id) }
            for i in agentSnapshots.indices {
                agentSnapshots[i].status = .stale
            }
            previousSourceTokens = previousSourceTokens.filter { existingIDs.contains($0.key) }
            previousModelTokens = previousModelTokens.filter { existingIDs.contains($0.key) }
            aggregated = AggregatedDashboard()
            // 账本数据保留（与额度周期无关），但需按最新快照重算对外视图
            recomputeTokenTotals()
            isRefreshing = false
            isLoading = false
            refreshProgress = 0
            syncWidgetSnapshot()   // 全空/全停用 → 小组件回到空态
            scheduleCatchUpRefresh()
            return
        }

        isRefreshing = true
        isLoading = true
        refreshProgress = 0.15   // 发起请求阶段

        // ── 防御看门狗 ──
        // 所有源均有内置超时（网络 30s / codex RPC 15s），正常不会卡死；
        // 此处兜底：90s 后强制复位刷新状态，保证停用/重新激活的刷新永不被永久吞掉。
        let refreshHardReset = Task { @MainActor in
            try? await Task.sleep(for: .seconds(90))
            if self.isRefreshing {
                self.isRefreshing = false
                self.isLoading = false
            }
        }
        defer { refreshHardReset.cancel() }

        // ── 并行拉取所有源 ──
        var results: [(id: String, snapshot: AgentSnapshot?, error: String)] = []
        await withTaskGroup(of: (String, AgentSnapshot?, String).self) { group in
            for source in sources {
                // 在 MainActor 上下文先取出 id，避免在 @Sendable 闭包内访问隔离属性
                let sourceID = source.id
                group.addTask {
                    do {
                        let snap = try await source.fetchSnapshot()
                        return (sourceID, snap, "")
                    } catch {
                        return (sourceID, nil, error.localizedDescription)
                    }
                }
            }
            var completed = 0
            let total = sources.count
            for await item in group {
                results.append(item)
                completed += 1
                // 真实进度：按已完成的源数推进（0.2 → 0.9）
                refreshProgress = 0.2 + 0.7 * Double(completed) / Double(total)
            }
        }

        // ── 合并结果：错误源保留旧快照并标记 error，未知源新建 error 快照 ──
        var merged: [AgentSnapshot] = []
        for (id, snapshot, err) in results {
            if var snap = snapshot {
                snap.errorMessage = err
                merged.append(snap)
            } else if let old = agentSnapshots.first(where: { $0.id == id }) {
                var stale = old
                stale.status = .error
                stale.errorMessage = err
                stale.lastUpdated = Date()
                merged.append(stale)
            } else {
                let sourceInfo = sources.first(where: { $0.id == id })
                merged.append(AgentSnapshot(
                    id: id,
                    name: sourceInfo?.name ?? L("Unknown source"),
                    iconName: "exclamationmark.triangle.fill",
                    sourceType: sourceInfo?.sourceType ?? .api,
                    status: .error,
                    errorMessage: err
                ))
            }
        }

        // 排序：正常源在前，错误源在后
        var finalSnapshots = merged.sorted {
            ($0.status == .ok ? 0 : 1) < ($1.status == .ok ? 0 : 1)
        }

        // ── 保留已停用配置的旧快照 ──
        // 停用 ≠ 删除：卡片仍显示（置灰），保留上次数据作为重新激活的入口。
        // 已删除（existingIDs 中不存在）的配置快照不再保留，卡片/模型行随刷新移除。
        // 聚合（TOTAL/成本/活跃源数）只用启用源（merged），停用源不计入。
        let activeIDs = Set(apiConfigs.filter { $0.isActive }.map { $0.id })
        for old in agentSnapshots
            where existingIDs.contains(old.id)
                && !activeIDs.contains(old.id)
                && !finalSnapshots.contains(where: { $0.id == old.id }) {
            var stale = old
            stale.status = .stale
            stale.errorMessage = ""
            finalSnapshots.append(stale)
        }
        // 内存卫生：清除已删除源的基线快照，避免残留引用
        previousSourceTokens = previousSourceTokens.filter { existingIDs.contains($0.key) }
        previousModelTokens = previousModelTokens.filter { existingIDs.contains($0.key) }
        agentSnapshots = finalSnapshots

        // ── 汇总 ──
        var agg = AggregatedDashboard()
        agg.snapshots = agentSnapshots
        agg.totalTokens = merged.reduce(0) { $0 + $1.totalTokens }
        agg.totalCost = merged.reduce(0) { $0 + $1.totalCost }
        agg.costCurrency = merged.first(where: { !$0.currency.isEmpty })?.currency ?? preferredCurrencyCode
        agg.activeSourceCount = merged.filter { $0.status == .ok }.count
        agg.lastUpdated = Date()
        aggregated = agg

        // ── 用量检测（按源语义分别检测） ──
        // 累计型（OpenAI/Claude/Copilot/本地日志）：总量单调递增，本次 > 上次 = 消耗
        // 余额型（DeepSeek）：余额减少 = 消耗，余额增加 = 充值
        let semanticsByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.semantics) })
        var consumedDelta = 0
        var detectedConsumption = false
        var detectedRecharge = false

        for snap in merged where snap.status == .ok {
            guard let prev = previousSourceTokens[snap.id] else {
                // 首次见到该源：建立基线，不产生消耗记录
                previousSourceTokens[snap.id] = snap.totalTokens
                continue
            }
            let delta = snap.totalTokens - prev
            previousSourceTokens[snap.id] = snap.totalTokens
            switch semanticsByID[snap.id] ?? .cumulative {
            case .cumulative:
                if delta > 0 { consumedDelta += delta; detectedConsumption = true }
            case .balance:
                if delta < 0 { consumedDelta += -delta; detectedConsumption = true }
                else if delta > 0 { detectedRecharge = true }
            }
        }

        // ── ★ 后端统计：把本次消耗差值累加到本地每日记录 ──
        if consumedDelta > 0 {
            accumulateLocalUsage(delta: consumedDelta)
        }

        // ── ★ Token 账本：按模型入账（明细型覆盖 / 汇总型增量），再重算三维总量 ──
        ingestTokenLedger(from: merged)
        saveTokenLedger()
        recomputeTokenTotals()

        // ── 兼容旧 UI：聚合所有正常源的数据映射到旧字段 + 本地快照持久化 ──
        let okSnapshots = merged.filter { $0.status == .ok }
        if let firstOK = okSnapshots.first {
            applyAggregatedToLegacyFields(okSnapshots)
            saveDashboardSnapshot(dashboardData(from: firstOK))
        }

        lastRefreshTime = Date()
        lastUpdated = Date()
        refreshProgress = 1.0
        errorMessage = nil

        // 延迟回调，避免回调内修改 @Published 与当前刷新冲突
        DispatchQueue.main.async { [weak self] in
            if fireSuccessCallback {
                self?.onDataUpdateSuccess?()
            }
            if detectedRecharge {
                self?.onTokenRecharge?()
            } else if detectedConsumption {
                self?.onTokenUsage?()
            }
        }

        isRefreshing = false
        isLoading = false

        // ★ 快照已定型 → 同步给小组件（写完会要求 WidgetKit 刷新时间线）
        syncWidgetSnapshot()

        // 刷新期间被吞掉的请求（如激活/取消激活触发的立即刷新）在此补跑
        scheduleCatchUpRefresh()
    }

    /// 将单个快照映射到旧版 @Published 字段（兼容现有 DashboardView）
    private func applySnapshotToLegacyFields(_ snap: AgentSnapshot) {
        totalTokens = snap.totalTokens
        totalCost = snap.totalCost
        totalCostYuan = snap.totalCost
        costCurrency = snap.currency
        activeDays = snap.activityDays
        quotas = []
        quotaList = []
        modelUsages = snap.modelUsages
        models = snap.modelUsages.map { item in
            ModelItem(id: item.id, name: item.modelName, tokens: item.tokenAmount, ratio: item.usagePercent)
        }
        sevenDayTrend = snap.sevenDayTrend
        trendData = snap.sevenDayTrend.map { Double($0) }
        if let maxVal = trendData.max(), maxVal > 0 {
            peakValue = maxVal
        }
        dailyHeatmap = mergeHeatmapSources(
            apiHeatmap: snap.dailyHeatmap,
            trend: snap.sevenDayTrend,
            local: localDailyUsage
        )
        heatmapData = convertDailyUsageToHeatmap(dailyHeatmap)
    }

    /// 将多个正常源的数据**聚合**映射到旧版 @Published 字段：
    /// 模型合并（同名累加）、趋势按天累加、热力图按天累加。
    private func applyAggregatedToLegacyFields(_ snapshots: [AgentSnapshot]) {
        guard !snapshots.isEmpty else { return }

        // 模型：同名模型合并累加 tokenAmount
        var modelDict: [String: Int] = [:]
        for snap in snapshots {
            for item in snap.modelUsages {
                modelDict[item.modelName, default: 0] += item.tokenAmount
            }
        }
        let totalTokensAll = modelDict.values.reduce(0, +)
        let mergedModels: [ModelUsageItem] = modelDict
            .map { name, amount in
                ModelUsageItem(
                    id: name,
                    modelName: name,
                    tokenAmount: amount,
                    usagePercent: totalTokensAll > 0 ? Double(amount) / Double(totalTokensAll) : 0
                )
            }
            .sorted { $0.tokenAmount > $1.tokenAmount }

        // 趋势：按天下标累加（取最长长度）
        let trendCount = snapshots.map { $0.sevenDayTrend.count }.max() ?? 7
        var mergedTrend = Array(repeating: 0, count: trendCount)
        for snap in snapshots {
            for (i, v) in snap.sevenDayTrend.enumerated() where i < trendCount {
                mergedTrend[i] += v
            }
        }

        // ── ★ 热力图：三层合并（API 历史 ⊕ 7 天趋势兜底 ⊕ 本地统计） ──
        let apiHeatmap = snapshots.flatMap { $0.dailyHeatmap }
        let mergedHeatmap = mergeHeatmapSources(
            apiHeatmap: apiHeatmap,
            trend: mergedTrend,
            local: localDailyUsage
        )

        // 总量
        totalTokens = snapshots.reduce(0) { $0 + $1.totalTokens }
        totalCost = snapshots.reduce(0) { $0 + $1.totalCost }
        totalCostYuan = totalCost
        costCurrency = snapshots.first(where: { !$0.currency.isEmpty })?.currency ?? preferredCurrencyCode
        activeDays = snapshots.reduce(0) { $0 + $1.activityDays }

        // 旧字段映射
        quotas = []
        quotaList = []
        modelUsages = mergedModels
        models = mergedModels.map { item in
            ModelItem(id: item.id, name: item.modelName, tokens: item.tokenAmount, ratio: item.usagePercent)
        }
        sevenDayTrend = mergedTrend
        trendData = mergedTrend.map { Double($0) }
        if let maxVal = trendData.max(), maxVal > 0 {
            peakValue = maxVal
        }
        dailyHeatmap = mergedHeatmap
        heatmapData = convertDailyUsageToHeatmap(mergedHeatmap)
    }

    /// 按数量映射热力图等级 (0~4)
    private func level(fromCount count: Int, max: Int) -> Int {
        guard count > 0, max > 0 else { return 0 }
        let ratio = Double(count) / Double(max)
        if ratio <= 0.25 { return 1 }
        if ratio <= 0.5  { return 2 }
        if ratio <= 0.75 { return 3 }
        return 4
    }

    /// 将快照转换为旧版 DashboardData（用于 iCloud 同步兼容）
    private func dashboardData(from snap: AgentSnapshot) -> DashboardData {
        DashboardData(
            totalTokens: snap.totalTokens,
            totalCost: snap.totalCost,
            costCurrency: snap.currency,
            quotas: [],
            modelUsages: snap.modelUsages,
            sevenDayTrend: snap.sevenDayTrend,
            dailyHeatmap: snap.dailyHeatmap,
            activityDays: snap.activityDays
        )
    }

    /// 将 DashboardData 映射到 @Published 变量
    private func applyDashboardData(_ data: DashboardData) {
        totalTokens = data.totalTokens
        totalCost = data.totalCost
        totalCostYuan = data.totalCost
        costCurrency = data.costCurrency
        activeDays = data.activityDays
        quotas = data.quotas
        quotaList = data.quotas
        modelUsages = data.modelUsages
        models = data.modelUsages.map { item in
            ModelItem(id: item.id, name: item.modelName, tokens: item.tokenAmount, ratio: item.usagePercent)
        }
        sevenDayTrend = data.sevenDayTrend
        trendData = data.sevenDayTrend.map { Double($0) }
        if let maxVal = trendData.max(), maxVal > 0 {
            peakValue = maxVal
        }
        dailyHeatmap = mergeHeatmapSources(
            apiHeatmap: data.dailyHeatmap,
            trend: data.sevenDayTrend,
            local: localDailyUsage
        )
        heatmapData = convertDailyUsageToHeatmap(dailyHeatmap)
    }

    /// 将 [DailyUsage] 转换为 GitHub 风格热力图 [[Int]]
    /// 7 行（周一~周日）× weeks 列（最近 weeks 周），无数据的格子为 0
    func convertDailyUsageToHeatmap(_ usages: [DailyUsage], weeks: Int? = nil) -> [[Int]] {
        guard !usages.isEmpty else { return [] }
        let weekCount = weeks ?? appearance.heatmapWeeks
        let calendar = Calendar.current
        let levels: [Date: Int] = Dictionary(uniqueKeysWithValues: usages.map { (calendar.startOfDay(for: $0.date), $0.level) })

        var rows: [[Int]] = Array(repeating: Array(repeating: 0, count: weekCount), count: 7)
        // 本周周一作为最后一列起点，向前铺满 weekCount 周
        guard let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start else { return rows }
        for col in 0..<weekCount {
            guard let weekStart = calendar.date(byAdding: .weekOfYear, value: col - (weekCount - 1), to: thisWeekStart) else { continue }
            for day in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: day, to: weekStart) else { continue }
                rows[day][col] = levels[date] ?? 0
            }
        }
        return rows
    }

    /// 热力图某一格对应的日期（行=星期 0~6，列=第几周，从最老的一周开始）。
    /// 与 `convertDailyUsageToHeatmap` 使用同一套"本周周一为最后一列"的铺排逻辑，
    /// 供悬停浮层取日期使用，避免两处逻辑漂移。
    func heatmapDate(row: Int, column: Int, weeks: Int? = nil) -> Date? {
        let weekCount = weeks ?? appearance.heatmapWeeks
        let calendar = Calendar.current
        guard row >= 0, row < 7, column >= 0, column < weekCount,
              let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start,
              let weekStart = calendar.date(byAdding: .weekOfYear, value: column - (weekCount - 1), to: thisWeekStart) else {
            return nil
        }
        return calendar.date(byAdding: .day, value: row, to: weekStart)
    }

    // ============================================================
    // MARK: - 本地快照持久化
    // ============================================================

    /// 持久化 Dashboard 快照到本地文件（跨重启恢复上次数据）
    private func saveDashboardSnapshot(_ data: DashboardData) {
        storage.save(data, forKey: AppConstants.lastDataKey)
    }

    private func loadPersistedState() {
        if let dashboardData: DashboardData = storage.load(DashboardData.self, forKey: AppConstants.lastDataKey) {
            applyDashboardData(dashboardData)
        }
    }

    // ============================================================
    // MARK: - 存量数据迁移（旧 UserDefaults suite → 文件存储）
    // ============================================================

    /// 将旧版 UserDefaults suite（group.com.tokenhamster）中的存量数据
    /// 一次性迁移到文件存储，然后清理旧数据。
    /// 目标文件已有数据时不覆盖（迁移只做一次）。
    private func migrateLegacyUserDefaultsData() {
        // localDailyUsage
        if let data = userDefaults.data(forKey: AppConstants.localUsageKey),
           let saved = try? JSONDecoder().decode([DailyUsage].self, from: data) {
            if storage.load([DailyUsage].self, forKey: AppConstants.localUsageKey) == nil {
                storage.save(saved, forKey: AppConstants.localUsageKey)
            }
            userDefaults.removeObject(forKey: AppConstants.localUsageKey)
        }
    }

    // ============================================================
    // MARK: - Widget 数据写入
    // ============================================================

    /// ★ 把当前额度快照写入 widget 的沙箱容器，供小组件读取（见 `WidgetBridge.swift`）。
    /// 只在**刷新收尾**调用：每次 `agentSnapshots` 定型后写一份，
    /// 停用/删除/全空这些分支也写（让小组件回到空态，而不是留着过期数据）。
    private func syncWidgetSnapshot() {
        WidgetSnapshotStore.write(
            WidgetPayloadBuilder.build(from: agentSnapshots),
            to: widgetDirectory
        )
    }

    /// 保存 API 配置 —— ★ 存文件存储（Application Support），**不再用钥匙串**。
    /// 原因见 `FileAppStorage` 顶部注释：ad-hoc 签名每次重编译都会让钥匙串条目 ACL 失配，
    /// 导致每次启动/保存都弹系统授权框。
    private func saveAPIConfigs() {
        if apiConfigs.isEmpty {
            storage.delete(forKey: AppConstants.apiConfigsKey)
        } else {
            storage.save(apiConfigs, forKey: AppConstants.apiConfigsKey)
        }
    }

    private func loadAPIConfigs() {
        // 1) 文件存储（当前主存储）
        if let saved: [APIConfigItem] = storage.load([APIConfigItem].self, forKey: AppConstants.apiConfigsKey) {
            apiConfigs = saved
            return
        }
        // 2) 兼容旧版：从 UserDefaults 迁移
        if let data = userDefaults.data(forKey: AppConstants.apiConfigsKey),
           let saved = try? JSONDecoder().decode([APIConfigItem].self, from: data) {
            apiConfigs = saved
            saveAPIConfigs()
            userDefaults.removeObject(forKey: AppConstants.apiConfigsKey)
            return
        }
        // 3) 钥匙串：★ **不读**。
        //    历史版本把配置存在钥匙串里，但读它会弹系统授权框（ad-hoc 签名 ACL 失配，
        //    且“始终允许”记不住），启动即弹、输密码也关不掉。详见 KeychainCredentials.swift 顶部说明。
        //    ⚠️ 曾经的“从钥匙串导入配置”入口已按用户要求移除 → 旧钥匙串里的配置不再可恢复。
    }
}
