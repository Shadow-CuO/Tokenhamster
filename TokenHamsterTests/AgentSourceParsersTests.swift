//
//  AgentSourceParsersTests.swift
//  TokenHamsterTests
//
//  Cursor / DSH / ZCode 三个数据源的解析与折算逻辑
//

import Foundation
import Testing
@testable import TokenHamster

// ============================================================
// MARK: - Cursor
// ============================================================

struct CursorCookieTests {

    @Test func parsesFullCookieHeader() throws {
        let parsed = try #require(CursorCookie.parse("WorkosCursorSessionToken=user_abc::jwt-token"))
        #expect(parsed.userId == "user_abc")
        #expect(parsed.cookieHeader == "WorkosCursorSessionToken=user_abc::jwt-token")
    }

    @Test func parsesBareCookieValue() throws {
        let parsed = try #require(CursorCookie.parse("user_abc::jwt-token"))
        #expect(parsed.userId == "user_abc")
        #expect(parsed.cookieHeader == "WorkosCursorSessionToken=user_abc::jwt-token")
    }

    /// 从浏览器整串 Cookie 中挑出目标项
    @Test func picksTargetFromMultiCookieString() throws {
        let raw = "other=1; WorkosCursorSessionToken=user_xyz::tok; another=2"
        let parsed = try #require(CursorCookie.parse(raw))
        #expect(parsed.userId == "user_xyz")
        #expect(parsed.cookieHeader == "WorkosCursorSessionToken=user_xyz::tok")
    }

    @Test func handlesTrailingWhitespace() throws {
        let parsed = try #require(CursorCookie.parse("  user_abc::jwt  \n"))
        #expect(parsed.userId == "user_abc")
    }

    @Test func rejectsEmptyAndMalformed() {
        #expect(CursorCookie.parse("") == nil)
        #expect(CursorCookie.parse("   ") == nil)
    }
}

struct CursorUsageParserTests {

    private var payload: [String: Any] {
        [
            "gpt-4": ["numRequests": 120, "maxRequestUsage": 500],
            "claude-4-sonnet": ["numRequests": 30, "maxRequestUsage": 500],
            "startOfMonth": "2026-09-01T00:00:00.000Z",
        ]
    }

    @Test func sumsRequestsAndReadsLimit() {
        let usage = CursorUsageParser.parse(payload)
        #expect(usage.models.count == 2)               // startOfMonth 不算模型
        #expect(usage.usedRequests == 150)
        #expect(usage.maxRequests == 500)
        #expect(usage.models.first?.modelName == "gpt-4")   // 降序 120 > 30
    }

    @Test func readsCycleStart() throws {
        let usage = CursorUsageParser.parse(payload)
        let start = try #require(usage.cycleStart)
        // 2026-09-01T00:00:00Z
        #expect(start.timeIntervalSince1970 == 1_788_220_800)
    }

    @Test func toleratesNumericStrings() {
        let json: [String: Any] = ["m": ["numRequests": "40", "maxRequestUsage": "100"]]
        let usage = CursorUsageParser.parse(json)
        #expect(usage.usedRequests == 40)
        #expect(usage.maxRequests == 100)
    }

    @Test func skipsZeroedEntries() {
        let json: [String: Any] = ["ghost": ["numRequests": 0, "maxRequestUsage": 0]]
        #expect(CursorUsageParser.parse(json).models.isEmpty)
    }

    @Test func makeSnapshotProducesCycleWindowAndModelLimits() {
        let quota = CursorQuotaFetcher.makeSnapshot(CursorUsageParser.parse(payload))
        let cycle = quota.window(.cycle)
        #expect(cycle?.usedPercent == 30)          // 150 / 500
        #expect(cycle?.remainingPercent == 70)
        #expect(quota.window(.session5h) == nil)   // Cursor 无 5h 档
        // 周期起点 + 1 个月 = 重置时刻
        #expect(cycle?.resetsAt != nil)
        #expect(quota.modelLimits.count == 2)
        #expect(quota.modelLimits.first { $0.modelName == "gpt-4" }?.usedPercent == 24)
    }

    @Test func makeSnapshotWithoutLimitProducesNoWindow() {
        let json: [String: Any] = ["m": ["numRequests": 10, "maxRequestUsage": 0]]
        let quota = CursorQuotaFetcher.makeSnapshot(CursorUsageParser.parse(json))
        #expect(quota.windows.isEmpty)
        #expect(quota.modelLimits.isEmpty)
    }

