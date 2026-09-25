//
//  TokenService.swift
//  TokenHamster
//
//  网络请求适配层 — 协议定义 + JSONPath 提取器 + 各厂商实现
//  由 DashboardViewModel 调用，不与 UI 直接交互
//

import Foundation

// ============================================================
// MARK: - 网络请求错误
// ============================================================

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(url: String, statusCode: Int, body: String)
    case decodingError(String)
    case missingKey(String)
    case unauthorized
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:           return L("Invalid API endpoint URL")
        case .invalidResponse:      return L("The server returned an invalid response")
        case .httpError(let url, let code, let body):
            return "\(url) → HTTP \(code): \(body)"
        case .decodingError(let msg): return L("Failed to parse data: %@", msg)
        case .missingKey(let key):    return L("Missing required field in JSON: %@", key)
        case .unauthorized:           return L("Invalid or expired API key")
        case .networkError(let err):  return err.localizedDescription
        }
    }
}

// ============================================================
// MARK: - APIService 协议
// ============================================================

// ============================================================
// MARK: - 用量语义
// ============================================================

/// 数据源的用量语义 — 决定"消耗/充值"如何检测。
/// - cumulative: 累计消耗量（单调递增），本次 > 上次 = 消耗
/// - balance:    余额（会减少），本次 < 上次 = 消耗；本次 > 上次 = 充值
enum UsageSemantics {
    case cumulative
    case balance
}

/// 所有厂商 API 服务必须实现的协议。
/// 外部只需调用 fetchData() 即可获得统一的 DashboardData。
protocol APIService {
    /// 发起网络请求并返回标准化仪表盘数据
    func fetchData() async throws -> DashboardData
    /// 该接口返回数据的用量语义（累计消耗 / 余额）
    var semantics: UsageSemantics { get }
}

// ============================================================
// MARK: - JSONPath 提取器
// ============================================================

/// 通用 JSON 路径提取工具。
/// 允许通过点分隔的 KeyPath 字符串从任意 JSON 字典中安全提取数值，
/// 防止因 JSON 结构变化导致解析崩溃。
/// nonisolated：纯静态解析函数，可在任意线程/任务上下文调用（项目默认 MainActor 隔离）。
nonisolated struct JSONPathExtractor {

    /// 从 JSON 字典中按路径提取值
    /// - Parameters:
    ///   - json: 已解析的 [String: Any] 字典
    ///   - path: 点分隔路径，如 "data.total_tokens" 或 "usage.total"
    /// - Returns: 提取到的值，类型不匹配或路径不存在返回 nil
    static func extract(_ json: [String: Any], path: String) -> Any? {
        let keys = path.split(separator: ".").map(String.init)
        var current: Any? = json

        for key in keys {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[key]
        }

        return current
    }

    /// 从 JSON 字典中提取 Int
    static func int(_ json: [String: Any], path: String, default: Int = 0) -> Int {
        guard let raw = extract(json, path: path) else { return `default` }
        if let v = raw as? Int { return v }
        if let v = raw as? Double { return Int(v) }
        if let v = raw as? String, let parsed = Int(v) { return parsed }
        return `default`
    }

    /// 从 JSON 字典中提取 Double
    static func double(_ json: [String: Any], path: String, default: Double = 0) -> Double {
        guard let raw = extract(json, path: path) else { return `default` }
        if let v = raw as? Double { return v }
        if let v = raw as? Int { return Double(v) }
        if let v = raw as? String, let parsed = Double(v) { return parsed }
        return `default`
    }

    /// 从 JSON 字典中提取 String
    static func string(_ json: [String: Any], path: String, default: String = "") -> String {
        guard let raw = extract(json, path: path) else { return `default` }
        if let v = raw as? String { return v }
        return "\(raw)"
    }

    /// 从 JSON 字典中提取数组
    static func array(_ json: [String: Any], path: String) -> [[String: Any]] {
        guard let raw = extract(json, path: path) else { return [] }
        return (raw as? [[String: Any]]) ?? []
    }
}

// ============================================================
// MARK: - 基础 HTTP 请求工具
// ============================================================

/// 通用 GET（internal：`ZaiQuotaFetcher` 等同模块抓取器复用）
struct HTTPClient {

    /// 通用 GET 请求，返回原始 JSON 字典。
    /// - Parameters:
    ///   - extraHeaders: 追加的自定义请求头（如 Anthropic 的 x-api-key / anthropic-version）。
    ///     非空时跳过 Bearer Authorization（由调用方通过请求头完成认证）。
    static func get(
        url: String,
        apiKey: String,
        extraHeaders: [String: String]? = nil
    ) async throws -> [String: Any] {
        guard let requestURL = URL(string: url),
              let scheme = requestURL.scheme,
              !scheme.isEmpty,
              requestURL.host != nil else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        if let extraHeaders {
            for (key, value) in extraHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        let body = String(data: data, encoding: .utf8) ?? ""

        switch httpResponse.statusCode {
        case 200:
            break
        case 401, 403:
            throw APIError.unauthorized
        default:
            throw APIError.httpError(url: url, statusCode: httpResponse.statusCode, body: body)
        }

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw APIError.decodingError(L("The response is not a valid JSON object"))
        }

        return json
    }
}

// ============================================================
// MARK: - OpenAI API 服务
// ============================================================

/// OpenAI 官方 Organization Usage API。
/// GET {base}/v1/organization/usage/completions?start_time=&bucket_width=1d&group_by[]=model
///   → total_usage（单位 = 100 万 tokens，需 ×1e6），data[].results[].n_tokens
/// GET {base}/v1/organization/usage/costs?start_time=&bucket_width=1d
///   → data[].amount.value（USD）
/// ⚠️ 需要具备组织用量读取权限的 API Key。
struct OpenAIService: APIService {

    let baseURL: String
    let apiKey: String
    let semantics: UsageSemantics = .cumulative

    /// 查询窗口：最近 30 天
    private let windowDays = 30

    func fetchData() async throws -> DashboardData {
        let startTime = Int(Date().addingTimeInterval(-Double(windowDays) * 86_400).timeIntervalSince1970)
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL

        // ── 1. 用量（completions）──
        let usageURL = "\(base)/v1/organization/usage/completions?start_time=\(startTime)&bucket_width=1d&group_by[]=model"
        let usageJSON = try await HTTPClient.get(url: usageURL, apiKey: apiKey)

        // total_usage 单位为 100 万 tokens → 换算为实际 token 数
        let totalTokens = JSONPathExtractor.int(usageJSON, path: "total_usage") * 1_000_000

        // 逐 bucket 聚合：模型排行 + 每日用量
        let buckets = JSONPathExtractor.array(usageJSON, path: "data")
        var modelTokens: [String: Int] = [:]
        var dayTokens: [Date: Int] = [:]
        var modelDayTokens: [String: [Date: Int]] = [:]
        let calendar = Calendar.current

        for bucket in buckets {
            let bucketStart = JSONPathExtractor.int(bucket, path: "start_time")
            let dayStart = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(bucketStart)))
            let results = JSONPathExtractor.array(bucket, path: "results")

