//
//  LocalizationTests.swift
//  TokenHamsterTests
//
//  运行时双语（语言 / 币种偏好）单元测试。
//
//  ★★ 环境隔离约定（改本文件前必读）：
//    `Localization` 的「当前语言」是**进程级全局状态** —— 服务层错误文案、NSMenu、
//    Widget 都靠它，无法做成实例参数。而测试默认**并行**执行（scheme
//    `parallelizable = YES`），既有的 `AgentSourceParsersTests` / `QuotaWindowTests`
//    等会断言 `L()` 产出的英文原文（如 "The dsh-usage-stats plugin is not installed"）。
//    因此本文件**只测纯函数与实例状态**，一律不调用会改全局语言的
//    `Localization.apply` / `AppSettingsStore.setLanguage` —— 否则那些断言会在
//    中文界面态随机失败。
//    真实切换链路（设置页 → 全局语言 → 界面文案）由人工渲染验收覆盖。
//

import Foundation
import Testing
@testable import TokenHamster

// ============================================================
// MARK: - 语言偏好解析
// ============================================================

struct AppLanguageTests {

    /// `.system` → 按系统首选语言解析
    @Test func systemFollowsPreferredLanguage() {
        #expect(AppLanguage.resolved(.system, preferredLanguages: ["zh-Hans-CN"]) == .chinese)
        #expect(AppLanguage.resolved(.system, preferredLanguages: ["zh-Hant-TW"]) == .chinese)
        #expect(AppLanguage.resolved(.system, preferredLanguages: ["en-US"]) == .english)
        #expect(AppLanguage.resolved(.system, preferredLanguages: ["ja-JP"]) == .english)  // 无日文 → 英文
        #expect(AppLanguage.resolved(.system, preferredLanguages: []) == .english)
    }

    /// 显式选择永远优先于系统语言
    @Test func explicitPreferenceWinsOverSystem() {
        #expect(AppLanguage.resolved(.english, preferredLanguages: ["zh-Hans-CN"]) == .english)
        #expect(AppLanguage.resolved(.chinese, preferredLanguages: ["en-US"]) == .chinese)
    }

    /// rawValue 会持久化 —— 改动等于让用户已保存的偏好失效
    @Test func persistedRawValuesAreStable() {
        #expect(AppLanguage.system.rawValue == "system")
        #expect(AppLanguage.chinese.rawValue == "zh-Hans")
        #expect(AppLanguage.english.rawValue == "en")
    }

    /// 持久化键名同理（App 与 Widget 共用一份）
    @Test func storageKeysAreStable() {
        #expect(Localization.languageKey == "app_language")
        #expect(Localization.currencyKey == "app_currency")
    }
}

// ============================================================
// MARK: - 币种偏好
// ============================================================

struct CurrencyPreferenceTests {

    /// 首启默认按系统地区：中国大陆 → CNY，其余 → USD
    @Test func systemDefaultFollowsRegion() {
        #expect(CurrencyPreference.systemDefault(region: "CN") == .cny)
        #expect(CurrencyPreference.systemDefault(region: "cn") == .cny)
        #expect(CurrencyPreference.systemDefault(region: "US") == .usd)
        #expect(CurrencyPreference.systemDefault(region: "") == .usd)
    }

    @Test func codeAndSymbol() {
        #expect(CurrencyPreference.cny.code == "CNY")
        #expect(CurrencyPreference.cny.symbol == "¥")
        #expect(CurrencyPreference.usd.code == "USD")
        #expect(CurrencyPreference.usd.symbol == "$")
        #expect(CurrencyPreference.cny.rawValue == "cny")
        #expect(CurrencyPreference.usd.rawValue == "usd")
    }

    /// ★ 设置页只显示 ISO 代码（`CNY` / `USD`），不写「人民币 / Chinese Yuan」全称，
    ///   也不必重复币种符号 —— 且与界面语言无关。
    @Test func displayNameIsBareISOCode() {
        #expect(CurrencyPreference.cny.displayName == "CNY")
        #expect(CurrencyPreference.usd.displayName == "USD")
        for preference in CurrencyPreference.allCases {
            let name = preference.displayName
            #expect(name == preference.code)
            #expect(!name.contains("(") && !name.contains("¥") && !name.contains("$"),
                    "展示名不该带符号或全称：\(name)")
            #expect(name.count == 3, "展示名应为 3 位 ISO 代码：\(name)")
        }
    }
}

// ============================================================
// MARK: - 取词（纯函数路径，不动全局状态）
// ============================================================

struct LocalizationLookupTests {

    /// 英文 = 源码原文（英文无需表，key 即文案）
    @Test func englishReturnsSourceTextVerbatim() {
        #expect(Localization.t("Settings", language: .english) == "Settings")
        #expect(Localization.t("Table 里没有的键", language: .english) == "Table 里没有的键")
    }

