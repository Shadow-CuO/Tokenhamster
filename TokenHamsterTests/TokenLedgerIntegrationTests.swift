//
//  TokenLedgerIntegrationTests.swift
//  TokenHamsterTests
//
//  Token 账本端到端：明细源幂等入账、三维总量、软重置及其持久化
//

import Foundation
import Testing
@testable import TokenHamster

// ============================================================
// MARK: - 测试夹具
// ============================================================

/// 隔离环境：临时 UserDefaults suite + 临时文件存储目录
@MainActor
private struct LedgerTestEnvironment {
    let defaults: UserDefaults
    let directory: URL
    let suiteName: String

    init() {
        suiteName = "test.tokenhamster.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.tokenhamster.\(UUID().uuidString)", isDirectory: true)
    }

    func makeViewModel() -> DashboardViewModel {
        DashboardViewModel(userDefaults: defaults, storage: FileAppStorage(directory: directory))
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// 写一个 Claude Code 格式的 jsonl 日志文件（时间戳 = 现在，保证落在「今天」）
private func makeClaudeLogFile(lines: [(model: String, input: Int, output: Int)]) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("test.ledgerlog.\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("session.jsonl")

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    let timestamp = iso.string(from: Date())

    let content = lines.map { line in
        """
        {"timestamp":"\(timestamp)","message":{"model":"\(line.model)","usage":{"input_tokens":\(line.input),"output_tokens":\(line.output)}}}
        """
    }.joined(separator: "\n")

    try Data(content.utf8).write(to: file)
    return file
}

/// 本地日志源配置（customPath → 无官方额度抓取，纯本地解析）
@MainActor
private func makeLocalLogConfig(name: String, path: URL) -> APIConfigItem {
    APIConfigItem(
        name: name,
        baseURL: "",
        apiKey: "",
        apiType: .localLog,
        isActive: true,
        agentProvider: .customPath,
        localLogPath: path.path
    )
}

// ============================================================
// MARK: - 明细型源：幂等入账
// ============================================================

@MainActor
struct TokenLedgerDetailSourceTests {

    /// ★ 核心：明细型源每次返回全量历史，重复刷新不得翻倍
    @Test func detailSourceLedgerIsIdempotentAcrossRefreshes() async throws {
        let env = LedgerTestEnvironment()
        defer { env.cleanUp() }

        let file = try makeClaudeLogFile(lines: [
            ("claude-opus-4-8", 1_000, 500),
        ])
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let vm = env.makeViewModel()
        vm.apiConfigs = [makeLocalLogConfig(name: "本地", path: file)]

        try await vm.manualRefresh()
        #expect(vm.totalTokenUsage.total == 1_500)
        #expect(vm.totalTokenUsage.day == 1_500)

        // 再刷两次：账本必须幂等，不能变成 3×1500
        try await vm.manualRefresh()
        try await vm.manualRefresh()
        #expect(vm.totalTokenUsage.total == 1_500)
    }

    /// 同一模型来自两个源必须相加（而非互相覆盖）
    @Test func sameModelFromTwoSourcesAddsUp() async throws {
        let env = LedgerTestEnvironment()
        defer { env.cleanUp() }

        let fileA = try makeClaudeLogFile(lines: [("claude-opus-4-8", 1_000, 0)])
        let fileB = try makeClaudeLogFile(lines: [("claude-opus-4-8", 2_000, 0)])
        defer {
            try? FileManager.default.removeItem(at: fileA.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: fileB.deletingLastPathComponent())
        }

        let vm = env.makeViewModel()
        vm.apiConfigs = [
            makeLocalLogConfig(name: "源 A", path: fileA),
            makeLocalLogConfig(name: "源 B", path: fileB),
        ]
        try await vm.manualRefresh()

        #expect(vm.totalTokenUsage.total == 3_000)
    }

    /// 多模型：总量为各模型相加，且明细按模型拆分
    @Test func multipleModelsAggregateIntoTotal() async throws {
        let env = LedgerTestEnvironment()
        defer { env.cleanUp() }

        let file = try makeClaudeLogFile(lines: [
            ("claude-opus-4-8", 1_000, 0),
            ("claude-sonnet-4-5", 400, 100),
        ])
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let vm = env.makeViewModel()
        vm.apiConfigs = [makeLocalLogConfig(name: "本地", path: file)]
        try await vm.manualRefresh()

        #expect(vm.totalTokenUsage.total == 1_500)
        #expect(vm.modelTokenTotals.count == 2)
        #expect(vm.modelTokenTotals.first?.modelName == "claude-opus-4-8")   // 降序
        #expect(vm.modelTokenTotals.first?.origin == .ideTool)               // 本地源 = IDE 通道
    }
}

// ============================================================
// MARK: - 软重置
// ============================================================

@MainActor
struct TokenLedgerResetTests {

    @Test func resetModelZeroesThatModelOnly() async throws {
        let env = LedgerTestEnvironment()
        defer { env.cleanUp() }

        let file = try makeClaudeLogFile(lines: [
            ("claude-opus-4-8", 1_000, 0),
            ("claude-sonnet-4-5", 400, 0),
        ])
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let vm = env.makeViewModel()
        vm.apiConfigs = [makeLocalLogConfig(name: "本地", path: file)]
        try await vm.manualRefresh()
        #expect(vm.totalTokenUsage.total == 1_400)

        vm.resetModelTokenUsage("claude-opus-4-8")
        // 被重置的模型归零，另一个不受影响
        #expect(vm.totalTokenUsage.total == 400)
        #expect(vm.hasTokenReset(for: "claude-opus-4-8"))
        #expect(!vm.hasTokenReset(for: "claude-sonnet-4-5"))

        // 重置后再刷新：日志内容未变 → 仍为 0 增量（严格截断）
        try await vm.manualRefresh()
        #expect(vm.totalTokenUsage.total == 400)
    }

    /// 重置点跨重启保留
    @Test func resetSurvivesReload() async throws {
        let env = LedgerTestEnvironment()
        defer { env.cleanUp() }

        let file = try makeClaudeLogFile(lines: [("claude-opus-4-8", 1_000, 0)])
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let config = makeLocalLogConfig(name: "本地", path: file)

        let first = env.makeViewModel()
        first.apiConfigs = [config]
        try await first.manualRefresh()
        #expect(first.totalTokenUsage.total == 1_000)
        first.resetModelTokenUsage("claude-opus-4-8")
        #expect(first.totalTokenUsage.total == 0)

        // 新实例读同一存储目录 → 重置点仍在
        let second = env.makeViewModel()
        second.apiConfigs = [config]
        #expect(second.totalTokenUsage.total == 0)
        #expect(second.hasTokenReset(for: "claude-opus-4-8"))

        // 新实例刷新后依然为 0（截断生效）
        try await second.manualRefresh()
        #expect(second.totalTokenUsage.total == 0)
    }

    @Test func resetAllClearsEveryModelAndPerModelMarks() async throws {
        let env = LedgerTestEnvironment()
        defer { env.cleanUp() }

        let file = try makeClaudeLogFile(lines: [
            ("claude-opus-4-8", 1_000, 0),
            ("claude-sonnet-4-5", 400, 0),
        ])
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let vm = env.makeViewModel()
        vm.apiConfigs = [makeLocalLogConfig(name: "本地", path: file)]
        try await vm.manualRefresh()

        vm.resetModelTokenUsage("claude-opus-4-8")
        vm.resetAllTokenUsage()

        #expect(vm.totalTokenUsage.total == 0)
        // 全局重置会清空模型级标记，避免叠加
        #expect(vm.tokenLedger.modelResets.isEmpty)
        #expect(vm.tokenLedger.globalReset != nil)

        try await vm.manualRefresh()
        #expect(vm.totalTokenUsage.total == 0)
    }

    /// 撤销模型重置 → 数据恢复可见
    @Test func clearingResetRestoresUsage() async throws {
        let env = LedgerTestEnvironment()
        defer { env.cleanUp() }

        let file = try makeClaudeLogFile(lines: [("claude-opus-4-8", 1_000, 0)])
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let vm = env.makeViewModel()
        vm.apiConfigs = [makeLocalLogConfig(name: "本地", path: file)]
        try await vm.manualRefresh()

        vm.resetModelTokenUsage("claude-opus-4-8")
        #expect(vm.totalTokenUsage.total == 0)

        vm.clearModelTokenReset("claude-opus-4-8")
        #expect(vm.totalTokenUsage.total == 1_000)
        #expect(!vm.hasTokenReset(for: "claude-opus-4-8"))
    }

    /// ★ 账本与额度板块独立：重置 token 用量不得影响额度百分比
    @Test func resettingTokenUsageDoesNotTouchQuota() async throws {
        let env = LedgerTestEnvironment()
        defer { env.cleanUp() }

        let file = try makeClaudeLogFile(lines: [("claude-opus-4-8", 1_000, 0)])
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let vm = env.makeViewModel()
        vm.apiConfigs = [makeLocalLogConfig(name: "本地", path: file)]
        try await vm.manualRefresh()

        let windowsBefore = vm.agentSnapshots.first?.quotaWindows
        vm.resetAllTokenUsage()
        #expect(vm.agentSnapshots.first?.quotaWindows == windowsBefore)
    }
}

// ============================================================
// MARK: - 三维维度
// ============================================================

@MainActor
struct TokenLedgerDimensionTests {

    @Test func dayMonthAndTotalAreDerivedIndependently() throws {
        var ledger = ModelTokenLedger()
        let calendar = Calendar.current
        func localDate(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            components.hour = 12
            return try #require(calendar.date(from: components))
        }

        let now = try localDate(2026, 9, 10)
        ledger.upsert(sourceID: "s", model: "m", dayKey: tokenDayKey(for: try localDate(2026, 9, 10), calendar: calendar), value: 100)
        ledger.upsert(sourceID: "s", model: "m", dayKey: tokenDayKey(for: try localDate(2026, 9, 2), calendar: calendar), value: 200)
        ledger.upsert(sourceID: "s", model: "m", dayKey: tokenDayKey(for: try localDate(2026, 7, 1), calendar: calendar), value: 300)

        let totals = ledger.totals(forModel: "m", now: now, calendar: calendar)
        #expect(totals.day == 100)     // 仅 9/10
        #expect(totals.month == 300)   // 9 月：100 + 200
        #expect(totals.total == 600)   // 全时段
    }
}
