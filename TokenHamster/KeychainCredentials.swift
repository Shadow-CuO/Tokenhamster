//
//  KeychainCredentials.swift
//  TokenHamster
//
//  macOS Keychain 凭据读取 — Claude Code CLI 登录态（只读，不写）
//
//  背景：新版 Claude Code 在 macOS 只在 Keychain 轮换 OAuth token，
//  ~/.claude/.credentials.json 仅是镜像、可能缺失或过期。
//  服务名：默认 "Claude Code-credentials"；v2.1.52+ 设置 CLAUDE_CONFIG_DIR
//  （即使指向 ~/.claude）时变为 "Claude Code-credentials-<sha256(绝对路径)[:8]>"
//  存的是 JSON blob：{"claudeAiOauth":{"accessToken":"...","refreshToken":"...","expiresAt":<ms>}}
//  少数版本存裸 token（sk-ant-* 或 JWT 三段）。
//

import Foundation
import CryptoKit

// ============================================================
// MARK: - security 子进程封装（带硬超时）
// ============================================================

struct KeychainCommandResult {
    var exitCode: Int32
    var stdout: String
    var timedOut: Bool
}

/// 运行 /usr/bin/security 子进程，带硬超时。
/// macOS 26.x 上 security 偶发无限挂起，所有调用必须有超时兜底。
///
/// ★ 两档超时：
/// - `metadataTimeout`（3s）—— 只读元数据（`find-generic-password` 不带 `-w`），正常无对话框
/// - `secretTimeout`（90s）—— 读密文（带 `-w`）**会弹钥匙串授权框**，必须给用户输入时间。
///   原实现统一 3s：用户正在输密码时进程被 kill，SecurityAgent 对话框变成永远无法满足的
///   孤儿窗口（表现就是“输了密码也关不掉”），且下一次轮询立刻再弹一个。
enum SecurityRunner {
    /// 元数据探测超时
    nonisolated static let metadataTimeout: TimeInterval = 3.0
    /// 读密文超时 —— 可能弹授权框，需留足人工输入时间
    nonisolated static let secretTimeout: TimeInterval = 90.0
    nonisolated static let securityPath = "/usr/bin/security"

    nonisolated static func run(
        arguments: [String],
        timeout: TimeInterval = metadataTimeout
    ) -> KeychainCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: securityPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return KeychainCommandResult(exitCode: -1, stdout: "", timedOut: false)
        }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            group.leave()
        }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            // ★ 只做优雅终止，不再 SIGKILL：强杀会把 SecurityAgent 上正在等用户
            //   输入密码的对话框变成无法满足的孤儿窗口。
            process.terminate()
            return KeychainCommandResult(exitCode: -1, stdout: "", timedOut: true)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        return KeychainCommandResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            timedOut: false
        )
    }
}

// ============================================================
// MARK: - 钥匙串访问开关（唯一闸门）
// ============================================================

/// 是否允许访问 Claude Code 钥匙串 —— **默认关闭**。
///
/// 为什么必须有这个开关：
/// - macOS 上读别人（Claude Code CLI）创建的钥匙串条目**必然弹授权框**，
///   一个 `security` 子进程一个框；而 Claude 凭据文件 `~/.claude/.credentials.json`
///   在较新版本里可能根本不存在（凭据只在钥匙串），于是每次刷新都要读 → 弹窗不断。
/// - 点“始终允许”也救不了：项目 ad-hoc 签名（`CODE_SIGN_IDENTITY=-`）没有稳定的
///   代码签名身份，ACL 里的信任记录无法匹配，重编译后依旧弹。
///
/// 所以：**默认关**。关闭时绝不发起任何钥匙串调用（零弹窗），
/// 只读 `~/.claude/.credentials.json`。
///
/// ⚠️ 状态**仅存内存、不持久化**（刻意为之）：
/// - 当前 App 已无任何入口能开启它（设置页的开关已按用户要求移除），生产环境下永远是 false；
/// - 曾用 UserDefaults 持久化，结果测试把真实 App Group 域写成了 true，
///   导致“重启后弹窗复发”且难以察觉。不落盘就没有这个隐患。
nonisolated enum ClaudeKeychainAccess {

    private static let lock = NSLock()
    private static var enabled = false

    /// 是否已开启（默认 false）
    static var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }

    static func setEnabled(_ value: Bool) {
        lock.lock(); enabled = value; lock.unlock()
    }
}

// ============================================================
// MARK: - 读取缓存（避免轮询反复唤起 security 子进程弹钥匙串授权框）
// ============================================================

