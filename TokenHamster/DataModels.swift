//
//  DataModels.swift
//  TokenHamster
//
//  后端数据模型定义 — 所有结构体、枚举、持久化配置
//  由 DashboardViewModel 驱动，供前端 UI 层消费
//

import Foundation

// ============================================================
// MARK: - API 类型枚举
// ============================================================

/// 用户可选的 API 协议类型。
/// ★ 暴露给前端 UI — 设置面板用此枚举渲染选项列表
///
/// ★ 历史上还有个 `.openAICompatible`（OneAPI/NewAPI 的 `/dashboard/billing` 中转网关）。
///   已于 2026-09-25 **整个类型连同服务一起删除** —— 它读的是一次性结算的
///   `hard_limit_usd − total_usage`，与同名的 `.openAI`（官方组织用量 API）高度混淆，
///   而中转网关的余额用 `.custom` + 字段映射同样能读，无需独立类型。
///   旧存档里的 `"openAICompatible"` 由 `APIConfigItem.init(from:)` 宽容解码为 `.custom`。
enum APIType: String, CaseIterable, Identifiable, Codable {
    case openAI       // OpenAI 官方组织用量 API
    case deepseek     // DeepSeek 余额查询
    case anthropic    // Anthropic Claude
    case gemini       // Google Gemini
    case kimi         // Kimi (Moonshot) 余额查询
    case openRouter   // OpenRouter 余额（/api/v1/key）
    case siliconFlow  // 硅基流动余额（/v1/user/info）
    case custom       // 自定义 JSON 接口
    case copilot      // GitHub Copilot（org 用量 API）
    case localLog     // 本地 CLI Agent 日志（Claude Code / Codex）

    var id: String { rawValue }

    /// ★ 暴露给前端 UI — 设置面板显示名称
    var displayName: String {
        switch self {
        case .openAI:           return "OpenAI"
        case .deepseek:         return "DeepSeek"
        case .anthropic:        return "Anthropic Claude"
        case .gemini:           return "Google Gemini"
        case .kimi:             return "Moonshot Kimi"
        case .openRouter:       return "OpenRouter"
        case .siliconFlow:      return L("SiliconFlow")
        case .custom:           return L("Custom")
        case .copilot:          return "GitHub Copilot"
        case .localLog:         return L("Local CLI")
        }
    }
}

// ============================================================
// MARK: - 本地 Agent / 订阅工具类型（Provider 注册表）
// ============================================================

/// 数据源实现类型 — `buildDataSources()` 据此分发到具体数据源。
enum AgentProviderKind: String, Codable {
    case claudeCodeLog   // 本地 ~/.claude/projects/**/*.jsonl + 官方 OAuth 额度
    case codexLog        // 本地 ~/.codex/sessions/**/*.jsonl + 官方 RPC/Web 额度
    case cursorWeb       // cursor.com/api/usage（需用户粘贴 cookie）
    case dshUsageStats   // 读 dsh-usage-stats 插件缓存（$DSH_HOME/storages/usage-stats-cache.json）
    case zaiPlan         // Z.ai Coding Plan 官方 API（需 Coding Plan Key）
    case customPath      // 用户自定路径的 jsonl
}

/// 本地 Agent / 订阅工具类型 — 取代原先散落的 `localLogKind` 字符串。
/// ★ 暴露给前端 UI — 预设选择与凭据表单按此渲染
enum AgentProvider: String, Codable, CaseIterable, Identifiable {
    case claudeCode
    case codex
    case cursor
    case dsh
    case zcode
    case customPath

    var id: String { rawValue }

    /// 能力规格（本枚举即注册表，避免额外一层查表）
    var spec: AgentProviderSpec { AgentProviderSpec.spec(for: self) }
}

