//
//  QuotaFetchers.swift
//  TokenHamster
//
//  官方额度抓取器 — Codex / Claude Code
//  凭据自动读取本地登录态（~/.codex/auth.json、~/.claude/），零配置
//  由 LocalLogSource 在本地日志统计之上并行抓取并合并，额度失败时静默降级
//

import Foundation

// ============================================================
// MARK: - 错误
// ============================================================

enum QuotaError: LocalizedError {
    case notLoggedIn(String)
    case invalidResponse(String)
    case httpError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn(let msg):     return msg
        case .invalidResponse(let msg): return L("Quota API response error: %@", msg)
        case .httpError(let code, let body):
            return L("Quota API HTTP %@: %@", code, body)
        }
    }
}

// ============================================================
// MARK: - 额度快照模型
// ============================================================

/// 模型级额度限制（官方接口返回）
struct ModelLimit: Equatable {
    var modelName: String       // 模型显示名
    var usedPercent: Double     // 0~100
    var resetsAt: Date?         // 重置时间
}

/// 倒计时精度
enum QuotaCountdownPrecision {
    case minute   // 精确到分："2h 12m"（5h 会话窗口）
    case hour     // 精确到小时："1d 2h"（周额度重置）
}

/// 额度窗口类型 — 官方接口只提供两类窗口
enum QuotaWindowKind: String, Codable, CaseIterable {
    case session5h   // 5 小时滚动会话窗口（Codex primary / Claude five_hour）
    case cycle       // 当前额度周期窗口（Codex secondary / Claude seven_day）
                     // 官方 7d 窗口的 resetsAt 即「用户可用额度被重置」的时刻

    /// 展示标签（前端额度卡片左列 / 右列的标题）
    var displayLabel: String {
        switch self {
        case .session5h: return "Session"
        case .cycle:     return "Weekly"
        }
    }

    /// ★ 倒计时精度：5h 窗口精确到分，周额度精确到小时
    var countdownPrecision: QuotaCountdownPrecision {
        switch self {
        case .session5h: return .minute
        case .cycle:     return .hour
        }
    }
}

/// 单个额度窗口。
/// ★ 官方接口给的是「已用百分比」，剩余百分比为其数学补集（100 − 已用）。
struct QuotaWindow: Codable, Equatable {
    var kind: QuotaWindowKind
    var label: String            // 展示标签（冗余存储，便于接口自定义文案）
    var usedPercent: Double      // 0~100
    var resetsAt: Date? = nil    // 该窗口的额度重置时刻

    /// 剩余百分比 = 100 − 已用（数学恒等，无需额外数据）
    var remainingPercent: Double { clampPercent(100 - usedPercent) }

    /// ★ 实时倒计时（5h 到分 / 周窗口到小时）。
    /// 每次访问按当前时间重算，而非固化抓取时刻的快照。
    var countdownText: String {
        guard let resetsAt else { return "" }
        return formatCountdown(
            resetsAt.timeIntervalSince(Date()), precision: kind.countdownPrecision
        )
    }

    /// 是否已过重置时刻
    var isExpired: Bool {
        guard let resetsAt else { return false }
        return resetsAt.timeIntervalSinceNow <= 0
    }

    /// 展示数据（含实时倒计时）
    var display: QuotaWindowDisplay {
        QuotaWindowDisplay(
            kind: kind,
            label: label,
            usedPercent: usedPercent,
            resetsAt: resetsAt
        )
    }

    /// 本周期起点 = 重置时刻 − 7 天（仅 cycle 窗口有意义）
    var cycleStart: Date? {
        guard kind == .cycle, let resetsAt else { return nil }
        return Calendar.current.date(byAdding: .day, value: -7, to: resetsAt)
    }

    init(kind: QuotaWindowKind, label: String? = nil, usedPercent: Double, resetsAt: Date? = nil) {
        self.kind = kind
        self.label = label ?? kind.displayLabel
        self.usedPercent = clampPercent(usedPercent)
        self.resetsAt = resetsAt
    }
}

