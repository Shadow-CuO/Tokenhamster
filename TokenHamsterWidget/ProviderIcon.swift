//
//  ProviderIcon.swift
//  TokenHamsterWidget
//
//  AI 厂商品牌图标（Widget 侧精简版）—— 资源图优先，SF Symbol 兜底。
//
//  ★ 资源从主 App 的 `TokenHamster/ProviderIcons/*.png` **复制**过来
//    （Widget 是独立 target 拿不到对方 Resources）。文件名即资源名
//    （openai.png → NSImage(named: "openai")），丢入即生效，无需改代码。
//
//  ★ 品牌图统一按**模板图**（alpha 通道）渲染 → 单色、跟随组件外观；
//    这样深色/浅色背景下都不会出现「黑 logo 看不见 / 亮 logo 糊成一片」。
//    PNG 本身是纯白填充，靠 `.renderingMode(.template)` + `.foregroundStyle` 着色。
//

import SwiftUI
import AppKit

/// 品牌图标视图：资源目录有对应图片时显示图片，否则回退 SF Symbol。
struct ProviderIcon: View {

    let assetName: String?
    let symbolName: String
    var size: CGFloat = 14
    var tint: Color = .primary

    var body: some View {
        Group {
            if let assetName, let img = WidgetProviderIcons.brandImage(named: assetName, pointSize: size) {
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
// MARK: - 品牌图加载（按目标 pt 尺寸预置）
// ============================================================

enum WidgetProviderIcons {

    /// 品牌图缓存："name@pointSize" → 已预置尺寸的 NSImage 副本。
    /// ★ `nonisolated(unsafe)`：Widget 渲染实际只在主线程发生，这里省掉 actor 标注，
    ///   避免跨隔离域调用（Widget target 没有 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`）。
    nonisolated(unsafe) private static var sizedCache: [String: NSImage] = [:]

    /// 取品牌图：模板图 + natural size 预置为 pointSize。
    ///
    /// ⚠️ **必须预设 `size`，只靠 `.resizable()` + `.frame()` 不够**：
    ///   256×256 的 PNG 没有 DPI 元数据 → natural size = 256pt，
    ///   在 AppKit 接管的渲染路径（如菜单项）里会被按 natural size 绘制而溢出。
    ///   预置 size 后两条渲染路径尺寸都正确。
    static func brandImage(named name: String, pointSize: CGFloat) -> NSImage? {
        let key = "\(name)@\(pointSize)"
        if let cached = sizedCache[key] { return cached }
        guard let base = NSImage(named: name) else { return nil }
        // ★ 复制而非原地修改：`NSImage(named:)` 返回 AppKit 缓存的共享实例，
        //   同一份资源会以多种 pt 尺寸出现，改原图会互相污染。
        let copy = (base.copy() as? NSImage) ?? base
        copy.isTemplate = true
        copy.size = NSSize(width: pointSize, height: pointSize)
        sizedCache[key] = copy
        return copy
    }
}