/// Provider 能力规格 — `buildDataSources()` 与设置页共用。
struct AgentProviderSpec: Equatable {
    let provider: AgentProvider
    let displayName: String
    let symbolName: String        // SF Symbol 回退
    let assetName: String?        // 品牌资源图（ProviderIcons/ 下的文件名）
    let kind: AgentProviderKind   // 数据源实现
    /// 是否能从本地登录态零配置读出官方额度（false = 只能统计用量/需手填）
    let hasBuiltInQuota: Bool
    /// 是否产出模型级明细
    let producesModelBreakdown: Bool
    /// 需要用户额外提供凭据时的说明（nil = 零配置）
    let credentialHint: String?
    /// 非 nil 时表单显示"密钥"输入框，并使用该占位文案（Cursor 用 `Cookie`）
    let secretFieldPlaceholder: String?

    static func spec(for provider: AgentProvider) -> AgentProviderSpec {
        switch provider {
        case .claudeCode:
            return AgentProviderSpec(
                provider: .claudeCode, displayName: "Claude Code",
                symbolName: "terminal.fill", assetName: "claude",
                kind: .claudeCodeLog, hasBuiltInQuota: true, producesModelBreakdown: true,
                credentialHint: nil,   // 零配置：读 ~/.claude 或 Keychain 登录态
                secretFieldPlaceholder: nil
            )
        case .codex:
            return AgentProviderSpec(
                provider: .codex, displayName: "Codex",
                symbolName: "terminal.fill", assetName: "codex",
                kind: .codexLog, hasBuiltInQuota: true, producesModelBreakdown: true,
                credentialHint: nil,   // 零配置：读 ~/.codex/auth.json
                secretFieldPlaceholder: nil
            )
        case .cursor:
            return AgentProviderSpec(
                provider: .cursor, displayName: "Cursor",
                symbolName: "cursorarrow.rays", assetName: "cursor",
                kind: .cursorWeb, hasBuiltInQuota: true, producesModelBreakdown: false,
                credentialHint: L("Paste the WorkosCursorSessionToken cookie from your browser (expires in about a month)"),
                secretFieldPlaceholder: "WorkosCursorSessionToken=user_xxx::..."
            )
        case .dsh:
            return AgentProviderSpec(
                provider: .dsh, displayName: "DeepSeek Harness",
                symbolName: "terminal.fill", assetName: "deepseek",
                kind: .dshUsageStats, hasBuiltInQuota: false, producesModelBreakdown: true,
                // 零配置：读 dsh-usage-stats 插件的落盘缓存（不需凭据 → 表单不显示提示）
                credentialHint: nil,
                secretFieldPlaceholder: nil
            )
        case .zcode:
            return AgentProviderSpec(
                provider: .zcode, displayName: "Z.ai Coding Plan",
                symbolName: "diamond.fill", assetName: "zai",
                kind: .zaiPlan, hasBuiltInQuota: true, producesModelBreakdown: true,
                // ★ 不显示能力说明：类型名 + 接口地址下拉已说明一切
                credentialHint: nil,
                secretFieldPlaceholder: "Coding Plan API Key"
            )
        case .customPath:
            return AgentProviderSpec(
                provider: .customPath, displayName: L("Custom path"),
                symbolName: "folder.fill", assetName: nil,
                kind: .customPath, hasBuiltInQuota: false, producesModelBreakdown: true,
                credentialHint: L("Requires the file or directory path of a local jsonl log"),
                secretFieldPlaceholder: nil
            )
        }
    }
}

// ============================================================
// MARK: - 模型消耗项
// ============================================================

/// 单个模型的 Token 消耗统计。
/// ★ 暴露给前端 UI — modelUsages 用于渲染模型消耗排行
struct ModelUsageItem: Identifiable, Codable, Equatable {
    let id: String
    var modelName: String          // e.g. "gpt-5.5", "claude-opus-4-8"
    var tokenAmount: Int           // 该模型消耗的精确 Token 数
    var usagePercent: Double       // 0~1，该模型占总消耗的百分比

