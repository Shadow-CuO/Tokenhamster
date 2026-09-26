//
//  ProviderQuotaWidgets.swift
//  TokenHamsterWidget
//
//  两个小组件定义 + AppIntent 配置（数据源选择）。
//
//  ★ 为什么用 AppIntentConfiguration：让用户在「编辑小组件」面板里直接下拉选数据源，
//    不用回主 App 改设置。可选源列表从 App Group 载荷里现取（`ProviderEntityQuery`）。
//
//  ★ 组件自身**不抓数据、不发网络请求** —— 只读 App 写好的载荷
//    （Timeline Provider 的预算只有几秒，抓取逻辑留在主 App）。
//

import AppIntents
import SwiftUI
import WidgetKit

// ============================================================
// MARK: - 时间线条目
// ============================================================

struct QuotaEntry: TimelineEntry {
    let date: Date
    /// 单源组件 = 0 或 1 个；双拼组件 = 0~2 个（顺序即列序）
    let providers: [WidgetQuotaProvider]

    /// 组件画廊预览数据（照参考图取值）
    static var placeholder: QuotaEntry {
        QuotaEntry(
            date: Date(),
            providers: [
                WidgetQuotaProvider(
                    id: "preview-codex", name: "Codex",
                    assetName: "codex", symbolName: "terminal.fill", status: "ok",
                    windows: [
                        WidgetQuotaWindow(
                            kind: WidgetQuotaWindow.sessionKind, usedPercent: 99,
                            resetsAt: Date().addingTimeInterval(3 * 3600)
                        ),
                        WidgetQuotaWindow(
                            kind: WidgetQuotaWindow.cycleKind, usedPercent: 19,
                            resetsAt: Date().addingTimeInterval(5 * 24 * 3600)
                        ),
                    ]
                ),
                WidgetQuotaProvider(
                    id: "preview-cursor", name: "Cursor",
                    assetName: "cursor", symbolName: "cursorarrow.rays", status: "ok",
                    windows: [
                        WidgetQuotaWindow(
                            kind: WidgetQuotaWindow.cycleKind, usedPercent: 45,
                            resetsAt: Date().addingTimeInterval(24 * 24 * 3600)
                        ),
                    ]
                ),
            ]
        )
    }
}

/// 时间线刷新间隔（分钟）—— App 每轮刷新后也会主动 `reloadAllTimelines`，
/// 这里只是兜底节奏，避免完全依赖 App 是否在运行。
private let widgetRefreshMinutes = 10

private func makeTimeline(_ entry: QuotaEntry) -> Timeline<QuotaEntry> {
    let next = Calendar.current.date(
        byAdding: .minute, value: widgetRefreshMinutes, to: entry.date
    ) ?? entry.date
    return Timeline(entries: [entry], policy: .after(next))
}

// ============================================================
// MARK: - 可选数据源（AppEntity）
// ============================================================

struct ProviderEntity: AppEntity {

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Data Source" }
    static var defaultQuery = ProviderEntityQuery()

    var id: String
    var name: String
    var symbolName: String
    var assetName: String?
    /// 是否含 5h 窗口（选默认源时优先挑这种）
    var hasSessionWindow: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct ProviderEntityQuery: EntityQuery {

    func entities(for identifiers: [String]) async throws -> [ProviderEntity] {
        let all = Self.all()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [ProviderEntity] {
        Self.all()
    }

    /// 未选择时的默认值：优先含 5h 窗口的源，否则第一个
    func defaultResult() async -> ProviderEntity? {
        let all = Self.all()
        return all.first(where: \.hasSessionWindow) ?? all.first
    }

    /// 从 App Group 载荷现取（载荷为空 → 无选项）
    static func all() -> [ProviderEntity] {
        (WidgetPayloadStore.read()?.providers ?? []).map {
            ProviderEntity(
                id: $0.id, name: $0.name, symbolName: $0.symbolName,
                assetName: $0.assetName, hasSessionWindow: $0.hasSessionWindow
            )
        }
    }
}

// ============================================================
// MARK: - 配置意图
// ============================================================

struct SingleProviderIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Data Source" }
    static var description: IntentDescription { IntentDescription("Choose the data source to show.") }

    @Parameter(title: "Data Source")
    var provider: ProviderEntity?
}

struct DualProviderIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Data Sources" }
    static var description: IntentDescription { IntentDescription("Choose two data sources to show side by side.") }

