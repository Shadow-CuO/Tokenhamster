//
//  MockServerTests.swift
//  TokenHamsterTests
//
//  Mock server 端到端验证：本地 HTTP server 返回各厂商官方 API 的真实 JSON 结构，
//  验证 fetch → parse → aggregate → heatmap → 消耗检测 完整链路。
//

import Foundation
import Network
import Testing
@testable import TokenHamster

// ============================================================
// MARK: - 极简本地 HTTP Mock Server（NWListener 实现）
// ============================================================

/// 禁用磁盘缓存：防止 mock 响应被 URLSession 写进真实的
/// ~/Library/Caches/<bundleID>/（每个 mock 测试运行前调用）。
func disableURLCacheForMockTests() {
    URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)
}

/// 记录请求头（用于断言认证头等细节）。server 在自己的队列上回调 → 加锁保证安全。
final class HeaderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: String] = [:]

    func record(_ headers: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        for (key, value) in headers { store[key.lowercased()] = value }
    }

    /// 大小写不敏感地取值
    func value(for name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return store[name.lowercased()]
    }
}

/// 按路径分发请求的本地 HTTP server。
/// handler 签名：`(调用次数) -> JSON 字符串`，可用于模拟数据变化。
final class MockHTTPServer {

    private let listener: NWListener
    private let queue = DispatchQueue(label: "tokenhamster.mock.server")
    private var handlers: [String: (Int) -> String]
    private var callCounts: [String: Int] = [:]
    /// 可选：把每个请求的头部交给外部记录（断言认证头用）
    private let headerSink: (([String: String]) -> Void)?

    /// 监听端口（start() 后有效）
    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var baseURL: String { "http://127.0.0.1:\(port)" }

    init(handlers: [String: (Int) -> String], headerSink: (([String: String]) -> Void)? = nil) throws {
        self.handlers = handlers
        self.headerSink = headerSink
        self.listener = try NWListener(using: .tcp, on: .any)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.start(queue: queue)
    }

    /// 等待监听器进入 .ready 状态（此时 port 才有效）。
    /// NWListener 用 `.any` 时端口是异步分配的，start() 后立即读 port 会得到 nil。
    func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            switch listener.state {
            case .ready:
                continuation.resume()
                return
            case .failed(let error):
                continuation.resume(throwing: error)
                return
            default:
                break
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
        }
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            // 解析请求行：GET /path?query HTTP/1.1
            let lines = request.components(separatedBy: "\r\n")
            guard let first = lines.first else { conn.cancel(); return }
            let parts = first.split(separator: " ")
            guard parts.count >= 2 else { conn.cancel(); return }
            let rawPath = String(parts[1])
            let path = rawPath.components(separatedBy: "?").first ?? rawPath

            // 解析请求头（Index 0 是请求行）
            if let sink = self.headerSink {
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let name = String(line[line.startIndex..<colon])
                        .trimmingCharacters(in: .whitespaces)
                    let value = String(line[line.index(after: colon)...])
                        .trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { headers[name] = value }
                }
                sink(headers)
            }

            let count = self.callCounts[path, default: 0]
            self.callCounts[path] = count + 1
            let body = self.handlers[path]?(count) ?? "{}"

            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: application/json\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                conn.cancel()
            })
        }
    }
}

// ============================================================
// MARK: - OpenAI 官方 Usage API 端到端
// ============================================================

struct OpenAIMockTests {

    init() { disableURLCacheForMockTests() }