    // ---- 模型级额度（官方接口注入；nil = 无额度数据）----
    var quotaUsed: Int? = nil      // 已用百分比（0~100）
    var quotaTotal: Int? = nil     // 额度上限（100 = 百分比制）
    var quotaResetText: String? = nil
    /// ★ 额度重置时刻（模型级额度为周窗口语义），供实时倒计时
    var quotaResetsAt: Date? = nil

    /// ★ 剩余百分比（有额度上限时）
    var quotaRemainingPercent: Double? {
        guard let quotaUsed else { return nil }
        return clampPercent(100 - Double(quotaUsed))
    }

    /// ★ 模型级额度实时倒计时（周窗口语义 → 精确到小时，如 "1d 2h"）
    var quotaCountdownText: String {
        guard let quotaResetsAt else { return "" }
        return formatCountdown(
            quotaResetsAt.timeIntervalSinceNow, precision: QuotaWindowKind.cycle.countdownPrecision
        )
    }

    /// ★ 暴露给前端 UI — 格式化后的 Token 数量
    var tokenFormatted: String {
        tokenAmount.formattedTokenCount
    }

    /// ★ 暴露给前端 UI — 百分比文案
    var percentText: String {
        String(format: "%.1f%%", usagePercent * 100)
    }
}

// ============================================================
// MARK: - 模型 × 日期 用量明细（Token 账本输入）
// ============================================================

/// 单个模型在某一天的 Token 用量。
/// ★ 本地日志解析 / OpenAI 每日历史都产出此结构，供 Token 账本按天写入。
struct ModelDailyToken: Codable, Equatable {
    var modelName: String
    var date: Date
    var tokens: Int
}

// ============================================================
// MARK: - 每日用量（热力图）
// ============================================================

/// 单日的 Token 消耗记录，用于前端绘制活动热力图。
/// ★ 暴露给前端 UI — dailyHeatmap 驱动热力图渲染
struct DailyUsage: Identifiable, Codable, Equatable {
    var id: String { "\(date.timeIntervalSince1970)" }
    var date: Date                 // 具体日期
    var tokenCount: Int            // 当日消耗 Token 数
    var level: Int                 // 0~4，热力图活跃等级（0=无, 4=极活跃）

    /// ★ 暴露给前端 UI — 按周/列组织的热力图数据
    /// 调用方可使用 Dictionary(grouping:by:) 按 ISO week 分组
    var weekOfYear: Int {
        Calendar.current.component(.weekOfYear, from: date)
    }

    var dayOfWeek: Int {
        Calendar.current.component(.weekday, from: date)
    }
}

// ============================================================
// MARK: - 统一仪表盘响应
// ============================================================

/// 后端返回的统一数据结构。
/// 各厂商 APIService 实现负责将各自 JSON 映射到此模型。
struct DashboardData: Codable, Equatable {
    var totalTokens: Int
    var totalCost: Double
    var costCurrency: String
    var quotas: [QuotaItem]
    var modelUsages: [ModelUsageItem]
    var sevenDayTrend: [Int]
    var dailyHeatmap: [DailyUsage]
    var activityDays: Int
    /// ★ 模型 × 日期 明细（官方接口若返回每日 + 模型维度则填充，供 Token 账本按天覆盖写入）
    var modelDailyTokens: [ModelDailyToken] = []

    /// 空状态兜底
    static let empty = DashboardData(
        totalTokens: 0,
        totalCost: 0,
        costCurrency: "USD",
        quotas: [],
        modelUsages: [],
        sevenDayTrend: Array(repeating: 0, count: 7),
        dailyHeatmap: [],
        activityDays: 0,
        modelDailyTokens: []
    )
}

// ============================================================
// MARK: - API 配置项（多 API 管理）
// ============================================================

