//
//  Storage/AppStorage.swift
//  TokenHamster
//
//  Created by 孙亦阳 on 2026/8/9.
//
//  数据存储抽象层 — Application Support 文件存储。
//  存放非敏感、会增长的用量数据（每日消耗 / Dashboard 快照），
//  以及 API 配置（2026-09-12 从钥匙串迁入）。
//
//  ⚠️ API 配置为何不再放钥匙串：
//  macOS 上读/写钥匙串条目需要条目的 ACL 命中当前二进制的代码签名。开发构建为
//  ad-hoc 签名（`CODE_SIGN_IDENTITY=-`），**每次重编译签名都变** → 原有条目的 ACL
//  必定失配 → 每次启动/保存都弹“请输入登录密码”的系统授权框，且“始终允许”也记不住。
//  改存 Application Support 下的 JSON（目录 0700），与大多数命令行工具同级别的威胁模型。
//

import Foundation

// ============================================================
// MARK: - 存储协议（可注入，便于测试隔离）
// ============================================================

/// 通用的 Codable 数据存储接口
protocol AppStoring {
    func save<T: Codable>(_ value: T, forKey key: String)
    func load<T: Codable>(_ type: T.Type, forKey key: String) -> T?
    func delete(forKey key: String)
}

// ============================================================
// MARK: - 文件存储实现
// ============================================================

/// Application Support 目录下的 JSON 文件存储。
/// 路径：~/Library/Application Support/<bundleID>/<key>.json
/// 写入采用 .atomic，避免进程被杀导致半截文件。
final class FileAppStorage: AppStoring {

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// 默认存储位置（macOS 主程序）
    static var `default`: FileAppStorage {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let bundleID = Bundle.main.bundleIdentifier ?? "TokenHamster"
        return FileAppStorage(directory: base.appendingPathComponent(bundleID, isDirectory: true))
    }

    /// 注入目录（测试用）
    init(directory: URL) {
        self.directory = directory
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // ★ 目录权限 0700：内含 API 配置，只允许本用户访问
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path
        )
    }

    private func fileURL(forKey key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    func save<T: Codable>(_ value: T, forKey key: String) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: fileURL(forKey: key), options: .atomic)
    }

    func load<T: Codable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = try? Data(contentsOf: fileURL(forKey: key)) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    func delete(forKey key: String) {
        try? FileManager.default.removeItem(at: fileURL(forKey: key))
    }
}

// ============================================================
// MARK: - 全局常量（主程序 / 测试 / 后续 Widget 共用）
// ============================================================

enum AppConstants {

    /// App Group suite — 与 Widget 现有值对齐。
    /// ★ 实测（2026-09-25）：各 target 均**未开沙箱** → `UserDefaults(suiteName:)` 落
    ///   `~/Library/Preferences/group.<id>.plist`，**跨进程可读**（`defaults read` 验证）。
    ///   若日后开启沙箱，须补 `application-groups` entitlement 才继续共享。
    nonisolated static let appGroupSuiteName = "group.com.YiyangSun.TokenHamster"
    /// 旧版 UserDefaults suite（已废弃，仅用于一次性迁移存量数据）
    nonisolated static let legacyUserDefaultsSuiteName = "group.com.tokenhamster"

    // ---- Keychain key（敏感数据） ----
    nonisolated static let apiConfigsKey = "user_api_configs"
    // ---- 文件存储 key（用量数据） ----
    nonisolated static let localUsageKey = "local_daily_usage"
    nonisolated static let lastDataKey = "last_dashboard_data"
    /// ★ 所有模型总用量的本地账本（模型 × 日期 明细 + 重置点）
    nonisolated static let modelTokenLedgerKey = "model_token_ledger"
    /// ★ Z.ai Coding Plan 的本地用量历史（按数据源分组）。
    /// 官方 model-usage 只能查 30 天，热力图靠这份累积历史延长。
    nonisolated static let zaiUsageHistoryKey = "zai_usage_history"

    // ---- Widget 共享 key（预留写入点） ----
    nonisolated static let widgetProgressKey = "widget_progress"
    nonisolated static let widgetLabelKey = "widget_label"

    // ---- 外部支持链接 ----

    /// DSH 用量插件（`@ychris12138/dsh-usage-stats`）安装 / 回退 / 卸载指南。
    ///
    /// ★ **URL 必须稳定：不得包含版本号** —— 否则旧版本 App 上的按钮会指向死链。
    /// ★ 这是唯一「改内容不发版」的对外通道：插件改包名、发坏版本、DSH 升级等
    ///   变化都靠它响应，所以文档内容更新优先改这里指向的页面，而不是发新版 App。
    ///
    /// ⚠️⚠️ **上线前必须替换**：当前值是 RFC 2606 保留域名（`.invalid`，永不解析），
    ///   刻意不用看起来像真站的域名 —— 万一漏改，用户看到的是浏览器错误页，
    ///   而不是被导向别人的网站。页面内容见 `docs/dsh-usage-stats-guide.md`。
    nonisolated static let dshPluginGuideURL = "https://example.invalid/dsh-usage-stats"
}