    /// OpenAI completions + costs 官方 JSON → DashboardData
    @Test func openAIEndToEnd() async throws {
        let today = Int(Date().timeIntervalSince1970)
        let yesterday = today - 86_400

        let server = try MockHTTPServer(handlers: [
            "/v1/organization/usage/completions": { _ in """
            {"total_usage": 5, "data": [
                {"start_time": \(today), "results": [
                    {"result": {"n_tokens": 4000000}, "dimensions": {"model": "gpt-5.5"}},
                    {"result": {"n_tokens": 1000000}, "dimensions": {"model": "gpt-4.1"}}
                ]},
                {"start_time": \(yesterday), "results": [
                    {"result": {"n_tokens": 2000000}, "dimensions": {"model": "gpt-5.5"}}
                ]}
            ]}
            """
            },
            "/v1/organization/usage/costs": { _ in """
            {"data": [
                {"amount": {"value": 8.50}},
                {"amount": {"value": 4.00}}
            ]}
            """
            },
        ])
        server.start()
        defer { server.stop() }
        try await server.waitUntilReady()

        let service = OpenAIService(baseURL: server.baseURL, apiKey: "sk-test")
        let data = try await service.fetchData()

        // total_usage 单位 = 100 万 tokens → ×1e6
        #expect(data.totalTokens == 5_000_000)
        // 费用聚合
        #expect(abs(data.totalCost - 12.50) < 0.001)
        #expect(data.costCurrency == "USD")
        // 模型排行（按消耗降序：gpt-5.5 = 6M，gpt-4.1 = 1M）
        #expect(data.modelUsages.count == 2)
        #expect(data.modelUsages.first?.modelName == "gpt-5.5")
        #expect(data.modelUsages.first?.tokenAmount == 6_000_000)
        // 每日热力图：2 天
        #expect(data.dailyHeatmap.count == 2)
        #expect(data.activityDays == 2)
        // 7 天趋势：今天与昨天有值
        #expect(data.sevenDayTrend.count == 7)
        #expect(data.sevenDayTrend.last == 5_000_000)   // 今天
        #expect(data.sevenDayTrend[data.sevenDayTrend.count - 2] == 2_000_000) // 昨天
    }

    /// costs 接口 401（无权限）不应导致整个请求失败
    @Test func openAICostsFailureTolerated() async throws {
        let server = try MockHTTPServer(handlers: [
            "/v1/organization/usage/completions": { _ in """
            {"total_usage": 3, "data": [
                {"start_time": \(Int(Date().timeIntervalSince1970)), "results": [
                    {"result": {"n_tokens": 3000000}, "dimensions": {"model": "gpt-5.5"}}
                ]}
            ]}
            """
            },
            "/v1/organization/usage/costs": { _ in """
            {"error": {"message": "insufficient permission"}}
            """
            },
        ])
        server.start()
        defer { server.stop() }
        try await server.waitUntilReady()

        let service = OpenAIService(baseURL: server.baseURL, apiKey: "sk-test")
        let data = try await service.fetchData()
        #expect(data.totalTokens == 3_000_000)
        #expect(data.totalCost == 0)  // 费用失败被容忍
    }
}

// ============================================================
// MARK: - Anthropic Admin API 端到端
// ============================================================

struct AnthropicMockTests {

    init() { disableURLCacheForMockTests() }

    @Test func anthropicEndToEnd() async throws {
        let server = try MockHTTPServer(handlers: [
            "/v1/organizations/org_test/usage_report": { _ in """
            {
              "total_usage": {"all_tokens": 2500000, "api_costs": 33.25},
              "api_usage": {"daily_usage": [
                {"date": "2026-08-07", "all_tokens": 1000000},
                {"date": "2026-08-08", "all_tokens": 1500000}
              ]}
            }
            """
            },
            "/v1/organizations/org_test/limits": { _ in """
            {
              "limits": [
                {"name": "Claude Opus", "enabled": true,
                 "current_usage": {"value": 40}, "usage_limit": {"value": 100},
                 "next_reset_time": "2026-08-15T00:00:00Z"},
                {"name": "Claude Sonnet", "enabled": false,
                 "current_usage": {"value": 10}, "usage_limit": {"value": 100},
                 "next_reset_time": "2026-08-15T00:00:00Z"}
              ]
            }
            """
            },
        ])
        server.start()
        defer { server.stop() }
        try await server.waitUntilReady()

        let service = AnthropicService(
            baseURL: server.baseURL,
            apiKey: "sk-ant-admin-test",
            organizationId: "org_test"
        )
        let data = try await service.fetchData()

        #expect(data.totalTokens == 2_500_000)
        #expect(abs(data.totalCost - 33.25) < 0.001)
        // 只有 enabled 的 limits 进入配额
        #expect(data.quotas.count == 1)
        #expect(data.quotas.first?.name == "Claude Opus")
        #expect(data.quotas.first?.weeklyUsedPercent == 40)
        // 热力图：2 天
        #expect(data.dailyHeatmap.count == 2)
        #expect(data.activityDays == 2)
    }