            var bucketTotal = 0
            for result in results {
                let nTokens = JSONPathExtractor.int(result, path: "result.n_tokens")
                let model = JSONPathExtractor.string(result, path: "dimensions.model", default: "unknown")
                bucketTotal += nTokens
                modelTokens[model, default: 0] += nTokens
                // ★ 模型 × 日期 明细（同一 bucket 内同模型可能多条 → 累加）
                modelDayTokens[model, default: [:]][dayStart, default: 0] += nTokens
            }
            dayTokens[dayStart, default: 0] += bucketTotal
        }

        // 模型排行（按消耗降序）
        let modelUsages = modelTokens
            .sorted { $0.value > $1.value }
            .enumerated()
            .map { i, item in
                ModelUsageItem(
                    id: "model_\(i)",
                    modelName: item.key,
                    tokenAmount: item.value,
                    usagePercent: totalTokens > 0 ? Double(item.value) / Double(totalTokens) : 0
                )
            }

        // 每日热力图（仅保留有消耗的天）
        let dailyHeatmap: [DailyUsage] = dayTokens
            .filter { $0.value > 0 }
            .map { date, tokens in
                DailyUsage(date: date, tokenCount: tokens, level: heatmapLevel(for: tokens))
            }
            .sorted { $0.date < $1.date }

        let sevenDayTrend = computeSevenDayTrend(from: dailyHeatmap)
        let activeDays = dailyHeatmap.count

        // ── 2. 费用（costs，失败不影响用量）──
        var totalCost: Double = 0
        do {
            let costURL = "\(base)/v1/organization/usage/costs?start_time=\(startTime)&bucket_width=1d"
            let costJSON = try await HTTPClient.get(url: costURL, apiKey: apiKey)
            for bucket in JSONPathExtractor.array(costJSON, path: "data") {
                totalCost += JSONPathExtractor.double(bucket, path: "amount.value")
            }
        } catch {
            // 费用接口可能无权限；用量数据仍可用
        }

        return DashboardData(
            totalTokens: totalTokens,
            totalCost: totalCost,
            costCurrency: "USD",
            quotas: [],
            modelUsages: modelUsages,
            sevenDayTrend: sevenDayTrend,
            dailyHeatmap: dailyHeatmap,
            activityDays: activeDays,
            modelDailyTokens: modelDayTokens.flatMap { model, dayMap in
                dayMap.map { ModelDailyToken(modelName: model, date: $0.key, tokens: $0.value) }
            }
        )
    }
}

/// 适配 DeepSeek 余额查询 API。
/// GET https://api.deepseek.com/user/balance
/// 期望 JSON 结构：
/// {
///   "is_available": true,
///   "balance_infos": [
///     { "currency": "CNY", "total_balance": "100.00", "total_discount": "0.00" }
///   ]
/// }
/// ⚠️ 注意：这是余额查询（剩余金额），不是 Token 用量查询。
/// 仅能展示总余额，不含模型消耗/每日用量等明细。
struct DeepSeekService: APIService {

    let baseURL: String
    let apiKey: String
    let semantics: UsageSemantics = .balance

    func fetchData() async throws -> DashboardData {
        let url = baseURL.hasSuffix("/") ? "\(baseURL)user/balance" : "\(baseURL)/user/balance"
        let json = try await HTTPClient.get(url: url, apiKey: apiKey)

        let isAvailable = json["is_available"] as? Bool ?? false
        let balanceInfos = JSONPathExtractor.array(json, path: "balance_infos")

        // 从 balance_infos 数组中提取余额信息
        var totalBalance: Double = 0
        var currency = "CNY"

        if let firstBalance = balanceInfos.first {
            currency = JSONPathExtractor.string(firstBalance, path: "currency", default: "CNY")
            totalBalance = JSONPathExtractor.double(firstBalance, path: "total_balance")
        }

        // DeepSeek 余额接口不含 Token 用量/模型消耗/每日趋势数据
        return DashboardData(
            totalTokens: 0,
            totalCost: totalBalance,
            costCurrency: currency,
            quotas: [
                QuotaItem(
                    id: "deepseek_balance",
                    name: L("DeepSeek Balance"),
                    used: 0,
                    total: 0,
                    resetDaysLeft: 0,
                    resetHoursLeft: 0,
                    hourlyUsedPercent: 0,
                    weeklyUsedPercent: isAvailable ? 0 : 100,
                    resetTimeString: isAvailable ? "Available" : "Used up"
                )
            ],
            modelUsages: [],
            sevenDayTrend: Array(repeating: 0, count: 7),
            dailyHeatmap: [],
            activityDays: 0
        )
    }
}

// ============================================================
// MARK: - Kimi (Moonshot) API 服务
// ============================================================

/// Kimi (Moonshot) 余额查询。
/// GET {base}/users/me/balance（base 形如 https://api.moonshot.cn/v1）
///   → { "code": 0, "data": { "available_balance": ..., "voucher_balance": ..., "cash_balance": ... } }
/// 仅能展示总余额，不含 Token 消耗/每日用量等明细。
struct KimiService: APIService {

    let baseURL: String
    let apiKey: String
    let semantics: UsageSemantics = .balance

    func fetchData() async throws -> DashboardData {
        let url = baseURL.hasSuffix("/") ? "\(baseURL)users/me/balance" : "\(baseURL)/users/me/balance"
        let json = try await HTTPClient.get(url: url, apiKey: apiKey)

        let code = json["code"] as? Int ?? -1
        guard code == 0 else {
            let msg = json["message"] as? String ?? "code \(code)"
            throw APIError.decodingError(L("Kimi API returned an error: %@", msg))
        }

        let dataDict = json["data"] as? [String: Any] ?? [:]
        let availableBalance = JSONPathExtractor.double(dataDict, path: "available_balance")

        // Kimi 余额接口不含 Token 用量/模型消耗/每日趋势数据
        return DashboardData(
            totalTokens: 0,
            totalCost: availableBalance,
            costCurrency: "CNY",
            quotas: [
                QuotaItem(
                    id: "kimi_balance",
                    name: L("Kimi Balance"),
                    used: 0,
                    total: 0,
                    resetDaysLeft: 0,
                    resetHoursLeft: 0,
                    hourlyUsedPercent: 0,
                    weeklyUsedPercent: 0,
                    resetTimeString: "Available"
                )
            ],
            modelUsages: [],
            sevenDayTrend: Array(repeating: 0, count: 7),
            dailyHeatmap: [],
            activityDays: 0
        )
    }
}

// ============================================================
// MARK: - 接口地址拼接 / 可选数值提取（余额类服务共用）
// ============================================================

/// 规范化 base URL 并拼接路径。
/// - 去掉尾部 `/`；`ensureV1 == true` 且 base 未以 `/v1` 结尾时自动补 `/v1`。
///   让用户填 `https://api.example.com` 或 `https://api.example.com/v1` 都能命中。
nonisolated func apiURL(_ base: String, path: String, ensureV1: Bool = true) -> String {
    var b = base.trimmingCharacters(in: .whitespaces)
    while b.hasSuffix("/") { b.removeLast() }
    if ensureV1, !b.hasSuffix("/v1") { b += "/v1" }
    return "\(b)/\(path)"
}

/// 提取**可选** Double —— 区分「字段缺失/null」与「值为 0」。
/// `JSONPathExtractor.double` 会把两者都返回 0，余额类接口必须区分
/// （如 OpenRouter 无限额度 key 的 `limit_remaining` 为 `null`）。
nonisolated func optionalDouble(_ json: [String: Any], path: String) -> Double? {
    guard let raw = JSONPathExtractor.extract(json, path: path), !(raw is NSNull) else { return nil }
    if let d = raw as? Double { return d }
    if let i = raw as? Int { return Double(i) }
    if let s = raw as? String, let d = Double(s) { return d }
    return nil
}