/// 单条 API 接入配置，支持添加/删除/激活多套 API。
/// ★ 暴露给前端 UI — 设置面板用此模型渲染 API 列表
struct APIConfigItem: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    /// 用户自定义名称，如 "OpenAI 生产环境"、"DeepSeek 测试"
    var name: String
    var baseURL: String
    var apiKey: String
    var apiType: APIType
    var pollingInterval: TimeInterval = 300
    /// 是否启用该数据源（可多选启用，启用后纳入综合监测并参与轮询）
    var isActive: Bool = false
    /// Custom 类型时的 JSONPath 映射（字段名 → 点分路径）
    var customKeyPaths: [String: String] = [:]
    /// Anthropic Admin API 组织 ID（org_xxx）— apiType == .anthropic 时使用
    var organizationId: String = ""
    /// GitHub Copilot 组织 slug（orgs/{org}/copilot/usage）— apiType == .copilot 时使用
    var copilotOrg: String = ""
    /// Agent / 订阅工具类型 — apiType == .localLog 时使用
    /// （claudeCode / codex / cursor / dsh / zcode / customPath）
    var agentProvider: AgentProvider = .claudeCode
    /// 本地自定义日志路径（文件或目录）— agentProvider == .customPath 时使用
    var localLogPath: String = ""

    init(
        id: String = UUID().uuidString,
        name: String,
        baseURL: String,
        apiKey: String,
        apiType: APIType,
        pollingInterval: TimeInterval = 300,
        isActive: Bool = false,
        customKeyPaths: [String: String] = [:],
        organizationId: String = "",
        copilotOrg: String = "",
        agentProvider: AgentProvider = .claudeCode,
        localLogPath: String = ""
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.apiType = apiType
        self.pollingInterval = pollingInterval
        self.isActive = isActive
        self.customKeyPaths = customKeyPaths
        self.organizationId = organizationId
        self.copilotOrg = copilotOrg
        self.agentProvider = agentProvider
        self.localLogPath = localLogPath
    }

    // 自定义 Codable — 新增字段用 decodeIfPresent，保证旧版存档（无新字段）可正常解码
    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL, apiKey, apiType, pollingInterval, isActive, customKeyPaths
        case organizationId, copilotOrg, agentProvider, localLogPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        // ★ 宽容解码：先取原始字符串再转枚举。已删除的类型（如旧存档里的
        //   "openAICompatible"）与未知值一律归为 `.custom`，而不是让整份配置
        //   数组解码抛错 —— 那会让用户所有数据源一起丢失。
        let rawType = try c.decodeIfPresent(String.self, forKey: .apiType) ?? ""
        apiType = APIType(rawValue: rawType) ?? .custom
        pollingInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .pollingInterval) ?? 300
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        customKeyPaths = try c.decodeIfPresent([String: String].self, forKey: .customKeyPaths) ?? [:]
        organizationId = try c.decodeIfPresent(String.self, forKey: .organizationId) ?? ""
        copilotOrg = try c.decodeIfPresent(String.self, forKey: .copilotOrg) ?? ""
        agentProvider = try c.decodeIfPresent(AgentProvider.self, forKey: .agentProvider) ?? .claudeCode
        localLogPath = try c.decodeIfPresent(String.self, forKey: .localLogPath) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(apiKey, forKey: .apiKey)
        try c.encode(apiType, forKey: .apiType)
        try c.encode(pollingInterval, forKey: .pollingInterval)
        try c.encode(isActive, forKey: .isActive)
        try c.encode(customKeyPaths, forKey: .customKeyPaths)
        try c.encode(organizationId, forKey: .organizationId)
        try c.encode(copilotOrg, forKey: .copilotOrg)
        try c.encode(agentProvider, forKey: .agentProvider)
        try c.encode(localLogPath, forKey: .localLogPath)
    }
}

// ============================================================
// MARK: - 数据源类型（综合监测）
// ============================================================

/// 数据源类别 — 决定 UI 图标与配置模板
enum AgentSourceType: String, Codable, CaseIterable, Identifiable {
    case api          // 官方 API 余额（OpenAI/DeepSeek/Claude/Gemini...）
    case subscription // 订阅制工具额度（Copilot 等公开接口）
    case local        // 本地 CLI Agent 用量（Claude Code/Codex...）

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .api:          return "API"
        case .subscription: return L("Subscription")
        case .local:        return L("Local")
        }
    }
}

