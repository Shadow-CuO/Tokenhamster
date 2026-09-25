//
//  TokenHamsterTests.swift
//  TokenHamsterTests
//
//  单元测试：JSONPath 提取、配置向后兼容、额度解析、热力图/趋势、日志解析、数据源语义
//

import Foundation
import Testing
import AppKit
@testable import TokenHamster

// ============================================================
// MARK: - JSONPathExtractor
// ============================================================

struct JSONPathExtractorTests {

    @Test func extractsNestedInt() {
        let json: [String: Any] = ["data": ["results": [["n_tokens": 123]]]]
        #expect(JSONPathExtractor.int(json, path: "data.results") == 0)   // 数组本身不可作为 Int
        #expect(JSONPathExtractor.array(json, path: "data.results").count == 1) // 数组路径可取出
        // 数组元素需先用 array() 取出，再按元素路径提取
        let first = JSONPathExtractor.array(json, path: "data.results").first ?? [:]
        #expect(JSONPathExtractor.int(first, path: "n_tokens") == 123)
        #expect(JSONPathExtractor.int(first, path: "missing") == 0)
    }

    @Test func handlesNumericStringAndArray() {
        let json: [String: Any] = [
            "a": 42,
            "b": 3.14,
            "c": "100",
            "d": [["x": 1], ["x": 2]],
        ]
        #expect(JSONPathExtractor.int(json, path: "a") == 42)
        #expect(JSONPathExtractor.int(json, path: "c") == 100)          // 字符串数字也可解析
        #expect(JSONPathExtractor.double(json, path: "b") == 3.14)
        #expect(JSONPathExtractor.double(json, path: "c") == 100.0)
        #expect(JSONPathExtractor.string(json, path: "c") == "100")
        #expect(JSONPathExtractor.array(json, path: "d").count == 2)
    }

    @Test func missingPathReturnsDefaults() {
        let json: [String: Any] = [:]
        #expect(JSONPathExtractor.int(json, path: "x.y") == 0)
        #expect(JSONPathExtractor.double(json, path: "x.y") == 0)
        #expect(JSONPathExtractor.string(json, path: "x.y") == "")
        #expect(JSONPathExtractor.array(json, path: "x.y").isEmpty)
    }
}

// ============================================================
// MARK: - APIConfigItem 编解码兼容
// ============================================================

struct APIConfigItemCodableTests {

    @Test func decodesLegacyJSONWithDefaults() throws {
        // 旧版存档：没有 organizationId / copilotOrg / localLogKind / localLogPath
        let legacy = """
        {"name":"DeepSeek","baseURL":"https://api.deepseek.com","apiKey":"sk-x","apiType":"deepseek","pollingInterval":300,"isActive":true,"customKeyPaths":{}}
        """
        let item = try JSONDecoder().decode(APIConfigItem.self, from: Data(legacy.utf8))
        #expect(item.name == "DeepSeek")
        #expect(item.apiType == .deepseek)
        #expect(item.isActive)
        #expect(item.organizationId == "")
        #expect(item.copilotOrg == "")
        #expect(item.agentProvider == .claudeCode)
        #expect(item.localLogPath == "")
        #expect(!item.id.isEmpty)
    }

    @Test func decodesLegacyLocalLogWithoutPath() throws {
        // 旧版 localLog 存档：没有 localLogPath 字段 → 默认空字符串
        let legacy = """
        {"name":"本地","baseURL":"","apiKey":"","apiType":"localLog","pollingInterval":300,"isActive":true,"customKeyPaths":{},"agentProvider":"customPath"}
        """
        let item = try JSONDecoder().decode(APIConfigItem.self, from: Data(legacy.utf8))
        #expect(item.agentProvider == .customPath)
        #expect(item.localLogPath == "")
    }

    /// ★ 旧存档里的已删除类型（`openAICompatible`）必须宽容解码为 `.custom`。
    /// 若直接 `decode(APIType.self)`，未知 rawValue 会抛错 —— 整份配置数组解码失败，
    /// 用户的**所有**数据源会一起消失。
    @Test func decodesRetiredAPITypeAsCustom() throws {
        let legacy = """
        {"name":"中转网关","baseURL":"https://gateway.example.com","apiKey":"sk-x","apiType":"openAICompatible","pollingInterval":300,"isActive":true,"customKeyPaths":{}}
        """
        let item = try JSONDecoder().decode(APIConfigItem.self, from: Data(legacy.utf8))
        #expect(item.apiType == .custom)
        #expect(item.baseURL == "https://gateway.example.com")
        #expect(item.name == "中转网关")
        // 整数组解码同样不能抛错（真实场景是一次 decode [APIConfigItem]）
        let array = try JSONDecoder().decode([APIConfigItem].self, from: Data("[\(legacy)]".utf8))
        #expect(array.count == 1)
        #expect(array.first?.apiType == .custom)
    }

    /// 未知 rawValue 同样归为 `.custom`（前向兼容：降级安装不会丢配置）
    @Test func decodesUnknownAPITypeAsCustom() throws {
        let unknown = """
        {"name":"未来类型","baseURL":"","apiKey":"","apiType":"someFutureType","isActive":false}
        """
        let item = try JSONDecoder().decode(APIConfigItem.self, from: Data(unknown.utf8))
        #expect(item.apiType == .custom)
    }

    @Test func roundTripPreservesNewFields() throws {
        let item = APIConfigItem(
            name: "Anthropic Admin",
            baseURL: "https://api.anthropic.com",
            apiKey: "sk-ant-admin-123",
            apiType: .anthropic,
            organizationId: "org_abc",
            copilotOrg: "acme-inc",
            agentProvider: .codex
        )
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(APIConfigItem.self, from: data)
        #expect(decoded.organizationId == "org_abc")
        #expect(decoded.copilotOrg == "acme-inc")
        #expect(decoded.agentProvider == .codex)
        #expect(decoded.apiType == .anthropic)
        #expect(decoded.localLogPath == "")
    }

    @Test func roundTripPreservesLocalLogPath() throws {
        let item = APIConfigItem(
            name: "自定义日志",
            baseURL: "",
            apiKey: "",
            apiType: .localLog,
            agentProvider: .customPath,
            localLogPath: "/Users/me/logs/sessions.jsonl"
        )
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(APIConfigItem.self, from: data)
        #expect(decoded.agentProvider == .customPath)
        #expect(decoded.localLogPath == "/Users/me/logs/sessions.jsonl")
        #expect(decoded.apiType == .localLog)
    }

    @Test func apiTypeDisplayNames() {
        #expect(APIType.copilot.displayName == "GitHub Copilot")
        #expect(APIType.localLog.displayName == "Local CLI")
        #expect(APIType.gemini.displayName == "Google Gemini")
        #expect(APIType.kimi.displayName == "Moonshot Kimi")
        #expect(APIType.custom.displayName == "Custom")
    }
}

// ============================================================
// MARK: - 热力图等级 & 7 天趋势
// ============================================================

struct HeatmapHelpersTests {

    @Test func heatmapLevelBuckets() {
        #expect(heatmapLevel(for: 0) == 0)
        #expect(heatmapLevel(for: 10_000) == 1)
        #expect(heatmapLevel(for: 20_000_000) == 2)
        #expect(heatmapLevel(for: 100_000_000) == 3)
        #expect(heatmapLevel(for: 1_000_000_000) == 4)
    }