    @Test func anthropicMissingOrgThrows() async throws {
        let service = AnthropicService(baseURL: "https://api.anthropic.com", apiKey: "sk-test")
        await #expect(throws: APIError.self) {
            try await service.fetchData()
        }
    }
}

// ============================================================
// MARK: - DeepSeek 余额端到端
// ============================================================

struct DeepSeekMockTests {

    init() { disableURLCacheForMockTests() }

    @Test func deepSeekBalanceEndToEnd() async throws {
        let server = try MockHTTPServer(handlers: [
            "/user/balance": { _ in """
            {"is_available": true, "balance_infos": [
                {"currency": "CNY", "total_balance": "88.50", "total_discount": "0.00"}
            ]}
            """
            },
        ])
        server.start()
        defer { server.stop() }
        try await server.waitUntilReady()

        let service = DeepSeekService(baseURL: server.baseURL, apiKey: "sk-test")
        let data = try await service.fetchData()

        // 余额语义 → 金额写入 totalCost
        #expect(abs(data.totalCost - 88.50) < 0.001)
        #expect(data.costCurrency == "CNY")
        #expect(data.quotas.count == 1)
        #expect(data.quotas.first?.resetTimeString == "Available")
    }
}

// ============================================================
// MARK: - Kimi (Moonshot) 余额端到端
// ============================================================

struct KimiMockTests {

    init() { disableURLCacheForMockTests() }

    @Test func kimiBalanceEndToEnd() async throws {
        let server = try MockHTTPServer(handlers: [
            "/v1/users/me/balance": { _ in """
            {"code":0,"data":{"available_balance":49.58894,"voucher_balance":46.58893,"cash_balance":3.00001},"scode":"0x0","status":true}
            """
            },
        ])
        server.start()
        defer { server.stop() }
        try await server.waitUntilReady()

        // 真实场景 base 为 https://api.moonshot.cn/v1（无尾斜杠）
        let service = KimiService(baseURL: server.baseURL + "/v1", apiKey: "sk-kimi-test")
        let data = try await service.fetchData()

        // 余额语义 → 金额写入 totalCost
        #expect(abs(data.totalCost - 49.58894) < 0.001)
        #expect(data.costCurrency == "CNY")
        #expect(data.quotas.count == 1)
        #expect(data.quotas.first?.name == "Kimi Balance")
        #expect(data.quotas.first?.resetTimeString == "Available")
    }
}

// ============================================================
// MARK: - 接口地址拼接 / 可选数值（新余额源共用工具）
// ============================================================

/// 接口地址拼接（纯函数）—— 用户填 `host` 或 `host/v1` 都要能命中
struct APIURLTests {

    @Test func appendsV1WhenMissing() {
        #expect(apiURL("https://api.example.com", path: "key") == "https://api.example.com/v1/key")
        #expect(apiURL("https://api.example.com/v1", path: "key") == "https://api.example.com/v1/key")
    }

    @Test func stripsTrailingSlashes() {
        #expect(apiURL("https://api.example.com/", path: "key") == "https://api.example.com/v1/key")
        #expect(apiURL("https://api.example.com/v1/", path: "key") == "https://api.example.com/v1/key")
    }

