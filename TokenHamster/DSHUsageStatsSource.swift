//
//  DSHUsageStatsSource.swift
//  TokenHamster
//
//  DeepSeek Harness (DSH) 用量数据源 — 读 `@ychris12138/dsh-usage-stats` 插件落盘的缓存
//
//  ── 为什么不再自己解析会话日志 ──
//  DSH 的会话日志默认是**多帧 Zstandard**（`session.v3.jsonl.zstd`）：整个文件是若干
//  完整 zstd frame 的拼接（每个 durable append 批一个 frame），单次解压只能得到第一个
//  frame；再加上多代文件共存（v0/v1/v2/v3）与 resume/fork 副本会重复计数。
//  Apple 的 Compression 框架不含 ZSTD，自研需实现 FSE/Huffman/LZ77 或链 C 库 —— 两条
//  路都不可接受。→ 改为消费第三方插件**已聚合好的普通 JSON 缓存**。
//
//  ── 数据来源 ──
//  `$DSH_HOME/storages/usage-stats-cache.json`（回退 `~/.dsh/storages/...`）
//  `CACHE_VERSION = 5`，原子写（tmp + rename）→ 可安全并发读。
//  该缓存已完成：多帧解码 / 同 (turn, step) 样本「替换而非累加」折叠 / 按天×模型聚合。
//
//  ── 口径 ──
//  ★ `totalTokens = inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens`（四桶）
//    （与插件 `lib/usage.js` 的 `totalTokens()` 完全一致）
//  ★ `days` 的键是**本地日历** `YYYY-MM-DD` → 不需要任何时区换算
//  ★ `models` 的键是 `providerId/model` → 同一模型来自不同供应商时天然区分
//
//  ⚠️ 刻意不复用插件的 `billing` / 估算费用 / 账户余额适配器：DSH 卡片只显示 token。
//  ⚠️ 插件缺失时不静默显示 0 —— 「0」与「真的没用过」无法区分，必须给出可行动提示。
//

import Foundation

// ============================================================
// MARK: - 缓存结构（对应插件 CACHE_VERSION = 5）
// ============================================================

/// 缓存文件顶层结构。未知键（`pricingFingerprint` / `pricingIdentityCutoff*`）自动忽略。
struct DSHUsageStatsCache: Decodable, Equatable {
    var version: Int?
    var sessions: [String: DSHUsageStatsSession]?
}

/// 单个会话的折叠状态。
/// ⚠️ 只声明我们真正需要的字段：`consumed` / `revision` / `kind` / `billing` /
///    `currentModel` / `currentRoute` 一律忽略，避免它们变化导致解析失败。
struct DSHUsageStatsSession: Decodable, Equatable {
    var title: String?
    /// 日期键（本地日历 `YYYY-MM-DD`）→ 当日用量
    var days: [String: DSHUsageStatsDay]?
    /// 最后一个用量样本（用于「数据是否冻结」判定）
    var lastSample: DSHUsageStatsSample?
}

struct DSHUsageStatsSample: Decodable, Equatable {
    /// epoch 毫秒；未知时为 nil
    var time: Int?
}

struct DSHUsageStatsDay: Decodable, Equatable {
    var totals: DSHUsageStatsBuckets?
    /// 模型键 `providerId/model` → 该模型当日用量
    var models: [String: DSHUsageStatsBuckets]?
}

/// 四类 token 桶。**全部可选**，缺字段按 0 —— 避免个别字段缺失导致整份缓存解析失败。
struct DSHUsageStatsBuckets: Decodable, Equatable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?

    /// ★ 四桶合计 —— 与插件 `lib/usage.js` 的 `totalTokens()` 一致
    var total: Int {
        (inputTokens ?? 0) + (outputTokens ?? 0)
            + (cacheReadTokens ?? 0) + (cacheWriteTokens ?? 0)
    }
}

// ============================================================
// MARK: - 可用性
// ============================================================

