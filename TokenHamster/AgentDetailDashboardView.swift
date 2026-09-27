//
//  AgentDetailDashboardView.swift
//  TokenHamster
//
//  Created by Oscar Sun on 2026/7/16.
//
//  二级详情页：点击 AGENTS 卡片进入，展示单个数据源的
//  额度 / 模型排行 / 7 日趋势 / 活动热力图（数据随轮询自动更新）
//

import SwiftUI

struct AgentDetailDashboardView: View {

    @ObservedObject var dashVM: DashboardViewModel
    @Environment(\.colorScheme) private var colorScheme

    /// 数据源 ID（与 APIConfigItem.id 一致）
    let sourceID: String

    /// 返回上一级
    var onBack: (() -> Void)? = nil

    /// 当前数据源快照 — 随轮询刷新自动更新
    private var snap: AgentSnapshot? {
        dashVM.agentSnapshots.first { $0.id == sourceID }
    }

    /// ★ 观察语言/币种偏好 — 切换语言时本页文案同步重建
    @ObservedObject private var settingsStore = AppSettingsStore.shared

    /// 自适应外观
    private var a: DashboardAppearance {
        var v = dashVM.appearance
        v.isDark = (colorScheme == .dark)
        return v
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: a.sectionGap) {
                    topBar

                    if let snap {
                        quotaSection(snap)

                        if !snap.modelUsages.isEmpty {
                            modelsSection(snap)
                        }

                        if !snap.dailyHeatmap.isEmpty {
                            activitySection(snap)
                        }

                        if snap.sevenDayTrend.count > 1 {
                            trendSection(snap)
                        }
                    } else {
                        // 数据源已删除/停用
                        Text(L("This data source no longer exists"))
                            .font(.system(size: a.fontQuotaName))
                            .foregroundStyle(a.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 60)
                    }
                }
                .padding(.horizontal, a.paddingOuter)
                .padding(.bottom, a.paddingOuter)
                .padding(.top, a.dragHandleZoneHeight)
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)

            // 顶部拖拽区
            dragHandle
        }
        .frame(width: a.panelWidth, height: a.panelHeight)
        .glassEffect(in: RoundedRectangle(cornerRadius: a.cornerRadius, style: .continuous))
        .compositingGroup()
        .mask {
            RoundedRectangle(cornerRadius: a.cornerRadius, style: .continuous)
        }
    }

    private var dragHandle: some View {
        DashboardDragHandle()
            .frame(width: a.panelWidth, height: a.dragHandleZoneHeight)
    }

    // ============================================================
    // MARK: - 顶栏（返回 + 名称 + 状态灯 + 更新时间）
    // ============================================================

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { onBack?() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: a.fontSectionLabel, weight: .semibold))
                    .foregroundStyle(a.accent)
            }
            .buttonStyle(.plain)

            Text(snap?.name ?? L("Details"))
                .font(.system(size: a.fontSectionLabel, weight: .semibold))
                .foregroundStyle(a.textHeading)
                .lineLimit(1)

            Spacer()

            if let snap {
                Circle()
                    .fill(statusColor(snap.status))
                    .frame(width: 8, height: 8)
                if let t = snap.lastUpdated {
                    Text(t.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: a.fontQuotaReset))
                        .foregroundStyle(a.textTertiary)
                }
            }
        }
    }

    // ============================================================
    // MARK: - 额度
    // ============================================================

    private func quotaSection(_ snap: AgentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(L(snap.quotaText))
                    .font(.system(size: a.fontTotalTokens, weight: .bold))
                    .foregroundStyle(a.textPrimary)
                // 百分比制额度已含 % 后缀，不重复显示单位
                if snap.quotaUnit != "%" {
                    Text(snap.quotaUnit)
                        .font(.system(size: a.fontQuotaPercent, weight: .medium))
                        .foregroundStyle(a.textSecondary)
                }
                Spacer()
                Text(snap.leftPercentText)
                    .font(.system(size: a.fontQuotaPercent, weight: .semibold))
                    .foregroundStyle(snap.status == .ok ? a.accent : statusColor(snap.status))
            }

            // 额度进度条
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: a.progressHeight / 2)
                    .fill(a.progressBg)
                    .frame(height: a.progressHeight)
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: a.progressHeight / 2)
                        .fill(snap.status == .ok ? a.accent : statusColor(snap.status))
                        .frame(width: geo.size.width * snap.usedRatio, height: a.progressHeight)
                }
            }
            .frame(height: a.progressHeight)

            // 底部信息行：重置时间 / 累计 tokens（额度板块不显示金额）
            HStack(spacing: 6) {
                if !snap.resetTimeString.isEmpty {
                    // ★ 哨兵文案只在渲染处取词，模型层保持英文原值
                    Label(L(snap.resetTimeString), systemImage: "clock.arrow.circlepath")
                        .font(.system(size: a.fontQuotaReset))
                        .foregroundStyle(a.textTertiary)
                }
                Spacer()
                Text(L("%@ tokens total", snap.totalTokens.formattedTokenCount))
                    .font(.system(size: a.fontQuotaReset))
                    .foregroundStyle(a.textTertiary)
            }

            if snap.status != .ok, !snap.errorMessage.isEmpty {
                Text(snap.errorMessage)
                    .font(.system(size: a.fontQuotaReset))
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(a.progressBg.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // ============================================================
    // MARK: - 模型排行
    // ============================================================

    private func modelsSection(_ snap: AgentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(icon: "cpu.fill", title: "MODELS")
            VStack(spacing: 4) {
                ForEach(snap.modelUsages) { model in
                    modelRow(model)
                }
            }
        }
    }

    // ============================================================
    // MARK: - 活动热力图
    // ============================================================

    private func activitySection(_ snap: AgentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionHeader(icon: "calendar", title: "ACTIVITY")
                Spacer()
                Text(L("Active %@ day%@", snap.activityDays, snap.activityDays == 1 ? "" : "s"))
                    .font(.system(size: a.fontActiveDays, weight: .medium))
                    .foregroundStyle(a.accent)
            }
            heatmapGrid(snap.dailyHeatmap)
        }
    }

    // ============================================================
    // MARK: - 7 日趋势
    // ============================================================

    private func trendSection(_ snap: AgentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionHeader(icon: "chart.line.uptrend.xyaxis", title: "TREND")
                Spacer()
                Text(L("Peak %@", peakFormatted(snap)))
                    .font(.system(size: a.fontPeak, weight: .medium))
                    .foregroundStyle(a.accent)
            }
            trendChart(snap.sevenDayTrend)
                .frame(height: a.trendChartHeight)
        }
    }

    private func peakFormatted(_ snap: AgentSnapshot) -> String {
        formatCompactCount(Double(snap.sevenDayTrend.max() ?? 0))
    }

    // ============================================================
    // MARK: - 公共组件
    // ============================================================

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: a.fontSectionIcon))
                .foregroundStyle(a.textHeading)
            Text(title)
                .font(.system(size: a.fontSectionLabel, weight: .semibold))
                .foregroundStyle(a.textHeading)
                .tracking(1)
        }
    }

    private func modelRow(_ model: ModelUsageItem) -> some View {
        HStack(spacing: 4) {
            Text(model.modelName)
                .font(.system(size: a.fontModelName, weight: .medium))
                .foregroundStyle(a.textPrimary)
                .lineLimit(1)
                .frame(width: a.modelNameWidth, alignment: .leading)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: a.modelBarHeight / 2)
                    .fill(a.progressBg)
                    .frame(height: a.modelBarHeight)
                RoundedRectangle(cornerRadius: a.modelBarHeight / 2)
                    .fill(a.accent.opacity(0.7))
                    .frame(width: a.modelBarWidth * model.usagePercent, height: a.modelBarHeight)
            }
            .frame(width: a.modelBarWidth, height: a.modelBarHeight)

            Text(model.tokenFormatted)
                .font(.system(size: a.fontModelValue, weight: .semibold))
                .foregroundStyle(a.textPrimary)
                .frame(width: a.modelValueWidth, alignment: .trailing)

            Text(model.percentText)
                .font(.system(size: a.fontModelPercent))
                .foregroundStyle(a.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: a.modelQuotaWidth, alignment: .trailing)

            // 模型级额度（官方接口）：百分比 + 颜色告警（>=80% 红 / >=50% 橙 / 其余 accent）
            if let used = model.quotaUsed, let total = model.quotaTotal, total > 0 {
                Text("\(used)%")
                    .font(.system(size: a.fontModelPercent, weight: .semibold))
                    .foregroundStyle(quotaColor(Double(used)))
                    .frame(width: a.modelQuotaWidth, alignment: .trailing)
            }
        }
    }

    /// 模型级额度颜色：>=80% 红、>=50% 橙、其余 accent
    private func quotaColor(_ percent: Double) -> Color {
        if percent >= 80 { return .red }
        if percent >= 50 { return .orange }
        return a.accent
    }

    private func trendChart(_ data: [Int]) -> some View {
        let maxV = max(data.max() ?? 0, 1)
        let accent = a.accent

        return Canvas { ctx, size in
            guard data.count > 1 else { return }
            let pts: [CGPoint] = data.enumerated().map { i, v in
                CGPoint(
                    x: size.width * CGFloat(i) / CGFloat(data.count - 1),
                    // 以 0 为基准：使用量为 0 时紧贴最底部
                    y: size.height * (1 - CGFloat(v) / CGFloat(maxV))
                )
            }

            // 填充
            var fill = Path()
            fill.move(to: CGPoint(x: pts[0].x, y: size.height))
            for p in pts { fill.addLine(to: p) }
            fill.addLine(to: CGPoint(x: pts.last!.x, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(accent.opacity(0.08)))

            // 平滑折线
            var line = Path()
            line.move(to: pts[0])
            for i in 1..<pts.count {
                let p0 = pts[i-1], p1 = pts[i]
                line.addCurve(
                    to: p1,
                    control1: CGPoint(x: p0.x + (p1.x - p0.x) / 3, y: p0.y),
                    control2: CGPoint(x: p0.x + 2 * (p1.x - p0.x) / 3, y: p1.y)
                )
            }
            ctx.stroke(line, with: .color(accent), lineWidth: 1.5)

            // 末端点
            if let last = pts.last {
                let r = CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)
                ctx.fill(Path(ellipseIn: r), with: .color(accent))
            }
        }
    }

    private func heatmapGrid(_ usages: [DailyUsage]) -> some View {
        let rows = dashVM.convertDailyUsageToHeatmap(usages)
        // 日期 → token 用量（按天去重，避免重复日期崩溃）
        let usageByDay = usages.reduce(into: [Date: Int]()) { dict, usage in
            dict[Calendar.current.startOfDay(for: usage.date)] = usage.tokenCount
        }

        return VStack(spacing: a.heatmapSpacing) {
            ForEach(0..<rows.count, id: \.self) { row in
                HStack(spacing: a.heatmapSpacing) {
                    ForEach(Array(rows[row].enumerated()), id: \.offset) { col, val in
                        let date = dashVM.heatmapDate(row: row, column: col)
                        HoverableHeatmapCell(
                            color: heatmapColor(val),
                            cellSize: a.heatmapCellSize,
                            cornerRadius: a.heatmapCorner,
                            date: date,
                            // 无记录日期显示 0（GitHub 风格），有记录显示实际用量
                            tokenCount: date.map { usageByDay[$0] ?? 0 }
                        )
                    }
                }
            }
        }
    }

    private func statusColor(_ status: AgentSourceStatus) -> Color {
        switch status {
        case .ok:    return .green
        case .error: return .red
        case .stale: return .orange
        }
    }

    private func heatmapColor(_ level: Int) -> Color {
        switch level {
        case 0: return a.isDark ? .white.opacity(0.06) : .black.opacity(0.04)
        case 1: return a.accent.opacity(0.15)
        case 2: return a.accent.opacity(0.35)
        case 3: return a.accent.opacity(0.6)
        case 4: return a.accent.opacity(0.85)
        default: return a.isDark ? .white.opacity(0.06) : .black.opacity(0.04)
        }
    }
}

#Preview {
    AgentDetailDashboardView(dashVM: DashboardViewModel(), sourceID: "preview")
        .padding()
}