/// 单个数据源的状态
enum AgentSourceStatus: String, Codable {
    case ok        // 数据正常
    case error     // 拉取失败
    case stale     // 数据过期（多次失败后）
}

/// 模型用量来源通道 — 前端「模型板块」按此拆为两个子区块。
/// ★ 注意：汇总「所有模型总用量」时不区分来源，只按模型相加。
enum ModelOrigin: String, Codable, CaseIterable {
    case directAPI   // 直接调用厂商 API（OpenAI / DeepSeek / Kimi / Anthropic / Custom）
    case ideTool     // 在 IDE / CLI 软件内消耗（Claude Code / Codex / Cursor / DSH / Z.ai）

    var displayName: String {
        switch self {
        case .directAPI: return L("Direct API")
        case .ideTool:   return L("IDE Tools")
        }
    }
}

// ============================================================
// MARK: - 额度快照（Agent 卡片核心数据）
// ============================================================

/// 单个 AI/agent 数据源的额度快照 — 由各 AgentDataSource 产出，供聚合层消费。
struct AgentSnapshot: Identifiable, Codable, Equatable {
    var id: String                    // 数据源 ID（与配置项 id 一致）
    var name: String                  // 显示名，如 "OpenAI 生产"、"Copilot"
    var iconName: String              // 回退 SF Symbol，如 "brain.head.profile"
    var assetName: String? = nil      // 品牌资源图名（ProviderIcons/ 目录），nil = 用 SF Symbol
    var sourceType: AgentSourceType

    // ---- 额度信息 ----
    var quotaUsed: Int = 0            // 已用额度（token 或自定义单位）
    var quotaTotal: Int = 0           // 总额度（0 = 无限）
    var quotaUnit: String = "tokens"  // 额度单位文案
    var resetTimeString: String = ""  // 重置文案，如 "5d 12h" / "每月 1 日"
    var currency: String = "USD"

    // ---- ★ 额度窗口（官方接口，可含 5h + 本周期多个窗口） ----
    /// 每个窗口含已用% / 剩余% / 重置时刻
    var quotaWindows: [QuotaWindow] = []
    /// 本周期额度起点（= 官方周期窗口 resetsAt − 7d），供模型板块按周期过滤
    var cycleStart: Date? = nil
    /// 模型明细来源通道（API 直连 / IDE 工具内）
    var origin: ModelOrigin = .directAPI

    /// ★ 每个额度窗口的展示数据（含实时倒计时）。
    /// 5h 与周期窗口各一条，分别带「已用% / 剩余% / 倒计时」：
    /// 5h 精确到分（"2h 12m"），周额度精确到小时（"1d 2h"）。
    /// ⚠️ 倒计时为实时计算值；前端需用 TimelineView/Timer 驱动重绘才能看到它走动。
    var quotaWindowDisplays: [QuotaWindowDisplay] { quotaWindows.map(\.display) }

    /// ★ 5h 会话窗口（可能为 nil）
    var session5hWindow: QuotaWindowDisplay? {
        quotaWindowDisplays.first { $0.kind == .session5h }
    }

    /// ★ 当前额度周期窗口（周额度重置），可能为 nil
    var cycleWindow: QuotaWindowDisplay? {
        quotaWindowDisplays.first { $0.kind == .cycle }
    }

    // ---- 用量统计 ----
    var totalTokens: Int = 0
    var totalCost: Double = 0
    var modelUsages: [ModelUsageItem] = []
    var sevenDayTrend: [Int] = []
    var dailyHeatmap: [DailyUsage] = []
    var activityDays: Int = 0
    /// ★ 模型 × 日期 明细（供 Token 账本写入「模型 × 日期」账本）
    var modelDailyTokens: [ModelDailyToken] = []

    // ---- 运行状态 ----
    var status: AgentSourceStatus = .ok
    var lastUpdated: Date? = nil
    var errorMessage: String = ""