    @Test func sevenDayTrendFillsMissingDays() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let heatmap = [
            DailyUsage(date: today, tokenCount: 100, level: 1),
            DailyUsage(date: yesterday, tokenCount: 50, level: 1),
        ]
        let trend = computeSevenDayTrend(from: heatmap)
        #expect(trend.count == 7)
        #expect(trend.last == 100)        // 今天
        #expect(trend[trend.count - 2] == 50)  // 昨天
        #expect(trend.dropLast(2).allSatisfy { $0 == 0 })  // 更早的天为 0
    }
}

// ============================================================
// MARK: - mergeHeatmapSources（API 优先、本地兜底、趋势补空）
// ============================================================

@MainActor
struct MergeHeatmapTests {

    private func day(_ offset: Int) -> Date {
        Calendar.current.startOfDay(
            for: Date().addingTimeInterval(TimeInterval(offset) * 86_400)
        )
    }

    /// 创建隔离 VM — 独立临时 suite + 临时目录文件存储，
    /// 绝不触碰真实 Application Support / 真实 legacy UserDefaults 数据。
    private func makeIsolatedVM() -> (vm: DashboardViewModel, cleanup: () -> Void) {
        let suiteName = "test.tokenhamster.\(UUID().uuidString)"
        let legacy = UserDefaults(suiteName: suiteName)!
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.tokenhamster.\(UUID().uuidString)", isDirectory: true)
        let vm = DashboardViewModel(userDefaults: legacy, storage: FileAppStorage(directory: tmpDir))
        return (vm, {
            legacy.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: tmpDir)
        })
    }

    @Test func apiOverridesLocalForSameDay() {
        let (vm, cleanup) = makeIsolatedVM()
        defer { cleanup() }
        let api = [DailyUsage(date: day(0), tokenCount: 1_000, level: 1)]
        let local = [DailyUsage(date: day(0), tokenCount: 99, level: 1)]  // 同一天
        let merged = vm.mergeHeatmapSources(apiHeatmap: api, trend: Array(repeating: 0, count: 7), local: local)
        let today = merged.first { $0.date == day(0) }
        #expect(today?.tokenCount == 1_000)  // API 优先，不叠加双倍
    }

    @Test func localFillsDaysMissingFromAPI() {
        let (vm, cleanup) = makeIsolatedVM()
        defer { cleanup() }
        let api: [DailyUsage] = []
        let local = [DailyUsage(date: day(-2), tokenCount: 42, level: 1)]
        let merged = vm.mergeHeatmapSources(apiHeatmap: api, trend: Array(repeating: 0, count: 7), local: local)
        let found = merged.first { $0.date == day(-2) }
        #expect(found?.tokenCount == 42)
    }

    @Test func trendFillsEmptyDaysOnly() {
        let (vm, cleanup) = makeIsolatedVM()
        defer { cleanup() }
        let api = [DailyUsage(date: day(0), tokenCount: 500, level: 1)]
        let trend = [0, 0, 0, 0, 0, 0, 300]  // 最后一项对应今天（会被 API 覆盖）
        let merged = vm.mergeHeatmapSources(apiHeatmap: api, trend: trend, local: [])
        let today = merged.first { $0.date == day(0) }
        #expect(today?.tokenCount == 500)  // API 覆盖趋势，不叠加
    }
}

// ============================================================
// MARK: - BrandMark（模型名 → 厂商标识别）
// ============================================================

struct BrandMarkTests {

    @Test func detectsCommonVendors() {
        #expect(BrandMark.detect(in: "gpt-5.6") == .openAI)
        #expect(BrandMark.detect(in: "gpt-5.1-codex") == .openAI)
        #expect(BrandMark.detect(in: "o3-mini") == .openAI)
        #expect(BrandMark.detect(in: "claude-opus-4-1") == .anthropic)
        #expect(BrandMark.detect(in: "claude-3-5-sonnet-20241022") == .anthropic)
        #expect(BrandMark.detect(in: "sonnet") == .anthropic)
        #expect(BrandMark.detect(in: "glm-5.2") == .zai)
        #expect(BrandMark.detect(in: "deepseek-chat") == .deepSeek)
        #expect(BrandMark.detect(in: "kimi-k2-instruct") == .moonshot)
        #expect(BrandMark.detect(in: "moonshot-v1-8k") == .moonshot)
        #expect(BrandMark.detect(in: "gemini-2.5-pro") == .google)
        #expect(BrandMark.detect(in: "grok-4") == .xai)
        #expect(BrandMark.detect(in: "qwen3-coder") == .qwen)
        #expect(BrandMark.detect(in: "llama3.2:latest") == .llama)
    }

    /// ★ 切词匹配的意义：子串误判会让整个模型栏挂错厂商标。
    @Test func doesNotConfuseSubstrings() {
        #expect(BrandMark.detect(in: "gpt-4o") == .openAI)        // „4o“ 不得被当成 o 系列
        #expect(BrandMark.detect(in: "codestral-latest") == .mistral)  // „codestral“ 不是 codex
        #expect(BrandMark.detect(in: "mistral-large") == .mistral)
        #expect(BrandMark.detect(in: "my-finetune-v2") == nil)    // 无厂商线索 → 回退数据源 logo
        #expect(BrandMark.detect(in: "") == nil)
    }

    /// 带路径前缀的模型名（如 openrouter 风格）仍能识别
    @Test func detectsWithPathPrefix() {
        #expect(BrandMark.detect(in: "z-ai/glm-4.6") == .zai)
        #expect(BrandMark.detect(in: "anthropic/claude-opus-4") == .anthropic)
    }
}

// ============================================================
// MARK: - ProviderIcons 尺寸预置（Picker 菜单尺寸溢出回归）
// ============================================================

@MainActor
struct ProviderIconSizingTests {

    /// ★ 回归：macOS 的 `Picker(.menu)` 菜单项由 AppKit 渲染，会按 NSImage 的
    /// **natural size** 绘制（SwiftUI 的 .resizable()/.frame() 在那条路径上不生效）。
    /// 256×256 PNG → 256pt，12pt 的图标会溢出盖住整个面板。
    /// 因此必须把 size 预置成目标 pt。
    @Test func sizedCopyPresetsPointSize() {
        let base = NSImage(size: NSSize(width: 256, height: 256))
        let copy = ProviderIcons.sizedCopy(of: base, pointSize: 12)
        #expect(copy.size == NSSize(width: 12, height: 12))
        #expect(copy.isTemplate)                     // 模板图 → 单色跟随主题
        // 不能污染 AppKit 缓存里的共享实例（否则 13/17pt 的调用点会被改错）
        #expect(base.size == NSSize(width: 256, height: 256))
    }

    /// 同一资源的不同 pt 尺寸互不影响
    @Test func distinctPointSizesAreIndependent() {
        let base = NSImage(size: NSSize(width: 256, height: 256))
        let small = ProviderIcons.sizedCopy(of: base, pointSize: 12)
        let medium = ProviderIcons.sizedCopy(of: base, pointSize: 17)
        #expect(small.size == NSSize(width: 12, height: 12))
        #expect(medium.size == NSSize(width: 17, height: 17))
    }

    /// 真实资源：取出的品牌图尺寸必须是请求的 pt，而不是 PNG 的像素尺寸
    @Test func brandImageFromBundleIsPointSized() {
        for size in [CGFloat(12), 13, 17] {
            guard let img = ProviderIcons.brandImage(named: "openai", pointSize: size) else {
                Issue.record("openai.png 未随 app 打包进 Resources —— 检查 ProviderIcons/ 目录")
                return
            }
            #expect(img.size == NSSize(width: size, height: size))
            #expect(img.isTemplate)
        }
    }
}

// ============================================================
// MARK: - ModelRows 余额型 / 累计型展开（MODELS 栏数据）
// ============================================================

