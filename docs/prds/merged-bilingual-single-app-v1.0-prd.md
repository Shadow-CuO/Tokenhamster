# PRD — 合并为单一 app：设置内切换语言 / 币种（v1.0）

## 1. 背景与决策

| 时间 | 决策 | 状态 |
|---|---|---|
| 2026-09-19 | 国内版（`main`）与国际版（`feat/zai-global`）**分成两个独立 app**，接受重复 | ❌ **已否决**（用户 2026-09-25 决定） |
| 2026-09-25 | **合并回单一 app**，语言与币种由用户在设置中切换 | ✅ 本文档 |

否决原因：两份代码重复维护成本高；真正的差异只有「语言」与「币种/站点」两项，适合做成运行时偏好。

## 2. 目标 / 非目标

**目标**
1. 合并 `feat/zai-global` 到 `main`，功能（`ZaiRegion` 分区）保留。
2. 引入运行时可切换的双语文案（简体中文 / English，默认跟随系统）。
3. 设置页提供 **语言**（跟随系统 / 简体中文 / English）与 **单位—币种**（¥ CNY / $ USD）两个选择器，选择持久化并立即生效。
4. 覆盖范围：界面文案、错误提示/状态文案、数据源与预设显示名、Widget 与右键菜单。

**非目标**
- ❌ 汇率换算。币种偏好**只作为「未知币种」时的默认值**，各数据源自带币种（bigmodel=CNY、Cursor=USD…）照旧。
- ❌ 数字量级单位（万/亿 ↔ K/M/B）切换：`formattedTokenCount` 固定 K/M/B。
- ❌ 语言与币种**不**联动 Z.ai 站点；站点仍由用户填的 `baseURL` 决定（`ZaiRegion.detect`）。
- ❌ 币种选项**只写 ISO 代码**（`CNY` / `USD`），不写「人民币 / Chinese Yuan」全称 ——
  ISO 代码是国际通用写法，**不随界面语言翻译**，因此也不进文案表。
- ❌ 设置页币种下方**不放说明文字**。
- ❌ 已发布前不做向后兼容（见 `project-constraints`）。

## 3. 双语范围界定（重要）
双语集合 = **两个版本之间真实存在的文案差异**，即 i18n 提交 `d758772` 中 15 个源文件、186 行 1:1 替换的中英文对照（`git diff d758772^ d758772`）。

两版**一致**的文案（本就英文）本次不动，属**已知遗留**：

| 位置 | 文案 |
|---|---|
| Dashboard / 详情页区块标题 | `TOTAL TOKENS` / `MODELS` / `TREND` / `ACTIVITY` / `SETTINGS` |
| 额度窗口 | `Session` / `Weekly` / `% left` / `Reset …` |
| 倒计时不足最小单位时 | `<1m` / `<1h`（由 `formatCountdown` 产出，测试断言依赖它，不加表） |
| 表单零散标签 | `Key:` / `profile` |

理由：这些是刻意的视觉标签（大写英文区块标题是设计语言），且中文版历史上一贯如此；为控制改动面先保持原样。

★ **计数不是双语项，而是全局唯一规范**（见第 3.1 节）：`1.2B` 在任何语言下都是 `1.2B`。

### 3.1 计数规范（全局，不随语言变化）

> 用户要求：**统一计数规范 —— 以 1K / 1M / 1T 等计数，并且不翻译，保持英文。**

| 项 | 规则 |
|---|---|
| 档位 | `K` / `M` / `B` / `T`（英文，**中文界面同样是 `1.2B`**，不写「12 亿」） |
| 小数位 | 固定 **1 位**，但**去掉末尾 `.0`** → `1K` / `1.5K` / `843.2M`（不是 `1.0K`） |
| 不足 1000 | 整数原样，无后缀（`999`） |
| 进位保护 | 四舍五入够得着上一档就进位 → `999_999 → "1M"`（**不出现 `1000K`**） |
| 唯一入口 | `formatCompactCount(_:)` / `Int.formattedTokenCount`（`DataModels.swift`） |

**接入点**：模型行 / 额度列、趋势图峰值（Peak）、详情页「累计 X tokens」、热力图悬浮提示。

#### 3.1.1 TOTAL TOKENS 头部专例外（`formatTotalTokensDisplay`）

头部是面板上唯一"想看见具体数字"的位置，所以规则反了一档 —— **优先原样显示完整数字**，
放不下才压缩，且压缩时**优先留在 K**（`1000000K` 比 `1B` 更「看得见数」）：

