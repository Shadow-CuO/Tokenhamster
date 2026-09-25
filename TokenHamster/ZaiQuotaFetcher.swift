//
//  ZaiQuotaFetcher.swift
//  TokenHamster
//
//  Z.ai / 智谱 GLM Coding Plan 官方用量接口
//
//  端点（base 只取 scheme://host[:port]，见 `zaiQuotaBaseURL(from:)`）：
//    GET {base}/api/monitor/usage/quota/limit                     额度（无 query）
//    GET {base}/api/monitor/usage/model-usage?startTime=&endTime= 模型用量
//    GET https://www.bigmodel.cn/api/biz/account/query-customer-account-report  账户余额（仅国内站）
//
//  ★★ 认证头是**裸 token**，不带 `Bearer` 前缀
//     （官方脚本原文：`headers: { 'Authorization': authToken }`）。
//     平台接口的 `Bearer` 写法在这里**会失败**。
//
//  ------------------------------------------------------------------
//  schema 依据
//  ------------------------------------------------------------------
//  官方 `zai-org/zai-coding-plugins` 只 dump 原始 JSON、未公开 schema，
//  因此本文件的字段与结构取自两个**独立第三方生产实现**（字段一致、互为印证）：
//    - steipete/CodexBar（Swift，`Plugins/zai.js` + `ZaiAPIRegion.swift`）
//    - tddworks/ClaudeBar（Swift，含 fixture 测试）
//
//  ★ 这四个点最初都写错了，改动前务必理解：
//    1. `type` 除 `TOKENS_LIMIT` 还可能是 **`CREDIT_LIMIT`**（积分制套餐）——
//       只认 TOKENS_LIMIT 会让积分制用户一个窗口都读不到
//    2. 窗口长度由 **`unit` + `number`** 编码，**不是数组顺序**
//    3. `nextResetTime`（epoch 毫秒）是重置倒计时的唯一来源
//    4. `model-usage` 是 **x_time × modelDataList 的矩阵**，不是逐条记录
//

import Foundation

// ============================================================
// MARK: - base URL 归一化
// ============================================================

/// 把用户填的内容归一化成 `scheme://host[:port]`。
/// 端点路径固定挂在 `/api/...` 下，所以 host 之后的路径一律丢弃 ——
/// 这样用户无论填 `https://open.bigmodel.cn`、带尾斜杠，还是直接粘官方文档里的
/// `https://open.bigmodel.cn/api/anthropic`，都能命中同一套接口。
/// 无法解析时返回 nil（调用方据此报错/回退）。
///
/// ★ 端口必须保留：`URL.host` **不含端口**，直接拼会丢掉它
///   （真实站点走隐式 443 看不出来，但自定义端口会直接连不上）。
nonisolated func zaiQuotaBaseURL(from raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    // 允许用户省略 scheme
    let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard let url = URL(string: candidate),
          let scheme = url.scheme?.lowercased(),
          (scheme == "http" || scheme == "https"),
          let host = url.host, !host.isEmpty else { return nil }

    guard let port = url.port else { return "\(scheme)://\(host)" }
    // 隐式默认端口不写出来
    if (scheme == "https" && port == 443) || (scheme == "http" && port == 80) {
        return "\(scheme)://\(host)"
    }
    return "\(scheme)://\(host):\(port)"
}

// ============================================================
// MARK: - 额度窗口模型
// ============================================================

/// `limits[]` 的一项（已归一化）。
struct ZaiLimit: Equatable {

    /// `TOKENS_LIMIT` / `CREDIT_LIMIT` / `TIME_LIMIT`
    var type: String
    /// 窗口单位代码（1=天 3=小时 5=分钟 6=周）
    var unit: Int
    /// 窗口数量（与 `unit` 相乘得长度）
    var number: Int
    /// 已用百分比（0~100）
    var usedPercent: Double
    /// 重置时刻
    var resetsAt: Date?
    /// 额度上限（credit / token 数）
    var usage: Double?
    var remaining: Double?
    var currentValue: Double?
    /// 窗口长度（分钟）；无法识别时为 nil
    var windowMinutes: Int?

    /// 积分制套餐用 `CREDIT_LIMIT` 代替 `TOKENS_LIMIT`，字段语义一致
    var isCredit: Bool { type == "CREDIT_LIMIT" }
    /// MCP 工具用量（月窗口），不映射到额度条
    var isMCP: Bool { type == "TIME_LIMIT" }
    /// 是否是可映射到额度条的窗口
    var isQuotaWindow: Bool { !isMCP }
}

/// `quota/limit` 的解析结果
struct ZaiOfficialQuota: Equatable {