/// 进程内缓存。
///
/// 背景：每次用 `security` 子进程访问 Claude Code 的条目都会**弹一次**钥匙串授权框
/// （几个子进程就几个框），而轮询会反复刷新；更麻烦的是 `SecurityRunner` 的 3s 硬超时
/// 会在用户正输密码时把进程 SIGKILL，于是框永远答不完、下个子进程又弹一个。
/// 因此必须缓存：
/// - service name 命中后不再重复探测；未命中做短 TTL 负缓存（便于 claude login 后自动发现）
/// - 凭据只在缺失 / 临近过期 / 显式失效时才重读（Claude token 通常数小时有效）
///
/// 线程安全，可从任意 actor 调用。
/// ★ 整个类标记 `nonisolated`：项目默认 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
///   否则存储属性与静态常量都会隐式 MainActor 隔离，非隔离方法访问会报错
///   （而钥匙串读取必须能离开主线程，见 ClaudeQuotaFetcher.loadCredentialSources）。
nonisolated final class ClaudeKeychainCache: @unchecked Sendable {

    static let shared = ClaudeKeychainCache()

    /// 未命中 service name 的负缓存时长 —— 取值偏大：重新探测会弹授权框，宁可晚一点
    /// 发现登录态（用户可在设置里关闭开关彻底免弹窗）。
    static let serviceNameMissTTL: TimeInterval = 1800
    /// 凭据提前重读量：剩余寿命不足此时长即重读钥匙串
    static let credentialRefreshMargin: TimeInterval = 300
    /// 无 expiresAt（裸 token / 解析不出）时的凭据缓存上限
    static let credentialFallbackTTL: TimeInterval = 3600
    /// “条目是否存在”的缓存上限 —— 即使 token 已过期也别反复探测弹框
    static let presenceTTL: TimeInterval = 3600
    /// 读取失败（用户拒绝 / 超时）后的静默期 —— 不缓存失败会每次轮询重试弹框
    static let readFailureTTL: TimeInterval = 1800

    private let lock = NSLock()
    private var serviceName: String?
    private var serviceNameMissedAt: Date?
    private var credential: ClaudeKeychainCredential?
    private var credentialReadAt: Date?
    private var readFailedAt: Date?

    // MARK: - service name

    /// 已命中的 service name（命中的条目不会消失，永久缓存）
    nonisolated func resolvedServiceName() -> String? {
        lock.lock(); defer { lock.unlock() }
        return serviceName
    }

    /// 未命中的负缓存是否仍新鲜（新鲜则本轮不再探测钥匙串）
    nonisolated func serviceNameMissIsFresh(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let missedAt = serviceNameMissedAt else { return false }
        return now.timeIntervalSince(missedAt) < Self.serviceNameMissTTL
    }

    nonisolated func storeServiceName(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        serviceName = name
        serviceNameMissedAt = nil
    }

    nonisolated func storeServiceNameMiss(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        serviceNameMissedAt = now
    }

    // MARK: - credential

    /// 仍新鲜的凭据（临近过期 / 超保有期限 → nil，调用方会重读钥匙串）
    nonisolated func freshCredential(now: Date = Date()) -> ClaudeKeychainCredential? {
        lock.lock(); defer { lock.unlock() }
        guard let credential else { return nil }
        if let expiresAt = credential.expiresAt {
            return expiresAt.timeIntervalSince(now) > Self.credentialRefreshMargin ? credential : nil
        }
        guard let readAt = credentialReadAt,
              now.timeIntervalSince(readAt) < Self.credentialFallbackTTL else { return nil }
        return credential
    }

    /// “条目存在”判定用：不管 token 是否过期，读取后一段时间内直接用缓存
    nonisolated func presenceCredential(now: Date = Date()) -> ClaudeKeychainCredential? {
        lock.lock(); defer { lock.unlock() }
        guard let credential, let readAt = credentialReadAt else { return nil }
        return now.timeIntervalSince(readAt) < Self.presenceTTL ? credential : nil
    }

    nonisolated func storeCredential(_ credential: ClaudeKeychainCredential, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        self.credential = credential
        self.credentialReadAt = now
        self.readFailedAt = nil
    }

    /// 读取失败（用户拒绝授权 / 超时）——静默期内不再重试，避免"拒绝一次就每次弹框"
    nonisolated func storeReadFailure(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        readFailedAt = now
    }

    /// 是否处于读取失败静默期
    nonisolated func isReadFailureFresh(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let failedAt = readFailedAt else { return false }
        return now.timeIntervalSince(failedAt) < Self.readFailureTTL
    }

    /// 凭据失效 —— 收到 401/403、或用户重新登录后调用；下次读取会重新访问钥匙串
    nonisolated func invalidate() {
        lock.lock(); defer { lock.unlock() }
        credential = nil
        credentialReadAt = nil
        readFailedAt = nil
    }
}

// ============================================================
// MARK: - Claude Code Keychain 凭据读取
// ============================================================

