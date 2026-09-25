//
//  ZaiPlanTests.swift
//  TokenHamsterTests
//
//  Z.ai / 智谱 GLM Coding Plan 官方接口解析与数据源行为。
//
//  ★ 这些测试的重点是**真实响应结构**（不是我们以为的结构）：
//    1. `type` 可能是 `CREDIT_LIMIT`（积分制套餐）而不只是 `TOKENS_LIMIT`
//    2. 窗口长度由 `unit` + `number` 编码，**不是数组顺序**
//    3. `nextResetTime` 是重置倒计时的唯一来源（epoch 毫秒）
//    4. `model-usage` 是 x_time × modelDataList 的**矩阵**，不是逐条记录
//  前三个最初都写错了，回归测试固定在这里。
//

import Foundation
import Testing
@testable import TokenHamster

// ============================================================
// MARK: - base URL 归一化
// ============================================================

struct ZaiQuotaBaseURLTests {

    @Test func keepsSchemeAndHostOnly() {
        #expect(zaiQuotaBaseURL(from: "https://open.bigmodel.cn") == "https://open.bigmodel.cn")
        #expect(zaiQuotaBaseURL(from: "https://api.z.ai/") == "https://api.z.ai")
        // 直接粘官方文档里的协议端点也要能用（路径被丢弃）
        #expect(zaiQuotaBaseURL(from: "https://open.bigmodel.cn/api/anthropic")
                == "https://open.bigmodel.cn")
        #expect(zaiQuotaBaseURL(from: "https://api.z.ai/api/anthropic") == "https://api.z.ai")
    }

    /// ★ 端口必须保留（`URL.host` 不含端口）—— 丢端口会直接连不上
    @Test func preservesNonDefaultPort() {
        #expect(zaiQuotaBaseURL(from: "http://127.0.0.1:8731") == "http://127.0.0.1:8731")
        #expect(zaiQuotaBaseURL(from: "http://127.0.0.1:8731/api/monitor") == "http://127.0.0.1:8731")
        #expect(zaiQuotaBaseURL(from: "https://example.com:8443") == "https://example.com:8443")
        // 隐式默认端口不写出来
        #expect(zaiQuotaBaseURL(from: "https://api.z.ai:443") == "https://api.z.ai")
        #expect(zaiQuotaBaseURL(from: "http://example.com:80") == "http://example.com")
    }

    @Test func toleratesMissingScheme() {
        #expect(zaiQuotaBaseURL(from: "api.z.ai") == "https://api.z.ai")
        #expect(zaiQuotaBaseURL(from: "  open.bigmodel.cn  ") == "https://open.bigmodel.cn")
    }

    @Test func rejectsUnusableInput() {
        #expect(zaiQuotaBaseURL(from: "") == nil)
        #expect(zaiQuotaBaseURL(from: "   ") == nil)
        #expect(zaiQuotaBaseURL(from: "ftp://x.com") == nil)   // 非 http(s)
    }
}

// ============================================================
// MARK: - quota/limit 解析
// ============================================================

struct ZaiQuotaParserTests {

    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    /// 真实响应形状（字段取自第三方生产实现的 fixture）
    private func response(limits: [[String: Any]], planName: String? = "Pro") -> [String: Any] {
        var data: [String: Any] = ["limits": limits]
        if let planName { data["planName"] = planName }
        return ["code": 200, "msg": "success", "success": true, "data": data]
    }

    private func sessionReset() -> Double {
        (now.timeIntervalSince1970 + 3 * 3600) * 1000   // 3 小时后，合理
    }