@MainActor
struct ModelRowsTests {

    /// 创建隔离 VM — 独立临时 suite + 临时目录文件存储，绝不触碰真实数据。
    private func makeIsolatedVM() -> (vm: DashboardViewModel, cleanup: () -> Void) {
        let suiteName = "test.tokenhamster.\(UUID().uuidString)"
        let legacy = UserDefaults(suiteName: suiteName)!
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.tokenhamster.\(UUID().uuidString)", isDirectory: true)
        let vm = DashboardViewModel(userDefaults: legacy, storage: FileAppStorage(directory: tmpDir))
        return (vm, {
            legacy.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: tmpDir)
        })
    }

    /// 余额型源（DeepSeek）：totalTokens 恒 0、只有余额金额 → modelRows 生成一行，
    /// 额度列显示 "¥88.50 left"，token 列留白（无 token 维度，不补位）。
    @Test func balanceSourceProducesRowWithCurrencyValue() {
        let (vm, cleanup) = makeIsolatedVM()
        defer { cleanup() }
        vm.agentSnapshots = [
            AgentSnapshot(
                id: "deepseek-1",
                name: "DeepSeek",
                iconName: "diamond.fill",
                assetName: "deepseek",
                sourceType: .api,
                resetTimeString: "Available",
                currency: "CNY",
                totalTokens: 0,
                totalCost: 88.50,
                status: .ok
            )
        ]
        let rows = vm.modelRows
        #expect(rows.count == 1)
        #expect(rows.first?.valueText == "¥88.50 left")      // 余额文案带 left
        #expect(rows.first?.usageText == "")                 // 无 token 用量 → token 列留白不补位
        #expect(rows.first?.quotaText == "¥88.50 left")      // 余额显示在额度列
        #expect(rows.first?.name == "DeepSeek")
    }

    /// ★ 两列原则回归：同一行同时有 token 用量与金额时，**token 用量优先**。
    @Test func tokenUsageTakesPriorityOverAmount() {
        let row = ModelRowItem(
            id: "x",
            assetName: nil,
            symbolName: "cpu.fill",
            name: "gpt-5.5",
            tokens: 1_500_000,
            ratio: 0.5,
            valueText: "¥99.00 left",
            origin: .directAPI
        )
        #expect(row.usageText == "1.5M")          // 左列：token 用量
        #expect(row.quotaText == "50.0%")         // 右列：百分比，不用金额
        #expect(row.quotaShowsAmount == false)    // 百分比 → 用较小的 fontModelPercent
    }

    /// ★ 额度列字体分档依据：展示金额/状态文案时才放大字号（金额用 fontModelAmount）
    @Test func quotaShowsAmountOnlyForNonTokenRows() {
        let amountRow = ModelRowItem(
            id: "a", assetName: nil, symbolName: "diamond.fill", name: "DeepSeek",
            tokens: 0, ratio: 0, valueText: "¥88.50 left", origin: .directAPI
        )
        #expect(amountRow.quotaShowsAmount == true)

        let exhaustedRow = ModelRowItem(
            id: "b", assetName: nil, symbolName: "diamond.fill", name: "DeepSeek",
            tokens: 0, ratio: 0, valueText: "Used up", origin: .directAPI
        )
        #expect(exhaustedRow.quotaShowsAmount == true)

        // 两列都空（理论上不出现）→ 不放大，纯留白
        let emptyRow = ModelRowItem(
            id: "c", assetName: nil, symbolName: "cpu.fill", name: "x",
            tokens: 0, ratio: 0, valueText: nil, origin: .directAPI
        )
        #expect(emptyRow.quotaText == "")
        #expect(emptyRow.quotaShowsAmount == false)
    }

    /// 余额型源且已用完（resetTimeString == "已用完"）→ valueText 显示状态而非金额。
    @Test func balanceSourceExhaustedShowsStatusText() {
        let (vm, cleanup) = makeIsolatedVM()
        defer { cleanup() }
        vm.agentSnapshots = [
            AgentSnapshot(
                id: "deepseek-2",
                name: "DeepSeek",
                iconName: "diamond.fill",
                assetName: "deepseek",
                sourceType: .api,
                resetTimeString: "Used up",
                currency: "CNY",
                totalTokens: 0,
                totalCost: 0,
                status: .ok
            )
        ]
        let rows = vm.modelRows
        #expect(rows.count == 1)
        #expect(rows.first?.valueText == "Used up")
        #expect(rows.first?.usageText == "")        // token 列仍留白
        #expect(rows.first?.quotaText == "Used up")   // 额度列显示状态
    }

    /// 累计型源（OpenAI）：totalTokens > 0 时生成行，valueText 为 nil（走 tokenFormatted）。
    @Test func cumulativeSourceKeepsTokenValue() {
        let (vm, cleanup) = makeIsolatedVM()
        defer { cleanup() }
        vm.agentSnapshots = [
            AgentSnapshot(
                id: "openai-1",
                name: "OpenAI",
                iconName: "brain.head.profile",
                assetName: "openai",
                sourceType: .api,
                resetTimeString: "",
                currency: "USD",
                totalTokens: 5_000_000,
                totalCost: 1.23,
                status: .ok
            )
        ]
        let rows = vm.modelRows
        #expect(rows.count == 1)
        #expect(rows.first?.valueText == nil)          // 累计型 → 无金额文案
        #expect(rows.first?.usageText == "5M")       // token 列显示用量（整数倍量级不带 .0）
        #expect(rows.first?.quotaText == "100.0%")     // 额度列显示百分比
        #expect(rows.first?.tokenFormatted == "5M")
    }

    /// ★ 逐行按模型名识别厂商标：同一数据源里 gpt-* 与 glm-* 应挂不同厂商 logo，
    /// 识别不出时才回退数据源自身的 assetName。
    @Test func modelRowsResolveBrandFromModelName() {
        let (vm, cleanup) = makeIsolatedVM()
        defer { cleanup() }
        vm.agentSnapshots = [
            AgentSnapshot(
                id: "codex-1",
                name: "Codex",
                iconName: "terminal.fill",
                assetName: "codex",
                sourceType: .local,
                modelUsages: [
                    ModelUsageItem(id: "1", modelName: "gpt-5.6", tokenAmount: 200, usagePercent: 0.5),
                    ModelUsageItem(id: "2", modelName: "glm-4.6", tokenAmount: 100, usagePercent: 0.25),
                    ModelUsageItem(id: "3", modelName: "my-finetune-v2", tokenAmount: 100, usagePercent: 0.25),
                ],
                status: .ok
            )
        ]
        let rows = vm.modelRows
        #expect(rows.count == 3)
        func row(_ name: String) -> ModelRowItem? { rows.first { $0.name == name } }
        #expect(row("gpt-5.6")?.assetName == "openai")          // 模型名认厂商，而非数据源的 codex
        #expect(row("glm-4.6")?.assetName == "zai")
        #expect(row("my-finetune-v2")?.assetName == "codex")    // 认不出 → 回退数据源 logo
        // symbol 回退与 assetName 出自同一套识别结果
        #expect(row("glm-4.6")?.symbolName == "diamond.fill")
        #expect(row("my-finetune-v2")?.symbolName == "terminal.fill")
    }
}

// ============================================================
// MARK: - LocalLogSource 日志解析
// ============================================================

struct LocalLogParsingTests {

