//
//  CursorQuotaFetcher.swift
//  TokenHamster
//
//  Cursor 额度数据源 — cursor.com 网页接口（Cookie 认证）
//
//  背景：Cursor 个人版没有公开的官方额度 API（`api.cursor.com` 的 Admin API
//  只对 Team / Enterprise 开放，且需 Basic auth），因此这里走网页端接口，
//  认证靠用户从浏览器复制的 session cookie。
//
//  凭据：`WorkosCursorSessionToken` cookie。该 cookie 的值形如
//  `<userId>::<jwt>`，因此 userId 可直接从 cookie 推出，无需用户另填。
//
//  返回结构（按模型聚合的当月请求数）：
//  {
//    "gpt-4":          { "numRequests": 120, "maxRequestUsage": 500 },
//    "claude-4-sonnet":{ "numRequests": 30,  "maxRequestUsage": 500 },
//    "startOfMonth":   "2026-09-01T00:00:00.000Z"
//  }
//  其中 `startOfMonth` 不是模型，是当月计费周期的起点。
//
//  ⚠️ 该接口非官方公开文档，字段名以实测为准；解析层对缺字段做了宽松处理。
//

import Foundation

// ============================================================
// MARK: - Cookie 解析
// ============================================================

enum CursorCookie {

    /// 从用户粘贴的内容中提取 userId 与可直接发送的 Cookie 头。
    /// 接受两种粘贴形式：
    /// - 完整 cookie：`WorkosCursorSessionToken=user_xxx::jwt`
    /// - 仅 cookie 值：`user_xxx::jwt`
    static func parse(_ raw: String) -> (userId: String, cookieHeader: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 取出 cookie 值（可能在 "WorkosCursorSessionToken=" 之后）
        let value: String
        if let range = trimmed.range(of: "WorkosCursorSessionToken=") {
            value = String(trimmed[range.upperBound...])
                .components(separatedBy: ";").first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } else {
            value = trimmed.components(separatedBy: ";").first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        guard !value.isEmpty else { return nil }

        // 值形如 `<userId>::<jwt>`
        let userId = value.components(separatedBy: "::").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !userId.isEmpty else { return nil }

        return (userId, "WorkosCursorSessionToken=\(value)")
    }
}

// ============================================================
// MARK: - 用量响应解析
// ============================================================

/// 单个模型的请求用量
struct CursorModelUsage: Equatable {
    var modelName: String
    var requests: Int
    var maxRequests: Int
}

/// Cursor `/api/usage` 的解析结果
struct CursorUsage: Equatable {
    var models: [CursorModelUsage] = []
    var cycleStart: Date? = nil

    /// 已用请求数（各模型求和）
    var usedRequests: Int { models.reduce(0) { $0 + $1.requests } }
    /// 额度上限（各模型共用一个上限，取第一份非零值）
    var maxRequests: Int { models.first { $0.maxRequests > 0 }?.maxRequests ?? 0 }
}

enum CursorUsageParser {

    /// `startOfMonth` 是周期起点而非模型名，需排除
    static let nonModelKeys: Set<String> = ["startOfMonth", "startOfMonthDate", "startOfCycle"]

    static func parse(_ json: [String: Any]) -> CursorUsage {
        var usage = CursorUsage()

        for (key, value) in json {
            if nonModelKeys.contains(key) {
                if let string = value as? String {
                    usage.cycleStart = parseISO8601Date(string)
                }
                continue
            }
            guard let entry = value as? [String: Any] else { continue }
            let requests = intValue(entry["numRequests"])
            let maxRequests = intValue(entry["maxRequestUsage"])
            // 两个计数都为 0 的键（如未知字段）跳过
            guard requests > 0 || maxRequests > 0 else { continue }
            usage.models.append(CursorModelUsage(
                modelName: key, requests: requests, maxRequests: maxRequests
            ))
        }
        usage.models.sort { $0.requests > $1.requests }
        return usage
    }

    private static func intValue(_ value: Any?) -> Int {
        if let v = value as? Int { return max(0, v) }
        if let v = value as? Double { return max(0, Int(v)) }
        if let v = value as? NSNumber { return max(0, v.intValue) }
        if let v = value as? String { return max(0, Int(v) ?? 0) }
        return 0
    }
}

// ============================================================
// MARK: - Cursor 额度抓取器
// ============================================================

enum CursorQuotaError: LocalizedError {
    case notLoggedIn(String)
    case invalidResponse(String)
    case httpError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn(let msg):     return msg
        case .invalidResponse(let msg): return L("Cursor usage API response error: %@", msg)
        case .httpError(let code):
            return code == 401 || code == 403
                ? L("Cursor cookie has expired or is invalid. Paste a new one in settings.")
                : L("Cursor usage API HTTP %@", code)
        }
    }
}

/// Cursor 额度抓取器（走网页接口，Cookie 认证）。
struct CursorQuotaFetcher {

    /// 注入用：自定义接口地址（便于后续接口变更时调整）
    private let baseURL: String
    /// 用户在设置中粘贴的 cookie
    private let rawCookie: String

    init(rawCookie: String, baseURL: String = "https://cursor.com") {
        self.rawCookie = rawCookie
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
    }

    var isLoggedIn: Bool {
        CursorCookie.parse(rawCookie) != nil
    }

