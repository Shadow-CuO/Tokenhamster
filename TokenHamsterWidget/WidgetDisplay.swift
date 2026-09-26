//
//  WidgetDisplay.swift
//  TokenHamsterWidget
//
//  纯展示映射 —— 标签文案、百分比格式、阈值配色、重置时间格式。
//
//  ★★ 标签**刻意不翻译**（用户决策）：
//    "5h" / "Week" / "Session" / "Weekly" 在中文界面里同样显示英文，
//    与主 App 额度卡片（裸 `Text(window.label)`）保持一致；计数单位
//    K/M/B/T 的先例同理（见主 App `DataComponents` 的计数规范）。
//    小组件里走 `L()` 的只有**错误态 / 空态 / 组件描述**三类文案。
//

import SwiftUI
import WidgetKit

// ============================================================
// MARK: - 标签
// ============================================================

/// 窗口标签风格：小尺寸用短标签，中尺寸用全称
enum QuotaLabelStyle: Equatable {
    case compact   // "5h"     / "Week"
    case full      // "Session" / "Weekly"

    /// 按组件尺寸选风格（小尺寸横向空间紧 → 用短标签）
    static func forFamily(_ family: WidgetFamily) -> QuotaLabelStyle {
        family == .systemSmall ? .compact : .full
    }

    /// 窗口标题文案（英文原文，不取词）
    func label(forKind kind: String) -> String {
        switch kind {
        case WidgetQuotaWindow.sessionKind: return self == .compact ? "5h" : "Session"
        case WidgetQuotaWindow.cycleKind:   return self == .compact ? "Week" : "Weekly"
        default:                            return kind   // 未知种类原样显示
        }
    }
}

// ============================================================
// MARK: - 尺寸
// ============================================================

/// 一套字号 / 尺度（小尺寸与中尺寸各一套）
struct QuotaMetrics {
    var icon: CGFloat
    var name: CGFloat
    var label: CGFloat
    var percent: CGFloat
    var barHeight: CGFloat
    var reset: CGFloat
    /// 标题行 ↔ 进度条 ↔ 时间行 之间的间距
    var barSpacing: CGFloat
    /// 一个窗口行 ↔ 下一个窗口行 / 标题 之间的间距
    var rowSpacing: CGFloat
    /// 双拼时两列之间的间距
    var columnSpacing: CGFloat
    /// 分段进度条的**目标单元宽度**（一格 + 一个间隙）。`nil` = 连续圆头条。
    /// ★ 这是「目标单元宽度」而不是「格数」—— 格数由可用宽度反推（见 `SegmentedQuotaBar`）：
    ///   中尺寸满宽 306pt → 20 格，双拼的每列 145pt → 10 格，
    ///   格子物理尺寸一致（固定 20 格的话双拼列会变成 4pt 细缝）。
    var segmentUnitWidth: CGFloat?
    /// 格与格之间的间隙（仅在 `segmentUnitWidth != nil` 时有意义）
    var segmentGap: CGFloat

    static func forStyle(_ style: QuotaLabelStyle) -> QuotaMetrics {
        switch style {
        case .compact:
            // ★ 字号/间距按「小尺寸 126×126pt 内容区能完整放下两行」反推
            //   （曾经 percent 22 / rowSpacing 9 → 内容 140pt，最后一行被裁掉）
            return QuotaMetrics(
                icon: 19, name: 14, label: 15, percent: 20,
                barHeight: 6, reset: 8.5, barSpacing: 3, rowSpacing: 4, columnSpacing: 12,
                segmentUnitWidth: nil, segmentGap: 0
            )
        case .full:
            // ★ 同上，按中尺寸 306×126pt 反推
            //   （曾经 percent 26 / label 17 / rowSpacing 12 → 内容 200pt，溢出 74pt）
            //   可用高度 126 − 内容 118 ≈ 8pt 余量，居中后上下各留一点。
            return QuotaMetrics(
                icon: 19, name: 16, label: 14, percent: 17,
                barHeight: 7, reset: 8.5, barSpacing: 3, rowSpacing: 6, columnSpacing: 16,
                segmentUnitWidth: 15, segmentGap: 3
            )
        }
    }
}

// ============================================================
// MARK: - 数值格式化 / 配色
// ============================================================

enum QuotaDisplay {

    /// 已用百分比文案，如 "99%"
    static func percentText(_ usedPercent: Double) -> String {
        "\(Int(usedPercent.rounded()))%"
    }

    /// 阈值配色（按**已用**百分比）：< 60% 绿 / 60–80% 橙 / ≥ 80% 红
    /// ★ 阈值是「已用」语义 —— 用得多才变红（与主 App 额度卡片的「剩余」语义相反）。
    static func percentColor(_ usedPercent: Double) -> Color {
        if usedPercent >= 80 { return .red }
        if usedPercent >= 60 { return .orange }
        return .green
    }

    /// 进度条填充比例（0…1）
    static func fraction(_ usedPercent: Double) -> Double {
        min(1, max(0, usedPercent / 100))
    }

    /// 重置时间的**绝对时刻**文案，如 "07/03 17:19 reset"；
    /// 该窗口没有重置时刻时返回 nil → 界面省略整行。
    ///
    /// ★ 用绝对时间而非倒计时：WidgetKit 不会连续重绘，倒计时只会冻在
    ///   时间线条目生成的那一刻，反而比绝对时间更容易误导。
    /// ★ 格式固定 `MM/dd HH:mm`（不随界面语言变），时区取本机当前时区。
    static func resetText(_ resetsAt: Date?) -> String? {
        guard let resetsAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter.string(from: resetsAt) + " reset"
    }
}
