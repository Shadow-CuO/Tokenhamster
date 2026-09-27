//
//  DashboardView.swift
//  TokenHamster
//
//  Created by Oscar Sun on 2026/7/13.
//
//  所有颜色/字号/间距均来自 DashboardAppearance（自适应暗/亮模式）

import SwiftUI

struct DashboardView: View {

    @StateObject private var dashVM: DashboardViewModel
    @Environment(\.colorScheme) private var colorScheme

    /// ★ 观察语言/币种偏好：切换语言时整个面板树重建（视图内 `L()` 在 body 求值时求值）。
    @ObservedObject private var settingsStore = AppSettingsStore.shared

    /// 是否展示设置面板
    @State private var isShowingSettings = false

    /// 是否展示额度管理页（订阅/本地 CLI 数据源）
    @State private var isShowingQuotaManagement = false

    /// 是否展示 API 模型管理页（API 型数据源）
    @State private var isShowingModelsManagement = false

    /// 关闭按钮回调
    var onClose: (() -> Void)? = nil

    /// 进入/退出设置时回调（用于控制窗口能否变 key）
    var onSettingsChanged: ((Bool) -> Void)? = nil

    /// ⚠️ AppDelegate 应传入共享的 DashboardViewModel；预览可无参创建
    init(viewModel: DashboardViewModel? = nil, onClose: (() -> Void)? = nil, onSettingsChanged: ((Bool) -> Void)? = nil) {
        _dashVM = StateObject(wrappedValue: viewModel ?? DashboardViewModel())
        self.onClose = onClose
        self.onSettingsChanged = onSettingsChanged
    }

    /// 自适应外观：isDark 跟随系统 ColorScheme
    private var a: DashboardAppearance {
        var v = dashVM.appearance
        v.isDark = (colorScheme == .dark)
        return v
    }

    var body: some View {
        Group {
            if isShowingSettings {
                SettingsView(dashVM: dashVM, onDismiss: {
                    closeAllSubpages()
                })
            } else if isShowingQuotaManagement {
                // 额度管理页：订阅 / 本地 CLI 数据源（Copilot / Claude Code / Codex）
                DataSourceManagementView(
                    dashVM: dashVM,
                    title: L("Quota Management"),
                    filter: { $0.apiType == .copilot || $0.apiType == .localLog },
                    presets: agentPresets,
                    onBack: {
                        withAnimation(.snappy(duration: 0.25)) {
                            closeAllSubpages()
                        }
                    }
                )
            } else if isShowingModelsManagement {
                // API 模型管理页：API 型数据源（OpenAI / DeepSeek / Kimi / Anthropic / 自定义）
                DataSourceManagementView(
                    dashVM: dashVM,
                    title: L("API & Model Management"),
                    filter: { $0.apiType != .copilot && $0.apiType != .localLog },
                    presets: apiPresets,
                    onBack: {
                        withAnimation(.snappy(duration: 0.25)) {
                            closeAllSubpages()
                        }
                    }
                )
            } else if let detailID = selectedSourceID {
                // 二级详情页：单个数据源的热力图 / 趋势 / 模型排行
                AgentDetailDashboardView(
                    dashVM: dashVM,
                    sourceID: detailID,
                    onBack: {
                        withAnimation(.snappy(duration: 0.25)) {
                            selectedSourceID = nil
                        }
                    }
                )
            } else {
                dashboardContent
            }
        }
        .onChange(of: needsKeyWindow) { oldValue, showing in
            onSettingsChanged?(showing)
        }
    }

    /// 需要键盘输入的子页面（设置 / 栏目管理）→ 控制面板能否成为 key 窗口
    private var needsKeyWindow: Bool {
        isShowingSettings || isShowingQuotaManagement || isShowingModelsManagement
    }

    /// 栏目管理页类型
    private enum ManagementPage {
        case quota
        case models
    }

    /// 打开栏目管理页（互斥：先关闭其他所有子页面）
    private func openManagement(_ page: ManagementPage) {
        withAnimation(.snappy(duration: 0.25)) {
            closeAllSubpages()
            switch page {
            case .quota:  isShowingQuotaManagement = true
            case .models: isShowingModelsManagement = true
            }
        }
    }

