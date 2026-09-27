//
//  SettingsView.swift
//  TokenHamster
//
//  Created by Oscar Sun on 2026/7/16.
//
//  设置面板（数据源管理已迁移至各栏目管理页 DataSourceManagementView）

import AppKit
import SwiftUI

struct SettingsView: View {

    @ObservedObject var dashVM: DashboardViewModel
    @Environment(\.colorScheme) private var colorScheme

    /// ★ 语言 / 币种偏好（App 与 Widget 共用一份存储）
    @ObservedObject private var settingsStore = AppSettingsStore.shared

    var onDismiss: (() -> Void)? = nil

    // ---- 外观 ----
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
                    languageSection
                    unitsSection
                }
                .padding(.horizontal, a.paddingOuter)
                .padding(.bottom, a.paddingOuter)
                .padding(.top, a.paddingOuter + a.dragHandleZoneHeight) // 给顶部拖拽区留出空间
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)

            // 顶部拖拽区 — 透明，按住直接拖动可移动窗口（同 macOS 标题栏行为）
            DashboardDragHandle()
                .frame(width: a.panelWidth, height: a.dragHandleZoneHeight)
        }
        .frame(width: a.panelWidth, height: a.panelHeight)
        .glassEffect(in: RoundedRectangle(cornerRadius: a.cornerRadius, style: .continuous))
        .compositingGroup()
        .mask {
            RoundedRectangle(cornerRadius: a.cornerRadius, style: .continuous)
        }
    }

    // ============================================================
    // MARK: - 顶栏
    // ============================================================

    private var topBar: some View {
        HStack {
            Button { onDismiss?() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: a.fontSectionLabel, weight: .semibold))
                }
                .foregroundStyle(a.accent)
            }
            .buttonStyle(.plain)

            Spacer()

            Text("SETTINGS")
                .font(.system(size: a.fontSectionLabel, weight: .semibold))
                .foregroundStyle(a.textHeading)
                .tracking(2)
        }
    }

    // ============================================================
    // MARK: - 语言
    // ============================================================

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(icon: "globe", title: L("Language"))
            menuRow(title: settingsStore.language.displayName, selection: languageBinding) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
        }
    }

    /// ★ 改语言要连带做两件事：
    ///   1. `AppSettingsStore` 通知 → 各页重建（`@ObservedObject`）→ 视图文案换语言；
    ///   2. 重新拉一次数据 —— 快照内的文案（重置文案 / 错误提示）是**抓取期**产出的，
    ///      不重拉就仍是旧语言（用 `relocalizeSnapshots`，不会触发仓鼠开心动画）。
    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { settingsStore.language },
            set: { newValue in
                settingsStore.setLanguage(newValue)
                dashVM.relocalizeSnapshots()
            }
        )
    }

    // ============================================================
    // MARK: - 单位（币种）
    // ============================================================

    private var unitsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(icon: "dollarsign.circle", title: L("Units"))
            menuRow(title: settingsStore.currency.displayName, selection: currencyBinding) {
                ForEach(CurrencyPreference.allCases) { currency in
                    Text(currency.displayName).tag(currency)
                }
            }
        }
    }

    /// ★ 币种只影响「数据源未提供币种」的展示，无需重拉数据（金额本身来自数据源）
    private var currencyBinding: Binding<CurrencyPreference> {
        Binding(
            get: { settingsStore.currency },
            set: { settingsStore.setCurrency($0) }
        )
    }

    // ============================================================
    // MARK: - 公共
    // ============================================================

    /// 设置页下拉行 —— **卡片本身就是菜单按钮**。
    ///
    /// ★ 为什么不用 `Picker(.menu)` 直接塞进卡片（2026-09-27 修）：
    ///   macOS 26 下 `.menu` 样式的 Picker 会**自己画一层圆角浮起底 + 内描边**
    ///   （AppKit 的 pop-up button bezel）。它落在这张卡片的 `pillSelectedBg` 圆角矩形上，
    ///   就成了两个错位的圆角框叠在一起 —— 即“选项框有叠层”。
    ///   试过 `.buttonStyle(.plain)` 去掉 bezel：确实不叠了，但**右侧指示器（上下箭头）也一起消失**，
    ///   看不出是下拉，故不可取。
    ///   最终改用 `Menu` + 自绘 label：卡片即按钮，值左对齐、指示器右对齐，
    ///   `Picker` 放进 `Menu` 里由系统渲染成带勾选的菜单项。
    private func menuRow<Value: Hashable>(
        title: String,
        selection: Binding<Value>,
        @ViewBuilder options: () -> some View
    ) -> some View {
        Menu {
            Picker("", selection: selection) {
                options()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .foregroundStyle(a.textPrimary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(a.textHeading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(a.pillSelectedBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(a.cardStroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

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
