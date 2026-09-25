//
//  QuotaWindowTests.swift
//  TokenHamsterTests
//
//  额度双窗口解析 + Token 账本（三维度 / 软重置严格截断）单元测试
//

import Foundation
import Testing
@testable import TokenHamster

// ============================================================
// MARK: - 官方额度双窗口解析
// ============================================================

struct QuotaWindowParsingTests {

    @Test func codexRPCProducesBothWindows() {
        let json: [String: Any] = [
            "rateLimits": [
                "planType": "plus",
                "primary": ["usedPercent": 12.0, "resetsAt": "2026-09-10T18:00:00Z"],
                "secondary": ["usedPercent": 34.0, "resetsAt": "2026-09-14T00:00:00Z"],
            ]
        ]
        let snapshot = CodexQuotaParser.parseRateLimitsResponse(json, source: "codex-rpc")
        // ★ 旧实现只会保留一个窗口
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.window(.session5h)?.usedPercent == 12.0)
        #expect(snapshot.window(.cycle)?.usedPercent == 34.0)
        // 剩余百分比 = 100 − 已用
        #expect(snapshot.window(.session5h)?.remainingPercent == 88.0)
        #expect(snapshot.window(.cycle)?.remainingPercent == 66.0)
        #expect(snapshot.planName == "plus")
        #expect(snapshot.primaryWindow?.kind == .session5h)
    }

    @Test func codexCycleOnlyStillParses() {
        let json: [String: Any] = [
            "rateLimits": ["secondary": ["usedPercent": 50.0]]
        ]
        let snapshot = CodexQuotaParser.parseRateLimitsResponse(json, source: "codex-rpc")
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.window(.cycle)?.usedPercent == 50.0)
        // 无 5h 窗口时主窗口回退首个
        #expect(snapshot.primaryWindow?.kind == .cycle)
    }

    @Test func codexModelLimitsStillParsedAlongsideWindows() {
        let json: [String: Any] = [
            "rateLimits": [
                "primary": ["usedPercent": 10.0],
                "secondary": ["usedPercent": 20.0],
            ],
            "rateLimitsByLimitId": [
                "codex-mini": ["limitName": "Codex Mini", "primary": ["usedPercent": 42.0]]
            ],
        ]
        let snapshot = CodexQuotaParser.parseRateLimitsResponse(json, source: "codex-rpc")
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.modelLimits.count == 1)
        #expect(snapshot.modelLimits.first?.modelName == "Codex Mini")
        #expect(snapshot.modelLimits.first?.usedPercent == 42.0)
    }

    @Test func claudeProducesBothWindows() {
        let json: [String: Any] = [
            "five_hour": ["utilization": 7.0, "resets_at": "2026-09-10T18:00:00Z"],
            "seven_day": ["utilization": 21.0, "resets_at": "2026-09-14T00:00:00Z"],
            "seven_day_opus": ["utilization": 5.0, "resets_at": "2026-09-14T00:00:00Z"],
        ]
        let snapshot = ClaudeQuotaParser.parse(json, source: "claude-oauth")
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.window(.session5h)?.usedPercent == 7.0)
        #expect(snapshot.window(.cycle)?.usedPercent == 21.0)
        #expect(snapshot.modelLimits.contains { $0.modelName == "opus" })
    }

    @Test func claudeFiveHourOnlyDoesNotFabricateCycleWindow() {
        let json: [String: Any] = ["five_hour": ["utilization": 7.0]]
        let snapshot = ClaudeQuotaParser.parse(json, source: "claude-oauth")
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.window(.session5h)?.usedPercent == 7.0)
        #expect(snapshot.window(.cycle) == nil)
    }

    @Test func cycleStartIsResetMinusSevenDays() throws {
        let resetsAt = try #require(ISO8601DateFormatter().date(from: "2026-09-14T00:00:00Z"))
        let window = QuotaWindow(kind: .cycle, usedPercent: 10, resetsAt: resetsAt)
        let start = try #require(window.cycleStart)
        let delta = resetsAt.timeIntervalSince(start)
        #expect(abs(delta - 7 * 86_400) < 1)
    }

    @Test func sessionWindowHasNoCycleStart() {
        let window = QuotaWindow(kind: .session5h, usedPercent: 10, resetsAt: Date())
        #expect(window.cycleStart == nil)
    }

    @Test func usedPercentIsClampedToRange() {
        #expect(QuotaWindow(kind: .cycle, usedPercent: 140).usedPercent == 100)
        #expect(QuotaWindow(kind: .cycle, usedPercent: -5).usedPercent == 0)
        #expect(QuotaWindow(kind: .cycle, usedPercent: 140).remainingPercent == 0)
    }
}