/// 缓存可用性 —— 每一种都对应一句**可行动**的用户提示。
enum DSHUsageStatsAvailability: Equatable {
    /// 可正常读取
    case ready
    /// 插件未安装（profiles 里找不到该包）
    case pluginMissing
    /// 插件已装但没有缓存文件（没跑过 / 装完还没重启 DSH）
    case cacheMissing
    /// 插件正在重建缓存（旧 schema 或被价格指纹变更清空）—— 暂时性状态
    case rebuilding
    /// 缓存版本比本应用支持的新 → 需要更新 TokenHamster
    case appOutdated
    /// 缓存文件损坏
    case corrupt
    /// 已装、有缓存，但数据没跟上会话日志（插件读不到新事件）
    case stale

    /// 需要显示给用户的提示；`.ready` 为空串
    var message: String {
        switch self {
        case .ready:         return ""
        case .pluginMissing: return L("The dsh-usage-stats plugin is not installed")
        case .cacheMissing:  return L("The plugin is installed but has no cache yet — restart DSH")
        case .rebuilding:    return L("The cache is being rebuilt — refresh again shortly")
        case .appOutdated:   return L("The plugin is newer than this app — update TokenHamster")
        case .corrupt:       return L("The cache file is corrupt — waiting for the plugin to rebuild it")
        case .stale:         return L("The plugin data is out of date — restart DSH or upgrade the plugin")
        }
    }

    /// 映射到卡片状态：非 ready 时状态灯变色，并借 errorMessage 显示提示
    /// （DashboardView 只在 `status != .ok` 时渲染提示文案）
    /// ★ `.rebuilding` 也必须走 error 通道 —— 否则卡片会**静默显示 0**，
    ///   与「真的没用过」无法区分（这正是本数据源刻意规避的失败态）。
    var snapshotStatus: AgentSourceStatus {
        switch self {
        case .ready: return .ok
        default:     return .error
        }
    }
}

// ============================================================
// MARK: - 聚合结果
// ============================================================

/// 缓存 → 聚合结果（纯数据，可单测）
struct DSHUsageStatsAggregate: Equatable {
    var totalTokens: Int = 0
    /// 模型显示名 → token 总数
    var modelTokens: [String: Int] = [:]
    /// 日期（本地 startOfDay）→ token 总数
    var dayTokens: [Date: Int] = [:]
    /// 模型显示名 → [日期: token]
    var modelDayTokens: [String: [Date: Int]] = [:]
    /// 缓存中记录到的最新用量样本时刻（冻结检测用；无样本时为 nil）
    var latestSampleDate: Date?
}

/// 评估结果 = 可用性 + 聚合数据
struct DSHUsageStatsEvaluation: Equatable {
    var availability: DSHUsageStatsAvailability = .cacheMissing
    var aggregate = DSHUsageStatsAggregate()
}

// ============================================================
// MARK: - DSH 数据源
// ============================================================

/// DeepSeek Harness 数据源：读 `@ychris12138/dsh-usage-stats` 的落盘缓存。
struct DSHUsageStatsSource: AgentDataSource {

    /// 消费的插件包名（★ 单一定义点，避免散落）
    static let pluginPackageName = "@ychris12138/dsh-usage-stats"
    /// 已验证可用的插件版本（安装时默认 pin 该版本）
    static let verifiedPluginVersion = "0.3.3"
    /// 本应用支持的缓存版本
    static let supportedCacheVersion = 5
    /// 冻结判定阈值：会话日志比缓存样本新出这么多，就认为插件没跟上
    static let stalenessThreshold: TimeInterval = 600

    let id: String
    let name: String
    let iconName: String
    let assetName: String?
    let sourceType: AgentSourceType = .local
    let semantics: UsageSemantics = .cumulative

    /// 缓存文件路径覆盖（单测注入；nil = 按 DSH_HOME 解析）
    private let cacheFilePathOverride: String?

