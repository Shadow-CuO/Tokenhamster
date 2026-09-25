//
//  DSHPluginInstaller.swift
//  TokenHamster
//
//  DeepSeek Harness 用量插件（`@ychris12138/dsh-usage-stats`）的安装引导。
//
//  ── 设计原则 ──
//  1. **不打包第三方代码**：只调用官方 `dsh plugin add`，让包管理器自己装。
//  2. **默认 pin 已验证版本**：该插件历史上出现过「装上后 DSH 启动崩溃」的版本，
//     盲装 latest 有真实风险 → 默认装我们实测过的版本，另给「装最新版」并明示风险。
//  3. **绝不谎报成功**：装完必须验证（包目录存在 + 缓存可用）才允许说「装好了」。
//     未生效时明确告知「需要你重启 DSH 我才能看到数据」。
//  4. **不代用户重启 DSH**：会杀掉他正在跑的 agent turn —— 重启只能由用户自己做。
//  5. **不做错误分类表**：失败时展示**原始输出**并指向支持文档，不猜原因。
//
//  ── 为什么要走 login shell ──
//  Finder 启动的 GUI 进程 PATH 只有 `/usr/bin:/bin:/usr/sbin:/sbin`，
//  而 `dsh` / `node` / `npm` 通常在 `/opt/homebrew/bin` 或 `~/.nvm/...` 下。
//  `Process` 直接传裸名会失败 → 统一用 `/bin/zsh -lc` 让登录 shell 自己解析 PATH。
//

import Foundation

// ============================================================
// MARK: - 安装目标版本
// ============================================================

/// 安装哪个版本
enum DSHPluginInstallTarget: String, CaseIterable, Identifiable {
    /// 本应用实测过的版本（默认）
    case verified
    /// 作者最新发布（可能含未验证改动）
    case latest

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .verified: return L("Verified version %@", DSHPluginInstaller.verifiedVersion)
        case .latest:   return L("Latest version (latest)")
        }
    }

    /// 传给 npm 的版本后缀
    var versionSuffix: String {
        switch self {
        case .verified: return "@\(DSHPluginInstaller.verifiedVersion)"
        case .latest:   return "@latest"
        }
    }

    /// 风险提示（`verified` 无风险）
    var riskNote: String? {
        switch self {
        case .verified:
            return nil
        case .latest:
            // ⚠️ 不要把另一个插件（`@liuguangzhe/dsh-token-usage`）的历史写进来 ——
            //    「0.1.0 导致 DSH 启动崩溃」是那个插件的，与本插件无关。
            //    本插件的缺陷表现是**插件自己加载失败**（宿主不受影响）。
            return L("The latest release has not been verified by this app. Some versions of this plugin were marked deprecated on npm")
                + L(" (they failed to load in DSH Desktop) — if you run into trouble, roll back to ")
                + L("%@ by following the install guide.", DSHPluginInstaller.verifiedVersion)
        }
    }
}

// ============================================================
// MARK: - 执行结果
// ============================================================

/// 子进程执行结果（合并 stdout + stderr）
struct DSHInstallOutput: Equatable {
    var exitCode: Int32
    var output: String
    var timedOut: Bool
    /// 实际执行的命令行（失败时展示给用户，便于手动重跑）
    var command: String

    var succeeded: Bool { !timedOut && exitCode == 0 }

    /// 展示用：原始输出（空时给一句占位，避免看起来像 UI 坏了）
    var displayOutput: String {
        if timedOut { return L("The command timed out and was terminated (the install may still be running in the background — check in DSH later).") }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L("(the command produced no output)") : trimmed
    }
}

/// 安装后的验证结论
enum DSHPluginInstallVerification: Equatable {
    /// 包目录不存在 → 安装没落地
    case notInstalled
    /// 包装上了，但还没有缓存 → 必须重启 DSH 才会生效
    case waitingForRestart
    /// 包在 + 缓存可用 → 已生效
    case active

    var isSuccess: Bool { self != .notInstalled }

    var message: String {
        switch self {
        case .notInstalled:
            return L("The install did not take effect: the package is still missing from the profile.")
        case .waitingForRestart:
            return L("The plugin is installed, but you need to restart DSH before I can read its data (the loader tree is fixed at startup).")
        case .active:
            return L("The plugin is active and its data can be read.")
        }
    }
}

// ============================================================
// MARK: - 安装器
// ============================================================

enum DSHPluginInstaller {

    static var packageName: String { DSHUsageStatsSource.pluginPackageName }
    static var verifiedVersion: String { DSHUsageStatsSource.verifiedPluginVersion }