    @Parameter(title: "Left")
    var primary: ProviderEntity?

    @Parameter(title: "Right")
    var secondary: ProviderEntity?
}

// ============================================================
// MARK: - Timeline Provider
// ============================================================

/// 把载荷里 id 对应的源取出来（找不到 → nil）
private func resolveProvider(_ entity: ProviderEntity?, in all: [WidgetQuotaProvider]) -> WidgetQuotaProvider? {
    guard let entity else { return nil }
    return all.first { $0.id == entity.id }
}

struct SingleQuotaTimelineProvider: AppIntentTimelineProvider {

    func placeholder(in context: Context) -> QuotaEntry { .placeholder }

    func snapshot(for configuration: SingleProviderIntent, in context: Context) async -> QuotaEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: SingleProviderIntent, in context: Context) async -> Timeline<QuotaEntry> {
        makeTimeline(entry(for: configuration))
    }

    private func entry(for configuration: SingleProviderIntent) -> QuotaEntry {
        let all = WidgetPayloadStore.read()?.providers ?? []
        let selected = resolveProvider(configuration.provider, in: all)
            ?? all.first(where: \.hasSessionWindow)
            ?? all.first
        return QuotaEntry(date: Date(), providers: selected.map { [$0] } ?? [])
    }
}

struct DualQuotaTimelineProvider: AppIntentTimelineProvider {

    func placeholder(in context: Context) -> QuotaEntry { .placeholder }

    func snapshot(for configuration: DualProviderIntent, in context: Context) async -> QuotaEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: DualProviderIntent, in context: Context) async -> Timeline<QuotaEntry> {
        makeTimeline(entry(for: configuration))
    }

    private func entry(for configuration: DualProviderIntent) -> QuotaEntry {
        let all = WidgetPayloadStore.read()?.providers ?? []

        let primary = resolveProvider(configuration.primary, in: all)
            ?? all.first(where: \.hasSessionWindow)
            ?? all.first

        // 次源未选 / 与主源重复 → 自动补一个不同的源（避免两列显示同一个）
        var secondary = resolveProvider(configuration.secondary, in: all)
        if secondary == nil || secondary?.id == primary?.id {
            secondary = all.first { $0.id != primary?.id }
        }

        var providers: [WidgetQuotaProvider] = []
        if let primary { providers.append(primary) }
        if let secondary { providers.append(secondary) }
        return QuotaEntry(date: Date(), providers: providers)
    }
}

// ============================================================
// MARK: - 组件定义
// ============================================================

/// 单源：一个数据源的 5h + 周额度（小尺寸短标签 / 中尺寸全称）
struct SingleProviderQuotaWidget: Widget {

    let kind = "SingleProviderQuotaWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SingleProviderIntent.self,
            provider: SingleQuotaTimelineProvider()
        ) { entry in
            SingleQuotaEntryView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("TokenHamster")
        .description(Text(L("Shows one data source's quota")))
        .supportedFamilies([.systemSmall, .systemMedium])
        // ★ 放到桌面时**立即弹出配置面板**选数据源。
        //   不加的话用户得自己想到「右键 → 编辑组件」，多数人不会发现可以改。
        //   用户直接取消也能用 —— timeline provider 有默认源兜底。
        .promptsForUserConfiguration()
    }
}

/// 双拼：两个数据源并排（仅中尺寸）
struct DualProviderQuotaWidget: Widget {

    let kind = "DualProviderQuotaWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: DualProviderIntent.self,
            provider: DualQuotaTimelineProvider()
        ) { entry in
            DualQuotaEntryView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("TokenHamster Dual")
        .description(Text(L("Shows two data sources side by side")))
        .supportedFamilies([.systemMedium])
        // ★ 同单源：放置即弹配置面板（双拼更需要 —— 要选两个源）
        .promptsForUserConfiguration()
    }
}