/// 额度窗口的展示数据。
/// ★ 每个窗口一条 — 前端额度卡片按参考图渲染成两列：
///   `Session  95% left` / `Weekly  13% left`，第二行 `Reset 4h 24m` / `Reset 1d 17h`。
///
/// ⚠️ 倒计时相关的属性（`countdownText` / `isExpired`）都是**实时计算**的，
///   不随快照固化。前端需用 `TimelineView(.periodic)` 驱动重绘才能看到它走动。
struct QuotaWindowDisplay: Identifiable, Equatable {
    var id: String { kind.rawValue }
    var kind: QuotaWindowKind
    var label: String
    var usedPercent: Double
    var resetsAt: Date?

    /// 剩余百分比 = 100 − 已用
    var remainingPercent: Double { clampPercent(100 - usedPercent) }

    /// 参考图样式："95% left"
    var percentLeftText: String {
        "\(Int(remainingPercent.rounded()))% left"
    }

    /// 实时倒计时：Session 到分（"2h 12m"）/ Weekly 到小时（"1d 17h"）
    var countdownText: String {
        guard let resetsAt else { return "" }
        return formatCountdown(
            resetsAt.timeIntervalSinceNow, precision: kind.countdownPrecision
        )
    }

    /// 是否已过重置时刻（实时）
    var isExpired: Bool {
        guard let resetsAt else { return false }
        return resetsAt.timeIntervalSinceNow <= 0
    }

    /// 参考图样式："Reset 4h 24m"；无重置时刻时为空
    var resetLine: String {
        countdownText.isEmpty ? "" : "Reset \(countdownText)"
    }

    /// 带标签的完整文案，如 "Session · 2h 12m"
    var displayText: String {
        countdownText.isEmpty ? label : "\(label) · \(countdownText)"
    }
}

/// 官方额度快照 — 由各 QuotaFetcher 产出（可含多个窗口）
struct QuotaSnapshot: Equatable {
    var windows: [QuotaWindow] = []
    var planName: String? = nil
    var modelLimits: [ModelLimit] = []
    var source: String = ""          // 数据来源标识（"codex-rpc"/"codex-web"/"claude-oauth"）

    init(windows: [QuotaWindow] = [], planName: String? = nil,
         modelLimits: [ModelLimit] = [], source: String = "") {
        self.windows = windows
        self.planName = planName
        self.modelLimits = modelLimits
        self.source = source
    }

    /// 主窗口 — 5h 会话优先，缺失回退首个窗口
    var primaryWindow: QuotaWindow? {
        windows.first { $0.kind == .session5h } ?? windows.first
    }

    /// 按类型取窗口
    func window(_ kind: QuotaWindowKind) -> QuotaWindow? {
        windows.first { $0.kind == kind }
    }

    // ---- 兼容旧调用点（等价于主窗口） ----
    var usedPercent: Double { primaryWindow?.usedPercent ?? 0 }
    var resetsAt: Date? { primaryWindow?.resetsAt }
    var windowLabel: String { primaryWindow?.label ?? "" }
}

/// 额度抓取协议 — LocalLogSource 依赖此接口注入官方额度
protocol QuotaFetcher {
    /// 是否存在登录态（凭据文件存在）
    var isLoggedIn: Bool { get }
    /// 拉取官方额度
    func fetchQuota() async throws -> QuotaSnapshot
}

// ============================================================
// MARK: - 通用工具
// ============================================================

/// 归一化百分比到 0~100
func clampPercent(_ value: Double) -> Double {
    min(100, max(0, value))
}

/// ISO8601 解析（支持小数秒）
func parseISO8601Date(_ string: String) -> Date? {
    guard !string.isEmpty else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
}