/// 余额型快照的公共构造：只有余额金额、没有 token 维度。
/// `totalTokens == 0` 会让 MODELS 栏把该源按「余额型」渲染成 `¥/$ xx.xx left`。
nonisolated func balanceDashboardData(
    amount: Double,
    currency: String,
    quotaID: String,
    quotaName: String,
    isAvailable: Bool = true
) -> DashboardData {
    DashboardData(
        totalTokens: 0,
        totalCost: amount,
        costCurrency: currency,
        quotas: [
            QuotaItem(
                id: quotaID,
                name: quotaName,
                used: 0,
                total: 0,
                resetDaysLeft: 0,
                resetHoursLeft: 0,
                hourlyUsedPercent: 0,
                weeklyUsedPercent: isAvailable ? 0 : 100,
                resetTimeString: isAvailable ? "Available" : "Used up"
            )
        ],
        modelUsages: [],
        sevenDayTrend: Array(repeating: 0, count: 7),
        dailyHeatmap: [],
        activityDays: 0
    )
}

// ============================================================
// MARK: - OpenRouter API 服务
// ============================================================

/// OpenRouter 余额查询。
///
/// 1. `GET {base}/key`（base 形如 https://openrouter.ai/api/v1）
///    → data.limit_remaining（本 key 剩余额度 USD）、data.limit、data.usage、
///      data.usage_daily / usage_weekly / usage_monthly、data.limit_reset
///    ✓ 普通推理 key 即可调用，覆盖面最广
/// 2. 若 key 为无限额度（limit_remaining == null）→ 退回
///    `GET {base}/credits` → data.total_credits − data.total_usage（账户余额 USD）
///    ⚠️ 该端点需要 **management key**
///
/// 字段与端点已按 OpenRouter 官方 OpenAPI（/key、/credits）核对。
/// 仅能展示余额/消费金额，不含 token 用量明细。
struct OpenRouterService: APIService {

    let baseURL: String
    let apiKey: String
    let semantics: UsageSemantics = .balance

    func fetchData() async throws -> DashboardData {
        let keyJSON = try await HTTPClient.get(
            url: apiURL(baseURL, path: "key"), apiKey: apiKey
        )
        let data = keyJSON["data"] as? [String: Any] ?? [:]

        // 1) 优先用本 key 的剩余额度
        if let remaining = optionalDouble(data, path: "limit_remaining") {
            return balanceDashboardData(
                amount: remaining,
                currency: "USD",
                quotaID: "openrouter_key",
                quotaName: L("OpenRouter Balance"),
                isAvailable: remaining > 0
            )
        }

        // 2) 无限额度 key → 退回账户级 credits
        let creditsJSON = try await HTTPClient.get(
            url: apiURL(baseURL, path: "credits"), apiKey: apiKey
        )
        let credits = creditsJSON["data"] as? [String: Any] ?? [:]
        guard let total = optionalDouble(credits, path: "total_credits") else {
            throw APIError.missingKey("data.total_credits")
        }
        let used = optionalDouble(credits, path: "total_usage") ?? 0
        let remaining = total - used

        return balanceDashboardData(
            amount: remaining,
            currency: "USD",
            quotaID: "openrouter_credits",
            quotaName: L("OpenRouter Balance"),
            isAvailable: remaining > 0
        )
    }
}

// ============================================================
// MARK: - 硅基流动 SiliconFlow API 服务
// ============================================================

/// 硅基流动（SiliconFlow）余额查询。
/// GET {base}/user/info（base 形如 https://api.siliconflow.cn/v1）
///   → data.totalBalance（总额 = 赠费 + 充值，字符串）、data.balance（赠费）、
///     data.chargeBalance（充值）、data.status
///
/// 字段已按官方文档 `GET /user/info` 的 OpenAPI schema 核对。
/// 币种按域名推断：`*.cn` → CNY（国内站），否则 USD（国际站）。
/// 仅能展示余额，不含 token 用量明细。
struct SiliconFlowService: APIService {

    let baseURL: String
    let apiKey: String
    let semantics: UsageSemantics = .balance

    func fetchData() async throws -> DashboardData {
        let json = try await HTTPClient.get(
            url: apiURL(baseURL, path: "user/info"), apiKey: apiKey
        )
        let data = json["data"] as? [String: Any] ?? [:]

        guard let total = optionalDouble(data, path: "totalBalance") else {
            throw APIError.missingKey("data.totalBalance")
        }
        // "normal" = 正常；其余（如欠费/封禁）视为不可用
        let status = JSONPathExtractor.string(data, path: "status", default: "normal")

        return balanceDashboardData(
            amount: total,
            currency: Self.currency(forHost: URL(string: baseURL)?.host ?? ""),
            quotaID: "siliconflow_balance",
            quotaName: L("SiliconFlow Balance"),
            isAvailable: status == "normal" && total > 0
        )
    }

    /// 国内站用人民币、国际站用美元。
    /// 纯函数便于测试（mock server 跑在 127.0.0.1，覆盖不到真实域名分支）。
    nonisolated static func currency(forHost host: String) -> String {
        host.hasSuffix(".cn") ? "CNY" : "USD"
    }
}

// ============================================================
// MARK: - Anthropic Claude API 服务
// ============================================================

/// Anthropic Admin API（组织级用量与额度）。
/// GET {base}/v1/organizations/{org_id}/usage_report
///   → total_usage.{input_tokens, output_tokens, all_tokens, api_costs}、api_usage.daily_usage[]
/// GET {base}/v1/organizations/{org_id}/limits
///   → limits[]（每个限额的 usage_limit / current_usage / next_reset_time）
/// ⚠️ 需要组织管理密钥（sk-ant-admin-...）+ 组织 ID。
struct AnthropicService: APIService {

    let baseURL: String
    let apiKey: String
    let organizationId: String
    let semantics: UsageSemantics = .cumulative

    init(baseURL: String, apiKey: String, organizationId: String = "") {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.organizationId = organizationId
    }

