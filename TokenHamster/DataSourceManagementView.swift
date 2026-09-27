//
//  DataSourceManagementView.swift
//  TokenHamster
//
//  Created by Oscar Sun on 2026/8/20.
//
//  栏目管理页（通用组件）：承载某一栏目的数据源增删改。
//   - 额度管理页：订阅/本地 CLI 源（agentPresets）
//   - API 模型管理页：API 型源（apiPresets）
//  逻辑由原 SettingsView 的 API 管理迁移而来，按 filter / presets 参数化：
//  每个栏目只展示、只可添加本栏目相关的数据源。
//

import AppKit
import SwiftUI

struct DataSourceManagementView: View {

    @ObservedObject var dashVM: DashboardViewModel
    @Environment(\.colorScheme) private var colorScheme

    /// 管理页标题（顶栏显示），如 "额度管理" / "API 模型管理"
    let title: String
    /// 此页管理的配置过滤条件（决定列表展示与可添加类型）
    let filter: (APIConfigItem) -> Bool
    /// 此页可选的模型预设（Picker 只显示本栏目相关选项）
    let presets: [ModelPreset]

    var onBack: (() -> Void)? = nil

    // ---- API 草稿 ----
    @State private var draftName: String = ""
    @State private var draftUrl: String = ""
    @State private var draftKey: String = ""
    /// API Key 明文/掩码切换（SecureField 掩码 ⇄ TextField 明文）
    @State private var showAPIKey = false
    @FocusState private var apiKeyFocused: Bool
    @State private var draftApiType: APIType = .openAI
    @State private var draftPolling: Double = 300
    @State private var editingConfigID: String? = nil
    @State private var showApiAddForm = false
    @State private var showJsonEditor = false         // 编辑配置(JSON)
    @State private var jsonEditorText = ""            // JSON 编辑器内容
    @State private var jsonEditorError: String? = nil // JSON 解析错误
    @State private var draftKeyPaths: [String: String] = [:]
    // 厂商专属字段
    @State private var draftOrgID: String = ""       // Anthropic 组织 ID
    @State private var draftCopilotOrg: String = ""  // GitHub 组织 slug
    @State private var draftAgentProvider: AgentProvider = .claudeCode // 本地 Agent 类型
    @State private var draftLocalPath: String = ""   // 本地自定义路径
    @State private var selectedPresetID: String = "openai" // 当前模型预设

    // ---- DSH 用量插件安装引导（仅 draftAgentProvider == .dsh 时出现）----
    @State private var dshAvailability: DSHUsageStatsAvailability = .ready
    @State private var showDSHInstallSheet = false
    @State private var dshProfiles: [String] = []
    @State private var dshSelectedProfile: String = ""
    @State private var dshInstallTarget: DSHPluginInstallTarget = .verified
    @State private var dshInstalling = false
    @State private var dshInstallOutput: DSHInstallOutput? = nil
    @State private var dshVerification: DSHPluginInstallVerification? = nil

    /// 本页管理的配置列表（过滤后）
    private var configs: [APIConfigItem] {
        dashVM.apiConfigs.filter(filter)
    }

