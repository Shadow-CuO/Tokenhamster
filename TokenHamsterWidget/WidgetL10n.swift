//
//  WidgetL10n.swift
//  TokenHamsterWidget
//
//  Widget 侧极简文案表。
//
//  ★ 为什么自带一张表：Widget 是独立 target（独立同步组），拿不到主 app 的
//    `Localization.swift` / `LocalizationTable.swift`；这里只保留 Widget 用到的几条。
//
//  ★★ 收词范围（用户决策 2026-09-26）：**只翻译「错误态 / 空态 / 组件描述」**三类。
//    额度窗口标签（"5h" / "Week" / "Session" / "Weekly"）与重置时间**一律不翻译**，
//    与主 App 额度卡片（裸 `Text(window.label)`）保持一致。
//
//  ★ 语言来源：widget **沙箱容器**里的 `WidgetLanguage.txt`（宿主 App 写入，
//    见 `WidgetBridgeFiles.languageFileName` / `WidgetSnapshotStore.writeLanguage`）。
//    ★ widget extension 在 macOS 上强制沙箱（未沙箱会被 `pkd` 拒绝注册），
//      读不到宿主那边的 `UserDefaults(suiteName:)` —— 所以偏好也走文件。
//      文件缺失 → 回退系统首选语言。
//
//  ⚠️ 本表里的 key 必须与源码里 `L("…")` 的字面量逐字一致，否则
//    `LocalizationTableIntegrityTests.widgetKeysHaveChineseTranslation` 会失败。
//

import Foundation

enum WidgetL10n {

    /// key = 英文原文（与主 app 的 key 逐字一致，便于对照维护）
    private static let zh: [String: String] = [
        // ---- 错误态 ----
        "Update failed": "更新失败",
        // ---- 空态 ----
        "Open TokenHamster to add a data source": "打开 TokenHamster 添加数据源",
        // ---- 组件描述（编辑面板 / 组件画廊）----
        "Shows one data source's quota": "显示单个数据源的额度",
        "Shows two data sources side by side": "并排显示两个数据源的额度",
    ]

    /// 是否用中文。偏好取值：`"zh-Hans"` / `"en"` / `"system"`（缺失 → 系统语言）。
    static var isChinese: Bool {
        if let raw = WidgetPayloadStore.readLanguageRawValue() {
            if raw.hasPrefix("zh") { return true }
            if raw == "en" { return false }
            // "system" 或未知 → 落到系统判断
        }
        return Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false
    }

    static func t(_ key: String) -> String {
        isChinese ? (zh[key] ?? key) : key
    }
}

/// 取词。与主 app 的 `L` 同名同义，但只在 Widget target 内编译。
func L(_ key: String) -> String { WidgetL10n.t(key) }