/// 把剩余时长格式化为倒计时文案。
/// - `.minute`："2h 12m" / "1d 3h 5m"（5h 会话窗口）
/// - `.hour`：  "1d 2h" / "3h"（周额度重置）
/// 已过重置时刻或不足一个最小单位时返回 "即将重置"。
/// 采用向下取整（截断），与「1d 2h」的常规读法一致。
func formatCountdown(_ interval: TimeInterval, precision: QuotaCountdownPrecision) -> String {
    guard interval > 0 else { return precision == .minute ? "<1m" : "<1h" }

    switch precision {
    case .minute:
        let totalMinutes = Int(interval / 60)
        guard totalMinutes > 0 else { return "<1m" }
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes / 60) % 24
        let mins = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h \(mins)m" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"

    case .hour:
        let totalHours = Int(interval / 3600)
        guard totalHours > 0 else { return "<1h" }
        let days = totalHours / 24
        let hours = totalHours % 24
        if days > 0 { return "\(days)d \(hours)h" }
        return "\(hours)h"
    }
}

/// 距重置时间的剩余文案，如 "5h · 距重置 2h 12m" / "本周期 · 距重置 1d 2h"
func quotaResetText(from resetsAt: Date?, windowLabel: String, kind: QuotaWindowKind) -> String {
    guard let resetsAt else { return "" }
    let interval = resetsAt.timeIntervalSinceNow
    guard interval > 0 else { return L("%@ · resetting soon", windowLabel) }
    return L("%@ · resets in %@", windowLabel, formatCountdown(interval, precision: kind.countdownPrecision))
}

/// 距重置时间的剩余文案（兼容旧调用点，按 5h 精度）
func quotaResetText(from resetsAt: Date?, windowLabel: String) -> String {
    guard let resetsAt else { return "" }
    let interval = resetsAt.timeIntervalSinceNow
    guard interval > 0 else { return L("%@ · resetting soon", windowLabel) }
    return L("%@ · resets in %@", windowLabel, formatCountdown(interval, precision: .minute))
}

// ============================================================
// MARK: - Codex
// ============================================================

/// Codex 额度抓取器。
/// 主通道：spawn `codex -s read-only -a untrusted app-server`，JSON-RPC 读取官方 rateLimits；
/// 降级通道：`GET https://chatgpt.com/backend-api/wham/usage`（Bearer access_token + ChatGPT-Account-Id）。
/// 凭据：`~/.codex/auth.json`（Codex CLI 登录后自动生成）。
struct CodexQuotaFetcher: QuotaFetcher {