    /// ★ 观察语言/币种偏好 — 切换语言时本页文案（含预设名/凭据提示）同步重建
    @ObservedObject private var settingsStore = AppSettingsStore.shared

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
                    apiSection
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
        .onAppear {
            // 保证默认预设属于本栏目的可选列表（避免 Picker invalid selection / 类型错位）
            if !presets.contains(where: { $0.id == selectedPresetID }), let first = presets.first {
                selectedPresetID = first.id
                applyPreset(first.id)
            }
            refreshDSHAvailability()
        }
        // 切到 DSH 时重新探测插件状态（用户可能刚在终端装好）
        .onChange(of: draftAgentProvider) { _, _ in refreshDSHAvailability() }
        .sheet(isPresented: $showDSHInstallSheet) {
            dshInstallSheet
                .background(Color.clear)
        }
    }

    // ============================================================
    // MARK: - 顶栏（返回 + 标题 + 添加）
    // ============================================================

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { onBack?() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: a.fontSectionLabel, weight: .semibold))
                }
                .foregroundStyle(a.accent)
            }
            .buttonStyle(.plain)

            Text(title)
                .font(.system(size: a.fontSectionLabel, weight: .semibold))
                .foregroundStyle(a.textHeading)
                .tracking(2)
                .lineLimit(1)

            Spacer()

            Button {
                if showApiAddForm { cancelEditing() }
                showApiAddForm.toggle()
                if showApiAddForm { clearApiDraft() }
            } label: {
                Image(systemName: showApiAddForm ? "minus.circle" : "plus.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(showApiAddForm ? a.textTertiary : a.accent)
            }
            .buttonStyle(.plain)
        }
    }

    // ============================================================
    // MARK: - 配置管理
    // ============================================================

    private var apiSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 已有配置列表
            if configs.isEmpty && !showApiAddForm {
                Text(L("No data sources yet"))
                    .font(.system(size: 12))
                    .foregroundStyle(a.textTertiary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    ForEach(configs) { cfg in
                        apiRow(cfg)
                    }
                }
            }

            // 添加表单
            if showApiAddForm {
                Divider().background(a.divider)
                configForm(isEditing: false)
            }
        }
    }

    @ViewBuilder
    private func apiRow(_ cfg: APIConfigItem) -> some View {
        let isEditing = editingConfigID == cfg.id

        VStack(alignment: .leading, spacing: 6) {
            // 只读行
            HStack(spacing: 6) {
                // 勾选框 — 点击切换激活（选中 = 绿色填充，无对勾）
                // ★ 停用态圆点必须可再次点击激活：Color.clear 的 alpha=0 完全不参与命中测试，
                //   且 contentShape 对 macOS Button 的命中测试不可靠（视图复用更新时易失效）→
                //   停用态改用 alpha=0.02 填充（肉眼不可见，但 alpha>0 保证可命中），
                //   contentShape 内移放大热区到 22×22，双保险确保取消激活后能重新点中。
                Button { dashVM.activateAPIConfig(id: cfg.id) } label: {
                    Circle()
                        .fill(cfg.isActive ? Color.green : Color.primary.opacity(0.02))
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(cfg.isActive ? Color.green : a.textTertiary, lineWidth: 1))
                        .contentShape(Circle())
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text(cfg.name)
                        .font(.system(size: a.fontDeviceName, weight: .medium))
                        .foregroundStyle(a.textPrimary)
                        .lineLimit(1)
                    Text(secondaryText(for: cfg))
                        .font(.system(size: a.fontDeviceUsage))
                        .foregroundStyle(a.textSecondary)
                        .lineLimit(1)
                    if cfg.apiType != .localLog {
                        Text("Key: \(maskedKey(cfg.apiKey))")
                            .font(.system(size: a.fontQuotaReset))
                            .foregroundStyle(a.textTertiary)
                    }
                }

                Spacer()

                Button {
                    if isEditing { cancelEditing() } else { startEditing(cfg) }
                } label: {
                    Image(systemName: isEditing ? "xmark.circle.fill" : "pencil")
                        .font(.system(size: 11))
                        .foregroundStyle(a.textTertiary)
                }
                .buttonStyle(.plain)

                Button {
                    dashVM.deleteAPIConfig(id: cfg.id)
                    if isEditing { cancelEditing() }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
            }

            // 编辑表单（内联展开）
            if isEditing {
                configForm(isEditing: true)
            }
        }
        .padding(8)
        .background(a.progressBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// 通用表单：添加 / 编辑
    private func configForm(isEditing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(L("Name"), text: $draftName)
                .textFieldStyle(.plain)
                .font(.system(size: a.fontQuotaName))
                .foregroundStyle(a.textPrimary)
                .padding(6)
                .background(a.progressBg)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            // ── 模型预设选择（本栏目可选预设）──
            HStack {
                Picker(L("Model"), selection: presetSelectionBinding) {
                    ForEach(presets) { p in
                        HStack(spacing: 5) {
                            ProviderIcon(assetName: p.asset, symbolName: p.icon, size: 12, tint: a.textSecondary)
                            Text(p.name)
                        }
                        .tag(p.id)
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: a.fontQuotaName))
                .onChange(of: selectedPresetID) { _, newID in
                    applyPreset(newID)
                }

                Spacer()

                Text(L("Poll %@s", Int(draftPolling)))
                    .font(.system(size: a.fontQuotaPercent))
                    .foregroundStyle(a.accent)
            }

            // ── Z.ai Coding Plan：接口地址（国内站 / 国际站两个官方节点）──
            // ★ 两个节点的端点路径完全相同，只有 host 与「有无账户余额」不同，
            //   所以不给自由文本地址框，而是像选厂商一样在这两个 URL 里挑一个。
            if draftApiType == .localLog && draftAgentProvider == .zcode {
                ZaiEndpointPicker(baseURL: $draftUrl)
            }

            // ── 接口地址（自定义 / Gemini / 余额型新源需要填写；其余官方预设用默认地址）──
            if needsAddressField {
                TextField(L("Endpoint URL"), text: $draftUrl)
                    .textFieldStyle(.plain)
                    .font(.system(size: a.fontQuotaName))
                    .foregroundStyle(a.textPrimary)
                    .padding(6)
                    .background(a.progressBg)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // ── API Key / Cookie（本地零配置类预设无需填写）──
            // ★ 用 SecureField 原生掩码：输入时显示 ••，不泄露明文。
            //   （掩码 TextField + 变换 Binding 在 macOS 上输入时会显示明文且污染草稿值，已弃用）
            //   ViewBridge 噪音日志（NSViewBridgeErrorCanceled）是 benign 的控制台噪音，不影响功能。
            //   点眼睛按钮临时切换明文 TextField（标准密码框模式）。
            if needsCredentialField {
                HStack(spacing: 6) {
                    Group {
                        if showAPIKey {
                            TextField(credentialFieldLabel, text: $draftKey)
                                .textFieldStyle(.plain)
                        } else {
                            SecureField(credentialFieldLabel, text: $draftKey)
                                .textFieldStyle(.plain)
                        }
                    }
                    .font(.system(size: a.fontQuotaName))
                    .foregroundStyle(a.textPrimary)
                    .focused($apiKeyFocused)
                    .padding(6)
                    .background(a.progressBg)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    Button { showAPIKey.toggle() } label: {
                        // 眼睛反映当前显示状态：明文可见 → 睁眼；掩码隐藏 → 斜眼
                        Image(systemName: showAPIKey ? "eye" : "eye.slash")
                            .font(.system(size: 12))
                            .foregroundStyle(showAPIKey ? a.accent : a.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // ── 自定义：本地路径（文件或目录）+ 系统文件选择器 ──
            if isCustomLocalPathMode {
                HStack(spacing: 6) {
                    TextField(L("Local path"), text: $draftLocalPath)
                        .textFieldStyle(.plain)
                        .font(.system(size: a.fontQuotaName))
                        .foregroundStyle(a.textPrimary)
                        .padding(6)
                        .background(a.progressBg)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    Button { pickLocalPath() } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 13))
                            .foregroundStyle(a.accent)
                    }
                    .buttonStyle(.plain)
                }
            }

            // ── 自定义接口：字段映射（JSON 文档配置）──
            if draftApiType == .custom && draftLocalPath.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showJsonEditor.toggle()
                        if showJsonEditor {
                            jsonEditorError = nil
                            if jsonEditorText.isEmpty {
                                jsonEditorText = defaultKeyPathsJSON()
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "curlybraces")
                            .font(.system(size: 9))
                        Text(L("Edit config (JSON)"))
                            .font(.system(size: a.fontQuotaReset, weight: .medium))
                    }
                    .foregroundStyle(showJsonEditor ? a.accent : a.textSecondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 2)

                if showJsonEditor {
                    jsonConfigEditor
                }
            }

            // ── Anthropic：组织 ID（仅选择 Anthropic 时需要，Admin API 必需）──
            if draftApiType == .anthropic {
                TextField(L("Organization ID"), text: $draftOrgID)
                    .textFieldStyle(.plain)
                    .font(.system(size: a.fontQuotaName))
                    .foregroundStyle(a.textPrimary)
                    .padding(6)
                    .background(a.progressBg)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // ── GitHub Copilot：组织 slug（仅选择 Copilot 时需要，用量 API 必需）──
            if draftApiType == .copilot {
                TextField(L("Organization slug"), text: $draftCopilotOrg)
                    .textFieldStyle(.plain)
                    .font(.system(size: a.fontQuotaName))
                    .foregroundStyle(a.textPrimary)
                    .padding(6)
                    .background(a.progressBg)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(L("Requires a GitHub PAT (read:org)"))
                    .font(.system(size: a.fontQuotaReset))
                    .foregroundStyle(a.textTertiary)
            }

            // ── 本地 Agent 类预设：提示读取位置 + 凭据说明 ──
            // ★ Z.ai 不显示这些说明（读取位置与凭据要求已在类型名/接口地址里自明）
            if draftApiType == .localLog && draftAgentProvider != .customPath,
               let hint = localPathHint(for: draftAgentProvider) {
                Text(hint)
                    .font(.system(size: a.fontQuotaReset))
                    .foregroundStyle(a.textTertiary)
                if let credentialHint = draftAgentProvider.spec.credentialHint {
                    Text(credentialHint)
                        .font(.system(size: a.fontQuotaReset))
                        .foregroundStyle(a.textTertiary)
                }
            }

            // ── DSH：数据靠第三方插件落盘，先显示它到底能不能用 ──
            if draftApiType == .localLog && draftAgentProvider == .dsh {
                dshPluginStatusRow
            }

            // ── Gemini（仅编辑旧配置时显示）──
            if draftApiType == .gemini {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: a.fontQuotaReset))
                        .foregroundStyle(.orange)
                    Text(L("Gemini has no public usage API"))
                        .font(.system(size: a.fontQuotaReset))
                        .foregroundStyle(a.textTertiary)
                }
            }

            // ── 余额型新源：说明数据从哪来（避免用户不知道能读到什么）──
            if let hint = providerHint {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(.system(size: a.fontQuotaReset))
                        .foregroundStyle(a.accent)
                    Text(hint)
                        .font(.system(size: a.fontQuotaReset))
                        .foregroundStyle(a.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Slider(value: $draftPolling, in: 30...3600, step: 30)
                .tint(a.accent)

            HStack {
                Button {
                    if isEditing { cancelEditing() }
                    else { showApiAddForm = false; clearApiDraft() }
                } label: {
                    Text(L("Cancel"))
                        .font(.system(size: a.fontQuotaName))
                        .foregroundStyle(a.textTertiary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    if isEditing, let id = editingConfigID { saveEdit(id: id) }
                    else { addConfig() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                        Text(isEditing ? L("Save") : L("Add"))
                    }
                    .font(.system(size: a.fontQuotaName, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(canSubmitDraft ? a.accent : a.progressBg)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSubmitDraft)
            }
        }
    }

    /// 表单可提交条件：有名称，且（本地日志 / Copilot 走官方 API 无需地址，或已填接口地址 / 本地路径）
    private var canSubmitDraft: Bool {
        guard !draftName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch draftApiType {
        case .localLog, .copilot:
            // Z.ai Coding Plan 只读官方 API → **必须有 Key**，否则存下来也是一张报错卡
            if draftAgentProvider == .zcode {
                return !draftKey.trimmingCharacters(in: .whitespaces).isEmpty
            }
            return true
        default:
            return !draftUrl.trimmingCharacters(in: .whitespaces).isEmpty
                || !draftLocalPath.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// 是否需要显示凭据输入框
    /// （API 类源需要；本地零配置源不需要；Cursor 虽是本地类但需要 Cookie）
    private var needsCredentialField: Bool {
        if draftApiType != .localLog { return true }
        return draftAgentProvider.spec.secretFieldPlaceholder != nil
    }

    /// 是否需要显示「接口地址」输入框。
    /// ★ 余额型新源（OpenRouter / SiliconFlow）虽已预填地址，但仍要给用户改的机会
    ///（如 SiliconFlow 国内站 .cn 与国际站 .com 是不同地址）。
    /// ★ Z.ai Coding Plan **不用自由文本地址框** —— 它只有两个官方节点（国内 / 国际），
    ///   改用地址下拉（`ZaiEndpointPicker`），避免手打 URL 出错。
    private var needsAddressField: Bool {
        switch draftApiType {
        case .gemini:
            return true
        case .custom:
            // 自定义接口 vs 自定义本地路径：填了本地路径就当本地源处理，不显示地址框
            return draftLocalPath.trimmingCharacters(in: .whitespaces).isEmpty
        case .openRouter, .siliconFlow:
            return true
        case .localLog, .copilot:
            return false
        default:
            return false
        }
    }

    /// 新源的能力说明（nil = 不显示提示行）
    private var providerHint: String? {
        switch draftApiType {
        case .openRouter:
            return L("Reads remaining credits from /api/v1/key (a standard key is enough); unlimited-credit keys automatically switch to /credits (requires a management key). Amount only, no token detail.")
        case .siliconFlow:
            return L("Reads the account credit total from /v1/user/info (granted + topped-up). The China site api.siliconflow.cn bills in CNY, the global site .com in USD. Amount only, no token detail.")
        default:
            return nil
        }
    }

    /// 凭据输入框占位文案（Cursor 用 Cookie）
    private var credentialFieldLabel: String {
        draftAgentProvider.spec.secretFieldPlaceholder ?? "API Key"
    }

    /// 是否处于"自定义本地路径"模式（自定义类型填本地路径，或已是 customPath 本地日志）
    private var isCustomLocalPathMode: Bool {
        draftApiType == .custom || (draftApiType == .localLog && draftAgentProvider == .customPath)
    }

    /// 本地 / Agent 类预设的读取位置提示（nil = 不显示该行）
    /// ★ Z.ai 为 nil：它早已不读本地账本（旧提示说的是 `~/.zcode/cli/db/db.sqlite`，已过时）
    private func localPathHint(for provider: AgentProvider) -> String? {
        switch provider {
        case .claudeCode: return L("Reads ~/.claude/projects")
        case .codex:      return L("Reads ~/.codex/sessions")
        case .cursor:     return L("Reads cursor.com/api/usage (cookie required)")
        case .dsh:        return L("Reads the local cache of the dsh-usage-stats plugin (~/.dsh/storages)")
        case .zcode:      return nil
        case .customPath: return L("Reads a custom path")
        }
    }

    // ============================================================
    // MARK: - DSH 插件状态 + 安装引导
    // ============================================================

    /// DSH 插件状态行：明确告诉用户现在能不能取到数，而不是静默显示 0。
    private var dshPluginStatusRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: dshAvailability == .ready
                      ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: a.fontQuotaReset))
                    .foregroundStyle(dshAvailability == .ready ? .green : .orange)
                Text(dshAvailability == .ready ? L("Plugin ready") : dshAvailability.message)
                    .font(.system(size: a.fontQuotaReset))
                    .foregroundStyle(a.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                // 只有「没数据可用」时才提供安装（已生效就不啰嗦）
                if dshAvailability != .ready {
                    Button { presentDSHInstallSheet() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle")
                            Text(L("Install plugin"))
                        }
                        .font(.system(size: a.fontQuotaReset, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(a.accent)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Button { openDSHPluginGuide() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "book")
                        Text(L("Install guide"))
                    }
                    .font(.system(size: a.fontQuotaReset))
                    .foregroundStyle(a.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(a.progressBg)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(a.progressBg.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// 打开安装弹窗前：列 profile、回读当前状态
    private func presentDSHInstallSheet() {
        let home = DSHPluginInstaller.dshHome
        let profiles = DSHPluginInstaller.availableProfiles(dshHome: home)
        dshProfiles = profiles
        dshSelectedProfile = DSHPluginInstaller.defaultProfile(from: profiles) ?? ""
        dshInstallTarget = .verified
        dshInstallOutput = nil
        dshVerification = nil
        showDSHInstallSheet = true
    }

    /// 重新探测插件状态（表单出现时 / 安装完成后）
    private func refreshDSHAvailability() {
        dshAvailability = DSHUsageStatsSource.currentAvailability(
            dshHome: DSHPluginInstaller.dshHome
        )
    }

    /// 安装确认弹窗。
    /// ★ 必须把四件事说清楚：装什么、要联网、会执行第三方脚本、装完需自己重启 DSH。
    private var dshInstallSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Install the DSH usage plugin"))
                .font(.system(size: a.fontQuotaName + 2, weight: .semibold))
                .foregroundStyle(a.textPrimary)

            VStack(alignment: .leading, spacing: 5) {
                dshFactRow("shippingbox", L("What gets installed"), "\(DSHPluginInstaller.packageName)\(dshInstallTarget.versionSuffix)")
                dshFactRow("wifi", L("Network required"), L("Downloaded from the npm registry"))
                dshFactRow("exclamationmark.shield", L("Runs third-party install scripts"), L("npm lifecycle scripts run as your user"))
                dshFactRow("arrow.clockwise", L("You must restart DSH afterwards"), L("This app won't restart it for you (that would interrupt your running tasks)"))
            }
            .padding(8)
            .background(a.progressBg.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // profile — 必须让用户确认：装进没被加载的 profile = 永远没数据
            HStack(spacing: 6) {
                Text("profile")
                    .font(.system(size: a.fontQuotaReset))
                    .foregroundStyle(a.textTertiary)
                if dshProfiles.isEmpty {
                    Text(L("No profile found under ~/.dsh/profiles"))
                        .font(.system(size: a.fontQuotaReset))
                        .foregroundStyle(.orange)
                } else {
                    Picker("", selection: $dshSelectedProfile) {
                        ForEach(dshProfiles, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(.system(size: a.fontQuotaName))
                }
            }

            // 版本 — 默认 pin 已验证版本；latest 带风险提示
            HStack(spacing: 6) {
                Text(L("Version"))
                    .font(.system(size: a.fontQuotaReset))
                    .foregroundStyle(a.textTertiary)
                Picker("", selection: $dshInstallTarget) {
                    ForEach(DSHPluginInstallTarget.allCases) { target in
                        Text(target.displayName).tag(target)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(.system(size: a.fontQuotaName))
                .disabled(dshInstalling)
            }
            if let risk = dshInstallTarget.riskNote {
                Text(risk)
                    .font(.system(size: a.fontQuotaReset))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 执行结果
            if dshInstalling {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("Installing, this may take a while…"))
                        .font(.system(size: a.fontQuotaReset))
                        .foregroundStyle(a.textSecondary)
                }
            } else if let verification = dshVerification {
                dshResultBlock(verification)
            }

            Divider().opacity(0.3)

            HStack(spacing: 8) {
                Button { showDSHInstallSheet = false } label: {
                    Text(dshInstalling ? L("Continue in background") : L("Close"))
                        .font(.system(size: a.fontQuotaName))
                        .foregroundStyle(a.textTertiary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button { copyDSHInstallCommand() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                        Text(L("Copy command"))
                    }
                    .font(.system(size: a.fontQuotaReset))
                    .foregroundStyle(a.textSecondary)
                }
                .buttonStyle(.plain)

                Button { startDSHInstall() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                        Text(L("Install"))
                    }
                    .font(.system(size: a.fontQuotaName, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(canInstallDSHPlugin ? a.accent : a.progressBg)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canInstallDSHPlugin)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private var canInstallDSHPlugin: Bool {
        !dshInstalling && !dshSelectedProfile.isEmpty
    }

    private func dshFactRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: a.fontQuotaReset))
                .foregroundStyle(a.textTertiary)
                .frame(width: 14)
            Text(title)
                .font(.system(size: a.fontQuotaReset, weight: .medium))
                .foregroundStyle(a.textSecondary)
            Text(detail)
                .font(.system(size: a.fontQuotaReset))
                .foregroundStyle(a.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 安装结果：先给结论，再给**原始输出**（不做错误分类，不猜原因）
    private func dshResultBlock(_ verification: DSHPluginInstallVerification) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: verification == .notInstalled
                      ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: a.fontQuotaReset))
                    .foregroundStyle(verification == .notInstalled ? .red : .green)
                Text(verification.message)
                    .font(.system(size: a.fontQuotaReset))
                    .foregroundStyle(a.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let output = dshInstallOutput {
                ScrollView {
                    Text(output.displayOutput)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(a.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 110)
                .padding(6)
                .background(a.progressBg.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                if !output.succeeded {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("You can rerun this manually in a terminal:"))
                            .font(.system(size: a.fontQuotaReset))
                            .foregroundStyle(a.textTertiary)
                        Text(output.command)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(a.textSecondary)
                            .textSelection(.enabled)
                        Text(L("Secondary check: %@", DSHPluginInstaller.secondaryCheckCommand))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(a.textTertiary)
                            .textSelection(.enabled)
                    }
                }
            }

            Button { openDSHPluginGuide() } label: {
                Text(L("View install / rollback / uninstall guide"))
                    .font(.system(size: a.fontQuotaReset))
                    .foregroundStyle(a.accent)
            }
            .buttonStyle(.plain)
        }
    }

    /// 执行安装 —— 在后台线程跑 login shell，完成后**必须验证**才给结论
    private func startDSHInstall() {
        let profile = dshSelectedProfile
        guard !profile.isEmpty else { return }
        let home = DSHPluginInstaller.dshHome
        let command = DSHPluginInstaller.installCommand(
            profile: profile, target: dshInstallTarget
        )

        dshInstalling = true
        dshInstallOutput = nil
        dshVerification = nil

        Task {
            let output = await Task.detached(priority: .userInitiated) {
                DSHPluginInstaller.run(command: command)
            }.value
            // ★ 绝不用 exitCode 冒充成功：以文件系统事实为准
            let verification = DSHPluginInstaller.verify(profile: profile, dshHome: home)
            dshInstallOutput = output
            dshVerification = verification
            dshInstalling = false
            refreshDSHAvailability()
        }
    }

    private func copyDSHInstallCommand() {
        let profile = dshSelectedProfile.isEmpty ? "<profile>" : dshSelectedProfile
        let text = DSHPluginInstaller.installCommand(profile: profile, target: dshInstallTarget)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func openDSHPluginGuide() {
        guard let url = URL(string: AppConstants.dshPluginGuideURL) else { return }
        NSWorkspace.shared.open(url)
    }

    private func maskedKey(_ key: String) -> String {
        guard key.count > 4 else { return String(repeating: "*", count: max(1, key.count)) }
        return String(key.prefix(4)) + String(repeating: "*", count: min(12, key.count - 4))
    }

    /// 模型预设 Picker 兜底绑定：selectedPresetID 不存在时回退到本栏目首个预设，
    /// 保证 selection 永远有对应 tag（避免 Picker invalid selection 警告）。
    private var presetSelectionBinding: Binding<String> {
        Binding(
            get: {
                if presets.contains(where: { $0.id == selectedPresetID }) { return selectedPresetID }
                return presets.first?.id ?? selectedPresetID
            },
            set: { selectedPresetID = $0 }
        )
    }

    // ============================================================
    // MARK: - 模型预设
    // ============================================================

    /// 选择预设：自动填充类型 / 接口地址，并重置厂商专属字段
    private func applyPreset(_ id: String) {
        guard let p = presets.first(where: { $0.id == id }) else { return }
        draftApiType = p.apiType
        draftAgentProvider = p.agentProvider ?? .claudeCode
        // ★ 直接赋值（含空串）：地址为空的预设（自定义）必须清空地址栏，
        //   否则会残留上一个厂商的地址 —— 看着像已填好，实际是错的。
        //   `startEditing` 不调用本方法，编辑已有配置不会被清掉。
        draftUrl = p.defaultURL
        draftOrgID = ""
        draftCopilotOrg = ""
        draftLocalPath = ""
        draftKeyPaths = [:]
        resetCustomEditorState()
        if p.apiType == .custom {
            showJsonEditor = true
            jsonEditorText = defaultKeyPathsJSON()
        }
    }

    /// 重置自定义 JSON 编辑器（JSON 文件）状态
    private func resetCustomEditorState() {
        showJsonEditor = false
        jsonEditorText = ""
        jsonEditorError = nil
    }

    /// 已有配置 → 预设 ID（gemini 兼容旧配置按自定义编辑）
    /// ★ 已删除的类型（旧存档的 `.openAICompatible` 会在解码时变成 `.custom`）走最后的
    ///   `.custom` 分支；若日后又删类型，也要在这里补上兜底，否则返回的 ID 不在
    ///   `presets` 里会落到 Picker 兜底绑定（虽不崩，但会静默显示成首个预设）。
    private func presetID(for cfg: APIConfigItem) -> String {
        switch cfg.apiType {
        case .openAI:           return "openai"
        case .deepseek:         return "deepseek"
        case .kimi:             return "kimi"
        case .anthropic:        return "anthropic"
        case .openRouter:       return "openrouter"
        case .siliconFlow:      return "siliconflow"
        case .copilot:          return "copilot"
        case .localLog:
            switch cfg.agentProvider {
            case .claudeCode: return "local-claude"
            case .codex:      return "local-codex"
            case .cursor:     return "local-cursor"
            case .dsh:        return "local-dsh"
            case .zcode:      return "local-zcode"
            case .customPath: return "custom"
            }
        case .custom, .gemini:
            return "custom"
        }
    }

    /// 系统文件选择器：选择本地日志文件或目录
    private func pickLocalPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            draftLocalPath = url.path
        }
    }

    // ============================================================
    // MARK: - 自定义 JSON 配置
    // ============================================================

    /// 「编辑配置(JSON)」：字段映射 JSON 编辑器（预填格式模板）
    private var jsonConfigEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $jsonEditorText)
                .font(.system(size: 10, design: .monospaced))
                .frame(height: 180)
                .padding(4)
                .background(a.progressBg)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 6) {
                Text(L("key = field name, value = JSON path (leave blank if unused)"))
                    .font(.system(size: a.fontQuotaReset))
                    .foregroundStyle(a.textTertiary)
                Spacer()
                Button(L("Apply")) { applyJSONConfig() }
                    .font(.system(size: a.fontQuotaReset, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(a.accent)
                    .clipShape(Capsule())
                    .buttonStyle(.plain)
            }

            if let jsonEditorError {
                Text(jsonEditorError)
                    .font(.system(size: a.fontQuotaReset))
                    .foregroundStyle(.red)
            }
        }
        .padding(8)
        .background(a.progressBg.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// 生成 JSON 配置文本：新建时用模板，编辑已有配置时带出当前路径
    private func defaultKeyPathsJSON() -> String {
        let template: [String: String] = [
            "totalTokens": "total_usage",
            "totalCost": "total_cost",
            "currency": "currency",
            "activeDays": "active_days",
            "models": "models",
            "modelName": "name",
            "modelTokens": "tokens",
            "modelPercent": "percent",
            "daily": "daily_breakdown",
            "dailyDate": "date",
            "dailyTokens": "tokens",
            "dailyLevel": "level",
        ]
        return keyPathsJSON(draftKeyPaths.isEmpty ? template : draftKeyPaths)
    }

    /// 字典 → 缩进 JSON 文本
    private func keyPathsJSON(_ dict: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    /// 「编辑配置(JSON)」应用：解析 JSON 文本 → draftKeyPaths
    private func applyJSONConfig() {
        guard let data = jsonEditorText.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            jsonEditorError = L("Failed to parse JSON. Check the format (keys are field names such as totalTokens, values are path strings).")
            return
        }
        var paths: [String: String] = [:]
        for (k, v) in obj {
            if let s = v as? String, !s.isEmpty {
                paths[k] = s
            }
        }
        draftKeyPaths = paths
        jsonEditorError = nil
    }

    // ============================================================
    // MARK: - 操作
    // ============================================================

    private func clearApiDraft() {
        draftName = ""
        draftUrl = ""
        draftKey = ""
        showAPIKey = false   // 每次打开表单都默认隐藏 key
        draftApiType = .openAI
        draftPolling = 300
        editingConfigID = nil
        draftKeyPaths = [:]
        resetCustomEditorState()
        draftOrgID = ""
        draftCopilotOrg = ""
        draftAgentProvider = .claudeCode
        draftLocalPath = ""
        selectedPresetID = presets.first?.id ?? "openai"
        if let first = presets.first { applyPreset(first.id) }
    }

    private func startEditing(_ cfg: APIConfigItem) {
        editingConfigID = cfg.id
        showApiAddForm = false
        showAPIKey = false   // 编辑已有配置时同样默认隐藏 key
        draftName = cfg.name
        draftUrl = cfg.baseURL
        draftKey = cfg.apiKey
        draftApiType = cfg.apiType
        draftPolling = cfg.pollingInterval
        draftKeyPaths = cfg.customKeyPaths
        resetCustomEditorState()
        draftOrgID = cfg.organizationId
        draftCopilotOrg = cfg.copilotOrg
        draftAgentProvider = cfg.agentProvider
        draftLocalPath = cfg.localLogPath
        selectedPresetID = presetID(for: cfg)
    }

    private func cancelEditing() {
        editingConfigID = nil
        clearApiDraft()
    }

    private func addConfig() {
        var type = draftApiType
        var provider = draftAgentProvider
        if type == .custom, !draftLocalPath.isEmpty {
            type = .localLog
            provider = .customPath
        }
        let keyPaths = type == .custom ? draftKeyPaths : [:]
        dashVM.addAPIConfig(
            name: draftName.isEmpty ? type.displayName : draftName.trimmingCharacters(in: .whitespaces),
            baseURL: draftUrl.trimmingCharacters(in: .whitespaces),
            apiKey: draftKey,
            type: type,
            pollingInterval: draftPolling,
            customKeyPaths: keyPaths,
            organizationId: draftOrgID.trimmingCharacters(in: .whitespaces),
            copilotOrg: draftCopilotOrg.trimmingCharacters(in: .whitespaces),
            agentProvider: provider,
            localLogPath: draftLocalPath.trimmingCharacters(in: .whitespaces)
        )
        showApiAddForm = false
        clearApiDraft()
    }

    private func saveEdit(id: String) {
        var type = draftApiType
        var provider = draftAgentProvider
        if type == .custom, !draftLocalPath.isEmpty {
            type = .localLog
            provider = .customPath
        }
        let keyPaths = type == .custom ? draftKeyPaths : [:]
        dashVM.updateAPIConfig(
            id: id,
            name: draftName.trimmingCharacters(in: .whitespaces),
            baseURL: draftUrl.trimmingCharacters(in: .whitespaces),
            apiKey: draftKey,
            type: type,
            pollingInterval: draftPolling,
            customKeyPaths: keyPaths,
            organizationId: draftOrgID.trimmingCharacters(in: .whitespaces),
            copilotOrg: draftCopilotOrg.trimmingCharacters(in: .whitespaces),
            agentProvider: provider,
            localLogPath: draftLocalPath.trimmingCharacters(in: .whitespaces)
        )
        cancelEditing()
    }

    /// 配置列表行次级文案：本地源显示路径/类型名，其余显示接口地址
    private func secondaryText(for cfg: APIConfigItem) -> String {
        if cfg.apiType == .localLog {
            if cfg.agentProvider == .customPath { return cfg.localLogPath }
            // Z.ai Coding Plan：显示区域主机（国内/国际站走不同端点，是国内站才有余额）
            if cfg.agentProvider == .zcode {
                let host = URL(string: cfg.baseURL)?.host ?? "open.bigmodel.cn"
                return "\(cfg.agentProvider.spec.displayName) · \(host)"
            }
            return cfg.agentProvider.spec.displayName
        }
        return cfg.baseURL
    }
}

// ============================================================
// MARK: - Z.ai 接口地址选择
// ============================================================

/// Z.ai Coding Plan 的**接口地址下拉**（国内站 / 国际站）。
///
/// ★ 两个官方节点的**端点路径完全相同**，只有 host 与「有无账户余额」不同
///   → 不给自由文本地址框，而是像选厂商一样在这两个 URL 里挑一个（选中即写入 `baseURL`）。
/// ★ 绑定用 `ZaiRegion` 而不是 URL 字符串：`detect` 只比较 host，
///   老配置里的 `https://open.bigmodel.cn/`（带尾斜杠 / 带路径）也能正确回显，
///   不会因字符串不完全相等而让菜单显示空白。
struct ZaiEndpointPicker: View {

    @Binding var baseURL: String

    /// 实际生效的 base URL（空地址 → 国际站，与运行期回退口径一致）
    private var resolvedBaseURL: String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? ZaiRegion.global.defaultBaseURL : trimmed
    }

    var body: some View {
        Picker(L("URL"), selection: Binding(
            get: { ZaiRegion.detect(base: resolvedBaseURL) },
            set: { baseURL = $0.defaultBaseURL }
        )) {
            ForEach(ZaiRegion.allCases) { region in
                Text(region.defaultBaseURL).tag(region)
            }
        }
        .pickerStyle(.menu)
    }
}