// ============================================================
// MARK: - 额度重置倒计时
// ============================================================

struct QuotaCountdownTests {

    /// 5h 窗口精确到分：2h 12m
    @Test func minutePrecisionRendersHoursAndMinutes() {
        let text = formatCountdown(2 * 3600 + 12 * 60, precision: .minute)
        #expect(text == "2h 12m")
    }

    @Test func minutePrecisionHandlesSubHour() {
        #expect(formatCountdown(12 * 60, precision: .minute) == "12m")
        #expect(formatCountdown(90, precision: .minute) == "1m")     // 截断到分
        #expect(formatCountdown(59, precision: .minute) == "<1m") // 不足 1 分钟
    }

    @Test func minutePrecisionHandlesMultiDay() {
        let text = formatCountdown(26 * 3600 + 5 * 60, precision: .minute)
        #expect(text == "1d 2h 5m")
    }

    /// 周额度精确到小时：1d 2h（截断，不含分钟）
    @Test func hourPrecisionRendersDaysAndHours() {
        let text = formatCountdown(26 * 3600 + 40 * 60, precision: .hour)
        #expect(text == "1d 2h")
    }

    @Test func hourPrecisionTruncatesBelowOneHour() {
        // 30 分钟不足 1 小时 → 即将重置（而非 "0h"）
        #expect(formatCountdown(30 * 60, precision: .hour) == "<1h")
        // 25 小时 → 1d 1h
        #expect(formatCountdown(25 * 3600, precision: .hour) == "1d 1h")
        // 恰好 1 小时 → 1h
        #expect(formatCountdown(3600, precision: .hour) == "1h")
    }

    @Test func expiredIntervalsBecomeResettingSoon() {
        #expect(formatCountdown(0, precision: .minute) == "<1m")
        #expect(formatCountdown(-100, precision: .hour) == "<1h")
        #expect(formatCountdown(0, precision: .hour) == "<1h")
    }

    /// ★ 精度绑定在窗口类型上：5h → 分，周期 → 小时
    @Test func windowKindDeterminesPrecision() {
        #expect(QuotaWindowKind.session5h.countdownPrecision == .minute)
        #expect(QuotaWindowKind.cycle.countdownPrecision == .hour)
    }

    /// ★ 倒计时是实时计算值，不随快照固化
    @Test func windowCountdownIsLive() {
        let inFiveHours = QuotaWindow(
            kind: .session5h, usedPercent: 10,
            resetsAt: Date().addingTimeInterval(5 * 3600)
        )
        let text = inFiveHours.countdownText
        // 5h 窗口 → 分钟精度
        #expect(text.contains("h"))
        #expect(text.contains("m"))
        #expect(!inFiveHours.isExpired)

        // 加 30s 缓冲，避免「恰好 26h」被截断成 1d 1h
        let futureCycle = QuotaWindow(
            kind: .cycle, usedPercent: 20,
            resetsAt: Date().addingTimeInterval(26 * 3600 + 30)
        )
        #expect(futureCycle.countdownText == "1d 2h")   // 小时精度，无分钟
    }

    @Test func windowWithoutResetTimeHasNoCountdown() {
        let window = QuotaWindow(kind: .cycle, usedPercent: 20)
        #expect(window.countdownText.isEmpty)
        #expect(!window.isExpired)
    }

    @Test func expiredWindowIsFlagged() {
        let window = QuotaWindow(
            kind: .cycle, usedPercent: 99,
            resetsAt: Date().addingTimeInterval(-60)
        )
        #expect(window.isExpired)
        #expect(window.countdownText == "<1h")
    }