    /// OpenRouter 的 base 含 `/api`，补完应为 `/api/v1` 而不是 `/api/v1/v1`
    @Test func handlesOpenRouterStyleBase() {
        #expect(apiURL("https://openrouter.ai/api/v1", path: "key")
                == "https://openrouter.ai/api/v1/key")
        #expect(apiURL("https://openrouter.ai/api", path: "key")
                == "https://openrouter.ai/api/v1/key")
    }

    /// ensureV1 = false 时保持原样
    @Test func ensureV1FalseKeepsBase() {
        #expect(apiURL("https://api.example.com/v1", path: "x", ensureV1: false)
                == "https://api.example.com/v1/x")
    }
}

/// `optionalDouble` 必须区分「字段为 null / 缺失」与「值真的是 0」
struct OptionalDoubleTests {

    @Test func distinguishesNullFromZero() {
        let json: [String: Any] = ["a": NSNull(), "b": 0, "c": 0.0, "d": "12.5", "e": 7]
        #expect(optionalDouble(json, path: "a") == nil)     // null ≠ 0
        #expect(optionalDouble(json, path: "missing") == nil)
        #expect(optionalDouble(json, path: "b") == 0)
        #expect(optionalDouble(json, path: "c") == 0)
        #expect(optionalDouble(json, path: "d") == 12.5)    // 字符串数字
        #expect(optionalDouble(json, path: "e") == 7)
    }

    @Test func readsNestedPath() {
        let json: [String: Any] = ["data": ["limit_remaining": 74.5]]
        #expect(optionalDouble(json, path: "data.limit_remaining") == 74.5)
    }
}

// ============================================================
// MARK: - 余额型快照的公共构造 / MODELS 栏呈现
// ============================================================

struct BalanceDashboardDataTests {

    /// 余额型快照：金额进 totalCost、无 token 维度、额度窗口文案区分可用/已用完
    @Test func buildsBalanceOnlySnapshot() {
        let data = balanceDashboardData(
            amount: 88.88, currency: "CNY",
            quotaID: "siliconflow_balance", quotaName: "SiliconFlow Balance"
        )
        #expect(data.totalTokens == 0)                 // 无 token 维度（不伪造数字）
        #expect(abs(data.totalCost - 88.88) < 0.001)
        #expect(data.costCurrency == "CNY")
        #expect(data.quotas.count == 1)
        #expect(data.quotas.first?.id == "siliconflow_balance")
        #expect(data.quotas.first?.resetTimeString == "Available")
        #expect(data.modelUsages.isEmpty)

        let exhausted = balanceDashboardData(
            amount: 0, currency: "USD",
            quotaID: "x", quotaName: "x", isAvailable: false
        )
        #expect(exhausted.quotas.first?.resetTimeString == "Used up")
    }
}

/// 余额型源在 MODELS 栏的用户可见结果
@MainActor
struct BalanceSourcePresentationTests {

    /// OpenRouter 余额 → MODELS 栏显示 "$xx.xx left"（而非 0 或空白）
    @Test func openRouterBalanceShowsAsAmountLeft() {
        let snap = AgentSnapshot(
            id: "or", name: "OpenRouter", iconName: "arrow.triangle.branch",
            assetName: "openrouter", sourceType: .api,
            resetTimeString: "Available",
            currency: "USD",
            totalTokens: 0, totalCost: 74.5, status: .ok
        )
        let suiteName = "test.tokenhamster.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.tokenhamster.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let vm = DashboardViewModel(userDefaults: defaults, storage: FileAppStorage(directory: tmpDir))
        vm.agentSnapshots = [snap]

        let rows = vm.modelRows
        #expect(rows.count == 1)
        #expect(rows.first?.name == "OpenRouter")
        #expect(rows.first?.usageText == "")              // token 列留白（无伪造数字）
        #expect(rows.first?.quotaText == "$74.50 left")   // 余额列显示真实余额
    }