    func fetchQuota() async throws -> QuotaSnapshot {
        guard let credentials = CursorCookie.parse(rawCookie) else {
            throw CursorQuotaError.notLoggedIn(L("No Cursor cookie configured (paste one in settings)"))
        }
        guard let url = URL(string: "\(baseURL)/api/usage?user=\(credentials.userId)") else {
            throw CursorQuotaError.invalidResponse(L("Invalid endpoint URL"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(credentials.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CursorQuotaError.invalidResponse(L("Invalid response"))
        }
        guard http.statusCode == 200 else {
            throw CursorQuotaError.httpError(statusCode: http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CursorQuotaError.invalidResponse(L("Response is not a JSON object"))
        }

        let usage = CursorUsageParser.parse(json)
        return Self.makeSnapshot(usage)
    }

    /// 组装额度快照（纯函数，可单测）。
    /// Cursor 只有「当月请求数」一个维度 → 只产出 cycle 窗口（无 5h 档）。
    static func makeSnapshot(_ usage: CursorUsage, source: String = "cursor-web") -> QuotaSnapshot {
        let limit = usage.maxRequests
        let used = usage.usedRequests

        var windows: [QuotaWindow] = []
        if limit > 0 {
            windows.append(QuotaWindow(
                kind: .cycle,
                usedPercent: clampPercent(Double(used) / Double(limit) * 100),
                resetsAt: usage.cycleStart.flatMap {
                    Calendar.current.date(byAdding: .month, value: 1, to: $0)
                }
            ))
        }

        // 模型级额度：每个模型的「当月请求数 / 上限」百分比
        let modelLimits = usage.models.compactMap { model -> ModelLimit? in
            guard model.maxRequests > 0 else { return nil }
            return ModelLimit(
                modelName: model.modelName,
                usedPercent: clampPercent(Double(model.requests) / Double(model.maxRequests) * 100),
                resetsAt: usage.cycleStart.flatMap {
                    Calendar.current.date(byAdding: .month, value: 1, to: $0)
                }
            )
        }

        return QuotaSnapshot(windows: windows, modelLimits: modelLimits, source: source)
    }
}

// ============================================================
// MARK: - Cursor 数据源
// ============================================================

/// Cursor 数据源：额度来自网页接口（Cookie），模型明细为「请求数」维度。
///
/// ★ 关键取舍：Cursor 不提供 token 数，只有请求数。因此
///   - `totalTokens` 恒为 0（绝不用请求数冒充 token，否则会污染 Token 账本）
///   - `modelUsages` 的 `tokenAmount` 恒为 0，额度百分比放在 `quotaUsed/quotaTotal`
///   前端按「拿不到 token 就不显示」的原则处理即可。
struct CursorSource: AgentDataSource {

    let id: String
    let name: String
    let iconName: String
    let assetName: String?
    let sourceType: AgentSourceType = .local
    let semantics: UsageSemantics = .cumulative

    private let rawCookie: String

    init(id: String, name: String, iconName: String, assetName: String? = nil, rawCookie: String) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.assetName = assetName
        self.rawCookie = rawCookie
    }

    func fetchSnapshot() async throws -> AgentSnapshot {
        let fetcher = CursorQuotaFetcher(rawCookie: rawCookie)
        let quota = try await fetcher.fetchQuota()
        return Self.buildSnapshot(
            id: id, name: name, iconName: iconName, assetName: assetName, quota: quota
        )
    }

    /// 由额度快照组装（纯函数，可单测）
    static func buildSnapshot(
        id: String,
        name: String,
        iconName: String,
        assetName: String?,
        quota: QuotaSnapshot
    ) -> AgentSnapshot {
        let cycleWindow = quota.window(.cycle)

        // 模型明细：token 恒为 0，额度百分比来自接口的请求数
        let modelUsages = quota.modelLimits.enumerated().map { index, limit in
            ModelUsageItem(
                id: "model_\(index)",
                modelName: limit.modelName,
                tokenAmount: 0,                       // ★ 不用请求数冒充 token
                usagePercent: 0,
                quotaUsed: Int(round(clampPercent(limit.usedPercent))),
                quotaTotal: 100,
                quotaResetText: quotaResetText(
                    from: limit.resetsAt,
                    windowLabel: QuotaWindowKind.cycle.displayLabel,
                    kind: .cycle
                ),
                quotaResetsAt: limit.resetsAt          // ★ 供实时倒计时
            )
        }

        return AgentSnapshot(
            id: id,
            name: name,
            iconName: iconName,
            assetName: assetName,
            sourceType: .local,
            quotaUsed: Int(round(cycleWindow?.usedPercent ?? 0)),
            quotaTotal: cycleWindow != nil ? 100 : 0,
            quotaUnit: cycleWindow != nil ? "%" : "requests",
            resetTimeString: quotaResetText(
                from: cycleWindow?.resetsAt,
                windowLabel: QuotaWindowKind.cycle.displayLabel,
                kind: .cycle
            ),
            currency: "USD",
            quotaWindows: quota.windows,
            cycleStart: cycleWindow?.cycleStart,
            origin: .ideTool,
            totalTokens: 0,
            totalCost: 0,
            modelUsages: modelUsages,
            status: .ok,
            lastUpdated: Date(),
            errorMessage: ""
        )
    }
}