    /// 默认凭据路径：优先 $CODEX_HOME/auth.json，否则 ~/.codex/auth.json
    static var defaultAuthPath: String {
        authPath(
            codexHome: ProcessInfo.processInfo.environment["CODEX_HOME"],
            homeDir: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    /// 凭据路径计算（纯函数，可单测）
    static func authPath(codexHome: String?, homeDir: String) -> String {
        if let codexHome, !codexHome.isEmpty {
            return (codexHome as NSString).appendingPathComponent("auth.json")
        }
        return (homeDir as NSString).appendingPathComponent(".codex/auth.json")
    }

    /// 可解析且 accessToken 或 apiKey 非空才算登录（文件存在但损坏不算）
    var isLoggedIn: Bool {
        Self.hasValidCredentials(at: Self.defaultAuthPath)
    }

    /// 凭据判定（纯逻辑，可单测）
    static func hasValidCredentials(at path: String) -> Bool {
        guard let credentials = try? CodexCredentials.load(from: path) else {
            return false
        }
        return !credentials.accessToken.isEmpty || !credentials.apiKey.isEmpty
    }

    func fetchQuota() async throws -> QuotaSnapshot {
        guard isLoggedIn else {
            throw QuotaError.notLoggedIn(L("No Codex login credentials found at %@", Self.defaultAuthPath))
        }
        // 主通道：CLI RPC（最权威）；失败静默降级 Web API
        if let snapshot = try? await fetchViaRPC() {
            return snapshot
        }
        // Web 降级通道需要 OAuth access_token；仅有 API key（BYOK）无法查询订阅额度
        let credentials = try CodexCredentials.load(from: Self.defaultAuthPath)
        guard !credentials.accessToken.isEmpty else {
            throw QuotaError.notLoggedIn(L("auth.json only contains an API key, so the subscription quota can't be queried (use `codex login`)"))
        }
        return try await fetchViaWeb()
    }

    // MARK: - RPC 主通道

    private func fetchViaRPC() async throws -> QuotaSnapshot {
        guard let session = CodexRPCSession(binary: "codex") else {
            throw QuotaError.invalidResponse(L("Could not start codex app-server (is the codex CLI installed?)"))
        }
        defer { session.terminate() }
        _ = try await session.call(method: "initialize")
        let result = try await session.call(method: "account/rateLimits/read")
        return CodexQuotaParser.parseRateLimitsResponse(result, source: "codex-rpc")
    }

    // MARK: - Web 降级通道

    private func fetchViaWeb() async throws -> QuotaSnapshot {
        let credentials = try CodexCredentials.load(from: Self.defaultAuthPath)
        guard !credentials.accessToken.isEmpty else {
            throw QuotaError.notLoggedIn(L("~/.codex/auth.json is missing access_token (log in to codex again)"))
        }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if !credentials.accountId.isEmpty {
            request.setValue(credentials.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30   // 避免无响应时刷新永久卡死

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.invalidResponse(L("Invalid response"))
        }
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw QuotaError.httpError(statusCode: http.statusCode, body: String(body.prefix(200)))
        }
        return CodexQuotaParser.parseWebResponse(json)
    }
}

/// Codex 凭据解析 — 纯函数，可单测
struct CodexCredentials: Equatable {
    var apiKey: String = ""
    var accessToken: String = ""
    var idToken: String = ""
    var refreshToken: String = ""
    var accountId: String = ""

    /// 解析 ~/.codex/auth.json
    /// 结构：{ "OPENAI_API_KEY": ..., "tokens": { "access_token", "id_token", "refresh_token", "account_id" }, "last_refresh" }
    static func load(from path: String) throws -> CodexCredentials {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.notLoggedIn(L("Could not read %@", path))
        }
        let tokens = json["tokens"] as? [String: Any]
        return CodexCredentials(
            apiKey: json["OPENAI_API_KEY"] as? String ?? "",
            accessToken: tokens?["access_token"] as? String ?? "",
            idToken: tokens?["id_token"] as? String ?? "",
            refreshToken: tokens?["refresh_token"] as? String ?? "",
            accountId: tokens?["account_id"] as? String ?? ""
        )
    }
}

/// Codex 额度响应解析 — 纯函数，可单测
enum CodexQuotaParser {

    /// RPC `account/rateLimits/read` 的 result
    /// { "rateLimits": { "planType", "primary": {...}, "secondary": {...} }, "rateLimitsByLimitId": {...} }
    static func parseRateLimitsResponse(_ json: [String: Any], source: String) -> QuotaSnapshot {
        let rateLimits = (json["rateLimits"] as? [String: Any]) ?? json
        var snapshot = Self.parseWindows(from: rateLimits, source: source)
        snapshot.planName = rateLimits["planType"] as? String ?? json["planType"] as? String

        // 模型级额度（rateLimitsByLimitId: { limitId: { limitId, limitName, primary: {...} } }）
        if let byLimit = json["rateLimitsByLimitId"] as? [String: Any] {
            for (key, value) in byLimit {
                guard let item = value as? [String: Any],
                      let window = item["primary"] as? [String: Any] else { continue }
                let name = (item["limitName"] as? String ?? key)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                snapshot.modelLimits.append(ModelLimit(
                    modelName: name,
                    usedPercent: Self.percent(from: window["usedPercent"]),
                    resetsAt: parseISO8601Date(window["resetsAt"] as? String ?? "")
                ))
            }
        }
        return snapshot
    }

    /// Web `wham/usage` 响应
    /// { "rateLimits": { "primary": {...}, "secondary": {...} }, "rateLimitResetCredits": {...} }
    static func parseWebResponse(_ json: [String: Any]) -> QuotaSnapshot {
        let rateLimits = (json["rateLimits"] as? [String: Any]) ?? json
        return Self.parseWindows(from: rateLimits, source: "codex-web")
    }