    @Test func parsesEnvelopeAndPlanName() throws {
        let quota = try ZaiQuotaParser.parse(
            response(limits: [["type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 25]]),
            now: now
        )
        #expect(quota.planName == "Pro")
        #expect(quota.limits.count == 1)
    }

    /// ★ unit=3（小时）× number=5 = 300 分钟 → 5 小时会话窗口
    @Test func sessionWindowFromUnit3Number5() throws {
        let quota = try ZaiQuotaParser.parse(
            response(limits: [[
                "type": "TOKENS_LIMIT", "unit": 3, "number": 5,
                "percentage": 25, "nextResetTime": sessionReset(),
            ]]),
            now: now
        )
        let session = try #require(quota.sessionWindow)
        #expect(session.windowMinutes == 300)
        #expect(session.usedPercent == 25)
        #expect(session.resetsAt != nil)
        #expect(quota.cycleWindow == nil)      // 只有一个窗口
    }

    /// ★ unit=6（周）× number=1 = 10080 分钟 → 周期窗口（最长的那条）
    @Test func weeklyWindowFromUnit6Number1() throws {
        let quota = try ZaiQuotaParser.parse(
            response(limits: [
                ["type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 25],
                ["type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 9],
            ]),
            now: now
        )
        let cycle = try #require(quota.cycleWindow)
        #expect(cycle.windowMinutes == 10_080)
        #expect(cycle.usedPercent == 9)
        #expect(quota.sessionWindow?.usedPercent == 25)
    }

    /// ★★ 回归：积分制套餐用 `CREDIT_LIMIT`（Lite 等）——
    /// 只认 TOKENS_LIMIT 会让这些用户一个窗口都读不到。
    @Test func creditLimitCountsAsQuotaWindow() throws {
        let quota = try ZaiQuotaParser.parse(
            response(limits: [
                ["type": "CREDIT_LIMIT", "unit": 3, "number": 5,
                 "usage": 2000, "currentValue": 0, "remaining": 2000, "percentage": 0],
                ["type": "CREDIT_LIMIT", "unit": 6, "number": 1,
                 "usage": 10000, "currentValue": 2004, "remaining": 7995, "percentage": 20],
            ]),
            now: now
        )
        #expect(quota.isCreditPlan)
        #expect(quota.isEmpty == false)                  // ★ 不能是空
        #expect(quota.sessionWindow?.isCredit == true)
        #expect(quota.cycleWindow?.isCredit == true)
        // 用 usage/remaining 重算：10000 − 7995 = 2005 → 20.05%
        #expect(abs((quota.cycleWindow?.usedPercent ?? 0) - 20.05) < 0.01)
    }

    /// ★ 回归：窗口顺序不能依赖数组顺序 —— 反着给也要正确分类
    @Test func windowOrderDoesNotDependOnArrayOrder() throws {
        let quota = try ZaiQuotaParser.parse(
            response(limits: [
                ["type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 9],    // 周先出现
                ["type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 25],   // 5h 后出现
            ]),
            now: now
        )
        #expect(quota.sessionWindow?.usedPercent == 25)   // 短窗口 = session
        #expect(quota.cycleWindow?.usedPercent == 9)      // 长窗口 = cycle
    }

    /// MCP（TIME_LIMIT，月窗口）不映射到额度条
    @Test func mcpTimeLimitIsNotAQuotaWindow() throws {
        let quota = try ZaiQuotaParser.parse(
            response(limits: [
                ["type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 25],
                ["type": "TIME_LIMIT", "unit": 5, "number": 1, "percentage": 5,
                 "currentValue": 1, "usage": 20],
            ]),
            now: now
        )
        #expect(quota.mcpWindow != nil)
        #expect(quota.mcpWindow?.usedPercent == 5)
        #expect(quota.mcpWindow?.windowMinutes == 30 * 24 * 60)   // 月，不是 1 分钟
        #expect(quota.quotaWindows.count == 1)                    // MCP 不计入额度条
    }

    /// usage/remaining 比 percentage 更靠得住 → 用它重算
    @Test func recomputesPercentFromUsageAndRemaining() throws {
        let quota = try ZaiQuotaParser.parse(
            response(limits: [[
                "type": "TOKENS_LIMIT", "unit": 3, "number": 5,
                "percentage": 1,            // 故意给错
                "usage": 100, "remaining": 25, "currentValue": 75,
            ]]),
            now: now
        )
        #expect(abs((quota.sessionWindow?.usedPercent ?? 0) - 75) < 0.01)
    }

    /// 无 usage 时仍用 percentage
    @Test func fallsBackToPercentageWithoutUsage() throws {
        let quota = try ZaiQuotaParser.parse(
            response(limits: [["type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 42.5]]),
            now: now
        )
        #expect(quota.sessionWindow?.usedPercent == 42.5)
    }

    /// ★ epoch 毫秒解析 + 合理性校验
    @Test func rejectsImplausibleSessionReset() throws {
        // 5h 窗口却报 20 小时后重置 → 丢弃（时区/单位处理出错的信号）
        let badReset = (now.timeIntervalSince1970 + 20 * 3600) * 1000
        let quota = try ZaiQuotaParser.parse(
            response(limits: [[
                "type": "TOKENS_LIMIT", "unit": 3, "number": 5,
                "percentage": 25, "nextResetTime": badReset,
            ]]),
            now: now
        )
        #expect(quota.sessionWindow?.resetsAt == nil)
    }

    /// 周期窗口不受 5h 合理性约束
    @Test func weeklyResetIsNotSubjectToSessionPlausibility() throws {
        let reset = (now.timeIntervalSince1970 + 6 * 24 * 3600) * 1000
        let quota = try ZaiQuotaParser.parse(
            response(limits: [
                ["type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 25],
                ["type": "TOKENS_LIMIT", "unit": 6, "number": 1,
                 "percentage": 9, "nextResetTime": reset],
            ]),
            now: now
        )
        #expect(quota.cycleWindow?.resetsAt != nil)
    }

    /// 响应级校验：只看 HTTP 200 会把业务错误当成功
    @Test func rejectsBusinessErrorEnvelope() {
        #expect(throws: QuotaError.self) {
            try ZaiQuotaParser.parse(["code": 401, "msg": "token expired", "success": false])
        }
        #expect(throws: QuotaError.self) {
            try ZaiQuotaParser.parse(["code": 200, "success": false])
        }
        #expect(throws: QuotaError.self) {
            try ZaiQuotaParser.parse(["msg": "no envelope at all"])
        }
    }

    @Test func missingLimitsArrayThrows() {
        #expect(throws: QuotaError.self) {
            try ZaiQuotaParser.parse(["code": 200, "success": true, "data": [:]])
        }
    }

    /// 形状不合法的条目跳过，但不影响其他条目
    @Test func skipsMalformedEntries() throws {
        let quota = try ZaiQuotaParser.parse(
            response(limits: [
                ["type": "TOKENS_LIMIT"],                                        // 缺 unit/number/percentage
                ["type": "TOKENS_LIMIT", "unit": 3, "number": 5],                // 缺 percentage
                ["unit": 3, "number": 5, "percentage": 10],                      // 缺 type
                ["type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 30],  // 唯一合法
            ]),
            now: now
        )
        #expect(quota.limits.count == 1)
        #expect(quota.sessionWindow?.usedPercent == 30)
    }

    /// 数值容错：字符串数字 / 超界夹取
    @Test func coercesNumericTypesAndClamps() throws {
        let quota = try ZaiQuotaParser.parse(
            response(limits: [
                ["type": "TOKENS_LIMIT", "unit": "3", "number": "5", "percentage": "88.5"],
                ["type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 140],
            ]),
            now: now
        )
        #expect(quota.sessionWindow?.usedPercent == 88.5)
        #expect(quota.cycleWindow?.usedPercent == 100)   // 夹取，不出现 140%
    }
}

// ============================================================
// MARK: - model-usage 矩阵解析
// ============================================================

struct ZaiModelUsageParserTests {

    private func response(labels: [String], models: [[String: Any]]) -> [String: Any] {
        ["code": 200, "msg": "success", "success": true,
         "data": ["x_time": labels, "modelDataList": models]]
    }

    /// ★★ 回归：真实结构是「时间轴 × 模型」矩阵，不是逐条记录。
    /// 按 list/records/items 去找会完全读不到。
    @Test func parsesMatrixShape() throws {
        let json = response(
            labels: ["2026-09-18 10:00", "2026-09-19 10:00"],
            models: [
                ["modelName": "glm-5.3", "tokensUsage": [100, 200]],
                ["modelName": "glm-5.3-flash", "tokensUsage": [10, 20]],
            ]
        )
        let parsed = try ZaiModelUsageParser.parse(json)

        #expect(parsed.count == 2)
        #expect(parsed["glm-5.3"]?.values.reduce(0, +) == 300)
        #expect(parsed["glm-5.3-flash"]?.values.reduce(0, +) == 30)
        // 两个不同日期 → 各 2 个桶? 不：每个模型 2 个日期
        #expect(parsed["glm-5.3"]?.count == 2)
    }

    /// ★ 逐小时标签 → **同一响应内按天求和**
    @Test func sumsHourlyPointsIntoOneDay() throws {
        let json = response(
            labels: ["2026-09-19 08:00", "2026-09-19 09:00", "2026-09-19 10:00"],
            models: [["modelName": "glm-5.3", "tokensUsage": [100, 50, 25]]]
        )
        let parsed = try ZaiModelUsageParser.parse(json)
        #expect(parsed["glm-5.3"]?.count == 1)                          // 合并成一天
        #expect(parsed["glm-5.3"]?.values.first == 175)
    }

    @Test func skipsUnknownLabelsAndNonPositiveValues() throws {
        let json = response(
            labels: ["2026-09-19 10:00", "not-a-date", "2026-09-20 10:00"],
            models: [["modelName": "glm-5.3", "tokensUsage": [100, 999, 0]]]
        )
        let parsed = try ZaiModelUsageParser.parse(json)
        // 无法解析的标签跳过；0 值不计
        #expect(parsed["glm-5.3"]?.values.reduce(0, +) == 100)
        #expect(parsed["glm-5.3"]?.count == 1)
    }

    /// tokensUsage 比 x_time 长时越界不崩
    @Test func ignoresIndexOverflow() throws {
        let json = response(
            labels: ["2026-09-19 10:00"],
            models: [["modelName": "glm-5.3", "tokensUsage": [100, 200, 300]]]
        )
        let parsed = try ZaiModelUsageParser.parse(json)
        #expect(parsed["glm-5.3"]?.values.reduce(0, +) == 100)
    }

    @Test func missingMatrixKeysThrows() {
        #expect(throws: QuotaError.self) {
            try ZaiModelUsageParser.parse(["code": 200, "success": true, "data": [:]])
        }
        #expect(throws: QuotaError.self) {
            try ZaiModelUsageParser.parse([
                "code": 200, "success": true,
                "data": ["x_time": ["2026-09-19 10:00"]],   // 缺 modelDataList
            ])
        }
    }

    @Test func businessErrorEnvelopeThrows() {
        #expect(throws: QuotaError.self) {
            try ZaiModelUsageParser.parse(["code": 401, "success": false])
        }
    }

    /// 模型名缺失的条目跳过
    @Test func skipsModelsWithoutName() throws {
        let json = response(
            labels: ["2026-09-19 10:00"],
            models: [
                ["tokensUsage": [100]],                                   // 无 modelName
                ["modelName": "", "tokensUsage": [100]],                  // 空名
                ["modelName": "glm-5.3", "tokensUsage": [50]],
            ]
        )
        let parsed = try ZaiModelUsageParser.parse(json)
        #expect(parsed.keys.sorted() == ["glm-5.3"])
    }
}

// ============================================================
// MARK: - 账户余额（仅国内站）
// ============================================================

struct ZaiBalanceParserTests {

    @Test func parsesChinaBalance() throws {
        let json: [String: Any] = [
            "success": true,
            "data": [
                "availableBalance": 42.5,
                "rechargeAmount": 100,
                "giveAmount": 20,
                "totalSpendAmount": 77.5,
            ],
        ]
        let balance = try #require(ZaiBalanceParser.parse(json))
        #expect(balance.available == 42.5)
        #expect(balance.spent == 77.5)
        #expect(balance.currency == "CNY")
    }

    /// availableBalance 缺失时回退 balance；两者都缺返回 nil
    @Test func fallsBackToBalanceField() throws {
        let withBalance: [String: Any] = ["success": true, "data": ["balance": 8.8]]
        #expect(try #require(ZaiBalanceParser.parse(withBalance)).available == 8.8)

        let empty: [String: Any] = ["success": true, "data": [:]]
        #expect(ZaiBalanceParser.parse(empty) == nil)
    }

    @Test func returnsNilWhenNotSuccess() {
        #expect(ZaiBalanceParser.parse(["success": false, "data": ["availableBalance": 1]]) == nil)
        #expect(ZaiBalanceParser.parse([:]) == nil)
    }

    /// ★ 仅国内站支持余额（`www.bigmodel.cn` 控制台端点）
    @Test func supportsBalanceOnlyForBigmodelHosts() {
        #expect(ZaiBalanceParser.supportsBalance(base: "https://open.bigmodel.cn"))
        #expect(ZaiBalanceParser.supportsBalance(base: "https://www.bigmodel.cn"))
        #expect(!ZaiBalanceParser.supportsBalance(base: "https://api.z.ai"))
    }
}

// ============================================================
// MARK: - 抓取器（HTTP + 认证头）
// ============================================================

struct ZaiPlanQuotaFetcherTests {

    init() { disableURLCacheForMockTests() }

    private let fixedNow = Date(timeIntervalSince1970: 1_789_000_000)

    private func quotaJSON() -> String {
        let reset = (fixedNow.timeIntervalSince1970 + 3 * 3600) * 1000
        return """
        {"code":200,"msg":"success","success":true,"data":{
          "planName":"Pro","limits":[
            {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25,"nextResetTime":\(reset)},
            {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":9}
          ]}}
        """
    }

    /// ★ 认证头是裸 token，**不能**带 Bearer 前缀
    @Test func sendsRawAuthorizationHeaderWithoutBearer() async throws {
        let captured = HeaderRecorder()
        let server = try MockHTTPServer(
            handlers: ["/api/monitor/usage/quota/limit": { _ in self.quotaJSON() }],
            headerSink: { captured.record($0) }
        )
        server.start()
        defer { server.stop() }
        try await server.waitUntilReady()

        let fetcher = try #require(ZaiPlanQuotaFetcher(
            rawBaseURL: server.baseURL, apiKey: "my-plan-key"
        ))
        _ = try await fetcher.fetchQuota(now: fixedNow)

        let auth = try #require(captured.value(for: "Authorization"))
        #expect(auth == "my-plan-key")
        #expect(!auth.hasPrefix("Bearer "))
    }

    /// 端到端：额度 → QuotaSnapshot（含计划名、倒计时、窗口标签）
    @Test func fetchQuotaEndToEnd() async throws {
        let server = try MockHTTPServer(handlers: [
            "/api/monitor/usage/quota/limit": { _ in self.quotaJSON() },
        ])
        server.start()
        defer { server.stop() }
        try await server.waitUntilReady()

        let fetcher = try #require(ZaiPlanQuotaFetcher(
            rawBaseURL: server.baseURL, apiKey: "k"
        ))
        let quota = try await fetcher.fetchQuota(now: fixedNow)

        #expect(quota.planName == "Pro")
        #expect(quota.windows.count == 2)
        #expect(quota.window(.session5h)?.usedPercent == 25)
        #expect(quota.window(.cycle)?.usedPercent == 9)
        #expect(quota.window(.session5h)?.resetsAt != nil)
        #expect(quota.source == "zai-plan")
    }

    /// 积分制套餐 → source 标注不同
    @Test func creditPlanIsLabelledSeparately() {
        let official = ZaiOfficialQuota(
            planName: "Lite",
            limits: [ZaiLimit(
                type: "CREDIT_LIMIT", unit: 3, number: 5,
                usedPercent: 10, resetsAt: nil,
                usage: 2000, remaining: 1800, currentValue: 200,
                windowMinutes: 300
            )]
        )
        let snapshot = ZaiPlanQuotaFetcher.makeSnapshot(official)
        #expect(snapshot.source == "zai-plan-credit")
        #expect(snapshot.window(.session5h)?.label == "5h credit")
    }

    /// 查询时间格式与官方脚本一致：当地时区 `yyyy-MM-dd HH:mm:ss`
    @Test func formatsQueryDateLikeOfficialScript() {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 19
        components.hour = 14; components.minute = 5; components.second = 7
        let calendar = Calendar.current
        let date = calendar.date(from: components)!
        #expect(ZaiPlanQuotaFetcher.formatQueryDate(date, calendar: calendar)
                == "2026-09-19 14:05:07")
    }

    /// 空 Key / 非法地址 → 构造失败（数据源据此报错而不是静默给空卡）
    @Test func requiresKeyAndValidHost() {
        #expect(ZaiPlanQuotaFetcher(rawBaseURL: "https://open.bigmodel.cn", apiKey: "") == nil)
        #expect(ZaiPlanQuotaFetcher(rawBaseURL: "https://open.bigmodel.cn", apiKey: "  ") == nil)
        #expect(ZaiPlanQuotaFetcher(rawBaseURL: "", apiKey: "k") == nil)
        #expect(ZaiPlanQuotaFetcher(rawBaseURL: "open.bigmodel.cn", apiKey: "k") != nil)
    }

    /// 无法识别的 limits → 抛错（不静默返回 0%）
    @Test func unrecognizedLimitsThrows() async throws {
        let server = try MockHTTPServer(handlers: [
            "/api/monitor/usage/quota/limit": { _ in
                #"{"code":200,"success":true,"data":{"limits":[]}}"#
            },
        ])
        server.start()
        defer { server.stop() }
        try await server.waitUntilReady()

        let fetcher = try #require(ZaiPlanQuotaFetcher(rawBaseURL: server.baseURL, apiKey: "k"))
        await #expect(throws: QuotaError.self) {
            _ = try await fetcher.fetchQuota(now: self.fixedNow)
        }
    }
}

// ============================================================
// MARK: - 站点分区（国内 / 国际）
// ============================================================

struct ZaiRegionTests {

