//
//  WidgetBridge.swift
//  TokenHamster
//
//  App → 小组件 的数据桥。
//
//  ★ 为什么由 App 算好再交给 Widget，而不是让 Widget 自己抓：
//    Timeline Provider 的预算只有几秒，且要重复 App 里的凭据读取、网络请求、
//    日志解析逻辑。这里把 App **已经算好的额度窗口**快照写一份精简 JSON，
//    Widget 只读不算。
//
//  ★★ 为什么走**文件**而不是 App Group / UserDefaults suite：
//    macOS 的 widget extension **必须开沙箱** —— 否则 `pkd` 直接拒绝注册：
//    `Ignoring mis-configured plugin …: plug-ins must be sandboxed`
//    （症状就是小组件库里根本找不到它）。而沙箱进程只能读**自己的容器**。
//    走系统 App Group 需要 `com.apple.security.application-groups` —— 那是要在
//    provisioning profile 里声明的 restricted entitlement，ad-hoc 签名
//    （`CODE_SIGN_IDENTITY=-`）下 extension 会因 entitlement 校验失败而起不来。
//    本 App 因要读任意路径日志 + spawn 子进程，**不能开沙箱**，
//    于是采用「不沙箱的宿主直接写进沙箱 extension 的容器」：
//    容器目录属主是当前用户，宿主有完整文件系统权限，两边路径稳定一致。
//
//  ★★ 两 target 的模型是**镜像**关系（Widget 拿不到 App 的源码）：
//    JSON 键由 `WidgetBridgeTests.payloadJSONKeyContract` 冻结 —— 改这里就要同步
//    改 `TokenHamsterWidget/WidgetPayloadModels.swift`，否则测试会红。
//

import Foundation
import WidgetKit

// ============================================================
// MARK: - 载荷模型
// ============================================================

/// 交给小组件的完整载荷（JSON 序列化后落在 widget 沙箱容器里）。
struct WidgetQuotaPayload: Codable, Equatable {

    /// 载荷格式版本 —— Widget 侧据此判断是否是自己能解的格式
    static let currentVersion = 1

    var version: Int
    var updatedAt: Date
    var providers: [WidgetQuotaProvider]

    static let empty = WidgetQuotaPayload(
        version: currentVersion, updatedAt: .distantPast, providers: []
    )
}

/// 单个数据源（= 一个 Agent 卡片）的精简额度信息。
struct WidgetQuotaProvider: Codable, Equatable {
    var id: String
    var name: String
    var assetName: String?
    var symbolName: String
    /// `AgentSourceStatus.rawValue` —— "error" 时 Widget 显示「更新失败」
    var status: String
    var windows: [WidgetQuotaWindow]
}

/// 单个额度窗口。
/// ★ 只保留 Widget 需要的三个字段：标签从 `kind` 推（见 Widget 侧 `QuotaWindowKind` 映射），
///   剩余百分比是 100 − 已用的数学补集，无需传输。
struct WidgetQuotaWindow: Codable, Equatable {
    /// `QuotaWindowKind.rawValue` —— "session5h" / "cycle"
    var kind: String
    /// 已用百分比（0~100）
    var usedPercent: Double
    /// 该窗口的重置时刻（nil = 不显示时间行）
    var resetsAt: Date?
}

// ============================================================
// MARK: - 载荷构建（纯函数，可单测）
// ============================================================

enum WidgetPayloadBuilder {

    /// 从 App 的快照数组构建载荷。
    ///
    /// 过滤规则：
    /// - **跳过 `.stale`** —— 那是「配置仍存在但已停用」的源，不该出现在小组件里。
    /// - 跳过**没有任何额度窗口**的源（余额型 API / DSH / Copilot）——
    ///   小组件只表达「5h + 周期」这类窗口额度，纯 token 统计源无处安放。
    /// - `.error` 的源**保留**（带上次成功的窗口）→ Widget 显示「更新失败 + 置灰旧数据」。
    static func build(from snapshots: [AgentSnapshot], now: Date = Date()) -> WidgetQuotaPayload {
        let providers = snapshots.compactMap { snap -> WidgetQuotaProvider? in
            guard snap.status != .stale else { return nil }
            let windows = windows(from: snap.quotaWindows)
            guard !windows.isEmpty else { return nil }
            return WidgetQuotaProvider(
                id: snap.id,
                name: snap.name,
                assetName: snap.assetName,
                symbolName: snap.iconName,
                status: snap.status.rawValue,
                windows: windows
            )
        }
        return WidgetQuotaPayload(
            version: WidgetQuotaPayload.currentVersion,
            updatedAt: now,
            providers: providers
        )
    }