    /// 从 rateLimits 对象提取两个窗口：primary → 5h 会话，secondary → 本周期。
    /// ★ 两者独立产出（旧实现「primary 优先、缺失才用 secondary」会丢弃一个窗口）。
    private static func parseWindows(from rateLimits: [String: Any], source: String) -> QuotaSnapshot {
        var windows: [QuotaWindow] = []
        if let primary = rateLimits["primary"] as? [String: Any] {
            windows.append(QuotaWindow(
                kind: .session5h,
                usedPercent: Self.percent(from: primary["usedPercent"]),
                resetsAt: parseISO8601Date(primary["resetsAt"] as? String ?? "")
            ))
        }
        if let secondary = rateLimits["secondary"] as? [String: Any] {
            windows.append(QuotaWindow(
                kind: .cycle,
                usedPercent: Self.percent(from: secondary["usedPercent"]),
                resetsAt: parseISO8601Date(secondary["resetsAt"] as? String ?? "")
            ))
        }
        return QuotaSnapshot(windows: windows, source: source)
    }

    private static func percent(from value: Any?) -> Double {
        if let v = value as? Double { return clampPercent(v) }
        if let v = value as? Int { return clampPercent(Double(v)) }
        if let v = value as? String, let d = Double(v) { return clampPercent(d) }
        return 0
    }
}

/// Codex CLI JSON-RPC 会话（app-server）
/// spawn `codex -s read-only -a untrusted app-server`，stdin/stdout 逐行 JSON-RPC
/// RPC 单次调用的完成状态（线程安全）— 保证 continuation 只被 resume 一次
private final class RPCCallState: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    /// 原子标记完成；返回 true 表示本次是第一个完成者（应 resume continuation）
    func markDone() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

private final class CodexRPCSession {
    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let queue = DispatchQueue(label: "codex-rpc-session")
    private var nextID = 0
    private var readBuffer = Data()

    init?(binary: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [binary, "-s", "read-only", "-a", "untrusted", "app-server"]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return nil
        }
        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading
    }

    /// 发送一条 JSON-RPC 请求并等待同 id 的响应
    /// ★ 带 15s 超时：codex 进程无响应时终止进程并抛错，
    ///   避免上游 performRefresh 永久卡死（isRefreshing 卡 true）。
    func call(method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        nextID += 1
        let id = nextID
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)
        var line = data
        line.append(0x0A)
        try stdinHandle.write(contentsOf: line)

        let state = RPCCallState()
        return try await withCheckedThrowingContinuation { continuation in
            // 读线程（专用队列）：阻塞读直到拿到同 id 响应
            queue.async {
                while true {
                    guard let line = self.readLine() else {
                        if state.markDone() {
                            continuation.resume(throwing: QuotaError.invalidResponse(L("codex RPC exited early")))
                        }
                        return
                    }
                    guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let responseID = json["id"] as? Int, responseID == id else { continue }
                    if let result = json["result"] as? [String: Any] {
                        if state.markDone() { continuation.resume(returning: result) }
                    } else if let error = json["error"] as? [String: Any] {
                        let message = error["message"] as? String ?? L("Unknown error")
                        if state.markDone() {
                            continuation.resume(throwing: QuotaError.invalidResponse("codex RPC error: \(message)"))
                        }
                    } else {
                        if state.markDone() {
                            continuation.resume(throwing: QuotaError.invalidResponse(L("codex RPC response is missing result")))
                        }
                    }
                    return
                }
            }

            // 超时任务：15s 无响应 → 终止进程（stdout 关闭 → readLine 返回 nil → 读线程退出）→ 抛超时
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                guard state.markDone() else { return }
                self.process.terminate()
                continuation.resume(throwing: QuotaError.invalidResponse(L("codex RPC timed out (15s); the codex process was terminated")))
            }
        }
    }

    /// 阻塞读一行（专用队列上调用）
    private func readLine() -> Data? {
        while true {
            if let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer.subdata(in: 0..<newline)
                readBuffer.removeSubrange(0...newline)
                return line
            }
            let chunk = stdoutHandle.readData(ofLength: 4096)
            if chunk.isEmpty {
                let rest = readBuffer
                readBuffer.removeAll()
                return rest.isEmpty ? nil : rest
            }
            readBuffer.append(chunk)
        }
    }

    func terminate() {
        process.terminate()
    }
}