    /// 默认 host 与币种按分区决定
    @Test func defaultsPerRegion() {
        #expect(ZaiRegion.china.defaultBaseURL == "https://open.bigmodel.cn")
        #expect(ZaiRegion.global.defaultBaseURL == "https://api.z.ai")
        #expect(ZaiRegion.china.currency == "CNY")      // 国内站计价分人民币
        #expect(ZaiRegion.global.currency == "USD")     // 国际站计价分美元
    }

    /// ★ 账户余额**仅国内站**有 —— 国际站 api.z.ai 无对应端点
    ///   （已用对照实验确认：该网关下 /api/biz/** 任何路径都返回 401，
    ///     所以 401 不能证明端点存在；官方文档也无此接口）
    @Test func accountBalanceIsChinaOnly() {
        #expect(ZaiRegion.china.hasAccountBalance)
        #expect(!ZaiRegion.global.hasAccountBalance)
        #expect(ZaiBalanceParser.supportsBalance(base: "https://open.bigmodel.cn"))
        #expect(!ZaiBalanceParser.supportsBalance(base: "https://api.z.ai"))
    }

    /// 由 base host 推断分区；未知 host 按国际站（无余额）处理
    @Test func detectsRegionFromBase() {
        #expect(ZaiRegion.detect(base: "https://open.bigmodel.cn") == .china)
        #expect(ZaiRegion.detect(base: "https://www.bigmodel.cn") == .china)
        #expect(ZaiRegion.detect(base: "https://api.z.ai") == .global)
        #expect(ZaiRegion.detect(base: "https://example.com") == .global)
        // 省略 scheme 也能认
        #expect(ZaiRegion.detect(base: "open.bigmodel.cn") == .china)
    }