    /// ★ 必须走 login shell（见文件头说明）
    static let loginShell = "/bin/zsh"
    /// 安装超时 —— npm 联网安装可能较慢
    static let installTimeout: TimeInterval = 300
    /// 校验超时
    static let checkTimeout: TimeInterval = 120

    /// 本机 DSH_HOME
    static var dshHome: String { DSHUsageStatsSource.resolvedDSHHome }

    // ============================================================
    // MARK: 命令构造（纯函数，可单测）
    // ============================================================

    /// 安装命令：`dsh plugin --profile <profile> add "<包名>@<版本>"`
    ///
    /// ★ 不手动删旧版本 —— 交给包管理器处理（重复安装是幂等的）。
    static func installCommand(profile: String, target: DSHPluginInstallTarget) -> String {
        "dsh plugin --profile \(profile) add \"\(packageName)\(target.versionSuffix)\""
    }

    /// 卸载命令（仅供支持文档/排障提示，本应用不主动执行）
    static func uninstallCommand(profile: String) -> String {
        "dsh plugin --profile \(profile) remove \"\(packageName)\""
    }

    /// 回退到指定版本的命令
    static func revertCommand(profile: String, version: String = verifiedVersion) -> String {
        "dsh plugin --profile \(profile) add \"\(packageName)@\(version)\""
    }

    /// 作者官方安装器的二次校验命令 —— 安装失败时提示用户手动跑（我们不自作主张执行）
    static let secondaryCheckCommand = "npx --yes github:Ychris12138/dsh-usage-stats --check"

    // ============================================================
    // MARK: profile 枚举
    // ============================================================

    /// `~/.dsh/profiles/` 下的 profile 名（排除 `node_modules`，只取目录）
    ///
    /// ★ 必须让用户自己确认 profile：猜错会装进一个没被加载的 profile，
    ///   造成「安装成功但永远没数据」的假成功。
    static func availableProfiles(
        dshHome: String,
        fileManager: FileManager = .default
    ) -> [String] {
        let profilesDir = (dshHome as NSString).appendingPathComponent("profiles")
        guard let entries = try? fileManager.contentsOfDirectory(atPath: profilesDir) else {
            return []
        }
        var names: [String] = []
        for entry in entries where entry != "node_modules" && !entry.hasPrefix(".") {
            var isDirectory: ObjCBool = false
            let full = (profilesDir as NSString).appendingPathComponent(entry)
            guard fileManager.fileExists(atPath: full, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            names.append(entry)
        }
        return names.sorted()
    }

    /// 默认选中的 profile —— 有 `web` 选 `web`（最常用），否则取第一个
    static func defaultProfile(from profiles: [String]) -> String? {
        if profiles.contains("web") { return "web" }
        return profiles.first
    }

    // ============================================================
    // MARK: 验证（纯函数，可单测）
    // ============================================================

    /// 安装后验证：包目录在不在 + 缓存能不能用
    ///
    /// ⚠️ 缓存**必须等用户重启 DSH** 才可能出现 —— 所以「包在但没缓存」是正常的中间态，
    ///    不能当作失败，更不能谎称成功。
    static func verify(
        profile: String,
        dshHome: String,
        fileManager: FileManager = .default
    ) -> DSHPluginInstallVerification {
        let profileDir = ((dshHome as NSString).appendingPathComponent("profiles") as NSString)
            .appendingPathComponent(profile)
        let packagePath = DSHUsageStatsSource.pluginInstallPath(profileDir: profileDir)
        guard fileManager.fileExists(atPath: packagePath) else { return .notInstalled }

        let cachePath = DSHUsageStatsSource.cachePath(dshHome: dshHome)
        guard fileManager.fileExists(atPath: cachePath) else { return .waitingForRestart }
        return .active
    }

    // ============================================================
    // MARK: 执行
    // ============================================================

    /// 在登录 shell 里跑一条命令（阻塞，调用方负责放到后台线程）
    nonisolated static func run(
        command: String,
        timeout: TimeInterval = installTimeout
    ) -> DSHInstallOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShell)
        // -l：登录 shell（读 .zprofile，Homebrew PATH 通常在这里）
        // -c：执行后面的命令串
        process.arguments = ["-l", "-c", command]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // 避免交互式提示（npm/pnpm 在非 tty 下不会等输入）
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return DSHInstallOutput(
                exitCode: -1,
                output: L("Could not launch %@: %@", loginShell, error.localizedDescription),
                timedOut: false,
                command: command
            )
        }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            group.leave()
        }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return DSHInstallOutput(
                exitCode: -1, output: "", timedOut: true, command: command
            )
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return DSHInstallOutput(
            exitCode: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? "",
            timedOut: false,
            command: command
        )
    }
}
