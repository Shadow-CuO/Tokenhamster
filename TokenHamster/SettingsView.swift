//
//  SettingsView.swift
//  TokenHamster
//
//  Created by 孙亦阳 on 2026/7/16.
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
            pickerCard {
                Picker("", selection: languageBinding) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(a.accent)
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
            pickerCard {
                Picker("", selection: currencyBinding) {
                    ForEach(CurrencyPreference.allCases) { currency in
                        Text(currency.displayName).tag(currency)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(a.accent)
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

    private func pickerCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(a.pillSelectedBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(a.cardStroke, lineWidth: 1)
        )
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