    /// ★ 新增源的默认站点**跟随系统地区**（中国大陆 → 国内站，其余 → 国际站）
    @Test func defaultRegionFollowsSystemRegion() {
        #expect(ZaiRegion.systemDefault(region: "CN") == .china)
        #expect(ZaiRegion.systemDefault(region: "cn") == .china)
        #expect(ZaiRegion.systemDefault(region: "US") == .global)
        #expect(ZaiRegion.systemDefault(region: "") == .global)
        // 预设里带的地址与该站点一致（表单初始值取自这里）
        #expect(agentPresets.first { $0.id == "local-zcode" }?.defaultURL
                == ZaiRegion.systemDefault().defaultBaseURL)
    }

    /// ★ 表单里的地址下拉（`ZaiEndpointPicker`）直接列出这两个官方 URL
    @Test func endpointPickerListsBothOfficialURLs() {
        #expect(ZaiRegion.allCases.map(\.defaultBaseURL)
                == ["https://open.bigmodel.cn", "https://api.z.ai"])
    }

    /// 两个站点的**额度/用量接口路径相同**，只有 host 不同
    @Test func endpointPathsAreIdenticalAcrossRegions() {
        let china = ZaiPlanQuotaFetcher.endpoint(
            ZaiRegion.china.defaultBaseURL, path: "api/monitor/usage/quota/limit"
        )
        let global = ZaiPlanQuotaFetcher.endpoint(
            ZaiRegion.global.defaultBaseURL, path: "api/monitor/usage/quota/limit"
        )
        #expect(china == "https://open.bigmodel.cn/api/monitor/usage/quota/limit")
        #expect(global == "https://api.z.ai/api/monitor/usage/quota/limit")
    }
}