    init(
        id: String,
        name: String,
        iconName: String,
        assetName: String? = nil,
        cacheFilePath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.assetName = assetName
        self.cacheFilePathOverride = cacheFilePath
    }

    // ============================================================
    // MARK: 路径解析
    // ============================================================

    /// DSH 根目录：优先 `$DSH_HOME`，否则 `~/.dsh`
    static func defaultDSHHome(dshHome: String?, homeDir: String) -> String {
        if let dshHome, !dshHome.isEmpty { return dshHome }
        return (homeDir as NSString).appendingPathComponent(".dsh")
    }

    /// 缓存文件路径：`<DSH_HOME>/storages/usage-stats-cache.json`
    static func cachePath(dshHome: String) -> String {
        ((dshHome as NSString).appendingPathComponent("storages") as NSString)
            .appendingPathComponent("usage-stats-cache.json")
    }

    /// 缓存文件路径（由环境推导 DSH_HOME）
    static func defaultCachePath(dshHome: String?, homeDir: String) -> String {
        cachePath(dshHome: defaultDSHHome(dshHome: dshHome, homeDir: homeDir))
    }

    /// 会话日志根：`<DSH_HOME>/sessions`（仅用于冻结检测）
    static func sessionsRoot(dshHome: String) -> String {
        (dshHome as NSString).appendingPathComponent("sessions")
    }

    static func defaultSessionsRoot(dshHome: String?, homeDir: String) -> String {
        sessionsRoot(dshHome: defaultDSHHome(dshHome: dshHome, homeDir: homeDir))
    }

    /// 插件安装目录（用于判断「未安装」还是「已装但没缓存」）
    static func pluginInstallPath(profileDir: String) -> String {
        ((profileDir as NSString).appendingPathComponent("node_modules") as NSString)
            .appendingPathComponent(pluginPackageName)
    }

    private var resolvedCachePath: String {
        let path = cacheFilePathOverride ?? Self.defaultCachePath(
            dshHome: ProcessInfo.processInfo.environment["DSH_HOME"],
            homeDir: FileManager.default.homeDirectoryForCurrentUser.path
        )
        return (path as NSString).expandingTildeInPath
    }

    // ============================================================
    // MARK: 拉取
    // ============================================================

    func fetchSnapshot() async throws -> AgentSnapshot {
        let cachePath = resolvedCachePath
        let dshHome = Self.defaultDSHHome(
            dshHome: ProcessInfo.processInfo.environment["DSH_HOME"],
            homeDir: FileManager.default.homeDirectoryForCurrentUser.path
        )

        let data = try? Data(contentsOf: URL(fileURLWithPath: cachePath))
        let evaluation = Self.evaluate(
            cacheData: data,
            pluginInstalled: Self.isPluginInstalled(dshHome: dshHome),
            latestLogModification: Self.latestSessionLogModification(
                sessionsRoot: Self.defaultSessionsRoot(
                    dshHome: dshHome,
                    homeDir: FileManager.default.homeDirectoryForCurrentUser.path
                )
            )
        )

        let attributes = try? FileManager.default.attributesOfItem(atPath: cachePath)
        let modifiedAt = attributes?[.modificationDate] as? Date

        return Self.buildSnapshot(
            id: id, name: name, iconName: iconName, assetName: assetName,
            evaluation: evaluation,
            cacheModifiedAt: modifiedAt
        )
    }

    // ============================================================
    // MARK: 纯函数（可单测）
    // ============================================================