    func fetchData() async throws -> DashboardData {
        guard !organizationId.isEmpty else {
            throw APIError.missingKey(L("organizationId (Anthropic organization ID)"))
        }
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let headers = ["x-api-key": apiKey, "anthropic-version": "2023-06-01"]

        // ── 1. 用量报告 ──
        let usageURL = "\(base)/v1/organizations/\(organizationId)/usage_report"
        let usageJSON = try await HTTPClient.get(url: usageURL, apiKey: apiKey, extraHeaders: headers)

        let totalTokens = JSONPathExtractor.int(usageJSON, path: "total_usage.all_tokens")
        let totalCost = JSONPathExtractor.double(usageJSON, path: "total_usage.api_costs")

        // 逐日用量（api_usage.daily_usage：date + all_tokens）
        let dailyJSON = JSONPathExtractor.array(usageJSON, path: "api_usage.daily_usage")
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dailyHeatmap: [DailyUsage] = dailyJSON.compactMap { item in
            guard let dateStr = item["date"] as? String,
                  let date = dateFormatter.date(from: dateStr) else { return nil }
            let tokens = JSONPathExtractor.int(item, path: "all_tokens")
            return DailyUsage(date: date, tokenCount: tokens, level: heatmapLevel(for: tokens))
        }
        .sorted { $0.date < $1.date }

        let sevenDayTrend = computeSevenDayTrend(from: dailyHeatmap)
        let activeDays = dailyHeatmap.filter { $0.tokenCount > 0 }.count

        // ── 2. 额度（limits）──
        let limitsURL = "\(base)/v1/organizations/\(organizationId)/limits"
        let limitsJSON = try await HTTPClient.get(url: limitsURL, apiKey: apiKey, extraHeaders: headers)
        let limitsArr = JSONPathExtractor.array(limitsJSON, path: "limits")
        var quotas: [QuotaItem] = []
        for item in limitsArr {
            // 只保留已启用的限额
            if let enabled = item["enabled"] as? Bool, !enabled { continue }
            let name = JSONPathExtractor.string(item, path: "name", default: "Unknown")
            let used = JSONPathExtractor.double(item, path: "current_usage.value")
            let limit = JSONPathExtractor.double(item, path: "usage_limit.value")
            let usedPercent = limit > 0 ? Int((used / limit) * 100) : 0
            let resetStr = JSONPathExtractor.string(item, path: "next_reset_time")
            let resetText = resetStr.isEmpty ? "—" : Self.formatReset(iso: resetStr)
            quotas.append(QuotaItem(
                id: "anthropic_limit_\(quotas.count)",
                name: name,
                used: Int(used),
                total: Int(limit),
                resetDaysLeft: 0,
                resetHoursLeft: 0,
                hourlyUsedPercent: 0,
                weeklyUsedPercent: usedPercent,
                resetTimeString: resetText
            ))
        }

        return DashboardData(
            totalTokens: totalTokens,
            totalCost: totalCost,
            costCurrency: "USD",
            quotas: quotas,
            modelUsages: [],
            sevenDayTrend: sevenDayTrend,
            dailyHeatmap: dailyHeatmap,
            activityDays: activeDays
        )
    }

    /// ISO8601 重置时间 → 剩余天数文案
    private static func formatReset(iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else {
            return iso
        }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        if days > 1 { return L("Resets in %@ days", days) }
        if days == 1 { return L("Resets tomorrow") }
        let hours = Calendar.current.dateComponents([.hour], from: Date(), to: date).hour ?? 0
        return hours > 0 ? L("Resets in %@ hour%@", hours, hours == 1 ? "" : "s") : L("Resetting soon")
    }
}

// ============================================================
// MARK: - Google Gemini API 服务
// ============================================================

/// Google Gemini 官方暂无公开的用量/账单查询 API。
/// 保留该类型仅用于兼容旧配置；fetchData 直接报错，提示改用 Custom 类型。
struct GeminiService: APIService {

    let baseURL: String
    let apiKey: String
    let semantics: UsageSemantics = .cumulative

    func fetchData() async throws -> DashboardData {
        throw APIError.decodingError(
            L("Google Gemini has no public usage API. Pick the “Custom” type in settings to hook up another stats service")
        )
    }
}

// ============================================================
// MARK: - Custom API 服务
// ============================================================

/// 自定义 JSON 接口 — 使用 KeyPath 映射配置。
/// 用户可在设置中提供 JSONPath 映射，灵活适配任意 JSON 结构。
struct CustomAPIService: APIService {

    let baseURL: String
    let apiKey: String
    let semantics: UsageSemantics = .cumulative

    /// 自定义 KeyPath 映射（可从 APIConfigItem.customKeyPaths 传入）
    var keyPathMap: [String: String]

    init(baseURL: String, apiKey: String, keyPathMap: [String: String] = [:]) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.keyPathMap = keyPathMap
    }

    func fetchData() async throws -> DashboardData {
        let json = try await HTTPClient.get(url: baseURL, apiKey: apiKey)

        let totalTokens = JSONPathExtractor.int(json, path: keyPathMap["totalTokens"] ?? "total_usage")
        let totalCost   = JSONPathExtractor.double(json, path: keyPathMap["totalCost"] ?? "total_cost")
        let currency    = JSONPathExtractor.string(json, path: keyPathMap["currency"] ?? "currency", default: "USD")

        let activeDays = JSONPathExtractor.int(json, path: keyPathMap["activeDays"] ?? "active_days")

        // 模型消耗
        let modelsJSON = JSONPathExtractor.array(json, path: keyPathMap["models"] ?? "models")
        let modelUsages: [ModelUsageItem] = modelsJSON.enumerated().map { i, item in
            ModelUsageItem(
                id: "model_\(i)",
                modelName: JSONPathExtractor.string(item, path: keyPathMap["modelName"] ?? "name"),
                tokenAmount: JSONPathExtractor.int(item, path: keyPathMap["modelTokens"] ?? "tokens"),
                usagePercent: JSONPathExtractor.double(item, path: keyPathMap["modelPercent"] ?? "percent")
            )
        }

        // 每日用量
        let dailyJSON = JSONPathExtractor.array(json, path: keyPathMap["daily"] ?? "daily_breakdown")
        let dateFormatter = ISO8601DateFormatter()
        let dailyHeatmap: [DailyUsage] = dailyJSON.compactMap { item in
            guard let dateStr = item[keyPathMap["dailyDate"] ?? "date"] as? String,
                  let date = dateFormatter.date(from: "\(dateStr)T00:00:00Z") else { return nil }
            let count = JSONPathExtractor.int(item, path: keyPathMap["dailyTokens"] ?? "tokens")
            let level = JSONPathExtractor.int(item, path: keyPathMap["dailyLevel"] ?? "level")
            return DailyUsage(date: date, tokenCount: count, level: level)
        }
        let sevenDayTrend = computeSevenDayTrend(from: dailyHeatmap)

        return DashboardData(
            totalTokens: totalTokens,
            totalCost: totalCost,
            costCurrency: currency,
            quotas: [],
            modelUsages: modelUsages,
            sevenDayTrend: sevenDayTrend,
            dailyHeatmap: dailyHeatmap,
            activityDays: activeDays
        )
    }
}

// ============================================================
// MARK: - 自定义接口辅助（设置面板：测试接口 / 粘贴 JSON 自动识别）
// ============================================================

/// 单字段预览结果（设置面板"测试接口"逐字段展示）
struct CustomFieldPreview: Identifiable, Equatable {
    var id: String { key }
    let key: String       // 映射键（totalTokens 等）
    let label: String     // 中文显示名
    let path: String      // 实际使用的路径
    let valueText: String // 提取值文案
    let isFound: Bool     // 是否成功提取
}

/// 从原始 JSON 按 keyPathMap 逐字段提取，供"测试接口"预览。
nonisolated func extractFieldPreviews(json: [String: Any], keyPathMap: [String: String]) -> [CustomFieldPreview] {
    let fields: [(key: String, label: String)] = [
        ("totalTokens", L("Total tokens")),
        ("totalCost", L("Total cost")),
        ("currency", L("Currency")),
        ("activeDays", L("Active days")),
        ("models", L("Model list")),
        ("daily", L("Daily usage")),
    ]
    return fields.map { field in
        let path = keyPathMap[field.key] ?? ""
        // 空路径视为未配置（直接跳过，避免 extract 空路径返回整个 JSON）
        guard !path.isEmpty else {
            return CustomFieldPreview(key: field.key, label: field.label, path: "", valueText: L("Not configured"), isFound: false)
        }
        let raw = JSONPathExtractor.extract(json, path: path)
        let valueText: String
        if let arr = raw as? [Any] {
            valueText = L("Array (%@ item%@)", arr.count, arr.count == 1 ? "" : "s")
        } else if let v = raw {
            valueText = "\(v)"
        } else {
            valueText = L("Not found")
        }
        return CustomFieldPreview(
            key: field.key,
            label: field.label,
            path: path,
            valueText: valueText,
            isFound: raw != nil
        )
    }
}