    /// 套餐名（`planName`，回退 plan / plan_type / packageName / level）
    var planName: String?
    var limits: [ZaiLimit] = []

    /// 全部可作额度条的窗口（按窗口长度升序）
    var quotaWindows: [ZaiLimit] {
        limits.filter(\.isQuotaWindow).sorted {
            ($0.windowMinutes ?? Int.max) < ($1.windowMinutes ?? Int.max)
        }
    }

    /// 5 小时会话窗口（最短的那条）
    var sessionWindow: ZaiLimit? { quotaWindows.first }
    /// 周期窗口（最长的那条；只有一个窗口时为 nil）
    var cycleWindow: ZaiLimit? {
        let windows = quotaWindows
        return windows.count >= 2 ? windows.last : nil
    }
    /// MCP 窗口（月）
    var mcpWindow: ZaiLimit? { limits.first(where: \.isMCP) }
    /// 是否为积分制套餐（任一条为 CREDIT_LIMIT）
    var isCreditPlan: Bool { limits.contains(where: \.isCredit) }

    var isEmpty: Bool { quotaWindows.isEmpty }
}

// ============================================================
// MARK: - 额度解析
// ============================================================

enum ZaiQuotaParser {

    /// `unit` → 每条 `number` 折算的分钟数
    static let unitMinutes: [Int: Int] = [
        1: 24 * 60,        // day
        3: 60,             // hour
        5: 1,              // minute
        6: 7 * 24 * 60,    // week
    ]

    /// 5 小时会话窗口的分钟数（用于重置时刻合理性校验）
    static let sessionWindowMinutes = 5 * 60

    /// 解析并做**响应级校验**：必须 `success == true` 且 `code == 200`。
    /// 官方脚本就是这么判的；只看 HTTP 200 会把业务错误当成功。
    static func parse(_ json: [String: Any], now: Date = Date()) throws -> ZaiOfficialQuota {
        try validateEnvelope(json)
        let data = dataNode(json)
        guard let rawLimits = data["limits"] as? [[String: Any]] else {
            throw QuotaError.invalidResponse(L("quota/limit is missing the data.limits array"))
        }

        var quota = ZaiOfficialQuota()
        quota.limits = rawLimits.compactMap { parseLimit($0, now: now) }

        // 套餐名：官方字段名不完全统一，按优先级取第一个非空字符串
        for key in ["planName", "plan", "plan_type", "packageName", "level"] {
            if let value = data[key] as? String,
               !value.trimmingCharacters(in: .whitespaces).isEmpty {
                quota.planName = value
                break
            }
        }
        return quota
    }

    /// 解析单项。形状不合法（缺 type / unit / number / percentage）→ nil 跳过。
    static func parseLimit(_ raw: [String: Any], now: Date = Date()) -> ZaiLimit? {
        guard let type = raw["type"] as? String, !type.isEmpty else { return nil }
        // unit / number 允许字符串数字
        // ⚠️ 局部变量不能叫 `number` —— 会遮蔽同名静态函数 `number(_:)`
        guard let unitCode = int(raw["unit"]),
              let windowNumber = int(raw["number"]),
              let percentage = number(raw["percentage"]) else { return nil }

        let usage = number(raw["usage"])
        let current = number(raw["currentValue"])
        let remaining = number(raw["remaining"])

        var percent = percentage
        // 有 usage 时用 usage/remaining 重算（比 percentage 更靠得住）
        if let usage, usage > 0 {
            var used: Double?
            if let remaining {
                used = max(usage - remaining, current ?? (usage - remaining))
            } else if let current {
                used = current
            }
            if let used { percent = used / usage * 100 }
        }

        var windowMinutes: Int? = nil
        if windowNumber > 0, let perUnit = unitMinutes[unitCode] {
            windowMinutes = windowNumber * perUnit
        }
        // MCP 月窗口标记：TIME_LIMIT + unit=5 + number=1（不是 1 分钟）
        if type == "TIME_LIMIT", unitCode == 5, windowNumber == 1 {
            windowMinutes = 30 * 24 * 60
        }

        var resetsAt: Date? = nil
        if let millis = number(raw["nextResetTime"]) {
            let candidate = millis > 1e12
                ? Date(timeIntervalSince1970: millis / 1000)
                : Date(timeIntervalSince1970: millis)
            // ★ 合理性校验：5 小时窗口的重置不可能在 10 小时之后。
            //   时区/单位处理出错时这里能挡住荒谬的倒计时，而不是显示出来。
            let isFiveHour = type != "TIME_LIMIT" && windowMinutes == sessionWindowMinutes
            let plausible = !isFiveHour
                || candidate.timeIntervalSince(now) <= Double(sessionWindowMinutes) * 60 + 60
            if plausible { resetsAt = candidate }
        }

        return ZaiLimit(
            type: type,
            unit: unitCode,
            number: windowNumber,
            usedPercent: clampPercent(percent),
            resetsAt: resetsAt,
            usage: usage,
            remaining: remaining,
            currentValue: current,
            windowMinutes: windowMinutes
        )
    }