    @Test func parsesClaudeCodeJsonl() {
        let jsonl = """
        {"timestamp":"2026-07-13T08:00:00Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":1000,"output_tokens":2000}}}
        {"timestamp":"2026-07-13T09:00:00Z","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":100,"output_tokens":50}}}
        """
        let result = LocalLogSource.parseLogContent(jsonl)
        #expect(result.totalTokens == 3150)
        #expect(result.modelTokens["claude-opus-4-8"] == 3000)
        #expect(result.modelTokens["claude-sonnet-4-5"] == 150)
        #expect(result.dayTokens.count == 1)
    }

    @Test func parsesCodexJsonl() {
        let jsonl = """
        {"timestamp":"2026-07-13T10:00:00Z","model":"gpt-5.5-codex","tokens":{"prompt":500,"completion":250}}
        """
        let result = LocalLogSource.parseLogContent(jsonl)
        #expect(result.totalTokens == 750)
        #expect(result.modelTokens["gpt-5.5-codex"] == 750)
    }

    @Test func parsesCodexRolloutTakesLastTokenCount() {
        // 新版 rollout：token_count 是会话累计值，多条时应取最后一条，不逐行累加
        let jsonl = """
        {"timestamp":"2026-07-13T10:00:00Z","ordinal":0,"type":"session_meta","payload":{"model_provider":"openai","model":"gpt-5.5-codex"}}
        {"timestamp":"2026-07-13T10:00:05Z","ordinal":1,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":300,"cache_write_input_tokens":100,"output_tokens":200,"reasoning_output_tokens":50,"total_tokens":1200}}}}
        {"timestamp":"2026-07-13T10:00:10Z","ordinal":2,"type":"event_msg","payload":{"type":"agent_message","message":"hi"}}
        {"timestamp":"2026-07-13T10:05:00Z","ordinal":3,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2000,"cached_input_tokens":600,"cache_write_input_tokens":100,"output_tokens":400,"reasoning_output_tokens":120,"total_tokens":2400}}}}
        """
        let result = LocalLogSource.parseLogContent(jsonl)
        #expect(result.totalTokens == 2400)              // 最后一条累计值，而非 1200+2400
        #expect(result.modelTokens["openai"] == 2400)    // 模型名来自 session_meta.model_provider
        #expect(result.dayTokens.count == 1)
    }

    @Test func parsesCodexRolloutWithoutTotalField() {
        // 无 total_tokens 字段时回退 input_tokens + output_tokens（cached ⊂ input，不额外剔除）
        let jsonl = """
        {"timestamp":"2026-07-13T10:00:00Z","type":"session_meta","payload":{"model_provider":"openai"}}
        {"timestamp":"2026-07-13T10:00:05Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":300,"output_tokens":200}}}}
        """
        let result = LocalLogSource.parseLogContent(jsonl)
        #expect(result.totalTokens == 1200)
        #expect(result.modelTokens["openai"] == 1200)
    }

    @Test func codexRolloutSkipsLegacyTokensBranch() {
        // 同一文件既有 token_count 又有顶层 tokens 时，不应重复计费
        let jsonl = """
        {"timestamp":"2026-07-13T10:00:00Z","type":"session_meta","payload":{"model_provider":"openai"}}
        {"timestamp":"2026-07-13T10:00:05Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"output_tokens":200,"total_tokens":1200}}}}
        {"timestamp":"2026-07-13T10:00:06Z","model":"gpt-5.5-codex","tokens":{"prompt":500,"completion":250}}
        """
        let result = LocalLogSource.parseLogContent(jsonl)
        #expect(result.totalTokens == 1200)
    }

    @Test func skipsInvalidLines() {
        let jsonl = "not-json\n\n{\"no\":\"usage\"}\n"
        let result = LocalLogSource.parseLogContent(jsonl)
        #expect(result.totalTokens == 0)
        #expect(result.modelTokens.isEmpty)
    }
}

// ============================================================
// MARK: - LocalLogSource customPath（自定义文件 / 目录）
// ============================================================

struct LocalLogSourceCustomPathTests {

    /// 临时目录 + 含当天时间戳的 jsonl 文件
    private func makeTempJsonl(
        named fileName: String,
        line: String
    ) throws -> (dir: URL, file: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.custompath.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(fileName)
        try Data(line.utf8).write(to: file)
        return (dir, file)
    }

    @Test func parsesDirectoryWithJsonl() async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let (dir, _) = try makeTempJsonl(
            named: "session.jsonl",
            line: """
            {"timestamp":"\(now)","message":{"model":"claude-opus-4-8","usage":{"input_tokens":1000,"output_tokens":2000}}}
            """
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = LocalLogSource(
            id: "custom-1",
            name: "自定义日志",
            iconName: "terminal.fill",
            kind: .customPath,
            customPath: dir.path
        )
        let snap = try await source.fetchSnapshot()
        #expect(snap.totalTokens == 3000)
        #expect(snap.modelUsages.first?.modelName == "claude-opus-4-8")
        #expect(snap.dailyHeatmap.count == 1)
        #expect(snap.activityDays == 1)
        #expect(snap.sevenDayTrend.count == 7)
        #expect(snap.sevenDayTrend.last == 3000)  // 今天
    }

    @Test func parsesSingleFile() async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let (dir, file) = try makeTempJsonl(
            named: "codex.jsonl",
            line: """
            {"timestamp":"\(now)","model":"gpt-5.5-codex","tokens":{"prompt":500,"completion":250}}
            """
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = LocalLogSource(
            id: "custom-2",
            name: "单文件",
            iconName: "terminal.fill",
            kind: .customPath,
            customPath: file.path
        )
        let snap = try await source.fetchSnapshot()
        #expect(snap.totalTokens == 750)
        #expect(snap.modelUsages.first?.modelName == "gpt-5.5-codex")
        #expect(snap.dailyHeatmap.count == 1)
    }

    @Test func emptyPathReturnsEmptySnapshot() async throws {
        let source = LocalLogSource(
            id: "custom-3",
            name: "空路径",
            iconName: "terminal.fill",
            kind: .customPath,
            customPath: ""
        )
        let snap = try await source.fetchSnapshot()
        #expect(snap.totalTokens == 0)
        #expect(snap.modelUsages.isEmpty)
        #expect(snap.status == .ok)
    }
}

// ============================================================
// MARK: - LocalLogSource codex 会话目录收集（rollout 三层结构）
// ============================================================

struct LocalLogSourceCodexPathTests {

    @Test func collectsRolloutFilesRecursively() throws {
        // 新版：sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl（三层）+ session_index.jsonl 应被排除
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.codex.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dayDir = root.appendingPathComponent("2026/07/13", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dayDir.appendingPathComponent("rollout-1720000000-abc.jsonl"))
        try Data("{}".utf8).write(to: dayDir.appendingPathComponent("rollout-1720000000-def.jsonl"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("session_index.jsonl"))

        let files = LocalLogSource.codexLogFiles(in: root)
        #expect(files.count == 2)
        #expect(files.allSatisfy { $0.lastPathComponent.hasPrefix("rollout-") })
    }

    @Test func fallsBackToLegacyFlatJsonl() throws {
        // 旧版：sessions/<date>/<session>.jsonl（单层，无 rollout- 前缀）
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.codex.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dateDir = root.appendingPathComponent("2026-07-13", isDirectory: true)
        try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dateDir.appendingPathComponent("session.jsonl"))

        let files = LocalLogSource.codexLogFiles(in: root)
        #expect(files.count == 1)
        #expect(files.first?.lastPathComponent == "session.jsonl")
    }

    @Test func missingSessionsDirReturnsEmpty() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.codex.missing.\(UUID().uuidString)", isDirectory: true)
        let files = LocalLogSource.codexLogFiles(in: root)
        #expect(files.isEmpty)
    }
}