    /// 关闭所有子页面，回到仪表盘主界面
    private func closeAllSubpages() {
        isShowingSettings = false
        isShowingQuotaManagement = false
        isShowingModelsManagement = false
        selectedSourceID = nil
    }

    /// 某数据源配置是否处于启用状态（卡片右上角激活圆点）
    private func isConfigActive(_ id: String) -> Bool {
        dashVM.apiConfigs.first(where: { $0.id == id })?.isActive ?? false
    }

    /// 栏目标题行 + 右侧管理箭头（点击进入该栏目管理页）
    /// ★ 命中热区 44×44（Apple 最小点击目标，原 34×34 偏小）；箭头视觉大小不变（9pt），
    ///   contentShape 置于 label 内——macOS 上 Button 外层 contentShape 的命中不可靠。
    /// ★ 改用 overlay 承载箭头：原先放在 HStack 里会把整行撑到 44pt 高，标题文字垂直居中后
    ///   多出约 15pt 空白，叠加 VStack spacing 使「标题 ↔ 内容」的视觉间距达 ~25pt。
    ///   overlay 不参与布局 → 标题行高度回到文字高度，间距恢复正常；点击热区仍是 44×44。
    private func manageableSectionHeader(icon: String, title: String, onManage: @escaping () -> Void) -> some View {
        sectionHeader(icon: icon, title: title)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                Button(action: onManage) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(a.textTertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // ★ 箭头整体适当右移（视觉 + 命中热区随动），大小与布局占位不变
                .offset(x: 6)
            }
    }

    // ============================================================
    // MARK: - 仪表盘主体
    // ============================================================

    private var dashboardContent: some View {
        ZStack(alignment: .top) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: a.sectionGap) {
                    // 错误提示
                    if let err = dashVM.errorMessage {
                        Text(err)
                            .font(.system(size: a.fontQuotaReset))
                            .foregroundStyle(.red)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    aggregatedHeaderSection
                    agentCardList

                    modelsSection
                    activitySection
                    trendSection

                    bottomBar
                }
                .padding(.horizontal, a.paddingOuter)
                .padding(.bottom, a.paddingOuter)
                .padding(.top, a.dragHandleZoneHeight) // 顶部只需给拖拽把手留空间
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)