/// Claude Code CLI 的 Keychain 凭据（只读解析结果）
struct ClaudeKeychainCredential: Equatable {
    var accessToken: String = ""
    var expiresAt: Date? = nil
}

enum ClaudeKeychainReader {

    nonisolated static let legacyServiceName = "Claude Code-credentials"
    nonisolated static let serviceNamePrefix = "Claude Code-credentials"

    /// Claude Code 默认配置目录（与 `ClaudeQuotaFetcher.defaultConfigDir` 一致）
    nonisolated static var defaultConfigDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
    }

    // MARK: - 服务名解析

    /// 候选 service name —— ★ **不再枚举整个钥匙串**。
    ///
    /// 历史坑：原实现用 `SecItemCopyMatching(kSecMatchLimitAll)` 枚举**所有** generic password，
    /// 而它是在主线程（项目默认 MainActor 隔离）上同步执行的：
    /// 1. 每条不属于本 App 的条目都可能弹一个授权框 → 用户看到“一堆”弹窗；
    /// 2. 主线程被这个同步调用卡死 → 界面冻结，弹窗答不完也关不掉；
    /// 3. 拒绝后每次都重跑 → 无限循环。
    /// 现在只试**有限几个可计算的候选名**（最多 3 次元数据探测）。
    nonisolated static func candidateServiceNames() -> [String] {
        var names: [String] = []
        if let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !configDir.isEmpty {
            names.append(hashedServiceName(configDir: configDir))
        }
        // v2.1.52+ 即使用默认目录也用 hash 名
        names.append(hashedServiceName(configDir: defaultConfigDir))
        names.append(legacyServiceName)
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// 依次尝试候选名。返回 nil 表示 Keychain 中无 Claude Code 凭据。
    /// ★ 开关关闭时直接返回 nil（不发起任何钥匙串调用）；
    ///   开启时结果缓存：命中永久有效；未命中做长 TTL 负缓存。
    nonisolated static func resolveServiceName(account: String = NSUserName(), forceRefresh: Bool = false) -> String? {
        guard ClaudeKeychainAccess.isEnabled else { return nil }
        let cache = ClaudeKeychainCache.shared
        if !forceRefresh {
            if let cached = cache.resolvedServiceName() { return cached }
            if cache.serviceNameMissIsFresh() { return nil }
        }
        for name in candidateServiceNames() where keychainItemExists(serviceName: name, account: account) {
            cache.storeServiceName(name)
            return name
        }
        cache.storeServiceNameMiss()
        return nil
    }

    /// 计算 `Claude Code-credentials-<sha256(绝对路径)[:8]>`（纯函数，可单测）
    nonisolated static func hashedServiceName(configDir: String) -> String {
        let absolute = (configDir as NSString).standardizingPath
        let digest = SHA256.hash(data: Data(absolute.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(serviceNamePrefix)-\(hex.prefix(8))"
    }

    /// 是否存在任意 Claude Code keychain 条目（isLoggedIn 判定用）
    /// ★ 开关关闭时返回 false —— 绝不起子进程（零弹窗）。
    /// ★ 开关开启时：命中缓存则不起子进程；读到的凭据会顺带喂进缓存，同一轮刷新不再读第二次。
    nonisolated static func hasAnyEntry(account: String = NSUserName(), forceRefresh: Bool = false) -> Bool {
        guard ClaudeKeychainAccess.isEnabled else { return false }
        let cache = ClaudeKeychainCache.shared
        if !forceRefresh {
            if cache.presenceCredential() != nil { return true }
            // 刚失败过（用户拒绝 / 超时）→ 静默期内不再探测，避免反复弹框
            if cache.isReadFailureFresh() { return false }
        }
        guard let name = cache.resolvedServiceName()
                ?? resolveServiceName(account: account, forceRefresh: forceRefresh),
              let raw = readCredentialsJSON(serviceName: name, account: account) else {
            cache.storeReadFailure()
            return false
        }
        cache.storeCredential(credential(from: raw))
        return !raw.isEmpty
    }

    // MARK: - 读取

    /// `security find-generic-password -s <svc> -a <account> -w`
    /// 超时 / 条目不存在（exit 44）/ 空 → nil
    /// ★ 用 `secretTimeout`（90s）—— 读密文会弹授权框，要留足人工输入时间
    nonisolated static func readCredentialsJSON(serviceName: String, account: String = NSUserName()) -> String? {
        let result = SecurityRunner.run(
            arguments: ["find-generic-password", "-s", serviceName, "-a", account, "-w"],
            timeout: SecurityRunner.secretTimeout
        )
        if result.timedOut || result.exitCode != 0 { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// 读取并解析为凭据（accessToken + expiresAt）
    /// ★ 开关关闭时返回 nil —— 绝不起子进程（零弹窗）。
    /// ★ 开关开启时：命中缓存则完全不起子进程 —— 弹窗只在缓存缺失 / 临近过期 / 显式失效时出现。
    nonisolated static func loadCredential(account: String = NSUserName(), forceRefresh: Bool = false) -> ClaudeKeychainCredential? {
        guard ClaudeKeychainAccess.isEnabled else { return nil }
        let cache = ClaudeKeychainCache.shared
        if !forceRefresh {
            if let cached = cache.freshCredential() { return cached }
            if cache.isReadFailureFresh() { return nil }   // 刚失败过 → 静默期内不重试
        }
        guard let name = cache.resolvedServiceName()
                ?? resolveServiceName(account: account, forceRefresh: forceRefresh),
              let raw = readCredentialsJSON(serviceName: name, account: account) else {
            cache.storeReadFailure()
            return nil
        }
        let credential = credential(from: raw)
        cache.storeCredential(credential)
        return credential
    }

    /// 原始 JSON → 凭据（解析失败时 accessToken 为空，供调用方判定未登录）
    private nonisolated static func credential(from raw: String) -> ClaudeKeychainCredential {
        ClaudeKeychainCredential(
            accessToken: parseAccessToken(from: raw) ?? "",
            expiresAt: parseExpiresAt(from: raw)
        )
    }

    // MARK: - 解析（纯函数，可单测）

    /// 三层兜底：JSON blob → 截断 JSON 正则 → 裸 token 形状
    nonisolated static func parseAccessToken(from raw: String) -> String? {
        // 1) JSON blob：claudeAiOauth.accessToken 等常见路径
        if let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let token = firstNonEmpty(in: json, paths: [
                "claudeAiOauth.accessToken",
                "oauthAccount.tokens.accessToken",
                "oauthAccount.accessToken",
                "accessToken"
            ]) { return token }
        }
        // 2) 截断 JSON 正则兜底（security 对大 payload >2KB 会截断）
        if let token = extractTokenViaRegex(from: raw) { return token }
        // 3) 裸 token 形状
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("sk-ant-") || trimmed.split(separator: ".").count == 3 {
            return trimmed
        }
        return nil
    }

    /// claudeAiOauth.expiresAt（>1e12 视为毫秒转秒）
    nonisolated static func parseExpiresAt(from raw: String) -> Date? {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let value = oauth["expiresAt"] as? Double else { return nil }
        let seconds = value > 1e12 ? value / 1000.0 : value
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: - 私有

    /// 只读元数据（不带 `-w`）—— 用短超时。
    private nonisolated static func keychainItemExists(serviceName: String, account: String) -> Bool {
        let result = SecurityRunner.run(
            arguments: ["find-generic-password", "-s", serviceName, "-a", account],
            timeout: SecurityRunner.metadataTimeout
        )
        return !result.timedOut && result.exitCode == 0
    }

    private nonisolated static func extractTokenViaRegex(from rawString: String) -> String? {
        let pattern = #""accessToken"\s*:\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: rawString, range: NSRange(rawString.startIndex..., in: rawString)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: rawString) else { return nil }
        return String(rawString[range])
    }

    private nonisolated static func firstNonEmpty(in json: [String: Any], paths: [String]) -> String? {
        for path in paths {
            let value = JSONPathExtractor.string(json, path: path)
            if !value.isEmpty { return value }
        }
        return nil
    }
}

// ============================================================
// MARK: - Claude 凭据选源（纯函数，可单测）
// ============================================================

/// 文件与 Keychain 双源选源：取 expiresAt 更晚者（Keychain 是 Claude 权威轮换源，
/// 文件可能是旧镜像）。两者都无 expiresAt 时优先 Keychain。
enum ClaudeCredentialSource {
    nonisolated static func preferred(
        fileToken: String?, fileExpiresAt: Date?,
        keychainToken: String?, keychainExpiresAt: Date?
    ) -> (token: String, expiresAt: Date?, source: String)? {
        let fileValid = fileToken?.isEmpty == false
        let keychainValid = keychainToken?.isEmpty == false
        switch (fileValid, keychainValid) {
        case (false, false):
            return nil
        case (true, false):
            return (fileToken!, fileExpiresAt, "file")
        case (false, true):
            return (keychainToken!, keychainExpiresAt, "keychain")
        case (true, true):
            switch (fileExpiresAt, keychainExpiresAt) {
            case (let f?, let k?):
                return f > k ? (fileToken!, f, "file") : (keychainToken!, k, "keychain")
            case (let f?, nil):
                return (fileToken!, f, "file")
            case (nil, let k?):
                return (keychainToken!, k, "keychain")
            case (nil, nil):
                return (keychainToken!, keychainExpiresAt, "keychain")
            }
        }
    }
}