// ============================================================
// MARK: - FileAppStorage（Application Support 文件存储）
// ============================================================

struct FileAppStorageTests {

    @Test func saveLoadRoundTrip() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.fas.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let storage = FileAppStorage(directory: tmpDir)

        let usage = [DailyUsage(date: Date(), tokenCount: 42, level: 1)]
        storage.save(usage, forKey: "test_usage")
        let loaded: [DailyUsage]? = storage.load([DailyUsage].self, forKey: "test_usage")
        #expect(loaded?.count == 1)
        #expect(loaded?.first?.tokenCount == 42)
    }

    @Test func loadMissingReturnsNil() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.fas.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let storage = FileAppStorage(directory: tmpDir)
        let loaded: [DailyUsage]? = storage.load([DailyUsage].self, forKey: "missing")
        #expect(loaded == nil)
    }

    @Test func deleteRemovesFile() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.fas.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let storage = FileAppStorage(directory: tmpDir)
        storage.save([1, 2, 3], forKey: "nums")
        storage.delete(forKey: "nums")
        let loaded: [Int]? = storage.load([Int].self, forKey: "nums")
        #expect(loaded == nil)
    }
}

// ============================================================
// MARK: - 存量数据迁移（旧 UserDefaults suite → 文件存储）
// ============================================================

@MainActor
struct LegacyMigrationTests {

    @Test func migratesUsageFromLegacyDefaults() {
        // 构造旧版 suite 数据（模拟旧版本写入 group.com.tokenhamster 的内容）
        let suiteName = "test.legacy.\(UUID().uuidString)"
        let legacy = UserDefaults(suiteName: suiteName)!
        defer { legacy.removePersistentDomain(forName: suiteName) }

        let usage = [DailyUsage(date: Date(), tokenCount: 999, level: 1)]
        legacy.set(try! JSONEncoder().encode(usage), forKey: AppConstants.localUsageKey)

        // 初始化 VM → 触发迁移
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.migrate.\(UUID().uuidString)", isDirectory: true)
        let storage = FileAppStorage(directory: tmpDir)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let vm = DashboardViewModel(userDefaults: legacy, storage: storage)

        // 断言：已迁移到文件存储
        let savedUsage: [DailyUsage]? = storage.load([DailyUsage].self, forKey: AppConstants.localUsageKey)
        #expect(savedUsage?.count == 1)
        // 旧数据已删除
        #expect(legacy.data(forKey: AppConstants.localUsageKey) == nil)
        // VM 内存态同步
        #expect(vm.localDailyUsage.count == 1)
    }

    @Test func keepsExistingFileDataOnMigration() {
        // 目标文件已有数据时，迁移不应覆盖
        let suiteName = "test.legacy.\(UUID().uuidString)"
        let legacy = UserDefaults(suiteName: suiteName)!
        defer { legacy.removePersistentDomain(forName: suiteName) }

        let oldUsage = [DailyUsage(date: Date(), tokenCount: 1, level: 0)]
        legacy.set(try! JSONEncoder().encode(oldUsage), forKey: AppConstants.localUsageKey)

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.migrate.\(UUID().uuidString)", isDirectory: true)
        let storage = FileAppStorage(directory: tmpDir)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        // 先写入更新的文件数据
        let newUsage = [DailyUsage(date: Date(), tokenCount: 2, level: 0)]
        storage.save(newUsage, forKey: AppConstants.localUsageKey)

        _ = DashboardViewModel(userDefaults: legacy, storage: storage)

        // 文件数据保持新值（不覆盖）
        let loaded: [DailyUsage]? = storage.load([DailyUsage].self, forKey: AppConstants.localUsageKey)
        #expect(loaded?.first?.tokenCount == 2)
        // 旧 legacy 数据仍被清理
        #expect(legacy.data(forKey: AppConstants.localUsageKey) == nil)
    }
}

// ============================================================
// MARK: - 自定义 JSON 辅助（autoMapKeyPaths / extractFieldPreviews / collectKeyPaths）
// ============================================================

struct CustomJSONMappingTests {

    /// 典型 OpenRouter 风格：总用量 + 模型数组 + 每日数组
    private func openRouterJSON() -> [String: Any] {
        [
            "data": [
                "total_usage": 123_456,
                "total_cost": 12.5,
                "currency": "USD",
                "active_days": 5,
            ],
            "models": [
                ["name": "gpt-4o", "tokens": 100_000, "percent": 0.6],
                ["name": "claude-3.5", "tokens": 40_000, "percent": 0.4],
            ],
            "daily": [
                ["date": "2025-01-01", "tokens": 1_000, "level": 2],
                ["date": "2025-01-02", "tokens": 500, "level": 1],
            ],
        ]
    }

    @Test func autoMapsTypicalResponse() {
        let map = autoMapKeyPaths(openRouterJSON())
        #expect(map["totalTokens"] == "data.total_usage")
        #expect(map["totalCost"] == "data.total_cost")
        #expect(map["currency"] == "data.currency")
        #expect(map["activeDays"] == "data.active_days")
        // 模型数组（含 name + tokens），不能把每日数组误认成模型
        #expect(map["models"] == "models")
        #expect(map["modelName"] == "name")
        #expect(map["modelTokens"] == "tokens")
        #expect(map["modelPercent"] == "percent")
        // 每日数组（含 date）
        #expect(map["daily"] == "daily")
        #expect(map["dailyDate"] == "date")
        #expect(map["dailyTokens"] == "tokens")
        #expect(map["dailyLevel"] == "level")
    }

    @Test func autoMapsDeepNestedAndAlternateKeys() {
        let json: [String: Any] = [
            "result": [
                "summary": [
                    "totalTokens": 99,
                    "totalSpentUsd": 3.3,
                    "currencyCode": "CNY",
                ],
                "models": [
                    ["model": "deepseek-r1", "output_tokens": 50, "ratio": 0.8],
                ],
                "usage": [
                    ["day": "2025-02-01", "token_count": 10, "heatmap_level": 3],
                ],
            ],
        ]
        let map = autoMapKeyPaths(json)
        #expect(map["totalTokens"] == "result.summary.totalTokens")
        #expect(map["totalCost"] == "result.summary.totalSpentUsd")
        #expect(map["currency"] == "result.summary.currencyCode")
        #expect(map["models"] == "result.models")
        #expect(map["modelName"] == "model")
        #expect(map["modelTokens"] == "output_tokens")
        #expect(map["modelPercent"] == "ratio")
        #expect(map["daily"] == "result.usage")
        #expect(map["dailyDate"] == "day")
        #expect(map["dailyTokens"] == "token_count")
        #expect(map["dailyLevel"] == "heatmap_level")
    }

    @Test func autoMapReturnsEmptyOnUnrecognizedShape() {
        let json: [String: Any] = ["foo": "bar", "nested": ["x": ["y": "z"]]]
        #expect(autoMapKeyPaths(json).isEmpty)
    }

    @Test func collectKeyPathsDepthFirst() {
        let json: [String: Any] = [
            "a": 1,
            "b": ["c": 2, "d": ["e": 3]],
        ]
        let paths = collectKeyPaths(json).map(\.path)
        #expect(paths.contains("a"))
        #expect(paths.contains("b"))
        #expect(paths.contains("b.c"))
        #expect(paths.contains("b.d"))
        #expect(paths.contains("b.d.e"))
        // 父路径在子路径之前
        let bIdx = paths.firstIndex(of: "b")!
        let bcIdx = paths.firstIndex(of: "b.c")!
        #expect(bIdx < bcIdx)
    }