// ============================================================
// MARK: - Claude Code
// ============================================================

/// Claude Code 额度抓取器（OAuth 通道）。
/// `GET https://api.anthropic.com/api/oauth/usage`（Bearer accessToken + `anthropic-beta: oauth-2025-04-20`）。
/// 凭据：`~/.claude/.credentials.json`（OAuth accessToken）+ `~/.claude/.config.json`（oauthAccount.accountUuid）。
struct ClaudeQuotaFetcher: QuotaFetcher {

    /// 默认配置目录 ~/.claude（Claude Code 登录后自动生成）
    nonisolated static var defaultConfigDir: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude").path
    }

    var isLoggedIn: Bool {
        ClaudeOAuthCredentials.credentialsFileExists(in: Self.defaultConfigDir)
            || ClaudeKeychainReader.hasAnyEntry()
    }

    func fetchQuota() async throws -> QuotaSnapshot {
        let (credentials, channel) = try await resolveCredentials()
        switch await requestQuota(token: credentials.accessToken) {
        case .ok(let snapshot):
            return snapshot

        case .unauthorized where channel == .file:
            // ★ 文件镜像的 token 可能未过期但已被轮换失效 → 失效缓存、强制读钥匙串重试一次。
            //   仅在“文件源”时重试：钥匙串是权威源，它再 401 就真的需要重新登录。
            ClaudeKeychainCache.shared.invalidate()
            let (retried, _) = try await resolveCredentials(forceKeychain: true)
            switch await requestQuota(token: retried.accessToken) {
            case .ok(let snapshot): return snapshot
            default: throw QuotaError.notLoggedIn(L("Claude credentials have expired. Run `claude` to log in again."))
            }

        case .unauthorized:
            throw QuotaError.notLoggedIn(L("Claude credentials have expired. Run `claude` to log in again."))

        case .failed(let error):
            throw error
        }
    }

    // MARK: - 请求

    private enum RequestOutcome {
        case ok(QuotaSnapshot)
        case unauthorized
        case failed(Error)
    }

    private func requestQuota(token: String) async -> RequestOutcome {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 30   // 避免无响应时刷新永久卡死

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(QuotaError.invalidResponse(L("Invalid response")))
            }
            if http.statusCode == 401 || http.statusCode == 403 { return .unauthorized }
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                return .failed(QuotaError.httpError(statusCode: http.statusCode, body: String(body.prefix(200))))
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed(QuotaError.invalidResponse(L("Response is not JSON")))
            }
            return .ok(ClaudeQuotaParser.parse(json, source: "claude-oauth"))
        } catch {
            return .failed(error)
        }
    }

    // MARK: - 取凭据

    /// 凭据来源通道（决定 401 时能否降级到钥匙串重试）
    enum CredentialChannel: Equatable { case file, keychain }

    /// token 是否临近过期（无 expiresAt 视为不临期，交给服务端 401 兜底）
    nonisolated static func isNearExpiry(_ expiresAt: Date?, now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < ClaudeKeychainCache.credentialRefreshMargin
    }

    /// 双源取凭据：~/.claude 文件 + macOS Keychain，取 expiresAt 更晚者。
    ///
    /// ★ 文件 token 尚未临近过期时**不读钥匙串** —— 否则每次轮询都要起 security 子进程、
    ///   每次都弹钥匙串授权框。文件缺失 / 临近过期 / forceKeychain（401 降级）时才读钥匙串兜底。
    ///
    /// ★ 钥匙串 IO 在**后台线程**（`loadCredentialSources`）—— `SecurityRunner` 会阻塞调用线程
    ///   等待子进程（读密文时可能等用户在授权框输密码，最长 90s），绝不能占着 MainActor 卡死面板。
    private func resolveCredentials(forceKeychain: Bool = false)
        async throws -> (credentials: ClaudeOAuthCredentials, channel: CredentialChannel) {

        let sources = await Self.loadCredentialSources(forceKeychain: forceKeychain)
        let fileCreds = sources.file
        let keychainCred = sources.keychain

        // 文件源可用（有 token 且未临近过期）→ 直接用，不碰钥匙串
        if !forceKeychain,
           let fileCreds, !fileCreds.accessToken.isEmpty,
           !Self.isNearExpiry(fileCreds.expiresAt) {
            return (fileCreds, .file)
        }

        // 401 降级：钥匙串是权威源，直接采用（不再比较 expiresAt）
        if forceKeychain, let keychainCred, !keychainCred.accessToken.isEmpty {
            var credentials = fileCreds ?? ClaudeOAuthCredentials()
            credentials.accessToken = keychainCred.accessToken
            if let expiresAt = keychainCred.expiresAt { credentials.expiresAt = expiresAt }
            return (credentials, .keychain)
        }

        guard let chosen = ClaudeCredentialSource.preferred(
            fileToken: fileCreds?.accessToken, fileExpiresAt: fileCreds?.expiresAt,
            keychainToken: keychainCred?.accessToken, keychainExpiresAt: keychainCred?.expiresAt
        ) else {
            throw QuotaError.notLoggedIn(L("No Claude Code OAuth accessToken found (log in to claude first)"))
        }
        var credentials = fileCreds ?? ClaudeOAuthCredentials()
        credentials.accessToken = chosen.token
        if let expiresAt = chosen.expiresAt { credentials.expiresAt = expiresAt }
        return (credentials, chosen.source == "keychain" ? .keychain : .file)
    }

    /// 在后台线程读两个来源（文件 + 钥匙串）。
    /// 文件源有效时直接返回 `keychain: nil`，**完全不起子进程**（零弹窗）。
    private nonisolated static func loadCredentialSources(forceKeychain: Bool)
        async -> (file: ClaudeOAuthCredentials?, keychain: ClaudeKeychainCredential?) {
        await Task.detached(priority: .userInitiated) { () -> (ClaudeOAuthCredentials?, ClaudeKeychainCredential?) in
            let file = try? ClaudeOAuthCredentials.load(configDir: defaultConfigDir)
            if !forceKeychain,
               let file, !file.accessToken.isEmpty,
               !isNearExpiry(file.expiresAt) {
                return (file, nil)
            }
            return (file, ClaudeKeychainReader.loadCredential(forceRefresh: forceKeychain))
        }.value
    }
}