| 值（十进制位数） | 输出 | 说明 |
|---|---|---|
| `999,999,999`（9 位） | `999,999,999` | 原样 |
| `9,999,999,999`（10 位） | `9,999,999,999` | 原样（**10 位是上限**） |
| `12,345,678,901`（11 位） | `12345679K` | 超出 → 用 K |
| `1,234,567,890,123`（13 位） | `1234567890K` | K 乘数正好 10 位，**仍不升 M** |
| `12,345,678,901,234`（14 位） | `12345679M` | K 乘数会到 11 位 → 只好升 M |
| `10,000,000,000,000,000`（17 位） | `10000000B` | K 14 位 / M 11 位都超限 → B |
| `9,999,999,999,999` | `10000000M` | 四舍五入进位使 K 乘数变 11 位 → 升 M |

- 判定用**数字本身的十进制位数**（不含千分位逗号）：`9,999,999,999` 是 13 个字符但只有 10 位 → 原样
- 乘数**取整、不带小数**；乘数位数**永不超过 10**
- 仅此一处使用，其他计数仍走通用规范

**★ 本次收敛的重复实现**：改动前同一规则有 **5 份各不相同的实现** ——
`Int.formattedTokenCount`、`ModelItem.tokenFormatted`、`ModelRowItem.tokenFormatted`
（三份重复）、以及 `DashboardView.peakFormatted` / `AgentDetailDashboardView.peakFormatted`
（只到 M，且 **K 用 0 位小数** → 显示 `843K`，与模型行的 `1.0K` 不一致）。
现已全部改为调用唯一入口；新增 `noScatteredMagnitudeFormatting` 测试扫描源码，
禁止再出现 `String(format: "%.1fM", …)` 这类散落实现。

## 4. 技术方案

### 4.1 机制选择

| 方案 | 结论 |
|---|---|
| String Catalog（`.xcstrings`）/ `.lproj` + SwiftUI 自动本地化 | ❌ 运行期切换依赖 `\.locale` 环境值；服务层/`NSMenu`/Widget 仍需 bundle 拼装；`.lproj` 在 `PBXFileSystemSynchronizedRootGroup` 下的归属不确定 |
| **Swift 侧查表（选用）** | ✅ 线程安全、无 bundle/构建系统依赖、App / Widget / 测试可用同一套途径、可单测校验键完整性 |

### 4.2 组件

- `TokenHamster/Localization.swift`
  - `enum AppLanguage { system, chinese, english }`，`.system` 按 `Locale.preferredLanguages` 解析
  - `enum CurrencyPreference { cny, usd }`，首启按系统地区（CN→CNY，其余 USD）
  - `enum Localization`：`NSLock` 保护的当前语言快照 + `t(key:)` / `t(key:args:)`（`String(format:)`）
  - `func L(_ key: String) -> String`、`func L(_ key: String, _ args: CVarArg...) -> String`
  - `final class AppSettingsStore: ObservableObject`：SwiftUI 面，持久化 + 通知刷新
- `TokenHamster/LocalizationTable.swift`：`zh` 表（**key = 英文源文案**，value = 中文）。英文无需表——英文就是源码本身；命中不到即原样返回。
- 插值文案用 **`%@` 格式键**：`Text("\(x) tokens total")` → `Text(L("%@ tokens total", x))`，中文表 `"%@ tokens total": "累计 %@ tokens"`。
- `TokenHamsterWidget/WidgetL10n.swift`：Widget 自带小表（3 条），语言取自 App Group suite 的 `app_language`（主 App 写入），读不到则跟随系统。
  ★ 实测有效：App 与 Widget **都未开沙箱** → `UserDefaults(suiteName: "group.…")` 落在
  `~/Library/Preferences/group.….plist`，跨进程可读（`defaults read` 验证）。日后若开启沙箱，
  需补 `application-groups` entitlement 才能继续共享。

### 4.3 哨兵字符串（不得本地化）

| 哨兵 | 产出 | 消费 | 处理 |
|---|---|---|---|
| `"Available"` / `"Used up"` | `TokenService`（`resetTimeString`） | `DashboardViewModel:354` `status != "Available"`；`DashboardView` / 详情页渲染 | **生产端保持英文原值**，仅在渲染处 `L(...)`；表中补了显示译文（"可用"/"已用完"） |
| `"Cumulative"` | `TokenService` / `DSHUsageStatsSource` | 测试断言；渲染处 | 同上（显示译文 "累计"） |
| `"<1m"` / `"<1h"` | `formatCountdown` | 测试断言 + 展示 | **不动**（两版一致，不加表） |
| `quotaUnit == "%"` | 各 fetcher | `AgentSnapshot.quotaText` | 保持 `"%"` |