    @Test func extractFieldPreviewsReflectsMapping() {
        let json: [String: Any] = ["data": ["total_tokens": 7, "currency": "USD"]]
        let map = ["totalTokens": "data.total_tokens", "totalCost": "data.total_cost", "currency": "data.currency"]
        let previews = extractFieldPreviews(json: json, keyPathMap: map)
        let byKey = Dictionary(uniqueKeysWithValues: previews.map { ($0.key, $0) })

        #expect(byKey["totalTokens"]?.isFound == true)
        #expect(byKey["totalTokens"]?.valueText == "7")
        #expect(byKey["totalCost"]?.isFound == false)          // 路径未命中
        #expect(byKey["totalCost"]?.valueText == "Not found")
        #expect(byKey["currency"]?.path == "data.currency")
        #expect(byKey["currency"]?.isFound == true)
        #expect(byKey["models"]?.isFound == false)             // 未配置 → 空路径
        #expect(byKey["models"]?.path == "")
    }

    @Test func extractFieldPreviewsHandlesArrayValue() {
        let json: [String: Any] = ["models": [["name": "gpt-4o", "tokens": 1]]]
        let map = ["models": "models"]
        let previews = extractFieldPreviews(json: json, keyPathMap: map)
        let models = previews.first { $0.key == "models" }
        #expect(models?.isFound == true)
        #expect(models?.valueText == "Array (1 item)")
    }
}

// ============================================================
// MARK: - Claude Keychain 凭据解析（纯函数）
// ============================================================

struct ClaudeKeychainParserTests {

    @Test func parsesAccessTokenFromFullBlob() {
        let raw = #"{"claudeAiOauth":{"accessToken":"sk-ant-atok-abc123","refreshToken":"r-1","expiresAt":1780000000000}}"#
        #expect(ClaudeKeychainReader.parseAccessToken(from: raw) == "sk-ant-atok-abc123")
    }

    @Test func parsesAccessTokenFromLegacyOauthAccountShape() {
        let raw = #"{"oauthAccount":{"tokens":{"accessToken":"sk-ant-legacy","id_token":"x"}}}"#
        #expect(ClaudeKeychainReader.parseAccessToken(from: raw) == "sk-ant-legacy")
    }

    @Test func parsesAccessTokenFromTruncatedJSON() {
        // security 对 >2KB payload 截断，JSON 不闭合，需正则兜底
        let raw = #"{"claudeAiOauth":{"accessToken":"sk-ant-truncated","refreshToken":"r-1","expiresAt":178"#
        #expect(ClaudeKeychainReader.parseAccessToken(from: raw) == "sk-ant-truncated")
    }

    @Test func parsesBareTokenShapes() {
        #expect(ClaudeKeychainReader.parseAccessToken(from: "sk-ant-bare-token") == "sk-ant-bare-token")
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig"
        #expect(ClaudeKeychainReader.parseAccessToken(from: jwt) == jwt)
    }

    @Test func returnsNilWhenNoToken() {
        #expect(ClaudeKeychainReader.parseAccessToken(from: #"{"foo":"bar"}"#) == nil)
        #expect(ClaudeKeychainReader.parseAccessToken(from: "not-a-token") == nil)
        #expect(ClaudeKeychainReader.parseAccessToken(from: "") == nil)
    }

    @Test func parsesExpiresAtMillis() {
        let raw = #"{"claudeAiOauth":{"accessToken":"t","expiresAt":1780000000000}}"#
        let date = ClaudeKeychainReader.parseExpiresAt(from: raw)
        #expect(date?.timeIntervalSince1970 == 1_780_000_000)
    }

    @Test func parsesExpiresAtSeconds() {
        let raw = #"{"claudeAiOauth":{"accessToken":"t","expiresAt":1780000000}}"#
        let date = ClaudeKeychainReader.parseExpiresAt(from: raw)
        #expect(date?.timeIntervalSince1970 == 1_780_000_000)
    }

    @Test func returnsNilWhenNoExpiresAt() {
        #expect(ClaudeKeychainReader.parseExpiresAt(from: #"{"claudeAiOauth":{"accessToken":"t"}}"#) == nil)
        #expect(ClaudeKeychainReader.parseExpiresAt(from: "junk") == nil)
    }

    @Test func hashedServiceNameFixedVector() {
        // 固定向量：sha256("/Users/test/.claude") 前 8 位 = 462977e4
        #expect(ClaudeKeychainReader.hashedServiceName(configDir: "/Users/test/.claude")
            == "Claude Code-credentials-462977e4")
        // 固定向量：sha256("/Users/sunyiyang/.claude") 前 8 位 = aaad841a
        #expect(ClaudeKeychainReader.hashedServiceName(configDir: "/Users/sunyiyang/.claude")
            == "Claude Code-credentials-aaad841a")
    }

    @Test func hashedServiceNameStandardizesPath() {
        // standardizingPath 归一化 ./ 与 ../
        #expect(ClaudeKeychainReader.hashedServiceName(configDir: "/Users/test/./x/../.claude")
            == ClaudeKeychainReader.hashedServiceName(configDir: "/Users/test/.claude"))
    }
}

// ============================================================
// MARK: - Claude 双源选源（纯函数）
// ============================================================

struct ClaudeCredentialsSourceTests {

    @Test func prefersLaterExpiryWhenBothPresent() {
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_800_000_000)
        let fileWins = ClaudeCredentialSource.preferred(
            fileToken: "file-t", fileExpiresAt: newer,
            keychainToken: "kc-t", keychainExpiresAt: older
        )
        #expect(fileWins?.token == "file-t")
        #expect(fileWins?.source == "file")

        let keychainWins = ClaudeCredentialSource.preferred(
            fileToken: "file-t", fileExpiresAt: older,
            keychainToken: "kc-t", keychainExpiresAt: newer
        )
        #expect(keychainWins?.token == "kc-t")
        #expect(keychainWins?.source == "keychain")
    }

    @Test func fallsBackToSingleSource() {
        let onlyFile = ClaudeCredentialSource.preferred(
            fileToken: "file-t", fileExpiresAt: nil,
            keychainToken: nil, keychainExpiresAt: nil
        )
        #expect(onlyFile?.token == "file-t")
        #expect(onlyFile?.source == "file")

        let onlyKeychain = ClaudeCredentialSource.preferred(
            fileToken: nil, fileExpiresAt: nil,
            keychainToken: "kc-t", keychainExpiresAt: nil
        )
        #expect(onlyKeychain?.token == "kc-t")
        #expect(onlyKeychain?.source == "keychain")
    }

    @Test func prefersKeychainWhenNoExpiryInfo() {
        // 文件无 expiresAt 时不可比新旧，Keychain 是权威轮换源 → 优先 Keychain
        let result = ClaudeCredentialSource.preferred(
            fileToken: "file-t", fileExpiresAt: nil,
            keychainToken: "kc-t", keychainExpiresAt: nil
        )
        #expect(result?.token == "kc-t")
        #expect(result?.source == "keychain")
    }

    @Test func usesFileWhenKeychainHasNoExpiry() {
        let newer = Date(timeIntervalSince1970: 1_800_000_000)
        let result = ClaudeCredentialSource.preferred(
            fileToken: "file-t", fileExpiresAt: newer,
            keychainToken: "kc-t", keychainExpiresAt: nil
        )
        #expect(result?.token == "file-t")
        #expect(result?.source == "file")
    }

    @Test func returnsNilWhenNoCredentials() {
        #expect(ClaudeCredentialSource.preferred(
            fileToken: nil, fileExpiresAt: nil,
            keychainToken: nil, keychainExpiresAt: nil) == nil)
        // 空字符串视为无效
        #expect(ClaudeCredentialSource.preferred(
            fileToken: "", fileExpiresAt: nil,
            keychainToken: "", keychainExpiresAt: nil) == nil)
    }
}