// ============================================================
// MARK: - 本地历史（延长热力图）
// ============================================================

struct ZaiUsageHistoryTests {

    private let calendar = Calendar.current

    /// ★ 合并语义：同一 (模型, 日期) 取 max → 重复抓取幂等、不回退
    @Test func mergeTakesMaxPerDay() {
        var history = ZaiUsageHistory()
        let day = 1_000

        history.merge(model: "glm-5.3", dayValues: [day: 100])
        #expect(history.modelDays["glm-5.3"]?[day] == 100)

        // 更小的值不得覆盖（官方对当天返回递增中的值）
        history.merge(model: "glm-5.3", dayValues: [day: 60])
        #expect(history.modelDays["glm-5.3"]?[day] == 100)

        // 更大的值覆盖
        history.merge(model: "glm-5.3", dayValues: [day: 150])
        #expect(history.modelDays["glm-5.3"]?[day] == 150)
    }

    @Test func mergeAccumulatesNewDaysAndModels() {
        var history = ZaiUsageHistory()
        history.merge(model: "a", dayValues: [1: 10])
        history.merge(model: "a", dayValues: [2: 20])
        history.merge(model: "b", dayValues: [1: 5])

        #expect(history.dailyTotals == [1: 15, 2: 20])          // 跨模型求和
        #expect(history.totalsByModel() == ["a": 30, "b": 5])
        #expect(history.totalTokens == 35)
        #expect(history.activeDays == 2)
    }