★ 踩过的坑：最初把哨兵整套跳过（不建表条目），结果中文界面里详情页直接显示 "Used up" ——
**「生产端不本地化」不等于「不需要译文」**，哨兵仍需**渲染用**的译文条目。
由 `LocalizationTests.sentinelDisplayTranslationsExist` 守住。

### 4.4 生效时机

- 视图文案：`@ObservedObject AppSettingsStore.shared` 触发重绘（视图内的 `L()` 在 body 求值时执行）。
- 服务层文案（快照内字符串，如 `resetTimeString` / 错误信息）：随下次刷新重写 → **切换语言后自动触发一次刷新**。
- 视图渲染期计算的文案（`AgentSnapshot.quotaText`、`AgentDetailDashboardView` 等）随重绘即时更新。

## 5. 验收标准

1. `main` 已包含 `ZaiRegion` 等国际站功能，分支合并记录可追溯。
2. 设置页可选择 语言 / 币种，重启后保持；语言默认跟随系统。
3. 切换语言后：设置页、仪表盘、详情页、数据源管理页、右键菜单文案立即变为目标语言；错误提示与快照内文案在刷新后一致。
4. 英文态下界面与 `feat/zai-global` 一致；中文态下界面与旧 `main` 一致（除第 3 节列出的遗留项）。
5. 哨兵逻辑未被破坏：`MockServerTests` / `TokenHamsterTests` 中 `"Available"` / `"Used up"` / `"<1m"` / `"<1h"` 断言保持通过。
6. 全量测试通过（含新增：语言解析、币种默认、文案表键完整性、哨兵显示译文）。

## 6. 风险

| 风险 | 缓解 |
|---|---|
| 漏改文案导致中英混杂 | `LocalizationTableIntegrityTests` 扫描源码 `L("…")` 字面量，断言中文表键齐全（含 Widget 独立表） |
| 哨兵被误本地化 → 逻辑静默失效 | 第 4.3 节白名单 + 既有测试（`MockServerTests` 断言生产端仍是英文原值） |
| 脚本批量替换误伤（注释 / 枚举 rawValue / Codable 键） | 逐文件 `git diff` 复核 + 全量测试 |
| 长英文在中文布局里溢出 | 仅替换文案不改布局，沿用既有版式（英文版本已在这些位置跑过） |
| ★ 测试并行 + 进程级语言状态 → 随机失败 | 本地化测试**只测纯函数与实例状态**，不改全局语言（见 `LocalizationTests` 文件头约定）；真实切换链路用离屏渲染人工验收 |

## 7. 实施记录（2026-09-25）

| 项 | 结果 |
|---|---|
| 合并 | `--no-ff` 合并 `feat/zai-global`（提交 `1c7055b`）；`ZaiRegion` 功能保留 |
| 双语改动面 | 15 个源文件、**183 处**字面量裹 `L(...)`；中文表 **175** 条（172 对照 + 3 哨兵显示译文） |
| 新增文件 | `Localization.swift`、`LocalizationTable.swift`、`TokenHamsterWidget/WidgetL10n.swift`、`LocalizationTests.swift` |
| 设置页 | 语言（跟随系统 / 简体中文 / English）+ 单位（人民币 / 美元），`AppSettingsStore` 持久化 |
| 切换语言 | 视图即时重建（`@ObservedObject AppSettingsStore.shared`）+ `relocalizeSnapshots()` 重拉一次换掉快照内文案 |
| 测试 | **303 项全绿**（272 原有 + 21 本地化 + 10 计数规范） |
| 人工验收 | 离屏渲染（`NSHostingView` + `cacheDisplay`）目视：设置页 / 额度管理页 / 详情页的中英两态 |
| 计数规范 | 5 份重复实现收敛为 `formatCompactCount`；K/M/B/T 不翻译、去掉末尾 `.0`、带进位保护 |
| 头部专例外 | `formatTotalTokensDisplay`：≤ 10 位原样、超出后用 K 起步（K 乘数封顶 10 位，装不下才升 M/B/T） |
| 跨进程 | App / Widget 均未开沙箱 → App Group suite 实际可跨进程共享（`defaults read` 实测），Widget 双语随设置生效 |

★ 币种偏好的可观察面很窄（各数据源多自带币种）：只影响**聚合币种**与
`currencySymbol(for:)` 的空币种回退。如果预期是「全局换符号」或「联动 Z.ai 站点」，
需要另开改动 —— 本版按用户选择「只做默认币种（不换算）」实现。

