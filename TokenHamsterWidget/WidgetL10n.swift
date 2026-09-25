//
//  WidgetL10n.swift
//  TokenHamsterWidget
//
//  Widget 侧极简文案表。
//
//  ★ 为什么自带一张表：Widget 是独立 target（独立同步组），拿不到主 app 的
//    `Localization.swift` / `LocalizationTable.swift`；这里只保留 Widget 用到的几条。
//
//  ★ 语言来源：App Group suite 的 `app_language`（主 app 写入同一份偏好）。
//    ★ 实测（2026-09-25）：App 与 Widget **都未开沙箱**（见 entitlements）→
//      `UserDefaults(suiteName: "group.…")` 落在
//      `~/Library/Preferences/group.….plist`，**跨进程可读**（用 `defaults read` 验证过）。
//      读不到时回退系统语言；日后若开启沙箱，需补 `application-groups` entitlement。
//

import Foundation

enum WidgetL10n {

    /// 与主 app `Localization.languageKey` 保持一致
    static let languageKey = "app_language"

    /// key = 英文原文（与主 app 的 key 逐字一致，便于对照维护）
    private static let zh: [String: String] = [
        "Today's token quota": "今日 Token 额度",
        "Used": "已使用",
        "Shows token usage progress": "显示 Token 使用进度",
    ]

    /// 是否用中文
    static var isChinese: Bool {
        if let raw = WidgetStorage.shared?.string(forKey: languageKey) {
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