    @Test func ignoresZeroAndNegativeValues() {
        var history = ZaiUsageHistory()
        history.merge(model: "a", dayValues: [1: 0, 2: -5])
        #expect(history.modelDays["a"] == nil)
        #expect(history.totalTokens == 0)
    }

    /// ★★ 回归：日期键必须**精确往返**。
    /// 早期用「epoch / 86400」的日序号，在 UTC+8 下 `dayKey * 86400` 会落回**前一天**。
    @Test func dayKeyRoundTripsExactly() {
        for offset in [-400, -100, -1, 0, 1, 100, 400] {
            let original = calendar.startOfDay(for: Date())
                .addingTimeInterval(TimeInterval(offset * 86_400))
            let key = ZaiUsageHistory.dayKey(for: original, calendar: calendar)
            let restored = ZaiUsageHistory.date(forDayKey: key)
            #expect(calendar.isDate(restored, inSameDayAs: original),
                    "offset \(offset) 本地日不一致")
            // 再次取键必须稳定（幂等）
            #expect(ZaiUsageHistory.dayKey(for: restored, calendar: calendar) == key)
        }
    }

    @Test func dailyUsagesAreSortedAndLeveled() {
        var history = ZaiUsageHistory()
        history.merge(model: "a", dayValues: [
            ZaiUsageHistory.dayKey(for: Date(), calendar: calendar): 100,
            ZaiUsageHistory.dayKey(for: Date().addingTimeInterval(-86_400), calendar: calendar): 50,
        ])
        let usages = history.dailyUsages()
        #expect(usages.count == 2)
        #expect(usages[0].date < usages[1].date)          // 升序
        #expect(usages.allSatisfy { $0.tokenCount > 0 })
        #expect(usages[1].level >= 1)                     // 有值 → 至少 1 级
    }

    @Test func modelDailyTokensMatchesHistory() {
        var history = ZaiUsageHistory()
        history.merge(model: "a", dayValues: [1: 10, 2: 20])
        history.merge(model: "b", dayValues: [1: 5])
        let tokens = history.modelDailyTokens()
        #expect(tokens.count == 3)
        #expect(tokens.reduce(0) { $0 + $1.tokens } == 35)
    }

    /// 口径版本不符 → 丢弃重算（不迁移）
    @Test func discardsHistoryWithOtherVersion() throws {
        let legacy = Data(#"{"version":999,"modelDays":{"a":{"1":100}}}"#.utf8)
        let decoded = try JSONDecoder().decode(ZaiUsageHistory.self, from: legacy)
        #expect(decoded.modelDays.isEmpty)
        #expect(decoded.version == ZaiUsageHistory.currentVersion)
    }

    @Test func historyRoundTripsThroughCodable() throws {
        var history = ZaiUsageHistory()
        history.merge(model: "glm-5.3", dayValues: [1: 10, 2: 20])
        let data = try JSONEncoder().encode(history)
        let decoded = try JSONDecoder().decode(ZaiUsageHistory.self, from: data)
        #expect(decoded == history)
    }

    /// 多源集合：每个源一份历史，互不污染
    @Test func storeKeepsSourcesSeparate() throws {
        var store = ZaiUsageHistoryStore()
        store["source-a"].merge(model: "m", dayValues: [1: 10])
        store["source-b"].merge(model: "m", dayValues: [1: 99])

        #expect(store["source-a"].totalTokens == 10)
        #expect(store["source-b"].totalTokens == 99)

        let data = try JSONEncoder().encode(store)
        let decoded = try JSONDecoder().decode(ZaiUsageHistoryStore.self, from: data)
        #expect(decoded["source-a"].totalTokens == 10)
        #expect(decoded["source-b"].totalTokens == 99)
    }
}

