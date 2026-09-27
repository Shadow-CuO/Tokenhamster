//
//  ProviderIcons.swift
//  TokenHamster
//
//  Created by Oscar Sun on 2026/8/10.
//
//  AI 厂商品牌图标 — 资源图优先（ProviderIcons/ 目录），SF Symbol 兜底。
//  ProviderIcons/ 下的 png 随 App 打包（扁平复制到 Resources 根目录），
//  文件名即资源名（如 openai.png → NSImage(named: "openai")），丢入即生效，无需改代码。
//  ★ 品牌图统一按**模板图**（alpha 通道）渲染 → 单色、跟随主题明暗，不用品牌原色；
//    这样深色/浅色模式下都不会出现「黑 logo 看不见 / 亮 logo 糊成一片」。
//

import SwiftUI
import AppKit

/// 品牌图标视图：资源目录有对应图片时显示图片，否则回退 SF Symbol。
/// - assetName: 资源图名（ProviderIcons/ 下的文件名，如 "openai"；nil = 无图）
/// - symbolName: 回退 SF Symbol 名
/// - tint: 着色 —— 品牌图与 SF Symbol 同色（品牌图按模板渲染，单色跟随主题）
struct ProviderIcon: View {

    let assetName: String?
    let symbolName: String
    var size: CGFloat = 14
    var tint: Color = .primary

    var body: some View {
        Group {
            if let assetName, let img = ProviderIcons.brandImage(named: assetName, pointSize: size) {
                Image(nsImage: img)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: symbolName)
                    .font(.system(size: size * 0.9, weight: .medium))
            }
        }
        .foregroundStyle(tint)
        .frame(width: size, height: size)
    }
}

// ============================================================
// MARK: - APIType → 品牌图标映射
// ============================================================

extension APIType {

    /// 品牌资源图名（ProviderIcons/ 下的文件名；nil = 无图，回退 SF Symbol）
    var brandAssetName: String? {
        switch self {
        case .openAI:           return "openai"
        case .deepseek:         return "deepseek"
        case .kimi:             return "kimi"
        case .anthropic:        return "claude"
        case .gemini:           return "gemini"
        case .openRouter:       return "openrouter"
        case .siliconFlow:      return "siliconflow"
        case .custom:           return nil
        case .copilot:          return "copilot"
        case .localLog:         return nil      // 由 AgentProvider 注册表按类型指定
        }
    }

    /// 回退 SF Symbol 名
    var brandSymbolName: String {
        switch self {
        case .openAI:           return "brain.head.profile"
        case .deepseek:         return "diamond.fill"
        case .kimi:             return "moon.stars.fill"
        case .anthropic:        return "circle.hexagongrid.fill"
        case .gemini:           return "sparkles"
        case .openRouter:       return "arrow.triangle.branch"
        case .siliconFlow:      return "cloud.fill"
        case .custom:           return "gearshape.2.fill"
        case .copilot:          return "chevron.left.forwardslash.chevron.right"
        case .localLog:         return "terminal.fill"
        }
    }
}

enum ProviderIcons {

    /// Agent / 订阅工具类型 → 品牌资源图名（由 AgentProvider 注册表提供）
    static func assetName(for provider: AgentProvider) -> String? {
        provider.spec.assetName
    }

    // ============================================================
    // MARK: - 品牌图加载（按目标 pt 尺寸预置）
    // ============================================================

    /// 品牌图缓存："name@pointSize" → 已预置尺寸的 NSImage 副本
    @MainActor
    private static var sizedCache: [String: NSImage] = [:]

    /// 取品牌图：模板图 + natural size 预置为 pointSize。
    ///
    /// ⚠️ **必须预设 `size`，只靠 `.resizable()` + `.frame()` 不够**：
    /// macOS 上 `Picker(.menu)` 的菜单项由 AppKit 接管渲染，它会拿 `Image(nsImage:)`
    /// 底层的 NSImage **按 natural size 绘制**，SwiftUI 的尺寸约束在那条路径上不生效。
    /// 而 256×256 的 PNG 没有 DPI 元数据 → natural size = 256pt
    /// → 12pt 的图标会按 256pt 画出来，溢出并盖住整个面板。
    /// 把 `size` 设成目标 pt 后，SwiftUI 与 AppKit 两条路径尺寸都正确。
    @MainActor
    static func brandImage(named name: String, pointSize: CGFloat) -> NSImage? {
        let key = "\(name)@\(pointSize)"
        if let cached = sizedCache[key] { return cached }
        guard let base = NSImage(named: name) else { return nil }
        let sized = sizedCopy(of: base, pointSize: pointSize)
        sizedCache[key] = sized
        return sized
    }