/// Claude Code OAuth 凭据解析 — 纯函数，可单测
struct ClaudeOAuthCredentials: Equatable {
    var accessToken: String = ""
    var accountUuid: String = ""
    var expiresAt: Date? = nil

    nonisolated init() {}

    nonisolated static func credentialsFileExists(in configDir: String) -> Bool {
        FileManager.default.fileExists(atPath: (configDir as NSString).appendingPathComponent(".credentials.json"))
    }

    /// 宽松解析 credentials.json + config.json 中的 OAuth 凭据。
    /// 兼容多种结构：oauthAccount.tokens.accessToken / claudeAiOauth.accessToken / oauthAccount.accessToken
    nonisolated static func load(configDir: String) throws -> ClaudeOAuthCredentials {
        let dir = URL(fileURLWithPath: configDir)
        let credentialsURL = dir.appendingPathComponent(".credentials.json")
        let configURL = dir.appendingPathComponent(".config.json")
        var credentials = ClaudeOAuthCredentials()

        if let data = try? Data(contentsOf: credentialsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            credentials.accessToken = Self.firstNonEmpty(in: json, paths: [
                "oauthAccount.tokens.accessToken",
                "claudeAiOauth.accessToken",
                "oauthAccount.accessToken",
                "accessToken",
            ])
            credentials.expiresAt = Self.parseExpiresAt(in: json)
        }
        if let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            credentials.accountUuid = JSONPathExtractor.string(json, path: "oauthAccount.accountUuid")
        }
        return credentials
    }

    private nonisolated static func parseExpiresAt(in json: [String: Any]) -> Date? {
        guard let raw = JSONPathExtractor.extract(json, path: "claudeAiOauth.expiresAt") else { return nil }
        let value: Double
        if let v = raw as? Double { value = v }
        else if let v = raw as? Int { value = Double(v) }
        else if let v = raw as? String, let parsed = Double(v) { value = parsed }
        else { return nil }
        let seconds = value > 1e12 ? value / 1000.0 : value
        return Date(timeIntervalSince1970: seconds)
    }

    private nonisolated static func firstNonEmpty(in json: [String: Any], paths: [String]) -> String {
        for path in paths {
            let value = JSONPathExtractor.string(json, path: path)
            if !value.isEmpty { return value }
        }
        return ""
    }
}