    /// 组装快照
    static func buildSnapshot(
        id: String,
        name: String,
        iconName: String,
        assetName: String?,
        evaluation: DSHUsageStatsEvaluation,
        cacheModifiedAt: Date? = nil
    ) -> AgentSnapshot {
        let agg = evaluation.aggregate
        let total = agg.totalTokens

        let modelUsages = agg.modelTokens
            .sorted { $0.value > $1.value }
            .enumerated()
            .map { index, item in
                ModelUsageItem(
                    id: "model_\(index)",
                    modelName: item.key,
                    tokenAmount: item.value,
                    usagePercent: total > 0 ? Double(item.value) / Double(total) : 0
                )
            }

        let dailyHeatmap: [DailyUsage] = agg.dayTokens
            .filter { $0.value > 0 }
            .map { DailyUsage(date: $0.key, tokenCount: $0.value, level: heatmapLevel(for: $0.value)) }
            .sorted { $0.date < $1.date }

        return AgentSnapshot(
            id: id,
            name: name,
            iconName: iconName,
            assetName: assetName,
            sourceType: .local,
            quotaUsed: total,
            quotaTotal: 0,                       // DSH 无订阅额度 → 卡片只显示累计 token
            quotaUnit: "tokens",
            resetTimeString: "Cumulative",
            currency: "USD",
            origin: .ideTool,
            totalTokens: total,
            totalCost: 0,
            modelUsages: modelUsages,
            sevenDayTrend: computeSevenDayTrend(from: dailyHeatmap),
            dailyHeatmap: dailyHeatmap,
            activityDays: dailyHeatmap.count,
            modelDailyTokens: agg.modelDayTokens.flatMap { model, dayMap in
                dayMap.map { ModelDailyToken(modelName: model, date: $0.key, tokens: $0.value) }
            },
            status: evaluation.availability.snapshotStatus,
            lastUpdated: cacheModifiedAt ?? agg.latestSampleDate,
            errorMessage: evaluation.availability.message
        )
    }

    /// ★ 核心纯函数：数据 + 外部事实 → 可用性 + 聚合。
    /// 把文件系统访问全部提到调用方，便于单测覆盖每种失败态。
    static func evaluate(
        cacheData: Data?,
        pluginInstalled: Bool,
        latestLogModification: Date?,
        calendar: Calendar = .current
    ) -> DSHUsageStatsEvaluation {
        var result = DSHUsageStatsEvaluation()

        // 1. 没有缓存文件
        guard let cacheData else {
            result.availability = pluginInstalled ? .cacheMissing : .pluginMissing
            return result
        }
        // 2. 解析（插件的 parseSession 是宽容的，我们也一样）
        guard let cache = try? JSONDecoder().decode(DSHUsageStatsCache.self, from: cacheData) else {
            result.availability = .corrupt
            return result
        }
        // 3. 版本判定
        //    插件自身会忽略旧 schema 并从会话事件重折叠 → 对我们只是「暂时没数据」
        let version = cache.version ?? 0
        if version > supportedCacheVersion {
            result.availability = .appOutdated
            return result
        }
        if version < supportedCacheVersion {
            result.availability = .rebuilding
            return result
        }
        // 4. sessions 为空 → 合法状态（价格指纹变更会整体清空，随后重折叠）
        let sessions = cache.sessions ?? [:]
        if sessions.isEmpty {
            result.availability = .rebuilding
            return result
        }
        // 5. 聚合
        result.aggregate = aggregate(sessions: sessions, calendar: calendar)
        // 6. 冻结检测：会话日志明显比缓存里的最后一个用量样本还新
        //    ⚠️ 只用 lastSample.time（毫秒级）比较 —— days 的键是「日」粒度，
        //       拿它比会把「今天有活动」误判成冻结。
        if let sampleDate = result.aggregate.latestSampleDate,
           let logDate = latestLogModification,
           logDate.timeIntervalSince(sampleDate) > stalenessThreshold {
            result.availability = .stale
        } else {
            result.availability = .ready
        }
        return result
    }