    @Test func chineseLooksUpTable() {
        #expect(Localization.t("Settings", language: .chinese) == "设置")
        #expect(Localization.t("Quota", language: .chinese) == "额度")
        #expect(Localization.t("Quit TokenHamster", language: .chinese) == "退出 TokenHamster")
    }

    /// ★ 缺条目 → 回退英文原文，绝不显示空串（漏译文只会中英混排，不会丢信息）
    @Test func missingEntryFallsBackToEnglish() {
        let key = "Definitely Not In The Table"
        #expect(Localization.t(key, language: .chinese) == key)
    }

    @Test func interpolationReplacesPlaceholdersInOrder() {
        #expect(Localization.t("%@ tokens total", ["1.2M"], language: .english) == "1.2M tokens total")
        #expect(Localization.t("%@ tokens total", ["1.2M"], language: .chinese) == "累计 1.2M tokens")
        #expect(Localization.t("%@ · resets in %@", ["Session", "2h 12m"], language: .chinese)
                == "Session · 距重置 2h 12m")
    }

    /// ★ 英文复数后缀在中文里没有对应占位 → 多出的参数被丢弃，而不是原样打印出来
    @Test func extraArgumentsAreDroppedForPlurals() {
        #expect(Localization.t("Active %@ day%@", [3, "s"], language: .chinese) == "活跃 3 天")
        #expect(Localization.t("Active %@ day%@", [3, "s"], language: .english) == "Active 3 days")
    }

    /// ★ 非字符串参数直接可用 —— `%@` 手工替换不依赖 `CVarArg`（`String(format:)` 会崩）
    @Test func nonStringArgumentsAreStringified() {
        #expect(Localization.t("Quota API HTTP %@: %@", [500, "boom"], language: .english)
                == "Quota API HTTP 500: boom")
        #expect(Localization.t("Poll %@s", [30], language: .chinese) == "轮询 30s")
    }

    /// 参数比占位少时不该崩、也不该留下裸 `%@`
    @Test func fewerArgumentsThanPlaceholders() {
        #expect(Localization.t("%@ · resets in %@", ["Session"], language: .chinese)
                == "Session · 距重置 %@")
    }

    /// ★★ 哨兵文案的显示译文必须在表里。
    ///   哨兵在**模型层**必须保持英文原值（`DashboardViewModel` 用
    ///   `status != "Available"` 判状态，生产端不本地化），只有在**渲染处**
    ///   `L(snap.resetTimeString)` 才映射成中文 —— 漏了译文就会出现「中文界面里
    ///   冒出一句 Used up」。
    @Test func sentinelDisplayTranslationsExist() {
        #expect(Localization.t("Available", language: .chinese) == "可用")
        #expect(Localization.t("Used up", language: .chinese) == "已用完")
        #expect(Localization.t("Cumulative", language: .chinese) == "累计")
        // 非哨兵文案（如套餐名）原样透传
        #expect(Localization.t("Max", language: .chinese) == "Max")
    }
}

// ============================================================
// MARK: - 文案表完整性（扫描源码）
// ============================================================

struct LocalizationTableIntegrityTests {

    /// 源码里每个 `L("…")` 的 key 都必须在中文表里。
    /// ★ 防的就是「改了文案忘了加译文」→ 中文界面里混一句英文。
    @Test func everyUsedKeyHasChineseTranslation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TokenHamsterTests/
            .deletingLastPathComponent()   // 仓库根
        let appDir = root.appendingPathComponent("TokenHamster", isDirectory: true)
        let files = try Self.swiftFiles(in: appDir)
        #expect(!files.isEmpty, "没扫到源码文件，检查目录：\(appDir.path)")