    /// ★ Cursor 不提供 token，绝不能用请求数冒充 token（否则污染账本）
    @Test func snapshotKeepsTokenCountsAtZero() {
        let quota = CursorQuotaFetcher.makeSnapshot(CursorUsageParser.parse(payload))
        let snapshot = CursorSource.buildSnapshot(
            id: "cursor", name: "Cursor", iconName: "cursorarrow.rays",
            assetName: nil, quota: quota
        )
        #expect(snapshot.totalTokens == 0)
        #expect(snapshot.origin == .ideTool)
        #expect(snapshot.modelDailyTokens.isEmpty)
        #expect(snapshot.modelUsages.count == 2)
        #expect(snapshot.modelUsages.allSatisfy { $0.tokenAmount == 0 })
        // 额度百分比仍然带上了
        #expect(snapshot.modelUsages.contains { $0.quotaUsed == 24 })
        #expect(snapshot.quotaWindows.count == 1)
    }
}

// ============================================================
// MARK: - DSH（读 @ychris12138/dsh-usage-stats 插件缓存）
// ============================================================

/// 构造符合插件 `CACHE_VERSION = 5` 形态的缓存 JSON。
/// 刻意包含 `pricingFingerprint` / `pricingIdentityCutoff*` —— 它们必须被安静忽略。
private func dshCacheJSON(version: Int = 5, sessions: String) -> Data {
    Data(
        #"{"version":\#(version),"pricingFingerprint":"fp","pricingIdentityCutoffAll":null,"pricingIdentityCutoffs":{},"sessions":{\#(sessions)}}"#.utf8
    )
}