/// 按草稿配置请求接口并逐字段提取（设置面板"测试接口"用）
func fetchCustomFieldPreviews(baseURL: String, apiKey: String, keyPathMap: [String: String]) async throws -> [CustomFieldPreview] {
    let json = try await HTTPClient.get(url: baseURL, apiKey: apiKey)
    return extractFieldPreviews(json: json, keyPathMap: keyPathMap)
}

/// 从示例 JSON 递归收集所有 (路径, 值) 候选（深度优先，父路径在前）
nonisolated func collectKeyPaths(_ json: [String: Any], prefix: String = "") -> [(path: String, value: Any)] {
    var result: [(String, Any)] = []
    for (key, value) in json {
        let path = prefix.isEmpty ? key : "\(prefix).\(key)"
        result.append((path, value))
        if let dict = value as? [String: Any] {
            result.append(contentsOf: collectKeyPaths(dict, prefix: path))
        }
    }
    return result
}

/// 从示例 JSON 自动识别字段路径映射（设置面板"粘贴 JSON 自动识别"用）。
/// 启发式：优先匹配已知字段名（total_tokens / total_cost / name+tokens 数组 / date+tokens 数组）。
nonisolated func autoMapKeyPaths(_ json: [String: Any]) -> [String: String] {
    let items = collectKeyPaths(json)
    let numbers: [(path: String, key: String)] = items.compactMap { item in
        guard item.value is NSNumber else { return nil }
        let path = item.path
        let key = String(path.split(separator: ".").last ?? "")
        return (path, key)
    }
    var map: [String: String] = [:]

    // 总 Token（累计消耗）
    let tokenKeys = ["total_tokens", "totalTokens", "total_usage", "totalUsage", "total_token", "total", "n_tokens", "total_completion_tokens"]
    if let hit = numbers.first(where: { tokenKeys.contains($0.key) }) {
        map["totalTokens"] = hit.path
    }
    // 总费用
    let costKeys = ["total_cost", "totalCost", "total_spent_usd", "totalSpentUsd", "total_spent", "totalSpent", "spent", "cost"]
    if let hit = numbers.first(where: { costKeys.contains($0.key) }) {
        map["totalCost"] = hit.path
    }
    // 货币单位
    if let hit = items.first(where: {
        let key = String($0.path.split(separator: ".").last ?? "")
        return ["currency", "costCurrency", "currency_code", "currencyCode"].contains(key) && $0.value is String
    }) {
        map["currency"] = hit.path
    }
    // 活跃天数
    if let hit = numbers.first(where: { ["active_days", "activeDays", "activity_days", "activityDays"].contains($0.key) }) {
        map["activeDays"] = hit.path
    }

    // 模型排行：数组 + 元素含 name/model + 数字 token 字段（排除含 date 的每日数组）
    for item in items {
        guard let arr = item.value as? [Any], let first = arr.first as? [String: Any] else { continue }
        if first.keys.contains(where: { ["date", "day", "time"].contains($0) }) { continue }
        let nameKey = first.keys.first { ["name", "model", "model_name", "modelName"].contains($0) } ?? "name"
        guard let numKey = first.keys.first(where: {
            ["tokens", "token", "total_tokens", "token_count", "usage", "n_tokens", "output_tokens", "input_tokens"].contains($0)
        }), first[numKey] is NSNumber else { continue }
        map["models"] = item.path
        map["modelName"] = nameKey
        map["modelTokens"] = numKey
        if let pctKey = first.keys.first(where: { ["percent", "percentage", "ratio"].contains($0) }) {
            map["modelPercent"] = pctKey
        }
        break
    }

    // 每日用量：数组 + 元素含 date 字段 + 数字 token 字段
    for item in items {
        guard let arr = item.value as? [Any], let first = arr.first as? [String: Any] else { continue }
        guard let dateKey = first.keys.first(where: { ["date", "day", "date_str", "time"].contains($0) }) else { continue }
        guard let numKey = first.keys.first(where: {
            ["tokens", "token", "token_count", "count", "usage", "n_tokens"].contains($0)
        }), first[numKey] is NSNumber else { continue }
        map["daily"] = item.path
        map["dailyDate"] = dateKey
        map["dailyTokens"] = numKey
        if let lvlKey = first.keys.first(where: { ["level", "heatmap_level", "intensity"].contains($0) }) {
            map["dailyLevel"] = lvlKey
        }
        break
    }

    return map
}

// ============================================================
// MARK: - API 服务工厂
// ============================================================

/// 根据配置创建对应的 API 服务实例
enum APIServiceFactory {

    static func create(
        type: APIType,
        baseURL: String,
        apiKey: String,
        keyPathMap: [String: String] = [:],
        organizationId: String = ""
    ) -> APIService {
        switch type {
        case .openAI:
            return OpenAIService(baseURL: baseURL, apiKey: apiKey)
        case .deepseek:
            return DeepSeekService(baseURL: baseURL, apiKey: apiKey)
        case .kimi:
            return KimiService(baseURL: baseURL, apiKey: apiKey)
        case .anthropic:
            return AnthropicService(baseURL: baseURL, apiKey: apiKey, organizationId: organizationId)
        case .gemini:
            return GeminiService(baseURL: baseURL, apiKey: apiKey)
        case .openRouter:
            return OpenRouterService(baseURL: baseURL, apiKey: apiKey)
        case .siliconFlow:
            return SiliconFlowService(baseURL: baseURL, apiKey: apiKey)
        case .custom:
            return CustomAPIService(baseURL: baseURL, apiKey: apiKey, keyPathMap: keyPathMap)
        case .copilot, .localLog:
            // Copilot / 本地 CLI 由 buildDataSources 分流构建，不走 APIService
            return CustomAPIService(baseURL: baseURL, apiKey: apiKey, keyPathMap: keyPathMap)
        }
    }
}

// ============================================================
// MARK: - 工具函数
// ============================================================

/// 从每日用量数据计算最近 7 天的 Token 趋势
func computeSevenDayTrend(from dailyHeatmap: [DailyUsage]) -> [Int] {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())

    var trend: [Int] = []
    for offset in (0..<7).reversed() {
        guard let targetDate = calendar.date(byAdding: .day, value: -offset, to: today) else {
            trend.append(0)
            continue
        }
        let dayStart = calendar.startOfDay(for: targetDate)
        let total = dailyHeatmap
            .filter { calendar.startOfDay(for: $0.date) == dayStart }
            .reduce(0) { $0 + $1.tokenCount }
        trend.append(total)
    }

    return trend
}

/// 根据 Token 数量计算热力图等级 (0~4)
func heatmapLevel(for tokenCount: Int) -> Int {
    switch tokenCount {
    case 0:              return 0
    case 1..<10_000_000:  return 1
    case 10_000_000..<50_000_000:  return 2
    case 50_000_000..<150_000_000: return 3
    default:              return 4
    }
}

// ============================================================
// MARK: - AgentDataSource 协议（综合监测数据源）
// ============================================================

/// 综合监测数据源协议。
/// 每个实现代表一种 AI/agent 额度来源（官方 API / 订阅工具 / 本地 CLI 日志），
/// 统一产出 AgentSnapshot 供聚合层消费。
protocol AgentDataSource {
    /// 数据源唯一 ID（与配置项 id 一致）
    var id: String { get }
    /// 显示名
    var name: String { get }
    /// SF Symbol 图标
    var iconName: String { get }
    /// 数据源类别
    var sourceType: AgentSourceType { get }
    /// 数据源用量语义（累计消耗 / 余额）
    var semantics: UsageSemantics { get }
    /// 拉取最新额度快照
    func fetchSnapshot() async throws -> AgentSnapshot
}