    // ---- 基础访问 ----

    /// 取 data 节点：优先 `json.data`，缺失退回顶层（同官方脚本 `json.data || json`）
    static func dataNode(_ json: [String: Any]) -> [String: Any] {
        (json["data"] as? [String: Any]) ?? json
    }

    /// 响应级校验：`success == true` 且 `code == 200`
    static func validateEnvelope(_ json: [String: Any]) throws {
        let success = json["success"] as? Bool ?? false
        let code = int(json["code"]) ?? -1
        guard success, code == 200 else {
            let msg = json["msg"] as? String ?? "code \(code)"
            throw QuotaError.invalidResponse(L("Z.ai API returned an error: %@", msg))
        }
    }

    // ---- 数值容错（Int / Double / NSNumber / String） ----

    static func number(_ value: Any?) -> Double? {
        if let v = value as? Double { return v }
        if let v = value as? Int { return Double(v) }
        if let v = value as? NSNumber { return v.doubleValue }
        if let v = value as? String { return Double(v) }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        guard let d = number(value) else { return nil }
        return Int(d)
    }
}

// ============================================================
// MARK: - 模型用量解析（矩阵结构）
// ============================================================

enum ZaiModelUsageParser {

    /// 解析 `model-usage` 的**矩阵**响应 → 模型 → [当地零时 epoch: token]。
    ///
    /// 真实结构：
    /// ```jsonc
    /// {"code":200,"success":true,"data":{
    ///   "x_time": ["2026-09-19 10:00", ...],                  // 时间轴
    ///   "modelDataList": [
    ///     {"modelName":"glm-5.3","tokensUsage":[0,120,...]}    // 与 x_time 下标对齐
    ///   ]
    /// }}
    /// ```
    ///
    /// ★ 一条时间点可能只覆盖当天的一部分（逐小时）→ **同一响应内按天求和**；
    ///   跨响应则由 `ZaiUsageHistory` 取 max。
    static func parse(
        _ json: [String: Any],
        calendar: Calendar = .current
    ) throws -> [String: [Int: Int]] {
        try ZaiQuotaParser.validateEnvelope(json)
        let data = ZaiQuotaParser.dataNode(json)

        guard let labels = data["x_time"] as? [Any] else {
            throw QuotaError.invalidResponse(L("model-usage is missing the data.x_time timeline"))
        }
        guard let modelList = data["modelDataList"] as? [[String: Any]] else {
            throw QuotaError.invalidResponse(L("model-usage is missing data.modelDataList"))
        }
        // 预解析时间轴 → 当地零时键（下标与 tokensUsage 对齐）
        let dayKeys: [Int?] = labels.map { label in
            guard let text = label as? String else { return nil }
            guard let date = parseLabel(text, calendar: calendar) else { return nil }
            return ZaiUsageHistory.dayKey(for: date, calendar: calendar)
        }

        var result: [String: [Int: Int]] = [:]
        for model in modelList {
            guard let name = model["modelName"] as? String, !name.isEmpty else { continue }
            guard let values = model["tokensUsage"] as? [Any] else { continue }

            var dayValues: [Int: Int] = [:]
            for (index, value) in values.enumerated() {
                guard index < dayKeys.count, let dayKey = dayKeys[index] else { continue }
                guard let tokens = ZaiQuotaParser.int(value), tokens > 0 else { continue }
                dayValues[dayKey, default: 0] += tokens
            }
            for (day, tokens) in dayValues {
                result[name, default: [:]][day, default: 0] += tokens
            }
        }
        return result
    }

    /// 时间轴标签：支持 `yyyy-MM-dd HH:mm:ss` / `yyyy-MM-dd HH:mm` / `yyyy-MM-dd` / epoch
    static func parseLabel(_ raw: String, calendar: Calendar = .current) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let value = Double(trimmed) {
            return value > 1e12
                ? Date(timeIntervalSince1970: value / 1000)
                : Date(timeIntervalSince1970: value)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return parseISO8601Date(trimmed)
    }
}

// ============================================================
// MARK: - 账户余额（仅国内站）
// ============================================================

