//
//  Localization.swift
//  TokenHamster
//
//  运行时双语文案 + 用户偏好（语言 / 币种）。
//
//  ★ 为什么不用 String Catalog（.xcstrings）/ .lproj：
//    运行期切换必须在 SwiftUI 之外也生效（服务层错误文案、NSMenu、Widget、测试），
//    而 `\.locale` 环境值只管 SwiftUI 的 Text；`.lproj` 资源在 Xcode16 的
//    `PBXFileSystemSynchronizedRootGroup` 下是否被当作本地化资源也不确定。
//    这里用一张 Swift 侧的表 + 锁保护的当前语言快照，App / Widget / 测试同源。
//
//  ★ 英文不需要表：英文态把 key 原样返回 —— key 就是源码里的英文原文，
//    所以英文文案的唯一来源是源码本身（见 `LocalizationTable.swift`）。
//

import Combine
import Foundation

// ============================================================
// MARK: - 语言偏好
// ============================================================

/// 界面语言偏好。`.system` = 跟随系统首选语言。
enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case system
    case chinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    /// 选择器显示名。
    /// ★ 具体语言用**自称**（不随界面语言变），用户不必懂当前界面语言也能认出来。
    var displayName: String {
        switch self {
        case .system:  return Localization.t("Follow System")
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }

    /// 把偏好解析成具体语言。
    /// `.system` → 系统首选（`zh*` → 中文，其余 → 英文）
    static func resolved(_ preference: AppLanguage,
                         preferredLanguages: [String]? = nil) -> AppLanguage {
        guard preference == .system else { return preference }
        let languages = preferredLanguages ?? Locale.preferredLanguages
        guard let first = languages.first?.lowercased() else { return .english }
        return first.hasPrefix("zh") ? .chinese : .english
    }
}

// ============================================================
// MARK: - 币种偏好
// ============================================================

/// 展示币种偏好。
/// ★ **只作「数据源未提供币种」时的默认值，不做汇率换算**：
///   各数据源自带币种（bigmodel=CNY、Cursor=USD…）照旧显示。
enum CurrencyPreference: String, CaseIterable, Codable, Identifiable {
    case cny
    case usd

    var id: String { rawValue }

    /// ISO 代码（数据模型 `currency` 字段的取值）
    var code: String {
        switch self {
        case .cny: return "CNY"
        case .usd: return "USD"
        }
    }

    var symbol: String {
        switch self {
        case .cny: return "¥"
        case .usd: return "$"
        }
    }

    /// 设置页展示名 —— ★ 只写 ISO 代码（`CNY` / `USD`），
    /// 不写「人民币 / Chinese Yuan」这类全称，也不必重复符号。
    /// ISO 代码本身是国际通用写法，中文界面下也无需翻译。
    var displayName: String { code }

    /// 首启默认：系统地区为中国大陆 → CNY，其余 → USD
    static func systemDefault(region: String? = nil) -> CurrencyPreference {
        let code = region ?? Locale.current.region?.identifier ?? ""
        return code.uppercased() == "CN" ? .cny : .usd
    }
}

// ============================================================
// MARK: - 运行期文案表
// ============================================================

/// 取词入口 —— 线程安全（服务层会在 `Task.detached` 里拼错误文案）。
enum Localization {

    /// 语言 / 币种偏好的存储键（同一份同时写 App Group 供 Widget 读取）
    nonisolated static let languageKey = "app_language"
    nonisolated static let currencyKey = "app_currency"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedPreference: AppLanguage = .system
    nonisolated(unsafe) private static var storedLanguage: AppLanguage = .english

    /// 当前生效语言（永不返回 `.system`）
    static var language: AppLanguage {
        lock.lock(); defer { lock.unlock() }
        return storedLanguage
    }

    /// 用户选择的语言偏好（可能为 `.system`）
    static var languagePreference: AppLanguage {
        lock.lock(); defer { lock.unlock() }
        return storedPreference
    }

    /// 应用语言偏好（解析 + 缓存）
    static func apply(preference: AppLanguage, preferredLanguages: [String]? = nil) {
        let resolved = AppLanguage.resolved(preference, preferredLanguages: preferredLanguages)
        lock.lock()
        storedPreference = preference
        storedLanguage = resolved
        lock.unlock()
    }

    /// 取词：英文 → 原样返回；中文 → 查表，缺条目回退英文原文（绝不显示空串）
    static func t(_ key: String) -> String {
        t(key, language: language)
    }

    /// 取词 + 按顺序替换 `%@` 占位。
    ///
    /// ★ 刻意不用 `String(format:)`：
    ///   - `%@` 逐个替换天然容忍「译文少一个占位」（如英文复数 "day%@s" 中文只用一个）
    ///   - 不需要调用点保证 `CVarArg` 类型（`Int` 传给 `%@` 是未定义行为）
    ///   - 译文里出现裸 `%` 不会被当成格式符
    static func t(_ key: String, _ args: [Any]) -> String {
        t(key, args, language: language)
    }