    /// 全部 API 预设都能建出服务，且新预设已就位
    @Test func allPresetsAreWiredUp() {
        for id in ["openrouter", "siliconflow", "gemini", "custom"] {
            #expect(apiPresets.contains { $0.id == id }, "预设 \(id) 缺失")
        }
        // 每个预设的 apiType 都能经工厂建出服务（不崩、语义明确）
        for preset in apiPresets {
            let service = APIServiceFactory.create(
                type: preset.apiType, baseURL: preset.defaultURL, apiKey: "k"
            )
            #expect(service.semantics == .balance || service.semantics == .cumulative)
        }
    }
}

// ============================================================
// MARK: - OpenRouter 余额端到端
// ============================================================

struct OpenRouterMockTests {

    init() { disableURLCacheForMockTests() }

    /// 普通推理 key → 读 `/key` 的 limit_remaining 作为余额
    @Test func keyRemainingIsUsedAsBalance() async throws {
        let server = try MockHTTPServer(handlers: [
            "/v1/key": { _ in """
            {"data": {"limit": 100, "limit_remaining": 74.5, "usage": 25.5,
                      "is_free_tier": false, "limit_reset": "monthly"}}
            """
            },
        ])
        server.start()
        defer { server.stop() }
        try await server.waitUntilReady()

        let data = try await OpenRouterService(
            baseURL: server.baseURL, apiKey: "sk-or-test"
        ).fetchData()

        #expect(abs(data.totalCost - 74.5) < 0.001)   // 余额放 totalCost
        #expect(data.totalTokens == 0)                // 该端点无 token 维度
        #expect(data.costCurrency == "USD")
        #expect(data.quotas.first?.resetTimeString == "Available")
    }

    /// 余额为 0 → 标记「已用完」（余额型判定依赖此文案）
    @Test func zeroRemainingIsReportedExhausted() async throws {
        let server = try MockHTTPServer(handlers: [
            "/v1/key": { _ in """
            {"data": {"limit": 10, "limit_remaining": 0, "usage": 10}}
            """
            },
        ])
        server.start()
        defer { server.stop() }
        try await server.waitUntilReady()

        let data = try await OpenRouterService(
            baseURL: server.baseURL, apiKey: "sk-or-test"
        ).fetchData()
        #expect(data.quotas.first?.resetTimeString == "Used up")
    }

    /// ★ 无限额度 key（limit_remaining == null）→ 回退 `/credits` 算账户余额
    @Test func unlimitedKeyFallsBackToCredits() async throws {
        let server = try MockHTTPServer(handlers: [
            "/v1/key": { _ in """
            {"data": {"limit": null, "limit_remaining": null, "usage": 25.5}}
            """
            },
            "/v1/credits": { _ in """
            {"data": {"total_credits": 100.5, "total_usage": 25.75}}
            """
            },
        ])
        server.start()
        defer { server.stop() }
        try await server.waitUntilReady()

        let data = try await OpenRouterService(
            baseURL: server.baseURL, apiKey: "sk-or-test"
        ).fetchData()
        // 100.5 − 25.75 = 74.75
        #expect(abs(data.totalCost - 74.75) < 0.001)
    }

    /// credits 里缺 total_credits → 抛错，不静默返回 0
    @Test func missingCreditsFieldThrows() async throws {
        let server = try MockHTTPServer(handlers: [
            "/v1/key": { _ in #"{"data": {"limit_remaining": null}}"# },
            "/v1/credits": { _ in #"{"data": {}}"# },
        ])
        server.start()
        defer { server.stop() }
        try await server.waitUntilReady()

        await #expect(throws: APIError.self) {
            _ = try await OpenRouterService(
                baseURL: server.baseURL, apiKey: "sk-or-test"
            ).fetchData()
        }
    }
}

// ============================================================
// MARK: - 硅基流动 SiliconFlow 余额端到端
// ============================================================

struct SiliconFlowMockTests {

    init() { disableURLCacheForMockTests() }