    /// 已用比例 (0~1)；总额度为 0（无限）时返回 0
    var usedRatio: Double {
        guard quotaTotal > 0 else { return 0 }
        return min(Double(quotaUsed) / Double(quotaTotal), 1.0)
    }

    /// 剩余比例文案，如 "62% left"；无固定额度（无限）时返回空串，不显示
    var leftPercentText: String {
        guard quotaTotal > 0 else { return "" }
        return "\(Int((1 - usedRatio) * 100))% left"
    }

    /// 格式化额度使用量：有总额度时 "1.9B / 2.5B"；百分比制时 "42%"；
    /// 无固定额度（无限）时仅显示已用量，如 "1.2M"（详情页另有单位）
    var quotaText: String {
        let used = quotaUsed.formattedTokenCount
        guard quotaTotal > 0 else { return used }
        if quotaUnit == "%" { return "\(quotaUsed)%" }
        return "\(used) / \(quotaTotal.formattedTokenCount)"
    }
}

// ============================================================
// MARK: - 聚合仪表盘数据
// ============================================================

/// 聚合层产出 — 所有数据源快照 + 汇总字段，供 UI 渲染卡片列表与头部。
struct AggregatedDashboard: Codable, Equatable {
    var snapshots: [AgentSnapshot] = []
    var totalTokens: Int = 0          // Σ 各源 totalTokens
    var totalCost: Double = 0         // Σ 各源 totalCost
    var costCurrency: String = "USD"
    var activeSourceCount: Int = 0    // status == .ok 的源数量
    var lastUpdated: Date? = nil
}

// ============================================================
// MARK: - 格式化扩展
// ============================================================

/// 计数单位档位（**从大到小**，顺序即优先级）。
///
/// ★★ **后缀刻意不本地化 / 不翻译** —— 全局统一用 K / M / B / T。
///   中文界面同样是 "1.2B"，不写成「12 亿」。
private let compactCountUnits: [(threshold: Double, suffix: String)] = [
    (1_000_000_000_000, "T"),
    (1_000_000_000, "B"),
    (1_000_000, "M"),
    (1_000, "K"),
]

/// **全应用唯一的计数格式化入口** —— 1.5K / 843.2M / 1.9B / 1T。
///
/// 规则：
/// - 后缀固定 `K` / `M` / `B` / `T`（英文，不随界面语言变化，见 `compactCountUnits`）
/// - 固定 **1 位小数**，但**去掉末尾的 `.0`**：`1_000 → "1K"`、`1_500 → "1.5K"`
/// - 不足 1000 → 直接显示整数（`999 → "999"`）
/// - 四舍五入后够得着下一档 → 进位（`999_999 → "1M"`，不会出现 `1000K`）
///
/// ⚠️ 新增计数展示请一律走这里 / `Int.formattedTokenCount`，
///   不要再写 `String(format: "%.1fM", …)` —— 之前散落 5 份实现，
///   峰值那份的 K 用 0 位小数（`843K`），与模型行的 `1.0K` 不一致。
func formatCompactCount(_ value: Double) -> String {
    guard value.isFinite else { return "0" }

    let magnitude = abs(value)
    guard magnitude >= 1_000 else { return String(Int(value.rounded())) }

    // 从大到小找到第一个不超出的档位（K 为兜底档，索引必 >= 0）
    var unitIndex = compactCountUnits.count - 1
    while unitIndex > 0, magnitude >= compactCountUnits[unitIndex - 1].threshold {
        unitIndex -= 1
    }
    var unit = compactCountUnits[unitIndex]
    var scaled = value / unit.threshold

    // ★ 进位保护：接近 1000 时改用上一档，避免 "1000K" / "1000.0M"
    if abs(scaled) >= 999.95, unitIndex > 0 {
        unit = compactCountUnits[unitIndex - 1]
        scaled = value / unit.threshold
    }
    return trimmingTrailingZero(String(format: "%.1f", scaled)) + unit.suffix
}