    /// 展示结构带完整的四个数：已用% / 剩余% / 倒计时 / 标签
    @Test func displayCarriesUsedRemainingAndCountdown() {
        let window = QuotaWindow(
            kind: .cycle, usedPercent: 42,
            resetsAt: Date().addingTimeInterval(26 * 3600 + 30)
        )
        let display = window.display
        #expect(display.usedPercent == 42)
        #expect(display.remainingPercent == 58)
        #expect(display.countdownText == "1d 2h")
        #expect(display.displayText == "Weekly · 1d 2h")
        #expect(display.id == "cycle")
    }

    /// 参考图样式字段："95% left" / "Reset 4h 24m"
    @Test func displayProvidesReferenceImageFields() {
        let window = QuotaWindow(
            kind: .session5h, usedPercent: 5,
            resetsAt: Date().addingTimeInterval(4 * 3600 + 24 * 60 + 30)
        )
        let display = window.display
        #expect(display.label == "Session")          // 左列标题
        #expect(display.percentLeftText == "95% left")
        #expect(display.resetLine == "Reset 4h 24m")
    }

    @Test func displayWithoutCountdownFallsBackToLabel() {
        let display = QuotaWindow(kind: .session5h, usedPercent: 10).display
        #expect(display.countdownText.isEmpty)
        #expect(display.resetLine.isEmpty)           // 无重置时刻 → 不显示 Reset 行
        #expect(display.displayText == "Session")
    }

    /// quotaResetText 按窗口类型选精度
    @Test func quotaResetTextUsesWindowPrecision() {
        let resetsAt = Date().addingTimeInterval(26 * 3600 + 30)
        let cycleText = quotaResetText(from: resetsAt, windowLabel: "Weekly", kind: .cycle)
        #expect(cycleText == "Weekly · resets in 1d 2h")

        let fiveHourResets = Date().addingTimeInterval(2 * 3600 + 12 * 60 + 30)
        let fiveHourText = quotaResetText(from: fiveHourResets, windowLabel: "Session", kind: .session5h)
        #expect(fiveHourText == "Session · resets in 2h 12m")
    }

    @Test func quotaResetTextWithoutResetTimeIsEmpty() {
        #expect(quotaResetText(from: nil, windowLabel: "Weekly", kind: .cycle).isEmpty)
    }

    /// 参考图标签：左列 Session、右列 Weekly
    @Test func windowLabelsMatchReferenceImage() {
        #expect(QuotaWindowKind.session5h.displayLabel == "Session")
        #expect(QuotaWindowKind.cycle.displayLabel == "Weekly")
    }
}

// ============================================================
// MARK: - 快照上的双窗口展示
// ============================================================

struct AgentSnapshotQuotaWindowTests {

    private func makeSnapshot(windows: [QuotaWindow]) -> AgentSnapshot {
        var snapshot = AgentSnapshot(id: "codex", name: "Codex", iconName: "terminal.fill", sourceType: .local)
        snapshot.quotaWindows = windows
        return snapshot
    }

    /// ★ Codex 场景：5h + 周额度两个窗口同时可展示
    @Test func exposesBothSessionAndCycleWindows() throws {
        let snapshot = makeSnapshot(windows: [
            QuotaWindow(kind: .session5h, usedPercent: 12,
                        resetsAt: Date().addingTimeInterval(2 * 3600 + 12 * 60 + 30)),
            QuotaWindow(kind: .cycle, usedPercent: 34,
                        resetsAt: Date().addingTimeInterval(26 * 3600 + 30)),
        ])

        let displays = snapshot.quotaWindowDisplays
        #expect(displays.count == 2)

        let fiveHour = try #require(snapshot.session5hWindow)
        #expect(fiveHour.usedPercent == 12)
        #expect(fiveHour.remainingPercent == 88)
        #expect(fiveHour.countdownText == "2h 12m")     // 精确到分

        let cycle = try #require(snapshot.cycleWindow)
        #expect(cycle.usedPercent == 34)
        #expect(cycle.remainingPercent == 66)
        #expect(cycle.countdownText == "1d 2h")         // 精确到小时
    }

    @Test func windowsAreNilWhenApiReturnsOnlyOne() {
        let snapshot = makeSnapshot(windows: [
            QuotaWindow(kind: .session5h, usedPercent: 5)
        ])
        #expect(snapshot.session5hWindow != nil)
        #expect(snapshot.cycleWindow == nil)
    }