    /// `/user/info` 的 totalBalance（字符串）→ 余额
    @Test func totalBalanceIsUsedAsBalance() async throws {
        let server = try MockHTTPServer(handlers: [
            "/v1/user/info": { _ in """
            {"code": 20000, "message": "OK", "status": true,
             "data": {"id": "u1", "balance": "0.88", "chargeBalance": "88.00",
                      "totalBalance": "88.88", "status": "normal"}}
            """
            },
        ])
        server.start()
        defer { server.stop() }
        try await server.waitUntilReady()

        let data = try await SiliconFlowService(
            baseURL: server.baseURL, apiKey: "sk-test"
        ).fetchData()

        #expect(abs(data.totalCost - 88.88) < 0.001)   // totalBalance = 赠费 + 充值
        #expect(data.totalTokens == 0)
        #expect(data.quotas.first?.resetTimeString == "Available")
        // mock 跑在 127.0.0.1 → 非 .cn → USD
        #expect(data.costCurrency == "USD")
    }

    /// status 非 normal → 「已用完」
    @Test func abnormalStatusIsReportedExhausted() async throws {
        let server = try MockHTTPServer(handlers: [
            "/v1/user/info": { _ in """
            {"code": 20000, "status": true,
             "data": {"totalBalance": "10.00", "status": "banned"}}
            """
            },
        ])
        server.start()
        defer { server.stop() }
        try await server.waitUntilReady()

        let data = try await SiliconFlowService(
            baseURL: server.baseURL, apiKey: "sk-test"
        ).fetchData()
        #expect(data.quotas.first?.resetTimeString == "Used up")
    }

    /// 币种按域名推断：国内站 ¥、国际站 $
    @Test func currencyFollowsHost() {
        #expect(SiliconFlowService.currency(forHost: "api.siliconflow.cn") == "CNY")
        #expect(SiliconFlowService.currency(forHost: "api.siliconflow.com") == "USD")
    }
}

// ============================================================
// MARK: - Copilot 组织用量 端到端（7 天聚合）
// ============================================================

struct CopilotMockTests {

    init() { disableURLCacheForMockTests() }

    @Test func copilotSevenDayAggregation() async throws {
        let server = try MockHTTPServer(handlers: [
            "/orgs/acme/copilot/usage": { _ in """
            {
              "total_suggestions_count": 100,
              "total_acceptances_count": 50,
              "total_chat_turns": 30,
              "total_active_users": 5
            }
            """
            },
        ])
        server.start()
        defer { server.stop() }
        try await server.waitUntilReady()

        let source = SubscriptionSource(
            id: "copilot-1",
            name: "GitHub Copilot",
            iconName: "chevron.left.forwardslash.chevron.right",
            kind: .copilot,
            token: "ghp_test",
            org: "acme",
            apiBaseURL: server.baseURL
        )
        let snap = try await source.fetchSnapshot()

        // 每天 tokens = 100+50+30 = 180，7 天 = 1260
        #expect(snap.totalTokens == 1260)
        #expect(snap.sevenDayTrend.count == 7)
        #expect(snap.sevenDayTrend.allSatisfy { $0 == 180 })
        #expect(snap.dailyHeatmap.count == 7)
        #expect(snap.activityDays == 7)
        #expect(snap.currency == "USD")
    }
}

// ============================================================
// MARK: - DashboardViewModel 完整链路（消耗检测 + 每日用量累加）
// ============================================================

@MainActor
struct DashboardPipelineMockTests {

    init() { disableURLCacheForMockTests() }