    /// 窗口筛选 + 排序 + 截断：
    /// - 只留 5h 会话窗口与周期窗口（官方接口只提供这两类）
    /// - 5h 在前、周期在后（参考图的行序）
    /// - 最多 2 个（Widget 版面只放得下两行）
    static func windows(from windows: [QuotaWindow]) -> [WidgetQuotaWindow] {
        windows
            .filter { $0.kind == .session5h || $0.kind == .cycle }
            .sorted { rank($0.kind) < rank($1.kind) }
            .prefix(2)
            .map {
                WidgetQuotaWindow(
                    kind: $0.kind.rawValue,
                    usedPercent: clampPercent($0.usedPercent),
                    resetsAt: $0.resetsAt
                )
            }
    }

    /// 行序：5h 会话窗口在前
    private static func rank(_ kind: QuotaWindowKind) -> Int {
        kind == .session5h ? 0 : 1
    }
}

// ============================================================
// MARK: - 跨进程文件位置
// ============================================================

/// 宿主与 widget 之间共享的文件位置（都在 widget 的**沙箱容器**内）。
enum WidgetBridgeFiles {

    /// Widget extension 的 bundle id。
    /// ⚠️ 必须与 pbxproj 里 `TokenHamsterWidgetExtension` target 的
    ///   `PRODUCT_BUNDLE_IDENTIFIER` 逐字一致（改一处就要改另一处）。
    static let widgetBundleID = "com.YiyangSun.TokenHamster.TokenHamsterWidget"

    /// 额度载荷（JSON）
    static let payloadFileName = "WidgetQuota.json"
    /// 界面语言偏好（纯文本，内容是 `AppLanguage.rawValue`）
    static let languageFileName = "WidgetLanguage.txt"

    /// 生产目录 = widget 沙箱容器里的 Application Support。
    ///
    /// 沙箱内 `Application Support` 展开为
    /// `~/Library/Containers/<bundle-id>/Data/Library/Application Support`，
    /// widget 侧用 `.applicationSupportDirectory` 会得到**同一个**目录。
    static var containerDirectory: URL? {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers")
            .appendingPathComponent(widgetBundleID)
            .appendingPathComponent("Data/Library/Application Support")
    }
}

// ============================================================
// MARK: - 载荷写入
// ============================================================

enum WidgetSnapshotStore {

    /// 生产写入目录。
    /// ★ 测试宿主里返回 nil → **不写**，否则跑一次单测就会把用户小组件载荷
    ///   换成 mock 数据（与 `AppSettingsStore.isRunningTests` 的既有隔离约定一致）。
    ///   测试要验证这条接线时，显式传入自己的临时目录。
    static var defaultDirectory: URL? {
        AppSettingsStore.isRunningTests ? nil : WidgetBridgeFiles.containerDirectory
    }

    /// 写入载荷并通知 WidgetKit 刷新时间线。
    /// - Parameters:
    ///   - directory: 写入目录（生产走 `defaultDirectory`，测试注入临时目录）
    ///   - reloadTimelines: 测试里关掉，避免无意义的 WidgetCenter 调用
    /// ★ `directory` **刻意不给默认值**：漏传时应该编译报错，而不是静默写错地方。
    static func write(
        _ payload: WidgetQuotaPayload,
        to directory: URL?,
        reloadTimelines: Bool = true
    ) {
        guard let directory else { return }
        let encoder = JSONEncoder()
        // ★ 与 Widget 侧解码策略必须一致（见 WidgetPayloadStore.read）
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(payload) else { return }
        write(data, named: WidgetBridgeFiles.payloadFileName, to: directory)

        // 测试宿主里不惊动 WidgetKit（不产生系统日志噪音）
        if reloadTimelines, !AppSettingsStore.isRunningTests {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// 写界面语言偏好（widget 靠它决定走中文还是英文）。
    /// ★ 与载荷分开一个文件：语言是配置性质、变化频率低，且读取时不必解 JSON。
    static func writeLanguage(_ rawValue: String, to directory: URL? = defaultDirectory) {
        guard let directory else { return }
        write(Data(rawValue.utf8), named: WidgetBridgeFiles.languageFileName, to: directory)
    }

    /// 原子写入（widget 读到的永远是完整文件，不会看到写一半的内容）。
    private static func write(_ data: Data, named name: String, to directory: URL) {
        let fileManager = FileManager.default
        // 容器目录通常由系统在 extension 注册时建好；宿主侧再兜底一次
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