// ============================================================
// MARK: - 钥匙串读取缓存（避免轮询反复唤起 security 子进程弹授权框）
// ============================================================

/// 缓存是全局单例（避免每次轮询都读钥匙串弹框），测试用**独立实例**验证新鲜度规则，
/// 不触碰 `shared`，避免污染其他测试。
///
/// ⚠️ `ClaudeKeychainAccess` 是进程级全局开关，本套件里有测试会临时改写它 →
/// 必须 `.serialized`，否则同套件内并行执行会互相覆盖开关值（实测出现过 flaky）。
/// （该开关已改为纯内存、不落盘，因此不再污染真实 App Group 域。）
@Suite(.serialized)
struct ClaudeKeychainCacheTests {

    @Test func serviceNameNegativeCacheExpiresAfterTTL() {
        let cache = ClaudeKeychainCache()
        let ttl = ClaudeKeychainCache.serviceNameMissTTL
        let t0 = Date()
        #expect(cache.resolvedServiceName() == nil)
        #expect(cache.serviceNameMissIsFresh(now: t0) == false)   // 尚未记录未命中 → 允许探测

        cache.storeServiceNameMiss(now: t0)
        #expect(cache.serviceNameMissIsFresh(now: t0.addingTimeInterval(ttl - 1)) == true)
        #expect(cache.serviceNameMissIsFresh(now: t0.addingTimeInterval(ttl + 1)) == false)

        // 命中后永久缓存，并清掉负缓存
        cache.storeServiceName("Claude Code-credentials")
        #expect(cache.resolvedServiceName() == "Claude Code-credentials")
        #expect(cache.serviceNameMissIsFresh(now: t0) == false)
    }

    @Test func credentialCacheFollowsExpiry() {
        let cache = ClaudeKeychainCache()
        let now = Date()

        cache.storeCredential(
            ClaudeKeychainCredential(accessToken: "t", expiresAt: now.addingTimeInterval(3600)),
            now: now
        )
        #expect(cache.freshCredential(now: now)?.accessToken == "t")

        // 剩余寿命不足重读余量 → 不新鲜，调用方会重读钥匙串
        cache.storeCredential(
            ClaudeKeychainCredential(accessToken: "t", expiresAt: now.addingTimeInterval(60)),
            now: now
        )
        #expect(cache.freshCredential(now: now) == nil)
        // 但"条目存在"判定在 presenceTTL 内仍命中 —— 过期 token 不该反复弹框
        #expect(cache.presenceCredential(now: now)?.accessToken == "t")
        #expect(cache.presenceCredential(now: now.addingTimeInterval(3601)) == nil)
    }

    @Test func credentialWithoutExpiryUsesFallbackTTL() {
        let cache = ClaudeKeychainCache()
        let now = Date()
        cache.storeCredential(ClaudeKeychainCredential(accessToken: "raw"), now: now)
        #expect(cache.freshCredential(now: now.addingTimeInterval(3599))?.accessToken == "raw")
        #expect(cache.freshCredential(now: now.addingTimeInterval(3601)) == nil)
    }

    @Test func invalidateForcesReread() {
        let cache = ClaudeKeychainCache()
        cache.storeCredential(ClaudeKeychainCredential(accessToken: "t"), now: Date())
        cache.invalidate()
        #expect(cache.freshCredential() == nil)
        #expect(cache.presenceCredential() == nil)
    }

    /// ★ 读取失败（用户拒绝授权 / 超时）必须进静默期 ——
    /// 否则每次轮询都会重试，表现为"拒绝一次后钥匙串弹窗永远关不掉"。
    @Test func readFailureEntersSilencePeriod() {
        let cache = ClaudeKeychainCache()
        let ttl = ClaudeKeychainCache.readFailureTTL
        let t0 = Date()
        #expect(cache.isReadFailureFresh(now: t0) == false)

        cache.storeReadFailure(now: t0)
        #expect(cache.isReadFailureFresh(now: t0.addingTimeInterval(ttl - 1)) == true)
        #expect(cache.isReadFailureFresh(now: t0.addingTimeInterval(ttl + 1)) == false)

        // 后来读取成功 → 清掉静默期
        cache.storeCredential(ClaudeKeychainCredential(accessToken: "t"), now: t0)
        #expect(cache.isReadFailureFresh(now: t0.addingTimeInterval(60)) == false)
    }

    /// ★ 候选 service name 必须**有限且可计算** —— 取代原来枚举整个钥匙串的做法
    /// （`SecItemCopyMatching(kSecMatchLimitAll)` 会为每条条目弹框且在主线程卡死 UI）。
    @Test func candidateServiceNamesAreBounded() {
        let names = ClaudeKeychainReader.candidateServiceNames()
        #expect(!names.isEmpty)
        #expect(names.count <= 3)                                  // 有限，不随钥匙串条目数增长
        #expect(Set(names).count == names.count)                   // 无重复
        #expect(names.contains(ClaudeKeychainReader.legacyServiceName))
        // 默认配置目录的 hash 名必须在候选里（v2.1.52+ 常见形态）
        #expect(names.contains(
            ClaudeKeychainReader.hashedServiceName(configDir: ClaudeKeychainReader.defaultConfigDir)))
    }

    /// 文件源可用判定：无 expiresAt 视为不临期（交给服务端 401 兜底）
    @Test func nearExpiryDetection() {
        let now = Date()
        #expect(ClaudeQuotaFetcher.isNearExpiry(nil, now: now) == false)
        #expect(ClaudeQuotaFetcher.isNearExpiry(now.addingTimeInterval(3600), now: now) == false)
        #expect(ClaudeQuotaFetcher.isNearExpiry(now.addingTimeInterval(60), now: now) == true)
        #expect(ClaudeQuotaFetcher.isNearExpiry(now.addingTimeInterval(-60), now: now) == true)
    }

    /// ★ 开关契约：**关闭时一律返回空**，绝不访问钥匙串（零弹窗）。
    /// 这台上 `~/.claude/.credentials.json` 不存在，若不拦就会每次刷新都弹授权框。
    @Test func keychainReadsAreGatedWhenDisabled() {
        let previous = ClaudeKeychainAccess.isEnabled
        defer { ClaudeKeychainAccess.setEnabled(previous) }

        ClaudeKeychainAccess.setEnabled(false)
        #expect(ClaudeKeychainAccess.isEnabled == false)
        #expect(ClaudeKeychainReader.hasAnyEntry() == false)
        #expect(ClaudeKeychainReader.loadCredential() == nil)
        #expect(ClaudeKeychainReader.resolveServiceName() == nil)

        // 开启后闸门放行（此处不实际断言读到凭据，结果取决于本机钥匙串状态）
        ClaudeKeychainAccess.setEnabled(true)
        #expect(ClaudeKeychainAccess.isEnabled == true)
    }

    /// 开关值改动立即生效（纯内存，不落盘 —— 避免污染真实 App Group 域）
    @Test func keychainAccessFlagIsInMemoryOnly() {
        let previous = ClaudeKeychainAccess.isEnabled
        defer { ClaudeKeychainAccess.setEnabled(previous) }

        ClaudeKeychainAccess.setEnabled(true)
        #expect(ClaudeKeychainAccess.isEnabled == true)

        ClaudeKeychainAccess.setEnabled(false)
        #expect(ClaudeKeychainAccess.isEnabled == false)

        // 确认不会再写入 UserDefaults（曾因此把真实域写脏 → 重启后弹窗复发）
        let defaults = UserDefaults(suiteName: AppConstants.appGroupSuiteName)
        #expect(defaults?.object(forKey: "claude_keychain_opt_in") == nil)
    }

    /// 静默期用长 TTL：反复弹窗的根因是"失败后马上重试"
    @Test func silenceWindowsAreLong() {
        #expect(ClaudeKeychainCache.readFailureTTL >= 1800)
        #expect(ClaudeKeychainCache.serviceNameMissTTL >= 1800)
    }
}

