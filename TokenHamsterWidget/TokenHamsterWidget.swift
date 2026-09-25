//
//  TokenHamsterWidget.swift
//  TokenHamsterWidget
//
//  Created by 孙亦阳 on 2026/7/13.
//

import WidgetKit
import SwiftUI

// MARK: - 共享数据层

/// UserDefaults 中使用的键名
/// ⚠️ 如需主 App 与 Widget 共享数据，请在 Xcode Capabilities 中开启 App Group，
///    并将 suiteName 替换为你的 Group ID（例如 "group.com.YiyangSun.TokenHamster"）
enum WidgetStorage {
    static let suiteName = "group.com.YiyangSun.TokenHamster"

    static var shared: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    /// 当前进度值 (0.0 ~ 1.0)
    static var progress: Double {
        get { shared?.double(forKey: "widget_progress") ?? 0.0 }
        set { shared?.set(newValue, forKey: "widget_progress") }
    }

    /// 顶部标题文字
    static var label: String {
        get { shared?.string(forKey: "widget_label") ?? "TokenHamster" }
        set { shared?.set(newValue, forKey: "widget_label") }
    }
}

// MARK: - Timeline Entry

struct MacWidgetEntry: TimelineEntry {
    let date: Date
    let progress: Double
    let label: String
}

// MARK: - Timeline Provider

struct MacWidgetProvider: TimelineProvider {

    func placeholder(in context: Context) -> MacWidgetEntry {
        MacWidgetEntry(date: Date(), progress: 0.5, label: "TokenHamster")
    }

    func getSnapshot(in context: Context, completion: @escaping (MacWidgetEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MacWidgetEntry>) -> Void) {
        let entry = currentEntry()
        // 每 15 分钟刷新一次
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: entry.date) ?? entry.date
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    // MARK: Helpers

    private func currentEntry() -> MacWidgetEntry {
        MacWidgetEntry(
            date: Date(),
            progress: WidgetStorage.progress,
            label: WidgetStorage.label
        )
    }
}

// MARK: - Widget View

struct MacWidgetEntryView: View {
    var entry: MacWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 标题
            Text(entry.label)
                .font(.headline)
                .fontWeight(.semibold)

            // 描述
            Text(L("Today's token quota"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 4)

            // 进度条
            ProgressView(value: entry.progress) {
                HStack {
                    Text("\(Int(entry.progress * 100))%")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(progressColor)
                    Spacer()
                    Text(L("Used"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .tint(progressColor)
        }
        .padding()
    }

    private var progressColor: Color {
        switch entry.progress {
        case ..<0.5:  return .green
        case ..<0.8:  return .orange
        default:      return .red
        }
    }
}

// MARK: - Widget 定义

struct MacWidget: Widget {
    let kind: String = "MacWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MacWidgetProvider()) { entry in
            if #available(macOS 14.0, *) {
                MacWidgetEntryView(entry: entry)
                    .containerBackground(.background, for: .widget)
            } else {
                MacWidgetEntryView(entry: entry)
                    .padding()
                    .background()
            }
        }
        .configurationDisplayName("TokenHamster")
        // ★ 取词结果是 String，`description(_:)` 只收 LocalizedStringKey → 用 Text 包一层
        .description(Text(L("Shows token usage progress")))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