/// 去掉 `%.1f` 结果末尾的 `.0`（"1.0K" → "1K"，"1.5K" 保持）
private func trimmingTrailingZero(_ text: String) -> String {
    text.hasSuffix(".0") ? String(text.dropLast(2)) : text
}

extension Int {
    /// 将 Token 数量格式化为人类可读文案："1T", "4.1B", "843.2M", "136.3K", "999"
    var formattedTokenCount: String { formatCompactCount(Double(self)) }
}

// ============================================================
// MARK: - TOTAL TOKENS 头部大字显示规则
// ============================================================

/// 压缩候选用单位（★ **从小到大**）—— 与 `compactCountUnits` 相反的顺序：
/// 头部要「优先留在最小单位」，所以从 K 开始往上试。
private let ascendingCountUnits: [(threshold: Double, suffix: String)] = [
    (1_000, "K"),
    (1_000_000, "M"),
    (1_000_000_000, "B"),
    (1_000_000_000_000, "T"),
]

/// 头部**原样显示**的最大十进制位数
private let totalTokensMaxRawDigits = 10
/// 压缩后**乘数**的最大位数
private let totalTokensMaxMultiplierDigits = 10

/// TOTAL TOKENS 头部大字的显示规则（★ **仅此一处使用**，2026-09-25 定）。
///
/// 与通用计数规范 `formatCompactCount` 的差别：
/// 头部**优先原样显示完整数字**，只在实在放不下时才压缩；压缩时**优先留在 K**，
/// 不急着升到 M/B/T —— 这样还能看出量级细节（`1000000K` 比 `1B` 更"看得见数"）。
///
/// - 十进制位数 ≤ 10 → 原样显示（含千分位）：`9,999,999,999`
/// - 位数 > 10 → 取**最小的单位**使乘数位数 ≤ 10（乘数取整、不显示小数）：
///   - `12,345,678,901`         → `12345679K`
///   - `1,234,567,890,123`      → `1234567890K`（K 乘数正好 10 位）
///   - `12,345,678,901,234`     → `12345679M`（K 乘数会到 11 位 → 只好升 M）
///   - `10,000,000,000,000,000` → `10000000B`
///   - `9,999,999,999,999`      → `10000000M`（四舍五入进位后位数超限 → 升档）
func formatTotalTokensDisplay(_ value: Int) -> String {
    guard value > 0 else { return "0" }

    // 位数没超上限 → 原样显示完整数字，不做任何压缩
    if String(value).count <= totalTokensMaxRawDigits { return value.formatted() }

    let magnitude = Double(value)
    let multiplierCap = pow(10.0, Double(totalTokensMaxMultiplierDigits))
    var chosen = ascendingCountUnits[ascendingCountUnits.count - 1]
    for unit in ascendingCountUnits {
        chosen = unit
        // ★ 用**四舍五入后**的值判位数：进位可能让乘数从 9,999,999,999 变成 10^10（11 位）
        if (magnitude / unit.threshold).rounded() < multiplierCap { break }
    }
    return String(Int((magnitude / chosen.threshold).rounded())) + chosen.suffix
}

// ============================================================
// MARK: - 模型预设（数据源配置模板）
// ============================================================

/// 数据源配置模板 — 选择预设自动填充类型/接口地址/厂商专属字段。
/// ★ 两组预设对应 Dashboard 两个管理栏目：
///   - apiPresets   → MODELS 管理页（API 型源：OpenAI/DeepSeek/Kimi/Anthropic/自定义）
///   - agentPresets → 额度管理页（订阅/本地 CLI：Copilot / Claude Code / Codex）
struct ModelPreset: Identifiable {
    let id: String
    let name: String
    let icon: String          // 回退 SF Symbol
    let asset: String?        // 品牌资源图名（ProviderIcons/ 目录，nil = 无图）
    let apiType: APIType
    let agentProvider: AgentProvider?   // 仅 Agent/本地类预设
    let defaultURL: String
}