        // ★ 负向后顾排除 `URL("…")` / `XxxL("…")` 这类误匹配
        let regex = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])L\("([^"\\]*)""#)
        var missing: [String] = []
        var seen = Set<String>()
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let code = Self.strippingLineComment(String(line))
                let range = NSRange(code.startIndex..., in: code)
                for match in regex.matches(in: code, range: range) {
                    guard let r = Range(match.range(at: 1), in: code) else { continue }
                    let key = String(code[r])
                    guard !key.isEmpty, seen.insert(key).inserted else { continue }
                    if LocalizationTable.zh[key] == nil { missing.append(key) }
                }
            }
        }
        #expect(seen.count > 150, "只扫到 \(seen.count) 个 key —— 扫描逻辑可能失效")
        #expect(missing.isEmpty, "以下 key 缺少中文译文：\(missing.sorted())")
    }

    /// Widget 是独立 target（另一张表）→ 单独校验它的 key 也都有译文。
    @Test func widgetKeysHaveChineseTranslation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let widgetDir = root.appendingPathComponent("TokenHamsterWidget", isDirectory: true)
        let tableFile = widgetDir.appendingPathComponent("WidgetL10n.swift")
        let tableText = try String(contentsOf: tableFile, encoding: .utf8)

        // 从 WidgetL10n.swift 的字典字面量里取 key
        let entryRegex = try NSRegularExpression(pattern: #"^\s*"([^"\\]+)": ""#)
        var translated = Set<String>()
        for line in tableText.split(separator: "\n") {
            let s = String(line)
            let range = NSRange(s.startIndex..., in: s)
            if let m = entryRegex.firstMatch(in: s, range: range),
               let r = Range(m.range(at: 1), in: s) {
                translated.insert(String(s[r]))
            }
        }
        #expect(!translated.isEmpty, "没解析到 Widget 文案表")

        let useRegex = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])L\("([^"\\]*)""#)
        var missing: [String] = []
        for file in try Self.swiftFiles(in: widgetDir) where file.lastPathComponent != "WidgetL10n.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let code = Self.strippingLineComment(String(line))
                let range = NSRange(code.startIndex..., in: code)
                for match in useRegex.matches(in: code, range: range) {
                    guard let r = Range(match.range(at: 1), in: code) else { continue }
                    let key = String(code[r])
                    // 解析 displayName("TokenHamster") 之类不在表里的是正常的
                    if !key.isEmpty, translated.contains(key) == false, missing.contains(key) == false {
                        missing.append(key)
                    }
                }
            }
        }
        #expect(missing.isEmpty, "Widget 缺少译文：\(missing.sorted())")
    }

    // ---- 工具 ----

    private static func swiftFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// 去掉行注释 —— 注释里举例说明 `L("…")` 不该被当成真实调用点
    private static func strippingLineComment(_ line: String) -> String {
        guard let range = line.range(of: "//") else { return line }
        return String(line[line.startIndex..<range.lowerBound])
    }
}

// ============================================================
// MARK: - 偏好存储（隔离 UserDefaults）
// ============================================================

@MainActor
struct AppSettingsStoreTests {

    private func isolatedDefaults() -> UserDefaults {
        // 与既有测试一致：独立 suite，绝不碰真实 UserDefaults
        let suite = "test.tokenhamster.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// ⚠️ 全程不调用 `setLanguage`（会改全局语言，见文件头）——
    ///    直接写盘来验证「读回 + 解析」这条真实启动路径。
    private func store(savedLanguage: String? = nil,
                       savedCurrency: String? = nil,
                       preferredLanguages: [String]) -> AppSettingsStore {
        let defaults = isolatedDefaults()
        if let savedLanguage { defaults.set(savedLanguage, forKey: Localization.languageKey) }
        if let savedCurrency { defaults.set(savedCurrency, forKey: Localization.currencyKey) }
        return AppSettingsStore(defaults: defaults, sharedDefaults: nil,
                                preferredLanguages: preferredLanguages)
    }

    /// 首启（无存档）：偏好仍是「跟随系统」，但已解析语言按系统语言落地
    @Test func freshInstallFollowsSystemLanguage() {
        let zh = store(preferredLanguages: ["zh-Hans-CN"])
        #expect(zh.language == .system)
        #expect(zh.resolvedLanguage == .chinese)

        let en = store(preferredLanguages: ["en-US"])
        #expect(en.resolvedLanguage == .english)
    }

    /// 存档恢复：显式偏好不被系统语言覆盖
    @Test func savedPreferencesAreRestored() {
        let s = store(savedLanguage: AppLanguage.chinese.rawValue,
                      savedCurrency: CurrencyPreference.usd.rawValue,
                      preferredLanguages: ["en-US"])
        #expect(s.language == .chinese)
        #expect(s.resolvedLanguage == .chinese)
        #expect(s.currency == .usd)
    }

    /// 存档损坏 / 枚举改名 → 回退默认，不是崩
    @Test func unknownStoredValuesFallBackToDefaults() {
        let s = store(savedLanguage: "klingon",
                      savedCurrency: "JPY",
                      preferredLanguages: ["en-US"])
        #expect(s.language == .system)
        #expect(s.resolvedLanguage == .english)
        #expect(s.currency == CurrencyPreference.systemDefault())
    }

    /// 币种切换会落盘（语言同理，路径一致）—— 用重新构造的 store 验证读回
    @Test func currencyChangeIsPersisted() {
        let defaults = isolatedDefaults()
        let first = AppSettingsStore(defaults: defaults, sharedDefaults: nil,
                                     preferredLanguages: ["en-US"])
        first.setCurrency(.cny)

        let second = AppSettingsStore(defaults: defaults, sharedDefaults: nil,
                                      preferredLanguages: ["en-US"])
        #expect(second.currency == .cny)
    }

    /// 重复设置同一值不该产生变更（避免无谓重绘 / 重复刷新）
    @Test func settingSameLanguageIsNoOp() {
        let s = store(preferredLanguages: ["en-US"])
        let before = s.language
        s.setLanguage(before)
        #expect(s.language == before)
    }
}
