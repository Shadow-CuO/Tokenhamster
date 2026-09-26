//
//  QuotaWidgetViews.swift
//  TokenHamsterWidget
//
//  小组件卡片视图 —— 单源（图 1）/ 双拼（图 2）两套排版。
//
//  版面（每行 = 一个额度窗口）：
//  ```
//  [logo] Codex
//  Session                    86%
//  ▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▯▯▯   ← 一格一格（中尺寸 20 格）
//  🕐 09/26 22:47 reset
//  Weekly                     98%
//  ▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮
//  🕐 10/01 19:47 reset
//  ```
//  ★ 大号数字与进度条都表示**已用**百分比；
//    配色阈值 < 60% 绿 / 60–80% 橙 / ≥ 80% 红。
//  ★ 标签与重置时间都**不取词**（用户决策，见 WidgetDisplay.swift 顶部）。
//

import SwiftUI
import WidgetKit

// ============================================================
// MARK: - 进度条
// ============================================================

/// 圆头连续进度条：底色槽 + 按已用比例填充的前景（宽度 0 时前景自动不可见）
struct QuotaProgressBar: View {

    let fraction: Double
    let color: Color
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.12))
                Capsule(style: .continuous)
                    .fill(color)
                    .frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: height)
    }
}

// ============================================================
// MARK: - 分段进度条（参考样式图）
// ============================================================

/// 一格一格的进度条（参考样式图）：把可用宽度等分成若干格，
/// 已用比例决定**点亮几格**，未点亮的格是暗淡轨道。
///
/// ★ 格数由**可用宽度**反推（`unitWidth` = 一格 + 一个间隙的目标宽度）：
///   这样同一套参数下，中尺寸满宽 ≈20 格、双拼的每列 ≈10 格，
///   格子物理尺寸保持一致 —— 若固定格数，双拼列会变成 4pt 的细缝。
///
/// ★ 点亮格数按**向下取整**（见 `litCount`）。
struct SegmentedQuotaBar: View {

    let fraction: Double
    let color: Color
    let height: CGFloat
    /// 一格 + 一个间隙的目标宽度（越小格数越多）
    let unitWidth: CGFloat
    let gap: CGFloat

    /// 该宽度下分几格（至少 3 格，避免极窄时只剩一两块）
    static func segmentCount(forWidth width: CGFloat, unitWidth: CGFloat) -> Int {
        guard unitWidth > 0, width > 0 else { return 1 }
        return max(3, Int((width / unitWidth).rounded()))
    }

    /// 点亮格数 —— **向下取整**（86% × 20 格 → 17 格，98% → 19 格留一格暗的）。
    /// ★ 不用四舍五入：那会让 98% 显示成满格，看着像额度已用尽。
    ///   向下取整偏保守，且与样例图一致。
    /// ★ 只要用了（fraction > 0）就至少亮一格 —— 否则 3% 会是一条空条，
    ///   与旁边的数字对不上。
    static func litCount(fraction: Double, segmentCount: Int) -> Int {
        guard fraction > 0, segmentCount > 0 else { return 0 }
        let lit = Int(fraction * Double(segmentCount))
        return min(segmentCount, max(1, lit))
    }