// ============================================================
// MARK: - APISource — 官方 API 余额（包装现有 APIService）
// ============================================================

/// 将现有 APIService（OpenAI/DeepSeek/Claude/Gemini/Quota/Custom）包装为 AgentDataSource。
/// 一个 API 配置 = 一个数据源。
struct APISource: AgentDataSource {

    let id: String
    let name: String
    let iconName: String
    let assetName: String?            // 品牌资源图（nil = 回退 iconName SF Symbol）
    let sourceType: AgentSourceType = .api
    let semantics: UsageSemantics

    private let service: APIService

    init(id: String, name: String, iconName: String = "brain.head.profile", assetName: String? = nil, service: APIService) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.assetName = assetName
        self.service = service
        self.semantics = service.semantics
    }

    func fetchSnapshot() async throws -> AgentSnapshot {
        let data = try await service.fetchData()
        return AgentSnapshot(
            id: id,
            name: name,
            iconName: iconName,
            assetName: assetName,
            sourceType: .api,
            quotaUsed: data.totalTokens,
            quotaTotal: 0,                       // 官方 API 通常无固定额度 → 无限
            quotaUnit: "tokens",
            // ★ 余额型状态（可用/已用完）经 quotas[0].resetTimeString 透传 → 快照可复用
            resetTimeString: data.quotas.first?.resetTimeString ?? "",
            currency: data.costCurrency,
            origin: .directAPI,
            totalTokens: data.totalTokens,
            totalCost: data.totalCost,
            modelUsages: data.modelUsages,
            sevenDayTrend: data.sevenDayTrend,
            dailyHeatmap: data.dailyHeatmap,
            activityDays: data.activityDays,
            modelDailyTokens: data.modelDailyTokens,
            status: .ok,
            lastUpdated: Date(),
            errorMessage: ""
        )
    }
}

/// 缺少必需配置的源 —— **不请求任何接口**，直接产出带原因的错误快照。
///
/// 用于「配置项能建、但必需参数缺失」的情况（典型：Z.ai 未填 Coding Plan Key）。
/// 让卡片**显式告诉用户缺什么**，而不是静默消失、或显示一张全 0 的空卡。
struct UnavailableAgentSource: AgentDataSource {

    let id: String
    let name: String
    let iconName: String
    let assetName: String?
    let sourceType: AgentSourceType
    let semantics: UsageSemantics = .cumulative
    /// 展示给用户的原因
    let reason: String

    init(
        id: String,
        name: String,
        iconName: String,
        assetName: String? = nil,
        sourceType: AgentSourceType = .subscription,
        reason: String
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.assetName = assetName
        self.sourceType = sourceType
        self.reason = reason
    }

    func fetchSnapshot() async throws -> AgentSnapshot {
        AgentSnapshot(
            id: id,
            name: name,
            iconName: iconName,
            assetName: assetName,
            sourceType: sourceType,
            status: .error,
            lastUpdated: Date(),
            errorMessage: reason
        )
    }
}

// ============================================================
// MARK: - SubscriptionSource — 订阅制工具公开接口
// ============================================================

/// 订阅制工具额度 — 通过公开/官方接口获取。
/// 目前支持 GitHub Copilot（GraphQL Usage API）。
/// 扩展新工具：新增 case + fetch 实现即可。
struct SubscriptionSource: AgentDataSource {

    enum SubscriptionKind: String {
        case copilot   // GitHub Copilot
    }

    let id: String
    let name: String
    let iconName: String
    let assetName: String?            // 品牌资源图（nil = 回退 iconName SF Symbol）
    let sourceType: AgentSourceType = .subscription
    let semantics: UsageSemantics = .cumulative

    private let kind: SubscriptionKind
    private let token: String        // GitHub PAT（需 read:org 权限）
    private let org: String          // GitHub 组织 slug
    private let apiBaseURL: String   // 可注入（测试指向本地 mock）；默认 GitHub

    init(id: String, name: String, iconName: String, assetName: String? = nil, kind: SubscriptionKind, token: String, org: String = "", apiBaseURL: String = "https://api.github.com") {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.assetName = assetName
        self.kind = kind
        self.token = token
        self.org = org
        self.apiBaseURL = apiBaseURL
    }

    func fetchSnapshot() async throws -> AgentSnapshot {
        switch kind {
        case .copilot:
            return try await fetchCopilotSnapshot()
        }
    }

    /// GitHub Copilot — 组织用量 API：GET /orgs/{org}/copilot/usage?day=YYYY-MM-DD
    /// 并行拉取最近 7 天的逐日快照，聚合出总量、7 日趋势与热力图。
    /// ⚠️ 需要 GitHub PAT（read:org 权限）。
    private func fetchCopilotSnapshot() async throws -> AgentSnapshot {
        guard !org.isEmpty else {
            throw APIError.missingKey(L("org (GitHub organization slug)"))
        }

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone(secondsFromGMT: 0)

        let calendar = Calendar.current
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: -$0, to: Date()) }

        // 并行拉最近 7 天的逐日快照
        var daySnapshots: [Date: (tokens: Int, activeUsers: Int)] = [:]
        try await withThrowingTaskGroup(of: (Date, Int, Int).self) { group in
            for day in days {
                group.addTask {
                    let dayStr = dayFormatter.string(from: day)
                    let base = apiBaseURL.hasSuffix("/") ? String(apiBaseURL.dropLast()) : apiBaseURL
                    let url = "\(base)/orgs/\(org)/copilot/usage?day=\(dayStr)"
                    let json = try await Self.fetchCopilotDay(url: url, token: token)
                    let suggestions = JSONPathExtractor.int(json, path: "total_suggestions_count")
                    let acceptances = JSONPathExtractor.int(json, path: "total_acceptances_count")
                    let chatTurns = JSONPathExtractor.int(json, path: "total_chat_turns")
                    let activeUsers = JSONPathExtractor.int(json, path: "total_active_users")
                    return (day, suggestions + acceptances + chatTurns, activeUsers)
                }
            }
            for try await item in group {
                daySnapshots[item.0] = (item.1, item.2)
            }
        }

        let ordered = days.sorted()
        let totalTokens = ordered.reduce(0) { $0 + (daySnapshots[$1]?.tokens ?? 0) }
        let sevenDayTrend = ordered.map { daySnapshots[$0]?.tokens ?? 0 }
        let dailyHeatmap: [DailyUsage] = ordered.compactMap { day in
            guard let snap = daySnapshots[day], snap.tokens > 0 else { return nil }
            return DailyUsage(date: day, tokenCount: snap.tokens, level: heatmapLevel(for: snap.tokens))
        }
        let activityDays = ordered.filter { (daySnapshots[$0]?.activeUsers ?? 0) > 0 }.count

        return AgentSnapshot(
            id: id,
            name: name,
            iconName: iconName,
            assetName: assetName,
            sourceType: .subscription,
            quotaUsed: totalTokens,
            quotaTotal: 0,                       // Copilot 无固定额度 → 无限
            quotaUnit: "tokens",
            resetTimeString: "",
            currency: "USD",
            origin: .ideTool,                    // Copilot 属 IDE 内消耗
            totalTokens: totalTokens,
            totalCost: 0,
            modelUsages: [],
            sevenDayTrend: sevenDayTrend,
            dailyHeatmap: dailyHeatmap,
            activityDays: activityDays,
            status: .ok,
            lastUpdated: Date(),
            errorMessage: ""
        )
    }

    /// 拉取单日 Copilot 用量（GET /orgs/{org}/copilot/usage?day=YYYY-MM-DD）
    private static func fetchCopilotDay(url: String, token: String) async throws -> [String: Any] {
        guard let requestURL = URL(string: url) else { throw APIError.invalidURL }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard http.statusCode == 200 else {
            throw APIError.httpError(url: url, statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw APIError.decodingError(L("Copilot response is not valid JSON"))
        }
        return json
    }
}