    @Test func noWindowsYieldsEmptyDisplays() {
        let snapshot = makeSnapshot(windows: [])
        #expect(snapshot.quotaWindowDisplays.isEmpty)
        #expect(snapshot.session5hWindow == nil)
        #expect(snapshot.cycleWindow == nil)
    }
}

// ============================================================
// MARK: - 模型级额度倒计时
// ============================================================

struct ModelUsageQuotaCountdownTests {

    @Test func modelLevelCountdownUsesHourPrecision() {
        let item = ModelUsageItem(
            id: "m", modelName: "gpt-5.5-codex", tokenAmount: 100, usagePercent: 0,
            quotaUsed: 30, quotaTotal: 100,
            quotaResetsAt: Date().addingTimeInterval(26 * 3600 + 30)
        )
        #expect(item.quotaCountdownText == "1d 2h")
        #expect(item.quotaRemainingPercent == 70)
    }

    @Test func modelLevelCountdownEmptyWithoutResetTime() {
        let item = ModelUsageItem(
            id: "m", modelName: "gpt-5.5-codex", tokenAmount: 100, usagePercent: 0,
            quotaUsed: 30, quotaTotal: 100
        )
        #expect(item.quotaCountdownText.isEmpty)
    }

    @Test func remainingPercentNilWithoutQuota() {
        let item = ModelUsageItem(id: "m", modelName: "x", tokenAmount: 1, usagePercent: 0)
        #expect(item.quotaRemainingPercent == nil)
    }

    /// applyQuota 必须把重置时刻写进模型明细（否则前端无法实时倒计时）
    @Test func applyQuotaStoresModelResetTime() throws {
        let resetsAt = Date().addingTimeInterval(3 * 3600 + 30)
        let quota = QuotaSnapshot(
            windows: [
                QuotaWindow(kind: .session5h, usedPercent: 10,
                            resetsAt: Date().addingTimeInterval(3600 + 30)),
                QuotaWindow(kind: .cycle, usedPercent: 50, resetsAt: resetsAt),
            ],
            modelLimits: [ModelLimit(modelName: "codex-mini", usedPercent: 42, resetsAt: resetsAt)]
        )
        var snapshot = AgentSnapshot(
            id: "codex", name: "Codex", iconName: "terminal.fill", sourceType: .local
        )
        snapshot.modelUsages = [
            ModelUsageItem(id: "m0", modelName: "codex-mini", tokenAmount: 10, usagePercent: 1)
        ]

        LocalLogSource.applyQuota(quota, to: &snapshot)

        #expect(snapshot.quotaWindows.count == 2)
        #expect(snapshot.cycleStart != nil)
        let item = try #require(snapshot.modelUsages.first)
        #expect(item.quotaUsed == 42)
        #expect(item.quotaResetsAt == resetsAt)
        #expect(item.quotaCountdownText == "3h")     // 小时精度
        // 兼容旧字段仍取主窗口（5h 会话窗口）
        #expect(snapshot.resetTimeString == "Session · resets in 1h 0m")    }
}

// ============================================================
// MARK: - Provider 注册表
// ============================================================

struct AgentProviderSpecTests {

    @Test func everyProviderHasUsableSpec() {
        for provider in AgentProvider.allCases {
            let spec = provider.spec
            #expect(!spec.displayName.isEmpty, "\(provider) 缺 displayName")
            #expect(!spec.symbolName.isEmpty, "\(provider) 缺 symbolName")
            #expect(spec.provider == provider)
        }
    }

    @Test func localProvidersMapToExpectedSourceKinds() {
        #expect(AgentProvider.claudeCode.spec.kind == .claudeCodeLog)
        #expect(AgentProvider.codex.spec.kind == .codexLog)
        #expect(AgentProvider.cursor.spec.kind == .cursorWeb)
        #expect(AgentProvider.dsh.spec.kind == .dshUsageStats)
        #expect(AgentProvider.zcode.spec.kind == .zaiPlan)
        #expect(AgentProvider.customPath.spec.kind == .customPath)
    }