/// Claude usage 响应解析 — 纯函数，可单测
/// 响应结构：
/// {
///   "five_hour": { "utilization": 7, "resets_at": "..." },          // 5h 会话窗口（主）
///   "seven_day": { "utilization": 21, "resets_at": "..." },         // 7d 周窗口
///   "seven_day_opus": { "utilization": 5, "resets_at": "..." },     // 模型级周窗口
///   "limits": [ { "kind": "weekly_scoped", "group": "weekly", "percent": 30, "resets_at": "...",
///                 "scope": { "model": { "id": "...", "display_name": "opus" } } } ]
/// }
enum ClaudeQuotaParser {

    static func parse(_ json: [String: Any], source: String) -> QuotaSnapshot {
        var snapshot = QuotaSnapshot(source: source)

        // 两个窗口独立产出：five_hour → 5h 会话，seven_day → 本周期（可用额度重置周期）
        if let fiveHour = json["five_hour"] as? [String: Any],
           let pct = percentValue(fiveHour["utilization"]) {
            snapshot.windows.append(QuotaWindow(
                kind: .session5h,
                usedPercent: clampPercent(pct),
                resetsAt: parseISO8601Date(fiveHour["resets_at"] as? String ?? "")
            ))
        }
        if let sevenDay = json["seven_day"] as? [String: Any],
           let pct = percentValue(sevenDay["utilization"]) {
            snapshot.windows.append(QuotaWindow(
                kind: .cycle,
                usedPercent: clampPercent(pct),
                resetsAt: parseISO8601Date(sevenDay["resets_at"] as? String ?? "")
            ))
        }

        // 模型级周窗口：seven_day_<model> 键 + limits[].weekly_scoped
        var seen = Set<String>()
        for (key, value) in json {
            guard key.hasPrefix("seven_day_"), key != "seven_day",
                  let window = value as? [String: Any],
                  let pct = percentValue(window["utilization"]) else { continue }
            let model = String(key.dropFirst("seven_day_".count))
            Self.appendUnique(&snapshot.modelLimits, seen: &seen, modelName: model,
                              usedPercent: pct, resetsAt: window["resets_at"] as? String)
        }
        for entry in JSONPathExtractor.array(json, path: "limits") {
            guard (entry["kind"] as? String) == "weekly_scoped",
                  let pct = percentValue(entry["percent"]) else { continue }
            let scope = entry["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            let name = (model?["display_name"] as? String)
                ?? (model?["id"] as? String) ?? ""
            Self.appendUnique(&snapshot.modelLimits, seen: &seen, modelName: name,
                              usedPercent: pct, resetsAt: entry["resets_at"] as? String)
        }
        return snapshot
    }

    private static func appendUnique(
        _ limits: inout [ModelLimit], seen: inout Set<String>,
        modelName: String, usedPercent: Double, resetsAt: String?
    ) {
        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !seen.contains(trimmed.lowercased()) else { return }
        seen.insert(trimmed.lowercased())
        limits.append(ModelLimit(
            modelName: trimmed,
            usedPercent: clampPercent(usedPercent),
            resetsAt: parseISO8601Date(resetsAt ?? "")
        ))
    }

    static func percentValue(_ value: Any?) -> Double? {
        if let v = value as? Double { return v }
        if let v = value as? Int { return Double(v) }
        if let v = value as? String { return Double(v) }
        return nil
    }
}