/// 国内站控制台的账户余额。`api.z.ai`（国际站）**没有**对应端点。
struct ZaiAccountBalance: Equatable {
    var available: Double
    var recharged: Double?
    var granted: Double?
    var spent: Double?

    var currency: String { "CNY" }
}

/// 站点分区 —— 决定默认 host、币种与余额可用性。
enum ZaiRegion: String, CaseIterable, Identifiable {
    /// 国内站（bigmodel.cn）：有账户余额端点
    case china
    /// 国际站（api.z.ai）：**无**账户余额端点
    case global

    var id: String { rawValue }

    /// 默认 base URL
    /// ★ 表单里这两个值就是**下拉菜单的两个选项**（`ZaiEndpointPicker`），
    ///   所以不再另设站点显示名 —— 菜单项的文案就是 URL 本身。
    var defaultBaseURL: String {
        switch self {
        case .china:  return "https://open.bigmodel.cn"
        case .global: return "https://api.z.ai"
        }
    }

    /// 计费币种（官方定价页：国内 ¥、国际 $）
    var currency: String {
        switch self {
        case .china:  return "CNY"
        case .global: return "USD"
        }
    }

    /// 是否有账户余额端点
    var hasAccountBalance: Bool { self == .china }

    /// 由 base URL 推断分区（未知→按国际站处理）
    static func detect(base: String) -> ZaiRegion {
        let host = URL(string: base)?.host ?? base
        return host.hasSuffix("bigmodel.cn") ? .china : .global
    }

    /// 新增数据源时的默认站点：**跟随系统地区** —— 中国大陆 → 国内站，其余 → 国际站。
    /// （口径与 `CurrencyPreference.systemDefault` 一致；`region` 可注入以便测试。）
    static func systemDefault(region: String? = nil) -> ZaiRegion {
        let code = region ?? Locale.current.region?.identifier ?? ""
        return code.uppercased() == "CN" ? .china : .global
    }
}

enum ZaiBalanceParser {

    /// 国内站余额端点固定在 `www.bigmodel.cn`（控制台主机），**不是** `open.bigmodel.cn`（API 主机）
    static let endpoint = "https://www.bigmodel.cn/api/biz/account/query-customer-account-report"

    /// 只有国内站能查余额 —— 由 base host 推断
    static func supportsBalance(base: String) -> Bool {
        ZaiRegion.detect(base: base).hasAccountBalance
    }

    static func parse(_ json: [String: Any]) -> ZaiAccountBalance? {
        let success = json["success"] as? Bool ?? false
        guard success else { return nil }
        let data = (json["data"] as? [String: Any]) ?? [:]

        // ★ `Number(null) == 0` 会悄悄毁掉回退逻辑 → 只接受真正的数值
        let available = ZaiQuotaParser.number(data["availableBalance"])
        let current = ZaiQuotaParser.number(data["balance"])
        guard let amount = available ?? current else { return nil }

        return ZaiAccountBalance(
            available: amount,
            recharged: ZaiQuotaParser.number(data["rechargeAmount"]),
            granted: ZaiQuotaParser.number(data["giveAmount"]),
            spent: ZaiQuotaParser.number(data["totalSpendAmount"])
        )
    }
}

// ============================================================
// MARK: - 额度抓取器
// ============================================================

/// GLM Coding Plan 官方额度抓取器。
///
/// 凭据：Coding Plan API Key（z.ai / bigmodel.cn → Coding Plan → Plan Overview 处创建）。
/// ⚠️ 官方明确 **Coding Plan Key 与平台其他 API Key 不通用**。
struct ZaiPlanQuotaFetcher: QuotaFetcher {

    /// 已完成归一化的 `scheme://host[:port]`
    let base: String
    let apiKey: String
    /// 可注入的请求函数（测试用）
    var getJSON: (String, String) async throws -> [String: Any]