/// API 型预设（MODELS 管理页可选）。
/// ★ 必须是**计算属性**：数组里的文案经 `L()` 取词，写成全局 `let` 会在首次访问时
///   把当时的语言固化下来，切换语言后不再更新。
var apiPresets: [ModelPreset] { [
    ModelPreset(id: "openai", name: "OpenAI", icon: "brain.head.profile", asset: "openai", apiType: .openAI, agentProvider: nil, defaultURL: "https://api.openai.com"),
    ModelPreset(id: "deepseek", name: "DeepSeek", icon: "diamond.fill", asset: "deepseek", apiType: .deepseek, agentProvider: nil, defaultURL: "https://api.deepseek.com"),
    ModelPreset(id: "kimi", name: "Moonshot Kimi", icon: "moon.stars.fill", asset: "kimi", apiType: .kimi, agentProvider: nil, defaultURL: "https://api.moonshot.cn/v1"),
    ModelPreset(id: "anthropic", name: "Anthropic Claude", icon: "circle.hexagongrid.fill", asset: "claude", apiType: .anthropic, agentProvider: nil, defaultURL: "https://api.anthropic.com"),
    // ★ 余额型：填 Key 就能读出真实余额，无需再配字段映射
    ModelPreset(id: "openrouter", name: "OpenRouter", icon: "arrow.triangle.branch", asset: "openrouter", apiType: .openRouter, agentProvider: nil, defaultURL: "https://openrouter.ai/api/v1"),
    ModelPreset(id: "siliconflow", name: L("SiliconFlow"), icon: "cloud.fill", asset: "siliconflow", apiType: .siliconFlow, agentProvider: nil, defaultURL: "https://api.siliconflow.cn/v1"),
    // ★ 原「OpenAI 兼容网关」预设已删除（2026-09-25）：类型与服务一并移除，
    //   中转网关请用下方的「自定义」预设 + 字段映射（旧存档会自动变成自定义源）。
    ModelPreset(id: "gemini", name: "Google Gemini", icon: "sparkles", asset: "gemini", apiType: .gemini, agentProvider: nil, defaultURL: "https://generativelanguage.googleapis.com"),
    ModelPreset(id: "custom", name: L("Custom"), icon: "gearshape.2.fill", asset: nil, apiType: .custom, agentProvider: nil, defaultURL: ""),
] }

/// 订阅 / 本地 CLI / Agent 预设（额度管理页可选）。★ 同 `apiPresets`：必须为计算属性。
var agentPresets: [ModelPreset] { [
    ModelPreset(id: "copilot", name: "GitHub Copilot", icon: "chevron.left.forwardslash.chevron.right", asset: "copilot", apiType: .copilot, agentProvider: nil, defaultURL: ""),
    ModelPreset(id: "local-claude", name: "Claude Code", icon: "terminal.fill", asset: "claude", apiType: .localLog, agentProvider: .claudeCode, defaultURL: ""),
    ModelPreset(id: "local-codex", name: "Codex", icon: "terminal.fill", asset: "codex", apiType: .localLog, agentProvider: .codex, defaultURL: ""),
    ModelPreset(id: "local-cursor", name: "Cursor", icon: "cursorarrow.rays", asset: "cursor", apiType: .localLog, agentProvider: .cursor, defaultURL: ""),
    ModelPreset(id: "local-dsh", name: "DeepSeek Harness", icon: "terminal.fill", asset: "deepseek", apiType: .localLog, agentProvider: .dsh, defaultURL: ""),
    // ★ Z.ai：默认站点跟随系统地区（中国大陆 → 国内站 open.bigmodel.cn，其余 → 国际站 api.z.ai）。
    //   表单里用地址下拉（`ZaiEndpointPicker`，选项即 `ZaiRegion.allCases`）改写它。
    ModelPreset(id: "local-zcode", name: "Z.ai Coding Plan", icon: "diamond.fill", asset: "zai", apiType: .localLog, agentProvider: .zcode, defaultURL: ZaiRegion.systemDefault().defaultBaseURL),
] }
