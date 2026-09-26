//
//  WidgetPayloadModels.swift
//  TokenHamsterWidget
//
//  App 侧 `WidgetBridge.swift` 载荷模型的**镜像副本**。
//
//  ★★ 为什么是副本而不是共享源码：Widget 是独立 target（独立同步组），
//    拿不到 App target 的源码；而新建一个跨 target 共享文件夹需要改 pbxproj。
//    这里沿用 `WidgetL10n.swift` 的既有先例 —— 手动镜像 + 契约测试防漂移：
//    `TokenHamsterTests/WidgetBridgeTests.swift` 的 `payloadJSONKeyContract`
//    冻结了 JSON 键名与日期编码策略，改了一边忘了另一边时它会红。
//
//  ★★ 为什么读**文件**而不是 App Group / UserDefaults suite：
//    widget extension 在 macOS 上**必须开沙箱** —— 否则 `pkd` 拒绝注册
//    （"plug-ins must be sandboxed" → 小组件库里根本找不到它），
//    而沙箱进程只能读**自己的容器**。因此宿主 App（不沙箱：要读任意路径日志 +
//    spawn 子进程）直接把 JSON 写进本容器的 `Application Support`，这里再读回来。
//    路径对齐：宿主侧 `WidgetBridgeFiles.containerDirectory`
//    ↔ 本侧 `WidgetStorage.directory`（`.applicationSupportDirectory`）。
//

import Foundation

// ============================================================
// MARK: - 沙箱容器
// ============================================================

enum WidgetStorage {

    /// 额度载荷文件名（与宿主侧 `WidgetBridgeFiles.payloadFileName` 逐字一致）
    static let payloadFileName = "WidgetQuota.json"
    /// 界面语言文件名（与宿主侧 `WidgetBridgeFiles.languageFileName` 逐字一致）
    static let languageFileName = "WidgetLanguage.txt"

    /// 自己的沙箱容器目录
    /// （`~/Library/Containers/<bundle-id>/Data/Library/Application Support`）
    static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }
}

// ============================================================
// MARK: - 载荷（与 App 侧 WidgetQuotaPayload 同构）
// ============================================================

struct WidgetQuotaPayload: Codable, Equatable {
    var version: Int
    var updatedAt: Date
    var providers: [WidgetQuotaProvider]

    static let empty = WidgetQuotaPayload(version: 1, updatedAt: .distantPast, providers: [])
}

struct WidgetQuotaProvider: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var assetName: String?
    var symbolName: String
    /// "ok" / "error"（"stale" 由 App 侧过滤掉，不会出现在载荷里）
    var status: String
    var windows: [WidgetQuotaWindow]

    /// 上次拉取失败（App 侧透传的 `.error`）→ 数据置灰 + 显示「更新失败」
    var isFailed: Bool { status != "ok" }

    /// 是否含 5h 会话窗口（选默认数据源时优先挑这种）
    var hasSessionWindow: Bool { windows.contains { $0.kind == WidgetQuotaWindow.sessionKind } }
}

struct WidgetQuotaWindow: Codable, Equatable, Identifiable {
    /// 与 App 侧 `QuotaWindowKind.rawValue` 一致
    static let sessionKind = "session5h"
    static let cycleKind = "cycle"

    var kind: String
    /// 已用百分比（0~100）
    var usedPercent: Double
    var resetsAt: Date?

    /// 同一数据源内窗口种类不重复 → 用 kind 当 id 即可
    var id: String { kind }
}

// ============================================================
// MARK: - 读取
// ============================================================

enum WidgetPayloadStore {

    /// 从沙箱容器读载荷。缺文件 / 解码失败 → nil（界面走空态）。
    /// ⚠️ 日期策略必须与宿主侧 `.secondsSince1970` 一致。
    static func read(directory: URL? = WidgetStorage.directory) -> WidgetQuotaPayload? {
        guard let directory else { return nil }
        let url = directory.appendingPathComponent(WidgetStorage.payloadFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetQuotaPayload.self, from: data)
    }

    /// 读界面语言偏好原文（`AppLanguage.rawValue`："system" / "zh-Hans" / "en"）。
    /// 没有文件时返回 nil → 调用方回退到系统首选语言。
    static func readLanguageRawValue(directory: URL? = WidgetStorage.directory) -> String? {
        guard let directory else { return nil }
        let url = directory.appendingPathComponent(WidgetStorage.languageFileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