// ============================================================
// MARK: - API 配置存储（★ 已从钥匙串迁到文件存储）
// ============================================================

/// 背景：ad-hoc 签名每次重编译都会让钥匙串条目 ACL 失配 → 每次启动/保存弹系统授权框。
/// 因此配置改存 Application Support 文件。这些测试确保迁移后的持久化语义正确，
/// 且**新实例不再写钥匙串**（ConfigStorageTests 全程只碰注入的临时目录）。
@MainActor
struct ConfigStorageTests {

    private func makeIsolatedVM() -> (vm: DashboardViewModel, dir: URL, cleanup: () -> Void) {
        let suiteName = "test.tokenhamster.\(UUID().uuidString)"
        let legacy = UserDefaults(suiteName: suiteName)!
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.tokenhamster.\(UUID().uuidString)", isDirectory: true)
        let vm = DashboardViewModel(userDefaults: legacy, storage: FileAppStorage(directory: tmpDir))
        return (vm, tmpDir, {
            legacy.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: tmpDir)
        })
    }

    /// 配置写入文件存储，而不是钥匙串
    @Test func configsPersistToFileStorage() {
        let (vm, dir, cleanup) = makeIsolatedVM()
        defer { cleanup() }

        vm.addAPIConfig(
            name: "DeepSeek", baseURL: "https://api.deepseek.com",
            apiKey: "sk-test", type: .deepseek
        )
        #expect(vm.apiConfigs.count == 1)

        // 文件存储里能读到（键名与 AppConstants 对齐）
        let fileURL = dir.appendingPathComponent("\(AppConstants.apiConfigsKey).json")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        let reloaded = FileAppStorage(directory: dir)
            .load([APIConfigItem].self, forKey: AppConstants.apiConfigsKey)
        #expect(reloaded?.count == 1)
        #expect(reloaded?.first?.name == "DeepSeek")
    }

    /// 同一存储再次构造 VM 时能恢复配置（不依赖钥匙串）
    @Test func configsReloadFromFileStorage() {
        let (vm, dir, cleanup) = makeIsolatedVM()
        defer { cleanup() }

        vm.addAPIConfig(
            name: "Kimi", baseURL: "https://api.moonshot.cn", apiKey: "sk-kimi", type: .kimi
        )

        let suiteName = "test.tokenhamster.\(UUID().uuidString)"
        let fresh = DashboardViewModel(
            userDefaults: UserDefaults(suiteName: suiteName)!,
            storage: FileAppStorage(directory: dir)
        )
        #expect(fresh.apiConfigs.count == 1)
        #expect(fresh.apiConfigs.first?.name == "Kimi")
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    /// 删光配置 → 文件被移除（不残留旧数组）
    @Test func emptyConfigsRemoveFile() {
        let (vm, dir, cleanup) = makeIsolatedVM()
        defer { cleanup() }

        vm.addAPIConfig(name: "A", baseURL: "https://a.com", apiKey: "k", type: .openAI)
        let id = vm.apiConfigs[0].id
        vm.deleteAPIConfig(id: id)

        #expect(vm.apiConfigs.isEmpty)
        let fileURL = dir.appendingPathComponent("\(AppConstants.apiConfigsKey).json")
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
    }

    /// 旧版 UserDefaults 数据仍可迁移（不丢存量配置）
    @Test func migratesLegacyUserDefaultsConfigs() throws {
        let suiteName = "test.tokenhamster.\(UUID().uuidString)"
        let legacy = UserDefaults(suiteName: suiteName)!
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.tokenhamster.\(UUID().uuidString)", isDirectory: true)
        defer {
            legacy.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: tmpDir)
        }

        let original = [APIConfigItem(
            name: "Legacy", baseURL: "https://legacy.com", apiKey: "old", apiType: .openAI
        )]
        legacy.set(try JSONEncoder().encode(original), forKey: AppConstants.apiConfigsKey)

        let vm = DashboardViewModel(userDefaults: legacy, storage: FileAppStorage(directory: tmpDir))
        #expect(vm.apiConfigs.count == 1)
        #expect(vm.apiConfigs.first?.name == "Legacy")

        // 迁移后旧键被清理，新值落在文件存储
        #expect(legacy.data(forKey: AppConstants.apiConfigsKey) == nil)
        let reloaded = FileAppStorage(directory: tmpDir)
            .load([APIConfigItem].self, forKey: AppConstants.apiConfigsKey)
        #expect(reloaded?.count == 1)
    }

    /// 文件存储目录权限收紧到 0700（内含 API Key）
    @Test func storageDirectoryIsUserOnly() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.tokenhamster.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        _ = FileAppStorage(directory: tmpDir)   // init 时设置权限
        let attrs = try FileManager.default.attributesOfItem(atPath: tmpDir.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o700)
    }
}

// ============================================================
// MARK: - Codex 凭据路径与登录判定
// ============================================================

struct CodexAuthPathTests {

    @Test func authPathHonorsCodexHome() {
        let path = CodexQuotaFetcher.authPath(codexHome: "/custom/codex", homeDir: "/Users/test")
        #expect(path == "/custom/codex/auth.json")
    }

    @Test func authPathFallsBackToHomeDir() {
        let path = CodexQuotaFetcher.authPath(codexHome: nil, homeDir: "/Users/test")
        #expect(path == "/Users/test/.codex/auth.json")
    }

    @Test func authPathTreatsEmptyCodexHomeAsUnset() {
        let path = CodexQuotaFetcher.authPath(codexHome: "", homeDir: "/Users/test")
        #expect(path == "/Users/test/.codex/auth.json")
    }

    @Test func hasValidCredentialsWithTempFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("th-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let validOAuth = dir.appendingPathComponent("oauth.json")
        try #"{"tokens":{"access_token":"sk-123","account_id":"acc-1"}}"#.write(to: validOAuth, atomically: true, encoding: .utf8)
        #expect(CodexQuotaFetcher.hasValidCredentials(at: validOAuth.path))

        let apiKeyOnly = dir.appendingPathComponent("byok.json")
        try #"{"OPENAI_API_KEY":"sk-proj-xxx"}"#.write(to: apiKeyOnly, atomically: true, encoding: .utf8)
        #expect(CodexQuotaFetcher.hasValidCredentials(at: apiKeyOnly.path))

        let empty = dir.appendingPathComponent("empty.json")
        try "{}".write(to: empty, atomically: true, encoding: .utf8)
        #expect(!CodexQuotaFetcher.hasValidCredentials(at: empty.path))

        let corrupt = dir.appendingPathComponent("corrupt.json")
        try "not-json".write(to: corrupt, atomically: true, encoding: .utf8)
        #expect(!CodexQuotaFetcher.hasValidCredentials(at: corrupt.path))

        #expect(!CodexQuotaFetcher.hasValidCredentials(at: dir.appendingPathComponent("missing.json").path))
    }
}