    // ---- 纯函数版本：**不读也不改全局状态**（测试 / 预览用） ----

    /// 指定语言取词
    static func t(_ key: String, language: AppLanguage) -> String {
        guard language == .chinese else { return key }
        return LocalizationTable.zh[key] ?? key
    }

    /// 指定语言取词 + 占位替换
    static func t(_ key: String, _ args: [Any], language: AppLanguage) -> String {
        var text = t(key, language: language)
        for arg in args {
            guard let range = text.range(of: "%@") else { break }
            text.replaceSubrange(range, with: "\(arg)")
        }
        return text
    }
}

/// 取词（英文原文即 key）。插值文案用 `%@`：`L("%@ tokens total", count)`
func L(_ key: String) -> String { Localization.t(key) }

/// 取词 + 占位替换
func L(_ key: String, _ args: Any...) -> String { Localization.t(key, args) }

// ============================================================
// MARK: - 偏好存储（SwiftUI 入口）
// ============================================================

/// 用户偏好（语言 / 币种）—— 持久化 + 变更通知。
/// ⚠️ 创建 `shared`（或在 App 启动时读一次）才能让启动界面用上已保存的语言。
@MainActor
final class AppSettingsStore: ObservableObject {

    static let shared = AppSettingsStore()

    /// 是否跑在测试宿主里。
    /// ★ 测试宿主会完整启动 App（含 `applicationDidFinishLaunching`）→ 若把**用户真实偏好**
    ///   写进全局语言，断言英文文案的既有测试会在中文系统上失败（本机就是 zh-Hans-CN）。
    ///   测试里请显式 `Localization.apply(preference:)` / `setLanguage(_:)` 切换。
    static let isRunningTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()

    /// 语言偏好（设置页绑定）
    @Published private(set) var language: AppLanguage
    /// 当前生效语言（`.system` 已解析）—— 视图用它触发重建
    @Published private(set) var resolvedLanguage: AppLanguage
    /// 币种偏好（仅作「未提供币种」时的默认值）
    @Published private(set) var currency: CurrencyPreference

    private let defaults: UserDefaults
    /// App Group suite（Widget 读同一份偏好；见 `syncToSharedDefaults`）
    private let sharedDefaults: UserDefaults?

    init(defaults: UserDefaults = .standard,
         sharedDefaults: UserDefaults? = UserDefaults(suiteName: AppConstants.appGroupSuiteName),
         preferredLanguages: [String]? = nil) {
        self.defaults = defaults
        self.sharedDefaults = sharedDefaults

        let savedLanguage = defaults.string(forKey: Localization.languageKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
        self.language = savedLanguage
        self.resolvedLanguage = AppLanguage.resolved(savedLanguage, preferredLanguages: preferredLanguages)

        if let raw = defaults.string(forKey: Localization.currencyKey),
           let saved = CurrencyPreference(rawValue: raw) {
            self.currency = saved
        } else {
            self.currency = CurrencyPreference.systemDefault()
        }

        // ★ 测试宿主不套用真实偏好 —— 见 `isRunningTests`
        if !Self.isRunningTests {
            Localization.apply(preference: savedLanguage, preferredLanguages: preferredLanguages)
        }
        syncToSharedDefaults()
    }

    func setLanguage(_ new: AppLanguage) {
        guard new != language else { return }
        language = new
        resolvedLanguage = AppLanguage.resolved(new)
        Localization.apply(preference: new)
        defaults.set(new.rawValue, forKey: Localization.languageKey)
        syncToSharedDefaults()
    }

    func setCurrency(_ new: CurrencyPreference) {
        guard new != currency else { return }
        currency = new
        defaults.set(new.rawValue, forKey: Localization.currencyKey)
        syncToSharedDefaults()
    }

    /// 写入 App Group（兼容旧的共享途径）+ widget 沙箱容器里的语言文件。
    /// ★ 两个进程**都未开沙箱**的假设已作废：widget extension 因 `pkd` 要求必须沙箱
    ///   （见 `WidgetBridge.swift` 顶部说明），读不到 suite plist ——
    ///   所以真正生效的是后面那个文件（`WidgetSnapshotStore.writeLanguage`）。
    ///   suite 写入保留：无害，且 `LocalizationTests` 依赖这条链路的键名。
    private func syncToSharedDefaults() {
        sharedDefaults?.set(language.rawValue, forKey: Localization.languageKey)
        sharedDefaults?.set(currency.rawValue, forKey: Localization.currencyKey)
        WidgetSnapshotStore.writeLanguage(language.rawValue)
    }
}