            // 顶部拖拽区 — 透明，按住直接拖动可移动窗口（同 macOS 标题栏行为）
            dragHandle
        }
        .frame(width: a.panelWidth, height: a.panelHeight)
        .glassEffect(in: RoundedRectangle(cornerRadius: a.cornerRadius, style: .continuous))
        .compositingGroup()
        .mask {
            RoundedRectangle(cornerRadius: a.cornerRadius, style: .continuous)
        }
    }

    /// 顶部拖拽区（透明，无视觉指示）— 仅在顶部区域按住拖动可移动窗口
    private var dragHandle: some View {
        DashboardDragHandle()
            .frame(width: a.panelWidth, height: a.dragHandleZoneHeight)
    }
    // ============================================================
    // MARK: - 时间范围胶囊
    // ============================================================

    private var timeRangePills: some View {
        let ranges = TimeRange.allCases
        return GeometryReader { geo in
            let itemWidth = geo.size.width / CGFloat(ranges.count)
            let selectedIndex = ranges.firstIndex(of: dashVM.selectedRange) ?? 0

            ZStack(alignment: .leading) {
                // 整块圆角背景
                Capsule()
                    .fill(a.pillUnselectedBg)

                // 滑块 — 小块圆角按钮，在三个选项之间滑动
                Capsule()
                    .fill(a.pillSelectedBg)
                    .overlay(
                        Capsule().stroke(a.pillSelectedStroke, lineWidth: 0.5)
                    )
                    .frame(width: itemWidth - 4)
                    .padding(.leading, 2)
                    .offset(x: CGFloat(selectedIndex) * itemWidth)
                    .animation(.snappy(duration: 0.25), value: selectedIndex)

                // 选项文字（点击切换）
                HStack(spacing: 0) {
                    ForEach(ranges) { range in
                        Button { dashVM.selectRange(range) } label: {
                            Text(range.rawValue)
                                .font(.system(size: a.fontTimeRange, weight: .medium))
                                .foregroundStyle(range == dashVM.selectedRange ? a.pillTextSelected : a.pillTextUnselected)
                                .frame(maxWidth: .infinity)
                                .frame(height: 28)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 28)
        }
        .frame(width: 170, height: 28)
        .offset(x: 8) // 整体向右移一点
    }

    // ============================================================
    // MARK: - 聚合头部（全源汇总）
    // ============================================================

    /// 当前进入详情的源 ID（点击卡片进入二级详情页）
    @State private var selectedSourceID: String?

    private var aggregatedHeaderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 第一行：TOTAL TOKENS 标题 + 时间胶囊（胶囊底部与标题底部对齐，数值独占下一行）
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .bottom, spacing: 10) {
                    Text("TOTAL TOKENS")
                        .font(.system(size: a.fontTotalLabel, weight: .semibold))
                        .foregroundStyle(a.textHeading)
                        .tracking(2)
                    Spacer()
                    timeRangePills
                }
                // ★ 头部专用规则（见 formatTotalTokensDisplay）：≤ 10 位原样显示，
                //   超出后用 K 起步压缩（优先留在 K，不急着升 M/B/T）
                Text(formatTotalTokensDisplay(dashVM.aggregated.totalTokens))
                    .font(.system(size: a.fontTotalTokens, weight: .bold))
                    .foregroundStyle(a.textPrimary)
                    .contentTransition(.numericText())
            }

            // 第二行：更新时间（总金额显示已按要求移除）
            Text(L("Updated %@", lastUpdatedText))
                .font(.system(size: a.fontQuotaReset))
                .foregroundStyle(a.textTertiary)
        }
    }

    /// 汇总头部最近更新时间
    private var lastUpdatedText: String {
        guard let d = dashVM.aggregated.lastUpdated ?? dashVM.lastUpdated else { return "--" }
        return d.formatted(date: .omitted, time: .shortened)
    }

    // ============================================================
    // MARK: - Agent 卡片列表（多源聚合）
    // ============================================================

    private var agentCardList: some View {
        VStack(alignment: .leading, spacing: 10) {
            manageableSectionHeader(icon: "square.grid.2x2.fill", title: L("Quota")) {
                openManagement(.quota)
            }

            let agents = dashVM.agentSnapshots.filter { $0.sourceType != .api }
            if agents.isEmpty {
                // 留白占位（无提示词）
                Color.clear.frame(height: 24)
            } else {
                VStack(spacing: 8) {
                    ForEach(agents) { snap in
                        agentCard(snap)
                    }
                }
            }
        }
    }

    /// 单个 Agent 数据源卡片 — 点击进入二级详情页；右上角圆点切换激活状态。
    /// 已停用源（isActive == false）保留显示：整卡置灰，圆点即重新激活入口。
    private func agentCard(_ snap: AgentSnapshot) -> some View {
        let isActive = isConfigActive(snap.id)
        return ZStack(alignment: .topTrailing) {
            Button {
                withAnimation(.snappy(duration: 0.25)) {
                    selectedSourceID = snap.id
                }
            } label: {
                VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    // 状态灯 + 图标（状态色只走圆底，logo 用主文字色：真实厂商标保持中性）
                    ZStack {
                        Circle()
                            .fill(statusColor(snap.status).opacity(0.15))
                            .frame(width: 34, height: 34)
                        ProviderIcon(
                            assetName: snap.assetName,
                            symbolName: snap.iconName,
                            size: 17,
                            tint: a.textPrimary
                        )
                    }

                    HStack(spacing: 6) {
                        Text(snap.name)
                            .font(.system(size: a.fontQuotaName, weight: .semibold))
                            .foregroundStyle(a.textPrimary)
                            .lineLimit(1)
                        Text(snap.sourceType.displayName)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(a.textTertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(a.progressBg))
                    }

                    Spacer()

                    // 无额度窗口的源（如 Copilot / DSH）仍显示总体剩余百分比
                    if snap.quotaWindowDisplays.isEmpty, !snap.leftPercentText.isEmpty {
                        Text(snap.leftPercentText)
                            .font(.system(size: a.fontQuotaPercent, weight: .semibold))
                            .foregroundStyle(snap.status == .ok ? a.accent : statusColor(snap.status))
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(a.textTertiary)
                }

                // ★ 双额度窗口（参考图）：Session / Weekly 两列，各含剩余% + 重置倒计时
                if !snap.quotaWindowDisplays.isEmpty {
                    quotaWindowColumns(snap)
                } else if !snap.quotaText.isEmpty {
                    // 无额度窗口：沿用原有单行展示
                    HStack(spacing: 6) {
                        Text(L(snap.quotaText))
                            .font(.system(size: a.fontQuotaReset, weight: .medium))
                            .foregroundStyle(a.textSecondary)
                        Spacer(minLength: 6)
                        if !snap.resetTimeString.isEmpty {
                            // ★ 哨兵文案（"Available"/"Used up"/"Cumulative"）只在渲染处取词，
                            //   模型层保持英文原值（判断逻辑依赖它）。
                            Text(L(snap.resetTimeString))
                                .font(.system(size: a.fontQuotaReset))
                                .foregroundStyle(a.textTertiary)
                        }
                    }
                }

                // 错误信息（停用源不显示，整卡已置灰）
                if snap.status != .ok, !snap.errorMessage.isEmpty, isActive {
                    Text(snap.errorMessage)
                        .font(.system(size: a.fontQuotaReset))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                }
                .padding(12)
                .background(a.progressBg.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .opacity(isActive ? 1 : 0.5)

            // 激活切换圆点 — 独立于卡片 Button，点击切换该源启用状态
            // ★ 停用态圆点必须可再次点击激活：Color.clear 的 alpha=0 不参与命中测试，
            //   contentShape 对 macOS Button 不可靠（视图复用更新时易失效）→
            //   停用态改用 alpha=0.02 填充（肉眼不可见但可命中），contentShape 内移放大热区。
            Button { dashVM.activateAPIConfig(id: snap.id) } label: {
                Circle()
                    .fill(isActive ? Color.green : Color.primary.opacity(0.02))
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(isActive ? Color.green : a.textTertiary, lineWidth: 1))
                    .contentShape(Circle())
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .padding(.trailing, 4)
        }
    }

    /// ★ 双额度窗口两列布局（参考图）：
    /// ```
    /// Session        95% left   Weekly      13% left
    /// Reset 4h 24m              Reset 1d 17h
    /// ```
    /// Session 列精确到分、Weekly 列精确到小时（由 QuotaWindowKind 决定）。
    private func quotaWindowColumns(_ snap: AgentSnapshot) -> some View {
        let windows = snap.quotaWindowDisplays
        return HStack(alignment: .top, spacing: 16) {
            ForEach(windows) { window in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(window.label)
                            .font(.system(size: a.fontQuotaReset, weight: .medium))
                            .foregroundStyle(a.textHeading)
                        Spacer(minLength: 6)
                        Text(window.percentLeftText)
                            .font(.system(size: a.fontQuotaPercent, weight: .semibold))
                            .foregroundStyle(quotaPercentColor(window, status: snap.status))
                    }
                    if !window.resetLine.isEmpty {
                        // TimelineView 驱动重绘，倒计时才会随时间走动（每分钟刷新一次）
                        TimelineView(.periodic(from: .now, by: 60)) { _ in
                            Text(window.resetLine)
                                .font(.system(size: a.fontQuotaReset))
                                .foregroundStyle(a.textTertiary)
                                .monospacedDigit()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 剩余额度配色：>50% accent；20~50% 橙；≤20% 红；源异常时用状态色
    private func quotaPercentColor(_ window: QuotaWindowDisplay, status: AgentSourceStatus) -> Color {
        guard status == .ok else { return statusColor(status) }
        let remaining = window.remainingPercent
        if remaining <= 20 { return .red }
        if remaining <= 50 { return .orange }
        return a.accent
    }

    /// 单行模型用量（参考图）：图标 + 模型名 + 两列（token 用量 / 额度）
    /// ```
    /// ⚙ gpt-5.5        1.9B    44%
    /// ✳ claude-opus-4-8 1.8B   43%
    /// ◆ ds                      ¥88.50 left
    /// ```
    /// ★ 两列宽固定 → 各行右边界整齐对齐；某列没有内容就是空串（留白不补位），
    ///   不用 "—" 占位、也不会让另一列位移。
    private func detailModelRow(_ model: ModelRowItem) -> some View {
        HStack(spacing: 6) {
            ProviderIcon(
                assetName: model.assetName,
                symbolName: model.symbolName,
                size: 13,
                tint: a.textSecondary
            )

            Text(model.name)
                .font(.system(size: a.fontModelName, weight: .medium))
                .foregroundStyle(a.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            // ★ 两列：左 = token 用量，右 = 额度（百分比 / ¥xxx left）。
            //   列宽固定 → 各行右边界整齐；没有内容就是空串，留白不补位。
            Text(model.usageText)
                .font(.system(size: a.fontModelValue, weight: .semibold))
                .foregroundStyle(a.textPrimary)
                .frame(width: a.modelValueWidth, alignment: .trailing)

            // 额度列：百分比用 fontModelPercent；金额/状态文案（如 "¥88.50 left"）用稍大的 fontModelAmount
            // ★ 渲染处取词：余额型源的额度列可能放哨兵文案（"Used up"）
            Text(L(model.quotaText))
                .font(.system(size: model.quotaShowsAmount ? a.fontModelAmount : a.fontModelPercent))
                .foregroundStyle(a.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: a.modelQuotaWidth, alignment: .trailing)
        }
    }

    private func detailTrendChart(_ data: [Int]) -> some View {
        let maxV = max(data.max() ?? 0, 1)

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
            ctx.fill(fill, with: .color(a.accent.opacity(0.08)))

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
            ctx.stroke(line, with: .color(a.accent), lineWidth: 1.5)

            // 末端点
            if let last = pts.last {
                let r = CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)
                ctx.fill(Path(ellipseIn: r), with: .color(a.accent))
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

    // ============================================================
    // MARK: - 模型（聚合）
    // ============================================================

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            manageableSectionHeader(icon: "cpu.fill", title: "MODELS") {
                openManagement(.models)
            }

            if dashVM.modelRows.isEmpty {
                // 留白占位（无提示词）
                Color.clear.frame(height: 24)
            } else {
                VStack(spacing: 6) {
                    ForEach(dashVM.modelRows) { model in
                        detailModelRow(model)
                    }
                }
            }
        }
    }

    // ============================================================
    // MARK: - 趋势（聚合）
    // ============================================================

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader(icon: "chart.line.uptrend.xyaxis", title: "TREND")
                Spacer()
                Text(L("Peak %@", peakFormatted))
                    .font(.system(size: a.fontPeak, weight: .medium))
                    .foregroundStyle(a.accent)
            }

            // 始终保留趋势图形区域：无数据时显示占位网格线
            detailTrendChart(dashVM.sevenDayTrend)
                .frame(height: a.trendChartHeight)
        }
    }

    /// ★ 统一走 `formatCompactCount`：与模型行/详情页的量级口径一致
    ///   （此前这里 K 用 0 位小数 → 显示 "843K"，而模型行是 "843.2K"）
    private var peakFormatted: String {
        formatCompactCount(dashVM.peakValue)
    }

    // ============================================================
    // MARK: - 活动热力图（聚合）
    // ============================================================

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader(icon: "calendar", title: "ACTIVITY")
                Spacer()
                Text(L("Active %@ day%@", dashVM.activeDays, dashVM.activeDays == 1 ? "" : "s"))
                    .font(.system(size: a.fontActiveDays, weight: .medium))
                    .foregroundStyle(a.accent)
            }

            if dashVM.dailyHeatmap.isEmpty {
                placeholderHeatmapGrid
            } else {
                heatmapGrid
            }
        }
    }

    private var heatmapGrid: some View {
        let data = dashVM.heatmapData
        let rows = data.count
        // 日期 → token 用量（按天去重，避免重复日期崩溃）
        let usageByDay = dashVM.dailyHeatmap.reduce(into: [Date: Int]()) { dict, usage in
            dict[Calendar.current.startOfDay(for: usage.date)] = usage.tokenCount
        }

        return VStack(spacing: a.heatmapSpacing) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: a.heatmapSpacing) {
                    ForEach(Array(data[row].enumerated()), id: \.offset) { col, val in
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

    /// 无数据时占位：摆好 7 × heatmapWeeks 空格子，保持热力图布局稳定。
    /// 同样接入可悬停组件（无用量 → 0），保证无数据时也能预览悬浮效果。
    private var placeholderHeatmapGrid: some View {
        VStack(spacing: a.heatmapSpacing) {
            ForEach(0..<7, id: \.self) { row in
                HStack(spacing: a.heatmapSpacing) {
                    ForEach(0..<a.heatmapWeeks, id: \.self) { col in
                        HoverableHeatmapCell(
                            color: heatmapColor(0),
                            cellSize: a.heatmapCellSize,
                            cornerRadius: a.heatmapCorner,
                            date: dashVM.heatmapDate(row: row, column: col),
                            tokenCount: 0
                        )
                    }
                }
            }
        }
    }

    // ============================================================
    // MARK: - 底部操作栏
    // ============================================================

    private var bottomBar: some View {
        HStack {
            Spacer()
            Button {
                dashVM.closePet()
                onClose?()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: a.fontQuotaName, weight: .medium))
                    Text(L("Hide pet"))
                        .font(.system(size: a.fontQuotaName, weight: .medium))
                }
                .foregroundStyle(a.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(a.progressBg)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button { isShowingSettings = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: a.fontQuotaName, weight: .medium))
                    Text(L("Settings"))
                        .font(.system(size: a.fontQuotaName, weight: .medium))
                }
                .foregroundStyle(a.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(a.accent.opacity(0.12))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
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
}

// ============================================================
// MARK: - 热力图悬停格子 + 浮层
// ============================================================

/// 热力图格子悬停浮层 — 日期 + token 用量
struct HeatmapCellTooltip: View {

    /// 估算高度（两行文字 + padding），用于格子上下偏移定位
    static let preferredHeight: CGFloat = 34

    let date: Date
    let tokenCount: Int

    /// 无用量时数字用次级色弱化，有用量用强调色突出
    private var countColor: Color {
        tokenCount > 0 ? .primary : .secondary
    }

    var body: some View {
        VStack(spacing: 1) {
            Text(date.formatted(.dateTime.month().day().weekday(.abbreviated)))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.primary)
            Text(tokenCount.formattedTokenCount)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(countColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        // 用纯色半透明背景（系统 windowBackground 自动适配明暗），
        // 避免 material 首次出现的 backdrop sampling 延迟导致"先暗后亮"
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
        .fixedSize()
        // 浮层不拦截鼠标事件：鼠标移到浮层上时事件穿透到格子，
        // 保证格子的 onHover 能正常收到"离开"，移开即关闭，避免浮层挡住其他 UI
        .allowsHitTesting(false)
    }
}

/// 可悬停热力图格子 — 放大悬浮（GitHub 风格）+ 弹出日期/用量浮层
struct HoverableHeatmapCell: View {

    let color: Color
    let cellSize: CGFloat
    let cornerRadius: CGFloat
    let date: Date?
    let tokenCount: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    /// 是否有实际用量（0 用量格子悬浮效果明显弱化）
    private var hasUsage: Bool { (tokenCount ?? 0) > 0 }

    /// 悬停放大：有用量 1.6×（明显抬起）；0 用量 1.18×（几乎不动，仅轻微反馈）
    private var hoverScale: CGFloat { hasUsage ? 1.6 : 1.18 }
    /// 悬停投影：有用量明显；0 用量几乎无投影
    private var hoverShadowOpacity: Double { hasUsage ? 0.35 : 0.08 }
    private var hoverShadowRadius: CGFloat { hasUsage ? 5 : 1 }
    private var hoverShadowY: CGFloat { hasUsage ? 3 : 0.5 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(color)
                .frame(width: cellSize, height: cellSize)
                .scaleEffect(isHovered ? hoverScale : 1.0)
                .shadow(
                    color: .black.opacity(isHovered ? hoverShadowOpacity : 0),
                    radius: isHovered ? hoverShadowRadius : 0,
                    y: isHovered ? hoverShadowY : 0
                )

            // 浮层不随格子缩放（兄弟层），避免被放大动画带着一起动；统一向上弹出
            if isHovered, let date, let tokenCount {
                HeatmapCellTooltip(date: date, tokenCount: tokenCount)
                    .offset(y: -(cellSize / 2 + HeatmapCellTooltip.preferredHeight / 2 + 6))
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .zIndex(10)
            }
        }
        .frame(width: cellSize, height: cellSize) // 布局占位固定，放大只做视觉
        .zIndex(isHovered ? 1 : 0)               // 置顶：放大格/浮层盖过相邻格
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1.0)) {
                isHovered = hovering
            }
        }
    }
}

#Preview {
    DashboardView()
        .padding()
}