    var body: some View {
        GeometryReader { geo in
            // 等分：总宽减去所有间隙后平均分给每格
            let count = Self.segmentCount(forWidth: geo.size.width, unitWidth: unitWidth)
            let cellWidth = max(1, (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            let lit = Self.litCount(fraction: fraction, segmentCount: count)
            HStack(spacing: gap) {
                ForEach(0..<count, id: \.self) { index in
                    RoundedRectangle(cornerRadius: min(3, cellWidth * 0.3), style: .continuous)
                        .fill(index < lit ? color : Color.primary.opacity(0.12))
                        .frame(width: cellWidth)
                }
            }
        }
        .frame(height: height)
    }
}

// ============================================================
// MARK: - 单个额度窗口行
// ============================================================

struct QuotaRowView: View {

    let window: WidgetQuotaWindow
    let style: QuotaLabelStyle
    let metrics: QuotaMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.barSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(style.label(forKind: window.kind))
                    .font(.system(size: metrics.label, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(QuotaDisplay.percentText(window.usedPercent))
                    .font(.system(size: metrics.percent, weight: .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            // 进度条：中尺寸走「一格一格」（见 QuotaMetrics.segmentUnitWidth）
            if let unitWidth = metrics.segmentUnitWidth {
                SegmentedQuotaBar(
                    fraction: QuotaDisplay.fraction(window.usedPercent),
                    color: QuotaDisplay.percentColor(window.usedPercent),
                    height: metrics.barHeight,
                    unitWidth: unitWidth,
                    gap: metrics.segmentGap
                )
            } else {
                QuotaProgressBar(
                    fraction: QuotaDisplay.fraction(window.usedPercent),
                    color: QuotaDisplay.percentColor(window.usedPercent),
                    height: metrics.barHeight
                )
            }

            if let reset = QuotaDisplay.resetText(window.resetsAt) {
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                        .font(.system(size: metrics.reset * 0.9, weight: .semibold))
                    Text(reset)
                        .font(.system(size: metrics.reset))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

// ============================================================
// MARK: - 单列（一个数据源）
// ============================================================

/// 一个数据源的一列：品牌图标 + 名称，下面跟着它的额度窗口行（最多两行）。
struct QuotaColumnView: View {

    let provider: WidgetQuotaProvider
    let style: QuotaLabelStyle

    private var metrics: QuotaMetrics { .forStyle(style) }

    /// ★ 拉取失败时**只保留首行**（最重要的那个窗口）：
    ///   列高有硬上限（中尺寸可用高度 ≈126pt），两行 + 错误行会溢出把标题裁掉。
    ///   失败时的数据本就是上次的陈旧值，少一行 + 明确的错误提示更诚实。
    private var rows: [WidgetQuotaWindow] {
        provider.isFailed ? Array(provider.windows.prefix(1)) : provider.windows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            // ★ 数据部分整块置灰（拉取失败时保留上次数据，用灰度表达「可能过期」）；
            //   Group + opacity 会逐个作用于子视图，所以这里用真实容器承载。
            VStack(alignment: .leading, spacing: metrics.rowSpacing) {
                HStack(spacing: 7) {
                    ProviderIcon(
                        assetName: provider.assetName,
                        symbolName: provider.symbolName,
                        size: metrics.icon,
                        tint: .primary
                    )
                    Text(provider.name)
                        .font(.system(size: metrics.name, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                ForEach(rows) { window in
                    QuotaRowView(window: window, style: style, metrics: metrics)
                }
            }
            .opacity(provider.isFailed ? 0.4 : 1)

            if provider.isFailed {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: metrics.reset * 0.9, weight: .semibold))
                    Text(L("Update failed"))
                        .font(.system(size: metrics.reset, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.red)
            }
        }
    }
}

// ============================================================
// MARK: - 空态
// ============================================================

/// 主 App 里还没有任何可用数据源（或载荷还没写过）
struct EmptyQuotaView: View {

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .font(.system(size: 22))
            Text(L("Open TokenHamster to add a data source"))
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// ============================================================
// MARK: - 卡片
// ============================================================

/// 单源卡片（小尺寸 / 中尺寸）：只有一个数据源，整体垂直居中
struct SingleQuotaCardView: View {

    let provider: WidgetQuotaProvider?
    let style: QuotaLabelStyle

    var body: some View {
        if let provider {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                QuotaColumnView(provider: provider, style: style)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            EmptyQuotaView()
        }
    }
}

/// 双拼卡片（中尺寸）：两列顶对齐，各占一半宽度；
/// 只配了一个源时该列占满整宽（避免右半边空着看着像坏了）
struct DualQuotaCardView: View {

    let providers: [WidgetQuotaProvider]
    let style: QuotaLabelStyle

    private var metrics: QuotaMetrics { .forStyle(style) }

    var body: some View {
        if providers.isEmpty {
            EmptyQuotaView()
        } else if providers.count == 1, let only = providers.first {
            QuotaColumnView(provider: only, style: style)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .top, spacing: metrics.columnSpacing) {
                column(providers[0])
                column(providers[1])
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func column(_ provider: WidgetQuotaProvider) -> some View {
        QuotaColumnView(provider: provider, style: style)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// ============================================================
// MARK: - 组件入口视图
// ============================================================

/// 单源组件入口 —— 按尺寸选标签风格与字号
struct SingleQuotaEntryView: View {

    @Environment(\.widgetFamily) private var family

    let entry: QuotaEntry

    var body: some View {
        SingleQuotaCardView(
            provider: entry.providers.first,
            style: QuotaLabelStyle.forFamily(family)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 双拼组件入口
struct DualQuotaEntryView: View {

    @Environment(\.widgetFamily) private var family

    let entry: QuotaEntry

    var body: some View {
        DualQuotaCardView(
            providers: entry.providers,
            style: QuotaLabelStyle.forFamily(family)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