/// 单会话 JSON（`days` 为原始片段，键需自带引号）
private func dshSession(_ id: String, days: String, lastSampleTime: Int? = nil) -> String {
    let sample = lastSampleTime.map { #","lastSample":{"key":"1:1","time":\#($0)}"# } ?? ""
    return #""\#(id)":{"kind":"persisted","consumed":3,"days":{\#(days)}\#(sample)}"#
}

/// 单日 JSON（`totals` 必填；`models` 可选）
private func dshDay(totals: String, models: String? = nil) -> String {
    guard let models else { return #"{"totals":\#(totals)}"# }
    return #"{"totals":\#(totals),"models":{\#(models)}}"#
}

struct DSHUsageStatsSourceTests {

    /// 四桶完整：100 + 50 + 900 + 40 = 1090
    private let allFourBuckets = #"{"inputTokens":100,"outputTokens":50,"cacheReadTokens":900,"cacheWriteTokens":40}"#

    // ------------------------------------------------------------
    // MARK: 聚合与口径
    // ------------------------------------------------------------

    /// ★ 口径 = 四桶相加（与插件 `lib/usage.js` 的 `totalTokens()` 一致），含 cacheWrite
    @Test func sumsAllFourBucketsIncludingCacheWrite() {
        let data = dshCacheJSON(sessions: dshSession("s1", days: #""2026-09-17":\#(dshDay(totals: allFourBuckets))"#))
        let eval = DSHUsageStatsSource.evaluate(
            cacheData: data, pluginInstalled: true, latestLogModification: nil
        )
        #expect(eval.availability == .ready)
        #expect(eval.aggregate.totalTokens == 1090)
    }

    /// 跨会话、跨天累加
    @Test func aggregatesAcrossSessionsAndDays() throws {
        let sessions = [
            dshSession("s1", days: #""2026-09-16":\#(dshDay(totals: #"{"inputTokens":100}"#)),"2026-09-17":\#(dshDay(totals: #"{"inputTokens":200}"#))"#),
            dshSession("s2", days: #""2026-09-17":\#(dshDay(totals: #"{"inputTokens":300}"#))"#),
        ].joined(separator: ",")

        let eval = DSHUsageStatsSource.evaluate(
            cacheData: dshCacheJSON(sessions: sessions),
            pluginInstalled: true, latestLogModification: nil
        )
        try #require(eval.availability == .ready)
        #expect(eval.aggregate.totalTokens == 600)
        #expect(eval.aggregate.dayTokens.count == 2)

        let sep17 = try #require(DSHUsageStatsSource.parseDayKey("2026-09-17"))
        #expect(eval.aggregate.dayTokens[sep17] == 500)      // 200 + 300
    }

    /// `models` 的键是 `providerId/model` → 展示名去掉供应商前缀；未知桶统一为 `(unknown)`
    @Test func groupsModelsByDisplayNameAndNormalisesUnknown() throws {
        let models = [
            #""deepseek-official/deepseek-flash":{"inputTokens":100}"#,
            #""ark/deepseek-flash":{"inputTokens":40}"#,          // 同模型不同供应商 → 展示时合并
            #""unknown/unknown":{"inputTokens":7}"#,
        ].joined(separator: ",")

        let data = dshCacheJSON(sessions: dshSession("s1", days: #""2026-09-17":\#(dshDay(totals: #"{"inputTokens":147}"#, models: models))"#))
        let eval = DSHUsageStatsSource.evaluate(
            cacheData: data, pluginInstalled: true, latestLogModification: nil
        )
        #expect(eval.aggregate.modelTokens["deepseek-flash"] == 140)
        #expect(eval.aggregate.modelTokens["(unknown)"] == 7)
        #expect(eval.aggregate.modelTokens.count == 2)
    }

    /// 日期键直接映射为本地 startOfDay —— 不需要任何时区换算
    @Test func mapsDayKeysDirectlyToLocalDates() throws {
        let data = dshCacheJSON(sessions: dshSession("s1", days: #""2026-09-17":\#(dshDay(totals: #"{"outputTokens":5}"#))"#))
        let eval = DSHUsageStatsSource.evaluate(
            cacheData: data, pluginInstalled: true, latestLogModification: nil
        )
        let expected = try #require(DSHUsageStatsSource.parseDayKey("2026-09-17"))
        #expect(eval.aggregate.dayTokens.keys.first == expected)
        #expect(eval.aggregate.dayTokens[expected] == 5)
    }

    @Test func parsesDayKeyWithLocalCalendar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 8 * 3600))
        let date = try #require(DSHUsageStatsSource.parseDayKey("2026-09-17", calendar: calendar))
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        #expect(parts.year == 2026)
        #expect(parts.month == 9)
        #expect(parts.day == 17)
        #expect(parts.hour == 0)
        // 非法键
        #expect(DSHUsageStatsSource.parseDayKey("2026-09") == nil)
        #expect(DSHUsageStatsSource.parseDayKey("nonsense") == nil)
    }

    @Test func displayNameStripsProviderPrefix() {
        #expect(DSHUsageStatsSource.displayModelName("deepseek-official/deepseek-flash") == "deepseek-flash")
        #expect(DSHUsageStatsSource.displayModelName("unknown/unknown") == "(unknown)")
        #expect(DSHUsageStatsSource.displayModelName("") == "(unknown)")
        #expect(DSHUsageStatsSource.displayModelName("gpt-5") == "gpt-5")
    }

    /// 单日 totals 为 0 / 缺字段不得产生假行
    @Test func ignoresZeroAndMissingBuckets() {
        let data = dshCacheJSON(sessions: dshSession("s1", days: #""2026-09-17":\#(dshDay(totals: "{}", models: #""x/y":{}"#))"#))
        let eval = DSHUsageStatsSource.evaluate(
            cacheData: data, pluginInstalled: true, latestLogModification: nil
        )
        #expect(eval.aggregate.totalTokens == 0)
        #expect(eval.aggregate.modelTokens.isEmpty)
        #expect(eval.aggregate.dayTokens.isEmpty)
    }

    // ------------------------------------------------------------
    // MARK: 可用性（每种都要给出可行动提示，绝不静默显示 0）
    // ------------------------------------------------------------

    @Test func reportsPluginMissingWhenNoCacheAndNothingInstalled() {
        let eval = DSHUsageStatsSource.evaluate(
            cacheData: nil, pluginInstalled: false, latestLogModification: nil
        )
        #expect(eval.availability == .pluginMissing)
        #expect(eval.availability.message == "The dsh-usage-stats plugin is not installed")
    }

    @Test func reportsCacheMissingWhenPluginInstalledButNoCache() {
        let eval = DSHUsageStatsSource.evaluate(
            cacheData: nil, pluginInstalled: true, latestLogModification: nil
        )
        #expect(eval.availability == .cacheMissing)
        #expect(!eval.availability.message.isEmpty)
    }

    @Test func reportsCorruptForMalformedJSON() {
        let eval = DSHUsageStatsSource.evaluate(
            cacheData: Data("not json at all".utf8),
            pluginInstalled: true, latestLogModification: nil
        )
        #expect(eval.availability == .corrupt)
    }

    /// 旧 schema → 插件会自行重折叠，对我们只是「暂时没数据」，不是错误
    @Test func reportsRebuildingForOlderCacheVersion() {
        let data = dshCacheJSON(version: 4, sessions: dshSession("s1", days: #""2026-09-17":\#(dshDay(totals: allFourBuckets))"#))
        let eval = DSHUsageStatsSource.evaluate(
            cacheData: data, pluginInstalled: true, latestLogModification: nil
        )
        #expect(eval.availability == .rebuilding)
        #expect(eval.availability.snapshotStatus == .error)   // 必须可见 —— 不能静默显示 0
        #expect(!eval.availability.message.isEmpty)
        #expect(eval.aggregate.totalTokens == 0)
    }

    /// 价格指纹变更会让插件整体清空 sessions → 空 sessions 是合法状态，不是错误
    @Test func reportsRebuildingForEmptySessions() {
        let eval = DSHUsageStatsSource.evaluate(
            cacheData: dshCacheJSON(sessions: ""),
            pluginInstalled: true, latestLogModification: nil
        )
        #expect(eval.availability == .rebuilding)
    }

    /// 缓存版本比本应用新 → 必须让用户更新 TokenHamster，不能猜结构
    @Test func reportsAppOutdatedForNewerCacheVersion() {
        let data = dshCacheJSON(version: 6, sessions: dshSession("s1", days: #""2026-09-17":\#(dshDay(totals: allFourBuckets))"#))
        let eval = DSHUsageStatsSource.evaluate(
            cacheData: data, pluginInstalled: true, latestLogModification: nil
        )
        #expect(eval.availability == .appOutdated)
        #expect(eval.availability.snapshotStatus == .error)
        #expect(eval.aggregate.totalTokens == 0)             // 不读不可信的结构
    }

    // ------------------------------------------------------------
    // MARK: 冻结检测
    // ------------------------------------------------------------

    /// 会话日志明显新于缓存里的最后一个用量样本 → 插件没跟上，数据冻结
    @Test func detectsFrozenCacheAgainstSessionLog() {
        let sampleMs = 1_787_000_000_000
        let sampleDate = Date(timeIntervalSince1970: Double(sampleMs) / 1000)
        let data = dshCacheJSON(sessions: dshSession(
            "s1", days: #""2026-09-17":\#(dshDay(totals: allFourBuckets))"#, lastSampleTime: sampleMs
        ))

        let frozen = DSHUsageStatsSource.evaluate(
            cacheData: data, pluginInstalled: true,
            latestLogModification: sampleDate.addingTimeInterval(3600)
        )
        #expect(frozen.availability == .stale)
        #expect(frozen.aggregate.latestSampleDate == sampleDate)

        // 阈值内（刚写过日志）不算冻结
        let healthy = DSHUsageStatsSource.evaluate(
            cacheData: data, pluginInstalled: true,
            latestLogModification: sampleDate.addingTimeInterval(60)
        )
        #expect(healthy.availability == .ready)
    }

    /// ★ 无 lastSample 时不做冻结判定 —— days 的键是「日」粒度，
    ///   拿它比会把「今天有活动」误判成冻结
    @Test func doesNotFlagFrozenWithoutSampleTime() {
        let data = dshCacheJSON(sessions: dshSession("s1", days: #""2026-09-17":\#(dshDay(totals: allFourBuckets))"#))
        let eval = DSHUsageStatsSource.evaluate(
            cacheData: data, pluginInstalled: true,
            latestLogModification: Date().addingTimeInterval(86_400 * 30)
        )
        #expect(eval.availability == .ready)
    }

    @Test func everyUnavailableStateHasAnActionableMessage() {
        for availability: DSHUsageStatsAvailability in [
            .pluginMissing, .cacheMissing, .rebuilding, .appOutdated, .corrupt, .stale,
        ] {
            #expect(!availability.message.isEmpty)
            // 非 ready 一律走 error 通道，否则卡片会静默显示 0
            #expect(availability.snapshotStatus == .error)
        }
        #expect(DSHUsageStatsAvailability.ready.message.isEmpty)
        #expect(DSHUsageStatsAvailability.ready.snapshotStatus == .ok)
    }

    // ------------------------------------------------------------
    // MARK: 快照组装
    // ------------------------------------------------------------

    /// DSH 卡片是纯 token 卡：无总额度、不显示剩余百分比、右列不需要占比
    @Test func buildSnapshotProducesTokenOnlyCard() {
        let data = dshCacheJSON(sessions: dshSession(
            "s1",
            days: #""2026-09-17":\#(dshDay(totals: allFourBuckets, models: #""deepseek-official/deepseek-flash":\#(allFourBuckets)"#))"#
        ))
        let eval = DSHUsageStatsSource.evaluate(
            cacheData: data, pluginInstalled: true, latestLogModification: nil
        )
        let snapshot = DSHUsageStatsSource.buildSnapshot(
            id: "dsh", name: "DeepSeek Harness",
            iconName: "terminal.fill", assetName: "deepseek",
            evaluation: eval
        )
        #expect(snapshot.totalTokens == 1090)
        #expect(snapshot.quotaTotal == 0)
        #expect(snapshot.quotaUnit == "tokens")
        #expect(snapshot.resetTimeString == "Cumulative")
        #expect(snapshot.leftPercentText.isEmpty)            // 无总额度 → 不显示 %
        #expect(snapshot.quotaText == "1.1K")
        #expect(snapshot.origin == .ideTool)
        #expect(snapshot.status == .ok)
        #expect(snapshot.errorMessage.isEmpty)
        #expect(snapshot.modelUsages.first?.modelName == "deepseek-flash")
        #expect(snapshot.modelDailyTokens.count == 1)
        #expect(snapshot.dailyHeatmap.count == 1)
    }

    @Test func buildSnapshotCarriesAvailabilityMessage() {
        let eval = DSHUsageStatsSource.evaluate(
            cacheData: nil, pluginInstalled: false, latestLogModification: nil
        )
        let snapshot = DSHUsageStatsSource.buildSnapshot(
            id: "dsh", name: "DeepSeek Harness",
            iconName: "terminal.fill", assetName: nil,
            evaluation: eval
        )
        #expect(snapshot.status == .error)
        #expect(snapshot.errorMessage == "The dsh-usage-stats plugin is not installed")
        #expect(snapshot.totalTokens == 0)
        #expect(snapshot.modelDailyTokens.isEmpty)
    }

    // ------------------------------------------------------------
    // MARK: 路径
    // ------------------------------------------------------------

    @Test func defaultCachePathHonoursDSHHome() {
        #expect(
            DSHUsageStatsSource.defaultCachePath(dshHome: "/x/dsh", homeDir: "/Users/u")
                == "/x/dsh/storages/usage-stats-cache.json"
        )
        #expect(
            DSHUsageStatsSource.defaultCachePath(dshHome: nil, homeDir: "/Users/u")
                == "/Users/u/.dsh/storages/usage-stats-cache.json"
        )
        // 空串等同未设置（DSH_HOME 常被导出为空）
        #expect(
            DSHUsageStatsSource.defaultCachePath(dshHome: "", homeDir: "/Users/u")
                == "/Users/u/.dsh/storages/usage-stats-cache.json"
        )
        #expect(
            DSHUsageStatsSource.defaultSessionsRoot(dshHome: "/x/dsh", homeDir: "/Users/u")
                == "/x/dsh/sessions"
        )
    }

    @Test func detectsPluginInstallationAcrossProfiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-profiles.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.path

        #expect(!DSHUsageStatsSource.isPluginInstalled(dshHome: home))

        // profiles/web/node_modules/@ychris12138/dsh-usage-stats
        let installed = URL(fileURLWithPath: home)
            .appendingPathComponent("profiles/web")
            .appendingPathComponent("node_modules/@ychris12138/dsh-usage-stats", isDirectory: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        #expect(DSHUsageStatsSource.isPluginInstalled(dshHome: home))
    }
}

// ============================================================
// MARK: - DSH 插件安装器
// ============================================================

struct DSHPluginInstallerTests {

    /// 默认装「已验证版本」，命令形态与官方 `dsh plugin add` 一致
    @Test func installCommandPinsVerifiedVersionByDefault() {
        let command = DSHPluginInstaller.installCommand(profile: "web", target: .verified)
        #expect(command == #"dsh plugin --profile web add "@ychris12138/dsh-usage-stats@0.3.3""#)
    }

    /// 最新版走 `@latest`，且**必须**带风险提示
    @Test func latestTargetUsesLatestTagAndWarns() {
        let command = DSHPluginInstaller.installCommand(profile: "desktop", target: .latest)
        #expect(command == #"dsh plugin --profile desktop add "@ychris12138/dsh-usage-stats@latest""#)
        #expect(DSHPluginInstallTarget.latest.riskNote != nil)
        #expect(DSHPluginInstallTarget.verified.riskNote == nil)
    }

    /// ★ 包装名必须带 scope —— 无 scope 的 dsh-usage-stats 是另一个项目
    @Test func packageNameIsScoped() {
        #expect(DSHPluginInstaller.packageName == "@ychris12138/dsh-usage-stats")
        #expect(DSHPluginInstaller.packageName.contains("/"))
        #expect(DSHPluginInstaller.installCommand(profile: "web", target: .verified)
            .contains("@ychris12138/dsh-usage-stats"))
    }

    @Test func uninstallAndRevertCommandsTargetTheSameScopedPackage() {
        #expect(DSHPluginInstaller.uninstallCommand(profile: "web")
            == #"dsh plugin --profile web remove "@ychris12138/dsh-usage-stats""#)
        #expect(DSHPluginInstaller.revertCommand(profile: "web")
            == #"dsh plugin --profile web add "@ychris12138/dsh-usage-stats@0.3.3""#)
        #expect(DSHPluginInstaller.revertCommand(profile: "web", version: "0.3.0")
            .contains("@0.3.0"))
        // 二次校验命令指向作者官方安装器
        #expect(DSHPluginInstaller.secondaryCheckCommand.contains("--check"))
    }

    /// 走登录 shell —— GUI 进程的 PATH 里没有 homebrew / nvm
    @Test func runsThroughLoginShell() {
        #expect(DSHPluginInstaller.loginShell == "/bin/zsh")
    }

    /// ★ 指南 URL 必须稳定 —— 旧版 App 会一直用它，含版本号就会指向死链
    @Test func guideURLIsStableAbsoluteAndVersionFree() throws {
        let raw = AppConstants.dshPluginGuideURL
        let url = try #require(URL(string: raw))
        #expect(url.scheme == "https")
        #expect(url.host?.isEmpty == false)
        #expect(!raw.contains(DSHPluginInstaller.verifiedVersion))
        #expect(!raw.contains("/v"))
    }

    // ------------------------------------------------------------
    // MARK: profile 枚举
    // ------------------------------------------------------------

    @Test func listsProfilesExcludingNodeModulesFilesAndHidden() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-home.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let profiles = home.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)

        for name in ["web", "desktop", "cli"] {
            try FileManager.default.createDirectory(
                at: profiles.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        // 应被排除：node_modules 目录、隐藏目录、普通文件
        try FileManager.default.createDirectory(
            at: profiles.appendingPathComponent("node_modules", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: profiles.appendingPathComponent(".cache", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: profiles.appendingPathComponent("profiles.lock"))

        let names = DSHPluginInstaller.availableProfiles(dshHome: home.path)
        #expect(names == ["cli", "desktop", "web"])
    }

    @Test func availableProfilesIsEmptyWhenDirectoryMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope.\(UUID().uuidString)", isDirectory: true)
        #expect(DSHPluginInstaller.availableProfiles(dshHome: missing.path).isEmpty)
    }

    /// 默认选 web（最常用），否则取第一个 —— 但仍需用户确认，因为猜错=永远没数据
    @Test func defaultProfilePrefersWeb() {
        #expect(DSHPluginInstaller.defaultProfile(from: ["desktop", "web"]) == "web")
        #expect(DSHPluginInstaller.defaultProfile(from: ["desktop"]) == "desktop")
        #expect(DSHPluginInstaller.defaultProfile(from: []) == nil)
    }

    // ------------------------------------------------------------
    // MARK: 安装后验证（绝不用退出码冒充成功）
    // ------------------------------------------------------------

    /// 包目录不存在 → 安装没落地
    @Test func verifyReportsNotInstalledWhenPackageAbsent() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-v1.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let result = DSHPluginInstaller.verify(profile: "web", dshHome: home.path)
        #expect(result == .notInstalled)
        #expect(!result.isSuccess)
    }

    /// 包在但没有缓存 → 正常中间态：需要用户重启 DSH
    @Test func verifyReportsWaitingForRestartWhenCacheAbsent() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-v2.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(
                "profiles/web/node_modules/@ychris12138/dsh-usage-stats", isDirectory: true
            ),
            withIntermediateDirectories: true
        )

        let result = DSHPluginInstaller.verify(profile: "web", dshHome: home.path)
        #expect(result == .waitingForRestart)
        #expect(result.isSuccess)                    // 不是失败，只是还没生效
        #expect(result.message.contains("restart"))
    }

    /// 包在 + 缓存在 → 已生效
    @Test func verifyReportsActiveWhenPackageAndCachePresent() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-v3.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(
                "profiles/web/node_modules/@ychris12138/dsh-usage-stats", isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("storages", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(
            to: home.appendingPathComponent("storages/usage-stats-cache.json")
        )

        let result = DSHPluginInstaller.verify(profile: "web", dshHome: home.path)
        #expect(result == .active)
        #expect(result.isSuccess)
    }

    /// 装错 profile → 探不到包（这是「假成功」的主要来源，必须能区分）
    @Test func verifyIsScopedToTheChosenProfile() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-v4.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(
                "profiles/web/node_modules/@ychris12138/dsh-usage-stats", isDirectory: true
            ),
            withIntermediateDirectories: true
        )

        #expect(DSHPluginInstaller.verify(profile: "web", dshHome: home.path) == .waitingForRestart)
        #expect(DSHPluginInstaller.verify(profile: "desktop", dshHome: home.path) == .notInstalled)
    }

    @Test func installOutputMarksFailureAndTimeout() {
        let ok = DSHInstallOutput(exitCode: 0, output: "added 1 package", timedOut: false, command: "x")
        #expect(ok.succeeded)
        #expect(ok.displayOutput == "added 1 package")

        let failed = DSHInstallOutput(exitCode: 1, output: "ERR 404", timedOut: false, command: "x")
        #expect(!failed.succeeded)

        let timedOut = DSHInstallOutput(exitCode: -1, output: "", timedOut: true, command: "x")
        #expect(!timedOut.succeeded)
        #expect(timedOut.displayOutput.contains("timed out"))

        // 无输出时给占位，避免看起来像 UI 坏了
        let silent = DSHInstallOutput(exitCode: 0, output: "   \n ", timedOut: false, command: "x")
        #expect(silent.displayOutput == "(the command produced no output)")
    }
}

// ============================================================
// MARK: - 账本口径版本
// ============================================================

struct ModelTokenLedgerMetricVersionTests {

    /// 无 metricVersion 的历史数据（或口径变更后）→ 丢弃，不参与累加
    @Test func discardsLedgerWithoutMatchingMetricVersion() throws {
        let key = LedgerKey.encode(sourceID: "dsh", model: "deepseek-flash")
        let legacy = Data(#"{"buckets":{"\#(key)":{"20000":123}},"modelResets":{},"globalReset":null}"#.utf8)

        let decoded = try JSONDecoder().decode(ModelTokenLedger.self, from: legacy)
        #expect(decoded.buckets.isEmpty)
        #expect(decoded.metricVersion == ModelTokenLedger.currentMetricVersion)
    }

    @Test func discardsLedgerWithAnotherMetricVersion() throws {
        let key = LedgerKey.encode(sourceID: "dsh", model: "deepseek-flash")
        let other = Data(#"{"metricVersion":99,"buckets":{"\#(key)":{"20000":123}},"modelResets":{},"globalReset":null}"#.utf8)

        let decoded = try JSONDecoder().decode(ModelTokenLedger.self, from: other)
        #expect(decoded.buckets.isEmpty)
    }

    /// 当前口径 → 正常往返，且重扫不翻倍（upsert 取 max）
    @Test func roundTripsAndStaysIdempotentUnderCurrentMetricVersion() throws {
        var ledger = ModelTokenLedger()
        ledger.upsert(sourceID: "dsh", model: "deepseek-flash", dayKey: 20_000, value: 100)
        ledger.upsert(sourceID: "dsh", model: "deepseek-flash", dayKey: 20_000, value: 100)

        let data = try JSONEncoder().encode(ledger)
        let decoded = try JSONDecoder().decode(ModelTokenLedger.self, from: data)

        #expect(decoded == ledger)
        #expect(decoded.buckets[LedgerKey.encode(sourceID: "dsh", model: "deepseek-flash")]?[20_000] == 100)
    }
}