    /// 两次刷新：第一次建立基线，第二次检测消耗 → localDailyUsage 累加
    @Test func fullPipelineDetectsConsumption() async throws {
        // 第一次请求 total_usage = 5 → 5M；之后返回 8 → 8M（消耗 3M）
        let server = try MockHTTPServer(handlers: [
            "/v1/organization/usage/completions": { count in
                let total = count == 0 ? 5 : 8
                return """
                {"total_usage": \(total), "data": [
                    {"start_time": \(Int(Date().timeIntervalSince1970)), "results": [
                        {"result": {"n_tokens": \(total * 1000000)}, "dimensions": {"model": "gpt-5.5"}}
                    ]}
                ]}
                """
            },
            "/v1/organization/usage/costs": { _ in """
            {"data": [{"amount": {"value": 1.00}}]}
            """
            },
        ])
        server.start()
        defer { server.stop() }
        try await server.waitUntilReady()

        // 隔离存储：注入独立临时 suite + 临时目录文件存储（UUID 命名），
        // 测试结束自动清除，绝不触碰真实 Application Support / UserDefaults 数据。
        let suiteName = "test.tokenhamster.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        defer { testDefaults.removePersistentDomain(forName: suiteName) }
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.tokenhamster.\(UUID().uuidString)", isDirectory: true)
        let vm = DashboardViewModel(userDefaults: testDefaults, storage: FileAppStorage(directory: tmpDir))
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        // 直接注入配置（绕过 addAPIConfig 的 HTTPS 强制转换）
        vm.apiConfigs = [
            APIConfigItem(
                name: "OpenAI Mock",
                baseURL: server.baseURL,
                apiKey: "sk-test",
                apiType: .openAI,
                isActive: true
            )
        ]
        // 第一次刷新：建立基线（5M），不产生消耗
        try await vm.manualRefresh()
        #expect(vm.aggregated.totalTokens == 5_000_000)
        #expect(vm.aggregated.activeSourceCount == 1)
        #expect(vm.agentSnapshots.count == 1)
        #expect(vm.agentSnapshots.first?.status == .ok)

        // 第二次刷新：总量 8M，消耗 3M
        try await vm.manualRefresh()
        #expect(vm.aggregated.totalTokens == 8_000_000)
        // 消耗已累加到本地每日记录（今天）
        let today = Calendar.current.startOfDay(for: Date())
        let todayUsage = vm.localDailyUsage.first { Calendar.current.startOfDay(for: $0.date) == today }
        #expect(todayUsage?.tokenCount == 3_000_000)
    }

    /// 回归（bug：删除 API Key 后卡片残留）：删除配置 → 刷新后快照/模型行消失。
    /// 删除 ≠ 停用：已删除配置的旧快照不再被"保留停用源"逻辑捞回。
    @Test func deletedConfigRemovesSnapshotAfterRefresh() async throws {
        let server = try MockHTTPServer(handlers: [
            "/v1/organization/usage/completions": { _ in """
            {"total_usage": 5, "data": [
                {"start_time": \(Int(Date().timeIntervalSince1970)), "results": [
                    {"result": {"n_tokens": 5000000}, "dimensions": {"model": "gpt-5.5"}}
                ]}
            ]}
            """
            },
            "/v1/organization/usage/costs": { _ in """
            {"data": [{"amount": {"value": 1.00}}]}
            """
            },
        ])
        server.start()
        defer { server.stop() }
        try await server.waitUntilReady()

        let suiteName = "test.tokenhamster.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        defer { testDefaults.removePersistentDomain(forName: suiteName) }
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.tokenhamster.\(UUID().uuidString)", isDirectory: true)
        let vm = DashboardViewModel(userDefaults: testDefaults, storage: FileAppStorage(directory: tmpDir))
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let cfg = APIConfigItem(
            name: "OpenAI Mock",
            baseURL: server.baseURL,
            apiKey: "sk-test",
            apiType: .openAI,
            isActive: true
        )
        vm.apiConfigs = [cfg]
        try await vm.manualRefresh()
        #expect(vm.agentSnapshots.count == 1)
        #expect(vm.agentSnapshots.first?.status == .ok)
        #expect(vm.modelRows.count == 1)   // OpenAI 快照有模型明细 → MODELS 栏一行

        // 模拟管理页删除按钮（真实入口：删除 + 保存 + 重启轮询触发立即刷新）
        vm.deleteAPIConfig(id: cfg.id)
        #expect(vm.apiConfigs.isEmpty)
        // 手动刷新确保状态收敛（与 deleteAPIConfig 触发的异步刷新竞争安全）
        try await vm.manualRefresh()
        #expect(vm.agentSnapshots.isEmpty)     // AGENTS 卡片消失
        #expect(vm.modelRows.isEmpty)          // MODELS 行消失
    }