    @Test func credentialHintsAreDeclaredOnlyWhereHelpful() {
        // 零配置源不需要提示
        #expect(AgentProvider.claudeCode.spec.credentialHint == nil)
        #expect(AgentProvider.codex.spec.credentialHint == nil)
        #expect(AgentProvider.dsh.spec.credentialHint == nil)
        #expect(AgentProvider.cursor.spec.credentialHint != nil)
        // ★ Z.ai 的说明文字已移除（接口地址下拉 + 密钥框占位文案已足够），
        //   但它**仍然需要凭据** —— 这两件事不能混为一谈。
        #expect(AgentProvider.zcode.spec.credentialHint == nil)
        #expect(AgentProvider.zcode.spec.secretFieldPlaceholder == "Coding Plan API Key")
        #expect(AgentProvider.cursor.spec.secretFieldPlaceholder != nil)
    }
}

// ============================================================
// MARK: - Token 账本（三维度 + 软重置）
// ============================================================

struct ModelTokenLedgerTests {

    private var calendar: Calendar { Calendar.current }

    private func localDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) throws -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return try #require(calendar.date(from: components))
    }

    private func write(
        _ ledger: inout ModelTokenLedger,
        source: String = "src",
        model: String,
        day: Date,
        value: Int
    ) {
        ledger.upsert(
            sourceID: source, model: model,
            dayKey: tokenDayKey(for: day, calendar: calendar), value: value
        )
    }

    @Test func totalsSplitIntoDayMonthAndAllTime() throws {
        var ledger = ModelTokenLedger()
        let now = try localDate(2026, 9, 10)
        write(&ledger, model: "gpt-5", day: try localDate(2026, 9, 10), value: 100)
        write(&ledger, model: "gpt-5", day: try localDate(2026, 9, 9), value: 200)
        write(&ledger, model: "gpt-5", day: try localDate(2026, 8, 1), value: 400)

        let totals = ledger.totals(forModel: "gpt-5", now: now, calendar: calendar)
        #expect(totals.day == 100)     // 仅今天
        #expect(totals.month == 300)   // 本自然月（9/10 + 9/9）
        #expect(totals.total == 700)   // 全时段
    }

    @Test func allTotalsSumsEveryModelRegardlessOfOrigin() throws {
        var ledger = ModelTokenLedger()
        let now = try localDate(2026, 9, 10)
        write(&ledger, source: "openai-api", model: "gpt-5", day: now, value: 100)
        write(&ledger, source: "claude-code", model: "claude-opus-4-8", day: now, value: 250)

        let totals = ledger.allTotals(now: now, calendar: calendar)
        #expect(totals.day == 350)
        #expect(totals.total == 350)
    }

    /// ★ 核心：同名模型来自两个源必须相加；同一源重复扫描不得翻倍
    @Test func sameModelFromTwoSourcesAddsUpButRescanIsIdempotent() throws {
        var ledger = ModelTokenLedger()
        let today = try localDate(2026, 9, 10)
        write(&ledger, source: "claude-code", model: "opus", day: today, value: 1000)
        write(&ledger, source: "anthropic-api", model: "opus", day: today, value: 2000)
        #expect(ledger.totals(forModel: "opus", now: today, calendar: calendar).total == 3000)

        // 重扫第一个源（返回同样的值）→ 不得翻倍
        write(&ledger, source: "claude-code", model: "opus", day: today, value: 1000)
        #expect(ledger.totals(forModel: "opus", now: today, calendar: calendar).total == 3000)

        // 单源视图仍可单独读取
        #expect(ledger.totals(
            sourceID: "claude-code", model: "opus", now: today, calendar: calendar
        ).total == 1000)
    }

    @Test func upsertTakesMaxWhileAccumulateAdds() {
        var ledger = ModelTokenLedger()
        // 明细型源：每次返回全量历史 → 重扫不得回退，也不得翻倍
        ledger.upsert(sourceID: "s", model: "detail", dayKey: 100, value: 50)
        ledger.upsert(sourceID: "s", model: "detail", dayKey: 100, value: 30)
        #expect(ledger.buckets[LedgerKey.encode(sourceID: "s", model: "detail")]?[100] == 50)
        ledger.upsert(sourceID: "s", model: "detail", dayKey: 100, value: 80)
        #expect(ledger.buckets[LedgerKey.encode(sourceID: "s", model: "detail")]?[100] == 80)

        // 汇总型源：只知累计值变化量 → 累加
        ledger.accumulate(sourceID: "s", model: "summary", dayKey: 100, delta: 50)
        ledger.accumulate(sourceID: "s", model: "summary", dayKey: 100, delta: 30)
        #expect(ledger.buckets[LedgerKey.encode(sourceID: "s", model: "summary")]?[100] == 80)
    }

    @Test func ledgerKeyRoundTripsIncludingEmptySource() {
        let key = LedgerKey.encode(sourceID: "abc", model: "gpt-5.5")
        #expect(LedgerKey.model(of: key) == "gpt-5.5")
        #expect(LedgerKey.sourceID(of: key) == "abc")

        // 空 sourceID（未知来源）仍需正确解析
        let emptySource = LedgerKey.encode(sourceID: "", model: "m")
        #expect(LedgerKey.model(of: emptySource) == "m")
        #expect(LedgerKey.sourceID(of: emptySource) == "")

        // 模型名含分隔符极端情况：只按首个分隔符切分
        let weird = LedgerKey.encode(sourceID: "s", model: "a\u{1F}b")
        #expect(LedgerKey.sourceID(of: weird) == "s")
        #expect(LedgerKey.model(of: weird) == "a\u{1F}b")
    }

    @Test func resetTruncatesDaysBeforeResetAndRebasesResetDay() throws {
        var ledger = ModelTokenLedger()
        let today = try localDate(2026, 9, 10)
        write(&ledger, model: "opus", day: try localDate(2026, 9, 8), value: 300)
        write(&ledger, model: "opus", day: try localDate(2026, 9, 9), value: 200)
        write(&ledger, model: "opus", day: today, value: 500)

        // 重置前：全部计入
        #expect(ledger.totals(forModel: "opus", now: today, calendar: calendar).total == 1000)

        // 今天 14:00 重置（当日快照 = 500）
        ledger.resetModel("opus", at: try localDate(2026, 9, 10, hour: 14), calendar: calendar)

        // 重置日之前归零；重置日扣除快照
        var totals = ledger.totals(forModel: "opus", now: today, calendar: calendar)
        #expect(totals.day == 0)
        #expect(totals.total == 0)

        // 日志全量重扫 → 当日原始值涨到 800，增量应显示为 300
        write(&ledger, model: "opus", day: today, value: 800)
        totals = ledger.totals(forModel: "opus", now: today, calendar: calendar)
        #expect(totals.day == 300)
        #expect(totals.total == 300)

        // 次日新增全额计入
        let tomorrow = try localDate(2026, 9, 11)
        write(&ledger, model: "opus", day: tomorrow, value: 150)
        totals = ledger.totals(forModel: "opus", now: tomorrow, calendar: calendar)
        #expect(totals.day == 150)
        #expect(totals.total == 450)
    }

    /// ★ 重置快照按「全部来源求和」记录，跨源同名模型一起截断
    @Test func resetSnapshotCoversAllSourcesOfSameModel() throws {
        var ledger = ModelTokenLedger()
        let today = try localDate(2026, 9, 10)
        write(&ledger, source: "a", model: "opus", day: today, value: 100)
        write(&ledger, source: "b", model: "opus", day: today, value: 200)
        ledger.resetModel("opus", at: try localDate(2026, 9, 10, hour: 14), calendar: calendar)

        #expect(ledger.modelResets["opus"]?.daySnapshot == 300)
        #expect(ledger.totals(forModel: "opus", now: today, calendar: calendar).total == 0)
    }

    @Test func resetDaySnapshotNeverGoesNegative() throws {
        var ledger = ModelTokenLedger()
        let today = try localDate(2026, 9, 10)
        write(&ledger, model: "m", day: today, value: 500)
        ledger.resetModel("m", at: try localDate(2026, 9, 10, hour: 14), calendar: calendar)
        // 当日值反而变小（异常数据）→ 截断为 0，不出现负数
        write(&ledger, model: "m", day: today, value: 200)
        let totals = ledger.totals(forModel: "m", now: today, calendar: calendar)
        #expect(totals.day == 0)
        #expect(totals.total == 0)
    }

    @Test func modelResetDoesNotAffectOtherModels() throws {
        var ledger = ModelTokenLedger()
        let today = try localDate(2026, 9, 10)
        write(&ledger, model: "a", day: today, value: 100)
        write(&ledger, model: "b", day: today, value: 200)
        ledger.resetModel("a", at: try localDate(2026, 9, 10, hour: 14), calendar: calendar)

        #expect(ledger.totals(forModel: "a", now: today, calendar: calendar).total == 0)
        #expect(ledger.totals(forModel: "b", now: today, calendar: calendar).total == 200)
    }

    @Test func globalResetClearsPerModelResetsAndZeroesEverything() throws {
        var ledger = ModelTokenLedger()
        let today = try localDate(2026, 9, 10)
        write(&ledger, model: "a", day: today, value: 100)
        write(&ledger, model: "b", day: today, value: 200)
        ledger.resetModel("a", at: try localDate(2026, 9, 10, hour: 8), calendar: calendar)
        #expect(ledger.modelResets["a"] != nil)

        ledger.resetAll(at: try localDate(2026, 9, 10, hour: 14), calendar: calendar)
        // 全局重置清空模型级重置点，避免叠加
        #expect(ledger.modelResets.isEmpty)
        #expect(ledger.globalReset?.daySnapshot == 300)   // 100 + 200
        #expect(ledger.allTotals(now: today, calendar: calendar).total == 0)
    }

    @Test func clearingModelResetRestoresAccumulation() throws {
        var ledger = ModelTokenLedger()
        let today = try localDate(2026, 9, 10)
        write(&ledger, model: "m", day: today, value: 100)
        ledger.resetModel("m", at: try localDate(2026, 9, 10, hour: 14), calendar: calendar)
        #expect(ledger.totals(forModel: "m", now: today, calendar: calendar).total == 0)

        ledger.clearReset(for: "m")
        #expect(ledger.totals(forModel: "m", now: today, calendar: calendar).total == 100)
    }

    @Test func modelTotalsAreSortedAndCarryOrigin() throws {
        var ledger = ModelTokenLedger()
        let today = try localDate(2026, 9, 10)
        write(&ledger, source: "codex", model: "small", day: today, value: 10)
        write(&ledger, source: "codex", model: "big", day: today, value: 900)

        let rows = ledger.modelTotals(
            originBySource: ["codex": .ideTool], now: today, calendar: calendar
        )
        #expect(rows.count == 2)
        #expect(rows[0].modelName == "big")
        #expect(rows[0].origin == .ideTool)
        #expect(rows[1].hasCustomReset == false)
    }

    /// 同名模型来自不同来源通道 → 拆成两行（前端两个子区块各一行）
    @Test func modelTotalsSplitSameModelAcrossOrigins() throws {
        var ledger = ModelTokenLedger()
        let today = try localDate(2026, 9, 10)
        write(&ledger, source: "openai-api", model: "gpt-5", day: today, value: 100)
        write(&ledger, source: "codex", model: "gpt-5", day: today, value: 300)

        let rows = ledger.modelTotals(
            originBySource: ["openai-api": .directAPI, "codex": .ideTool],
            now: today, calendar: calendar
        )
        #expect(rows.count == 2)
        #expect(rows[0].origin == .ideTool)      // 300 在前
        #expect(rows[0].totals.total == 300)
        #expect(rows[1].origin == .directAPI)
        #expect(rows[1].totals.total == 100)
        // 但总用量仍是相加
        #expect(ledger.allTotals(now: today, calendar: calendar).total == 400)
    }

    @Test func ledgerRoundTripsThroughCodable() throws {
        var ledger = ModelTokenLedger()
        let today = try localDate(2026, 9, 10)
        write(&ledger, source: "s1", model: "m", day: today, value: 42)
        ledger.resetModel("m", at: today, calendar: calendar)

        let data = try JSONEncoder().encode(ledger)
        let decoded = try JSONDecoder().decode(ModelTokenLedger.self, from: data)
        #expect(decoded == ledger)
    }
}