// ============================================================
// MARK: - LocalLogSource — 本地 CLI Agent 用量统计
// ============================================================

/// 解析本地 CLI Agent 的日志文件，统计 Token 消耗。
/// 支持 Claude Code (~/.claude/projects/**/*.jsonl) 与 Codex (~/.codex/sessions/**/*.jsonl)。
/// 依赖 FileManager 读取（App sandbox 已关闭，可读用户目录）。
struct LocalLogSource: AgentDataSource {

    enum LocalKind: String {
        case claudeCode   // Claude Code
        case codex        // Codex CLI
        case customPath   // 用户自定义文件/目录
    }

    let id: String
    let name: String
    let iconName: String
    let assetName: String?            // 品牌资源图（nil = 回退 iconName SF Symbol）
    let sourceType: AgentSourceType = .local
    let semantics: UsageSemantics = .cumulative

    private let kind: LocalKind
    private let customPath: String

    init(id: String, name: String, iconName: String, assetName: String? = nil, kind: LocalKind, customPath: String = "") {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.assetName = assetName
        self.kind = kind
        self.customPath = customPath
    }

    /// 官方额度抓取器 — 按数据源类型自动读取真实登录目录（~/.claude、~/.codex）；customPath 无官方额度
    private var quotaFetcher: QuotaFetcher? {
        switch kind {
        case .claudeCode: return ClaudeQuotaFetcher()
        case .codex:      return CodexQuotaFetcher()
        case .customPath: return nil
        }
    }

    func fetchSnapshot() async throws -> AgentSnapshot {
        // 额度抓取与日志解析并行（额度走网络，日志走本地 IO）
        let fetcher = quotaFetcher
        let quotaTask: Task<Result<QuotaSnapshot, Error>?, Never>?
        if let fetcher, fetcher.isLoggedIn {
            quotaTask = Task {
                do { return .success(try await fetcher.fetchQuota()) }
                catch { return .failure(error) }
            }
        } else {
            quotaTask = nil
        }
        defer { quotaTask?.cancel() }

        let urls = try logURLs()
        var totalTokens = 0
        var modelTokens: [String: Int] = [:]
        var dayTokens: [Date: Int] = [:]
        var modelDayTokens: [String: [Date: Int]] = [:]

        for url in urls {
            var isDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                // 目录：枚举其下所有 jsonl
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
                for file in files where file.pathExtension == "jsonl" {
                    parseLogFile(
                        file, totalTokens: &totalTokens, modelTokens: &modelTokens,
                        dayTokens: &dayTokens, modelDayTokens: &modelDayTokens
                    )
                }
            } else if url.pathExtension == "jsonl" {
                // 单个 jsonl 文件（customPath 或 codex 会话文件）
                parseLogFile(
                    url, totalTokens: &totalTokens, modelTokens: &modelTokens,
                    dayTokens: &dayTokens, modelDayTokens: &modelDayTokens
                )
            }
        }

        let modelUsages = modelTokens
            .sorted { $0.value > $1.value }
            .enumerated()
            .map { i, item in
                ModelUsageItem(
                    id: "model_\(i)",
                    modelName: item.key,
                    tokenAmount: item.value,
                    usagePercent: totalTokens > 0 ? Double(item.value) / Double(totalTokens) : 0
                )
            }

        // 每日热力图 + 7 日趋势（按日志时间戳聚合）
        let dailyHeatmap: [DailyUsage] = dayTokens
            .filter { $0.value > 0 }
            .map { date, tokens in
                DailyUsage(date: date, tokenCount: tokens, level: heatmapLevel(for: tokens))
            }
            .sorted { $0.date < $1.date }
        let sevenDayTrend = computeSevenDayTrend(from: dailyHeatmap)
        let activeDays = dailyHeatmap.count

        var snapshot = AgentSnapshot(
            id: id,
            name: name,
            iconName: iconName,
            assetName: assetName,
            sourceType: .local,
            quotaUsed: totalTokens,
            quotaTotal: 0,                       // 本地用量无固定额度
            quotaUnit: "tokens",
            resetTimeString: "Cumulative",
            currency: "USD",
            origin: .ideTool,                    // 本地 Agent 属 IDE / CLI 内消耗
            totalTokens: totalTokens,
            totalCost: 0,
            modelUsages: modelUsages,
            sevenDayTrend: sevenDayTrend,
            dailyHeatmap: dailyHeatmap,
            activityDays: activeDays,
            modelDailyTokens: modelDayTokens.flatMap { model, dayMap in
                dayMap.map { ModelDailyToken(modelName: model, date: $0.key, tokens: $0.value) }
            },
            status: .ok,
            lastUpdated: Date(),
            errorMessage: ""
        )