    /// 回归（防误伤）：停用（非删除）配置 → 刷新后快照保留为 .stale，作为重新激活入口。
    @Test func deactivatedConfigKeepsStaleSnapshot() async throws {
        let server = try MockHTTPServer(handlers: [
            "/v1/organization/usage/completions": { _ in """
            {"total_usage": 5, "data": [
                {"start_time": \(Int(Date().timeIntervalSince1970)), "results": [
                    {"result": {"n_tokens": 5000000}, "dimensions": {"model": "gpt-5.5"}}
                ]}
            ]}
            """
            },
            "/v1/organization/usage/costs": { _ in """
            {"data": [{"amount": {"value": 1.00}}]}
            """
            },
        ])
        server.start()
        defer { server.stop() }
        try await server.waitUntilReady()

        let suiteName = "test.tokenhamster.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        defer { testDefaults.removePersistentDomain(forName: suiteName) }
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.tokenhamster.\(UUID().uuidString)", isDirectory: true)
        let vm = DashboardViewModel(userDefaults: testDefaults, storage: FileAppStorage(directory: tmpDir))
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let cfg = APIConfigItem(
            name: "OpenAI Mock",
            baseURL: server.baseURL,
            apiKey: "sk-test",
            apiType: .openAI,
            isActive: true
        )
        vm.apiConfigs = [cfg]
        try await vm.manualRefresh()
        #expect(vm.agentSnapshots.first?.status == .ok)

        // 停用（isActive = false，等同 UI 激活圆点切换），配置仍在 apiConfigs
        var updated = vm.apiConfigs
        updated[0].isActive = false
        vm.apiConfigs = updated
        try await vm.manualRefresh()
        #expect(vm.agentSnapshots.count == 1)                       // 卡片仍在
        #expect(vm.agentSnapshots.first?.status == .stale)          // 置灰可重新激活
        #expect(vm.aggregated.activeSourceCount == 0)               // 停用不计入聚合
    }

    /// 回归（空源分支）：全部配置删除后刷新 → 快照清空，不残留任何卡片。
    @Test func deleteAllConfigsClearsSnapshots() async throws {
        let server = try MockHTTPServer(handlers: [
            "/v1/organization/usage/completions": { _ in """
            {"total_usage": 5, "data": [
                {"start_time": \(Int(Date().timeIntervalSince1970)), "results": [
                    {"result": {"n_tokens": 5000000}, "dimensions": {"model": "gpt-5.5"}}
                ]}
            ]}
            """
            },
            "/v1/organization/usage/costs": { _ in """
            {"data": [{"amount": {"value": 1.00}}]}
            """
            },
        ])
        server.start()
        defer { server.stop() }
        try await server.waitUntilReady()

        let suiteName = "test.tokenhamster.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        defer { testDefaults.removePersistentDomain(forName: suiteName) }
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.tokenhamster.\(UUID().uuidString)", isDirectory: true)
        let vm = DashboardViewModel(userDefaults: testDefaults, storage: FileAppStorage(directory: tmpDir))
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        vm.apiConfigs = [
            APIConfigItem(name: "OpenAI Mock", baseURL: server.baseURL, apiKey: "sk-a", apiType: .openAI, isActive: true),
            APIConfigItem(name: "OpenAI Mock 2", baseURL: server.baseURL, apiKey: "sk-b", apiType: .openAI, isActive: true),
        ]
        try await vm.manualRefresh()
        #expect(vm.agentSnapshots.count == 2)

        // 全删（等同逐条 deleteAPIConfig 后）→ 空源 guard 分支
        vm.apiConfigs = []
        try await vm.manualRefresh()
        #expect(vm.agentSnapshots.isEmpty)
    }
}