// ============================================================
// MARK: - 数据源（官方 API + 本地历史）
// ============================================================

@MainActor
struct ZaiPlanSourceTests {

    private let calendar = Calendar.current

    private func makeStorage() -> (storage: FileAppStorage, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.zai.\(UUID().uuidString)", isDirectory: true)
        return (FileAppStorage(directory: dir), { try? FileManager.default.removeItem(at: dir) })
    }

    /// 官方额度 → 数据源快照（额度窗口、套餐名、倒计时）
    @Test func buildSnapshotCarriesQuotaWindows() throws {
        let official = ZaiOfficialQuota(
            planName: "Pro",
            limits: [
                ZaiLimit(type: "TOKENS_LIMIT", unit: 3, number: 5, usedPercent: 25,
                         resetsAt: Date().addingTimeInterval(3 * 3600),
                         usage: nil, remaining: nil, currentValue: nil, windowMinutes: 300),
                ZaiLimit(type: "TOKENS_LIMIT", unit: 6, number: 1, usedPercent: 9,
                         resetsAt: Date().addingTimeInterval(6 * 86_400),
                         usage: nil, remaining: nil, currentValue: nil, windowMinutes: 10_080),
            ]
        )
        let quota = ZaiPlanQuotaFetcher.makeSnapshot(official)

        var history = ZaiUsageHistory()
        history.merge(model: "glm-5.3", dayValues: [
            ZaiUsageHistory.dayKey(for: Date(), calendar: calendar): 1200,
        ])

        let snapshot = ZaiPlanSource.buildSnapshot(
            id: "zai", name: "Z.ai", iconName: "diamond.fill", assetName: "zai",
            quota: quota, history: history, balance: nil, region: .china, now: Date()
        )

        #expect(snapshot.quotaUnit == "%")
        #expect(snapshot.quotaUsed == 25)                     // 主窗口
        #expect(snapshot.quotaWindows.count == 2)
        #expect(snapshot.sourceType == .subscription)
        #expect(snapshot.origin == .ideTool)
        #expect(snapshot.totalTokens == 1200)
        #expect(snapshot.modelUsages.first?.modelName == "glm-5.3")
        #expect(snapshot.resetTimeString.hasPrefix("Pro · "))  // 套餐名 + 倒计时
        #expect(snapshot.resetTimeString.contains("resets in"))
    }

    /// 国内站余额 → 金额进入快照（CNY）
    @Test func buildSnapshotCarriesBalance() {
        let balance = ZaiAccountBalance(
            available: 42.5, recharged: 100, granted: 20, spent: 77.5
        )
        let snapshot = ZaiPlanSource.buildSnapshot(
            id: "zai", name: "Z.ai", iconName: "diamond.fill", assetName: "zai",
            quota: ZaiPlanQuotaFetcher.makeSnapshot(ZaiOfficialQuota(planName: "Pro")),
            history: ZaiUsageHistory(), balance: balance, region: .china, now: Date()
        )
        #expect(snapshot.totalCost == 42.5)
        #expect(snapshot.currency == "CNY")
    }

    /// 国际站无余额 → 0，但仍能出额度
    @Test func buildSnapshotWithoutBalanceStillWorks() {
        let snapshot = ZaiPlanSource.buildSnapshot(
            id: "zai", name: "Z.ai", iconName: "diamond.fill", assetName: nil,
            quota: ZaiPlanQuotaFetcher.makeSnapshot(ZaiOfficialQuota(planName: "Max")),
            history: ZaiUsageHistory(), balance: nil, region: .global, now: Date()
        )
        #expect(snapshot.totalCost == 0)
        #expect(snapshot.currency == "USD")             // 国际站计价分美元
        #expect(snapshot.resetTimeString == "Max")      // 无窗口 → 退化为套餐名
    }