    /// 跨全部会话累加 `days`（★ `days` 已由插件按天×模型聚合好，这里只做求和）
    static func aggregate(
        sessions: [String: DSHUsageStatsSession],
        calendar: Calendar = .current
    ) -> DSHUsageStatsAggregate {
        var result = DSHUsageStatsAggregate()
        var latestSample: Date?

        for session in sessions.values {
            if let ms = session.lastSample?.time, ms > 0 {
                let date = Date(timeIntervalSince1970: Double(ms) / 1000)
                if latestSample == nil || date > latestSample! { latestSample = date }
            }
            for (dayKey, day) in session.days ?? [:] {
                guard let date = parseDayKey(dayKey, calendar: calendar) else { continue }

                let dayTotal = day.totals?.total ?? 0
                if dayTotal > 0 {
                    result.totalTokens += dayTotal
                    result.dayTokens[date, default: 0] += dayTotal
                }
                for (modelKey, buckets) in day.models ?? [:] {
                    let value = buckets.total
                    guard value > 0 else { continue }
                    let model = displayModelName(modelKey)
                    result.modelTokens[model, default: 0] += value
                    result.modelDayTokens[model, default: [:]][date, default: 0] += value
                }
            }
        }

        result.latestSampleDate = latestSample
        return result
    }

    /// `YYYY-MM-DD`（本地日历）→ 本地 startOfDay
    static func parseDayKey(_ key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        return calendar.startOfDay(for: date)
    }

    /// `providerId/model` → 展示用模型名（去掉供应商前缀）；未知桶统一为 `(unknown)`
    static func displayModelName(_ key: String) -> String {
        if key.isEmpty || key == "unknown/unknown" { return "(unknown)" }
        guard let slash = key.firstIndex(of: "/") else { return key }
        let model = String(key[key.index(after: slash)...])
        return model.isEmpty ? key : model
    }

    // ============================================================
    // MARK: 文件系统探测（失败态判定）
    // ============================================================

    /// ★ 当前环境的可用性（读缓存 + 探测插件 + 冻结检测）。
    /// 供设置页状态行与安装引导复用 —— 单一真源，避免 UI 自己拼判断。
    static func currentAvailability(
        dshHome: String,
        fileManager: FileManager = .default
    ) -> DSHUsageStatsAvailability {
        let data = try? Data(contentsOf: URL(fileURLWithPath: cachePath(dshHome: dshHome)))
        return evaluate(
            cacheData: data,
            pluginInstalled: isPluginInstalled(dshHome: dshHome, fileManager: fileManager),
            latestLogModification: latestSessionLogModification(
                sessionsRoot: sessionsRoot(dshHome: dshHome), fileManager: fileManager
            )
        ).availability
    }

    /// 当前解出的 DSH_HOME
    static var resolvedDSHHome: String {
        defaultDSHHome(
            dshHome: ProcessInfo.processInfo.environment["DSH_HOME"],
            homeDir: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    /// 是否已在任一 profile 装过该插件
    static func isPluginInstalled(dshHome: String, fileManager: FileManager = .default) -> Bool {
        let profiles = (dshHome as NSString).appendingPathComponent("profiles")
        // ① profiles/<name>/node_modules/@ychris12138/dsh-usage-stats
        if let entries = try? fileManager.contentsOfDirectory(atPath: profiles) {
            for entry in entries {
                let path = pluginInstallPath(
                    profileDir: (profiles as NSString).appendingPathComponent(entry)
                )
                if fileManager.fileExists(atPath: path) { return true }
            }
        }
        // ② profiles/node_modules/...（部分安装器直接装在 profiles 根）
        return fileManager.fileExists(atPath: pluginInstallPath(profileDir: profiles))
    }

    /// 会话日志目录下最新的修改时间（冻结检测用；目录不存在返回 nil）
    static func latestSessionLogModification(
        sessionsRoot: String,
        fileManager: FileManager = .default
    ) -> Date? {
        let root = (sessionsRoot as NSString).expandingTildeInPath
        guard fileManager.fileExists(atPath: root) else { return nil }
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var latest: Date?
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]
            ), values.isRegularFile == true,
               let date = values.contentModificationDate else { continue }
            if latest == nil || date > latest! { latest = date }
        }
        return latest
    }
}