    /// 复制一份并预置点尺寸（同时标记为模板图）。
    /// ★ 复制而非原地修改：`NSImage(named:)` 返回的是 AppKit 缓存的**共享实例**，
    ///   而同一份资源会以多种 pt 尺寸出现（12/13/17），改原图会互相污染。
    static func sizedCopy(of base: NSImage, pointSize: CGFloat) -> NSImage {
        let copy = (base.copy() as? NSImage) ?? base
        copy.isTemplate = true
        copy.size = NSSize(width: pointSize, height: pointSize)
        return copy
    }
}

// ============================================================
// MARK: - 模型名 → 厂商品牌识别
// ============================================================

/// 厂商品牌标记 — 用于按**模型名**识别 logo（MODELS 栏逐行显示厂商标）。
/// 例：Codex 数据源解析出的模型里，`gpt-5.6` 显示 OpenAI 标、`glm-4.6` 显示 Z.ai 标，
/// 而不是统统挂数据源自己的 logo。
/// ★ `assetName` 必须与 `ProviderIcons/` 下的文件名一致。
enum BrandMark: String, CaseIterable {

    case openAI, anthropic, google, deepSeek, moonshot, zai
    case xai, qwen, mistral, llama, ollama, copilot, cursor

    /// 品牌资源图名（ProviderIcons/ 下的文件名）
    var assetName: String {
        switch self {
        case .openAI:    return "openai"
        case .anthropic: return "claude"
        case .google:    return "gemini"
        case .deepSeek:  return "deepseek"
        case .moonshot:  return "kimi"
        case .zai:       return "zai"
        case .xai:       return "xai"
        case .qwen:      return "qwen"
        case .mistral:   return "mistral"
        case .llama:     return "meta"
        case .ollama:    return "ollama"
        case .copilot:   return "copilot"
        case .cursor:    return "cursor"
        }
    }

    /// 缺图时的 SF Symbol 回退
    var symbolName: String {
        switch self {
        case .openAI:    return "brain.head.profile"
        case .anthropic: return "circle.hexagongrid.fill"
        case .google:    return "sparkles"
        case .deepSeek:  return "diamond.fill"
        case .moonshot:  return "moon.stars.fill"
        case .zai:       return "diamond.fill"
        case .xai:       return "xmark"
        case .qwen:      return "cloud.fill"
        case .mistral:   return "wind"
        case .llama:     return "hare.fill"
        case .ollama:    return "desktopcomputer"
        case .copilot:   return "chevron.left.forwardslash.chevron.right"
        case .cursor:    return "cursorarrow.rays"
        }
    }

    /// 从模型名 / 厂商名识别品牌（大小写不敏感）。
    /// ★ 按非字母数字切词后**逐词匹配** —— 避免 `gpt-4o` 被当成 o 系列、
    ///   `codestral` 被当成 codex 之类的子串误判。
    static func detect(in text: String) -> BrandMark? {
        let tokens = text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        for token in tokens {
            if let mark = match(token) { return mark }
        }
        return nil
    }

    /// 单词级匹配规则（先具体后笼统；首个命中即返回）
    private static func match(_ token: String) -> BrandMark? {
        // Anthropic：claude-* / 裸 sonnet·opus·haiku（Claude Code 日志里常见）
        if token.hasPrefix("claude") || token == "sonnet" || token == "opus" || token == "haiku" {
            return .anthropic
        }
        // OpenAI：gpt-* / o1·o3·o4 推理系列 / codex / davinci
        if token.hasPrefix("gpt") || token.hasPrefix("davinci") { return .openAI }
        if token == "o1" || token == "o3" || token == "o4" { return .openAI }
        if token.hasPrefix("codex") { return .openAI }
        // Google
        if token.hasPrefix("gemini") || token.hasPrefix("gemma") || token.hasPrefix("palm") { return .google }
        // DeepSeek
        if token.hasPrefix("deepseek") { return .deepSeek }
        // Moonshot / Kimi
        if token.hasPrefix("kimi") || token.hasPrefix("moonshot") { return .moonshot }
        // Z.ai / 智谱 GLM
        if token.hasPrefix("glm") || token.hasPrefix("chatglm") || token.hasPrefix("zhipu") { return .zai }
        // xAI Grok
        if token.hasPrefix("grok") { return .xai }
        // 阿里通义千问
        if token.hasPrefix("qwen") || token.hasPrefix("tongyi") { return .qwen }
        // Mistral 系
        if token.hasPrefix("mistral") || token.hasPrefix("mixtral")
            || token.hasPrefix("codestral") || token.hasPrefix("devstral") { return .mistral }
        // Meta Llama
        if token.hasPrefix("llama") { return .llama }
        // 本地运行时 / 工具
        if token.hasPrefix("ollama") { return .ollama }
        if token.hasPrefix("copilot") { return .copilot }
        if token.hasPrefix("cursor") { return .cursor }
        return nil
    }
}