    /// 从用户填写的原始地址构造；地址非法或 Key 为空时返回 nil
    init?(rawBaseURL: String, apiKey: String) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let base = zaiQuotaBaseURL(from: rawBaseURL) else { return nil }
        self.base = base
        self.apiKey = key
        self.getJSON = Self.defaultGetJSON
    }

    /// 测试注入用
    init(base: String, apiKey: String, getJSON: @escaping (String, String) async throws -> [String: Any]) {
        self.base = base
        self.apiKey = apiKey
        self.getJSON = getJSON
    }

    var isLoggedIn: Bool { true }   // 能构造出来就说明有 Key

    /// 官方地址固定挂 `/api/...`，**不带 `/v1`**
    static func endpoint(_ base: String, path: String) -> String {
        apiURL(base, path: path, ensureV1: false)
    }

    /// ★ 裸 token，无 `Bearer` 前缀
    static func defaultGetJSON(url: String, apiKey: String) async throws -> [String: Any] {
        try await HTTPClient.get(
            url: url,
            apiKey: apiKey,
            extraHeaders: [
                "Authorization": apiKey,
                "Accept-Language": "en-US,en",
            ]
        )
    }

    // ---- 额度 ----

    /// 协议要求（`QuotaFetcher`）：拉取官方额度。
    /// ★ 默认参数**不能满足协议要求**，所以这里显式实现无参版本。
    func fetchQuota() async throws -> QuotaSnapshot {
        try await fetchQuota(now: Date())
    }

    /// 可注入时钟的版本（测试用）
    func fetchQuota(now: Date) async throws -> QuotaSnapshot {
        let url = Self.endpoint(base, path: "api/monitor/usage/quota/limit")
        let json = try await getJSON(url, apiKey)
        let official = try ZaiQuotaParser.parse(json, now: now)
        guard !official.isEmpty else {
            throw QuotaError.invalidResponse(L("quota/limit returned no recognizable quota windows"))
        }
        return Self.makeSnapshot(official)
    }

    /// 官方额度 → `QuotaSnapshot`（纯函数，可单测）
    static func makeSnapshot(_ official: ZaiOfficialQuota) -> QuotaSnapshot {
        var windows: [QuotaWindow] = []

        if let session = official.sessionWindow {
            windows.append(QuotaWindow(
                kind: .session5h,
                label: sessionLabel(for: session),
                usedPercent: session.usedPercent,
                resetsAt: session.resetsAt
            ))
        }
        if let cycle = official.cycleWindow {
            windows.append(QuotaWindow(
                kind: .cycle,
                label: cycleLabel(for: cycle),
                usedPercent: cycle.usedPercent,
                resetsAt: cycle.resetsAt
            ))
        }
        return QuotaSnapshot(
            windows: windows,
            planName: official.planName,
            source: official.isCreditPlan ? "zai-plan-credit" : "zai-plan"
        )
    }

    /// 5h 窗口标题：积分制标 credit，token 制标 token
    static func sessionLabel(for limit: ZaiLimit) -> String {
        limit.isCredit ? "5h credit" : "5h token"
    }

    /// 周期窗口标题：按窗口长度给可读名字
    static func cycleLabel(for limit: ZaiLimit) -> String {
        let unitWord: String
        switch limit.windowMinutes {
        case 7 * 24 * 60:
            unitWord = L("Weekly")
        case let minutes? where minutes % (24 * 60) == 0:
            unitWord = L("%@-day", minutes / (24 * 60))
        case let minutes? where minutes % 60 == 0:
            unitWord = L("%@-hour", minutes / 60)
        default:
            unitWord = L("Cycle")
        }
        return limit.isCredit ? "\(unitWord) credit" : "\(unitWord) token"
    }

    // ---- 模型用量 ----

    /// 拉取官方模型用量（矩阵 → 模型 → [当地零时: token]）。
    /// ★ 与额度分开：失败不应影响额度显示。
    func fetchModelUsage(
        from start: Date,
        to end: Date,
        calendar: Calendar = .current
    ) async throws -> [String: [Int: Int]] {
        let query = "?startTime=\(Self.formatQueryDate(start, calendar: calendar))"
            + "&endTime=\(Self.formatQueryDate(end, calendar: calendar))"
        let url = Self.endpoint(base, path: "api/monitor/usage/model-usage") + query
        let json = try await getJSON(url, apiKey)
        return try ZaiModelUsageParser.parse(json, calendar: calendar)
    }

    /// 官方用量接口的查询范围上限（天）。
    /// 实测：1 天=逐小时、30 天=逐日；再长官方不接受。
    /// 历史延长靠 `ZaiUsageHistory` 本地累积，而不是拉更长的区间。
    static let maxQueryDays = 30

    // ---- 账户余额（仅国内站，尽力而为） ----

    /// 拉取账户余额。国际站无此端点 → 返回 nil（不当作错误）。
    func fetchBalance() async -> ZaiAccountBalance? {
        guard ZaiBalanceParser.supportsBalance(base: base) else { return nil }
        guard let json = try? await getJSON(ZaiBalanceParser.endpoint, apiKey) else { return nil }
        return ZaiBalanceParser.parse(json)
    }

    /// 官方脚本用的查询时间格式：**当地时区** `yyyy-MM-dd HH:mm:ss`
    static func formatQueryDate(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