    /// ★★ 核心交付：热力图**不只是官方 30 天** ——
    /// 本地历史累积后可以远超官方查询上限。
    @Test func heatmapExtendsBeyondOfficialThirtyDays() async throws {
        let (storage, cleanup) = makeStorage()
        defer { cleanup() }

        // 预置 90 天历史（模拟长期累积），官方本次只给最近 30 天
        var store = ZaiUsageHistoryStore()
        var history = ZaiUsageHistory()
        let today = Date()
        for offset in 0..<90 {
            let day = calendar.startOfDay(for: today.addingTimeInterval(TimeInterval(-offset * 86_400)))
            history.merge(model: "glm-5.3", dayValues: [
                ZaiUsageHistory.dayKey(for: day, calendar: calendar): 100,
            ])
        }
        store["zai"] = history
        storage.save(store, forKey: AppConstants.zaiUsageHistoryKey)

        let fetcher = ZaiPlanQuotaFetcher(base: "https://open.bigmodel.cn", apiKey: "k") { url, _ in
            if url.contains("quota/limit") {
                return ["code": 200, "success": true, "data": ["planName": "Pro", "limits": [
                    ["type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 10],
                ]]]
            }
            // model-usage 只回最近 30 天
            let labels = (0..<30).map { offset -> String in
                let day = today.addingTimeInterval(TimeInterval(-offset * 86_400))
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyy-MM-dd"
                return f.string(from: day)
            }
            return ["code": 200, "success": true, "data": [
                "x_time": labels,
                "modelDataList": [["modelName": "glm-5.3", "tokensUsage": Array(repeating: 100, count: 30)]],
            ]]
        }

        let source = ZaiPlanSource(
            id: "zai", name: "Z.ai", iconName: "diamond.fill", assetName: "zai",
            fetcher: fetcher, storage: storage
        )
        let snapshot = try await source.fetchSnapshot()

        // 官方上限 30 天，但热力图有 90 天
        #expect(snapshot.dailyHeatmap.count == 90)
        #expect(snapshot.activityDays == 90)
        #expect(snapshot.sevenDayTrend.count == 7)
        #expect(snapshot.totalTokens == 9_000)
    }

    /// 历史落盘：抓取后写盘，下次仍能读到
    @Test func persistsHistoryAcrossFetches() async throws {
        let (storage, cleanup) = makeStorage()
        defer { cleanup() }

        let fetcher = ZaiPlanQuotaFetcher(base: "https://open.bigmodel.cn", apiKey: "k") { url, _ in
            if url.contains("quota/limit") {
                return ["code": 200, "success": true, "data": ["limits": [
                    ["type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 10],
                ]]]
            }
            return ["code": 200, "success": true, "data": [
                "x_time": ["2026-09-19"],
                "modelDataList": [["modelName": "glm-5.3", "tokensUsage": [500]]],
            ]]
        }
        let source = ZaiPlanSource(
            id: "zai", name: "Z.ai", iconName: "diamond.fill", assetName: nil,
            fetcher: fetcher, storage: storage
        )
        _ = try await source.fetchSnapshot()

        let saved: ZaiUsageHistoryStore? = storage.load(
            ZaiUsageHistoryStore.self, forKey: AppConstants.zaiUsageHistoryKey
        )
        #expect(saved?["zai"].totalTokens == 500)
    }

    /// model-usage 失败**不影响**额度显示（额度必需、用量可选）
    @Test func modelUsageFailureDoesNotBreakQuota() async throws {
        let (storage, cleanup) = makeStorage()
        defer { cleanup() }

        let fetcher = ZaiPlanQuotaFetcher(base: "https://open.bigmodel.cn", apiKey: "k") { url, _ in
            if url.contains("quota/limit") {
                return ["code": 200, "success": true, "data": ["planName": "Pro", "limits": [
                    ["type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 66],
                ]]]
            }
            throw QuotaError.invalidResponse("model-usage 挂了")
        }
        let source = ZaiPlanSource(
            id: "zai", name: "Z.ai", iconName: "diamond.fill", assetName: nil,
            fetcher: fetcher, storage: storage
        )
        let snapshot = try await source.fetchSnapshot()

        #expect(snapshot.quotaUsed == 66)      // 额度照常
        #expect(snapshot.totalTokens == 0)     // 用量缺失
    }

    /// 额度失败 → 抛错（没 Key 就没数据，不显示假 0）
    @Test func quotaFailureThrows() async throws {
        let (storage, cleanup) = makeStorage()
        defer { cleanup() }

        let fetcher = ZaiPlanQuotaFetcher(base: "https://open.bigmodel.cn", apiKey: "k") { _, _ in
            throw QuotaError.notLoggedIn("Key 无效")
        }
        let source = ZaiPlanSource(
            id: "zai", name: "Z.ai", iconName: "diamond.fill", assetName: nil,
            fetcher: fetcher, storage: storage
        )
        await #expect(throws: (any Error).self) {
            _ = try await source.fetchSnapshot()
        }
    }
}