        // 合并官方额度：成功则填充额度字段（利用率按 0~100 映射）；失败仅记录具体原因，不降级日志数据
        if let result = await quotaTask?.value {
            switch result {
            case .success(let quota):
                Self.applyQuota(quota, to: &snapshot)
            case .failure(let error):
                snapshot.errorMessage = L("Failed to fetch quota (local usage is still valid): %@", error.localizedDescription)
            }
        }
        return snapshot
    }

    // MARK: - 官方额度合并

    /// 将官方额度合并进快照（百分比制：quotaTotal=100，quotaUnit=%）。
    /// ★ 多窗口：quotaWindows 原样落库，主窗口字段为兼容镜像。
    /// ★ cycleStart 由周期窗口推导，供模型板块做周期内过滤。
    /// 模型级额度按模型名模糊匹配注入 modelUsages。
    static func applyQuota(_ quota: QuotaSnapshot, to snapshot: inout AgentSnapshot) {
        snapshot.quotaWindows = quota.windows
        snapshot.cycleStart = quota.window(.cycle)?.cycleStart
        snapshot.quotaUsed = Int(round(clampPercent(quota.usedPercent)))
        snapshot.quotaTotal = 100
        snapshot.quotaUnit = "%"
        // 兼容旧字段：取主窗口（5h 优先）的重置文案，按其窗口精度格式化
        if let primary = quota.primaryWindow {
            snapshot.resetTimeString = quotaResetText(
                from: primary.resetsAt, windowLabel: primary.label, kind: primary.kind
            )
        } else {
            snapshot.resetTimeString = ""
        }

        guard !quota.modelLimits.isEmpty else { return }
        for index in snapshot.modelUsages.indices {
            let logModel = snapshot.modelUsages[index].modelName
            guard let limit = quota.modelLimits.first(where: { Self.matches($0.modelName, logModel) }) else { continue }
            snapshot.modelUsages[index].quotaUsed = Int(round(clampPercent(limit.usedPercent)))
            snapshot.modelUsages[index].quotaTotal = 100
            // ★ 存时刻而不只存文案，前端才能显示实时倒计时（模型级为周窗口 → 精确到小时）
            snapshot.modelUsages[index].quotaResetsAt = limit.resetsAt
            snapshot.modelUsages[index].quotaResetText = quotaResetText(
                from: limit.resetsAt,
                windowLabel: QuotaWindowKind.cycle.displayLabel,
                kind: .cycle
            )
        }
    }

    /// 模型名匹配：接口名是日志模型名的子串（"opus" ⊂ "claude-opus-4-8"）或相等
    static func matches(_ apiName: String, _ logName: String) -> Bool {
        let a = apiName.lowercased()
        let l = logName.lowercased()
        return l == a || l.contains(a)
    }

    // MARK: - 日志目录

    private func logURLs() throws -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch kind {
        case .claudeCode:
            // ~/.claude/projects/<project-hash>/<uuid>.jsonl
            let projectsDir = home.appendingPathComponent(".claude/projects")
            let dirs = (try? FileManager.default.contentsOfDirectory(
                at: projectsDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            return dirs.filter { $0.hasDirectoryPath }
        case .codex:
            // 新版：~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl（递归三层）
            // 旧版 fallback：~/.codex/sessions/<date>/*.jsonl
            let sessionsDir = home.appendingPathComponent(".codex/sessions")
            return Self.codexLogFiles(in: sessionsDir)
        case .customPath:
            // 用户指定路径：支持单个 jsonl 文件或包含 jsonl 的目录
            guard !customPath.isEmpty else { return [] }
            let expanded = (customPath as NSString).expandingTildeInPath
            return [URL(fileURLWithPath: expanded)]
        }
    }

    /// 收集 Codex 会话目录下的 jsonl 文件。
    /// 新版：sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl（递归三层，rollout- 前缀）；
    /// 旧版：sessions/<date>/*.jsonl（单层，无前缀）。
    /// 优先返回 rollout- 前缀文件；若一个都没有，回退到全部 jsonl（旧版兼容），
    /// 并排除 session_index.jsonl 这类索引文件。
    static func codexLogFiles(in sessionsDir: URL) -> [URL] {
        let all = Self.jsonlFilesRecursively(in: sessionsDir)
        let rollout = all.filter { $0.lastPathComponent.hasPrefix("rollout-") }
        if !rollout.isEmpty { return rollout }
        return all.filter { $0.lastPathComponent != "session_index.jsonl" }
    }

    private static func jsonlFilesRecursively(in dir: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            result.append(url)
        }
        return result
    }

    // MARK: - 日志解析

    /// 解析单个 jsonl 文件，累加 token、模型统计与每日用量。
    /// Claude Code 每行含 "message.usage"（input_tokens/output_tokens）与 "timestamp"；
    /// Codex 新版 rollout 每行含 "event_msg"/"token_count"（会话累计值，取最后一条）
    /// 与 "session_meta"（payload.model_provider 提供模型名）；
    /// Codex 旧版每行含 "tokens"（prompt/completion）。
    private func parseLogFile(
        _ file: URL,
        totalTokens: inout Int,
        modelTokens: inout [String: Int],
        dayTokens: inout [Date: Int],
        modelDayTokens: inout [String: [Date: Int]]
    ) {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return }
        let result = Self.parseLogContent(content)
        totalTokens += result.totalTokens
        for (k, v) in result.modelTokens { modelTokens[k, default: 0] += v }
        for (k, v) in result.dayTokens { dayTokens[k, default: 0] += v }
        for (model, dayMap) in result.modelDayTokens {
            for (day, tokens) in dayMap { modelDayTokens[model, default: [:]][day, default: 0] += tokens }
        }
    }

    /// 本地日志解析结果。
    /// `modelDayTokens` 是「模型 × 日期」明细 — 模型板块按额度周期过滤、Token 账本按天写入都依赖它。
    struct LocalLogParseResult: Equatable {
        var totalTokens: Int = 0
        /// 模型 → token 总数
        var modelTokens: [String: Int] = [:]
        /// 日期 → token 总数
        var dayTokens: [Date: Int] = [:]
        /// ★ 模型 → [日期: token]
        var modelDayTokens: [String: [Date: Int]] = [:]
    }

    /// 纯字符串解析（供单元测试）
    static func parseLogContent(_ content: String) -> LocalLogParseResult {
        var result = LocalLogParseResult()
        let lines = content.components(separatedBy: .newlines)
        let calendar = Calendar.current
        let isoFormatter = ISO8601DateFormatter()

        // Codex 新版 rollout 状态：token_count 是会话累计值，只取最后一条，避免重复累加；
        // 模型名来自 session_meta 行的 payload.model_provider（兼容 payload.model）。
        var codexModel = "unknown"
        var codexLastTokens = 0
        var codexLastDate = Date()
        var sawTokenCount = false

        /// 记录一条用量（同时写入模型总数 / 每日总数 / 模型×日期明细）
        func record(model: String, tokens: Int, date: Date) {
            guard tokens > 0 else { return }
            let day = calendar.startOfDay(for: date)
            result.totalTokens += tokens
            result.modelTokens[model, default: 0] += tokens
            result.dayTokens[day, default: 0] += tokens
            result.modelDayTokens[model, default: [:]][day, default: 0] += tokens
        }

        for line in lines {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }

            // 行级时间戳（Claude Code / Codex 日志均含 ISO8601 "timestamp"）
            var lineDate = Date()
            if let ts = json["timestamp"] as? String {
                lineDate = isoFormatter.date(from: ts) ?? lineDate
            }

            // Codex 新版 rollout：type == "event_msg"，payload.type == "token_count"
            if let type = json["type"] as? String {
                if type == "session_meta",
                   let payload = json["payload"] as? [String: Any] {
                    codexModel = (payload["model_provider"] as? String)
                        ?? (payload["model"] as? String)
                        ?? codexModel
                }
                if type == "event_msg",
                   let payload = json["payload"] as? [String: Any],
                   (payload["type"] as? String) == "token_count",
                   let info = payload["info"] as? [String: Any],
                   let usage = info["total_token_usage"] as? [String: Any] {
                    let input = (usage["input_tokens"] as? Int) ?? 0
                    let output = (usage["output_tokens"] as? Int) ?? 0
                    // total_tokens = input + output；cached ⊂ input、reasoning ⊂ output，无需剔除
                    codexLastTokens = (usage["total_tokens"] as? Int) ?? (input + output)
                    codexLastDate = lineDate
                    sawTokenCount = true
                }
            }

            // Claude Code: message.usage.{input_tokens, output_tokens}
            if let message = json["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any] {
                let input = (usage["input_tokens"] as? Int) ?? 0
                let output = (usage["output_tokens"] as? Int) ?? 0
                let model = (message["model"] as? String) ?? "unknown"
                record(model: model, tokens: input + output, date: lineDate)
            }

            // Codex 旧版: tokens.{prompt, completion}（部分版本在 "payload" 下）
            // 同一文件已含 token_count（新版）时跳过，避免重复计费
            if !sawTokenCount,
               let tokens = json["tokens"] as? [String: Any] {
                let prompt = (tokens["prompt"] as? Int) ?? 0
                let completion = (tokens["completion"] as? Int) ?? 0
                let model = (json["model"] as? String) ?? "unknown"
                record(model: model, tokens: prompt + completion, date: lineDate)
            }
        }

        // 取最后一条 token_count（会话累计值）
        if sawTokenCount {
            record(model: codexModel, tokens: codexLastTokens, date: codexLastDate)
        }

        return result
    }
}
