# API 数据源接入（官方接口清单）

记录 TokenHamster 里每个 API 型数据源**实际调用的端点**、字段依据，以及为什么某些厂商没接入。

原则：**只接有真实可用接口的厂商**。读不出数据的源一律不加 —— 卡片显示 0 比没有这个选项更糟。

## 已接入

| 预设 | apiType | 端点 | 语义 | 字段依据 |
|---|---|---|---|---|
| OpenAI | `.openAI` | `GET /v1/organization/usage/completions`、`/costs` | 累计 | 官方 Usage API（需组织权限 Key） |
| Anthropic Claude | `.anthropic` | `GET /v1/organizations/{org}/usage_report`、`/limits` | 累计 | Admin API（`sk-ant-admin-…` + 组织 ID） |
| Google Gemini | `.gemini` | — | — | ⚠️ 无公开用量 API，仅兼容旧配置 |
| DeepSeek | `.deepseek` | `GET /user/balance` | 余额 | `balance_infos[].total_balance` |
| Moonshot Kimi | `.kimi` | `GET /users/me/balance` | 余额 | `data.available_balance`，需 `code == 0` |
| **OpenRouter** | `.openRouter` | `GET /api/v1/key` → 失败退 `/credits` | 余额 | 官方 OpenAPI：`limit_remaining` / `total_credits − total_usage` |
| **硅基流动 SiliconFlow** | `.siliconFlow` | `GET /v1/user/info` | 余额 | 官方文档：`data.totalBalance`（= 赠费 + 充值） |

### OpenRouter 细节

- 先用 `GET /key` 的 `limit_remaining`（**普通推理 key 即可**，覆盖面最广）
- `limit_remaining` 为 `null`（无限额度 key）→ 退到 `GET /credits` 算 `total_credits − total_usage`
  ⚠️ `/credits` 需要 **management key**，普通 key 会 401
- 所以：如果 key 无限额度且不是 management key，会如实报错而不是显示 0

### 硅基流动细节

- `data.totalBalance` 是字符串，等于 `balance`（赠费）+ `chargeBalance`（充值）
- 币种按域名推断：`*.cn` → CNY，其余 → USD（`SiliconFlowService.currency(forHost:)`）

### OpenAI 兼容网关（已删除：2026-09-25）

`.openAICompatible` 枚举类型、`apiPresets` 预设与 `OpenAICompatibleService` 服务**已全部删除**。
原因：它读的是一次性结算的 `hard_limit_usd − total_usage/100`，与同名的 `.openAI`
（官方组织用量 API）极易混淆；而中转网关的余额用「自定义」类型 + 字段映射同样能读。

**旧配置怎么办**：`APIConfigItem.init(from:)` 会把已保存的 `"openAICompatible"`
宽容解码为 `.custom`（连同未知 rawValue 一并兼容），不会因解码失败丢掉整份配置数组。
用户需自行在「编辑配置(JSON)」里填端点与字段映射 —— 我们**不预先填一套映射**，
因为单端点的自定义源无法复现上面那个双端点减法（填一半的映射会显示误导性的数字）。

以下细节仅作存档，供用户手工配映射时参考：

- `hard_limit_usd` = **总额度**（不是剩余！），剩余 = `hard_limit_usd − total_usage / 100`
- ⚠️ `total_usage` 单位是**美分**（0.01 美元）—— 与 OneAPI 自己的换算方式一致
- ⚠️ **官方 OpenAI 已废弃这些端点**，官方账户请用「OpenAI」预设
- 网关不支持时直接报错，不静默返回 0（该行为现在由自定义源自身决定）

## 未接入（以及原因）

这些厂商**没有公开的余额/用量接口**，因此没有加预设。它们的 OpenAI 兼容端点只能列出
`/v1/models`（**模型目录，不含任何用量数字**），拿不到余额，所以不能当数据源用：

Groq、Together、xAI Grok、Mistral、MiniMax、阿里百炼 DashScope、Novita、DeepInfra、Ollama（本地）等。

### 智谱 GLM 的特别说明

**`open.bigmodel.cn` 的余额接口：不存在（已验证）**

该网关对**任意路径**都返回 401（包括故意编造的路径），所以无法用状态码判定端点是否存在。
早期探测得出的 `/user/info`、`/billing/balance` 等路径**均不可信**，故未接入。

**但 GLM Coding Plan 有官方用量接口（在 `api.z.ai` 主机上）** —— 见下节。
两者的区别是主机不同：编码套餐的用量接口在 `api.z.ai`，不在 `open.bigmodel.cn`。

> 注意：智谱的**Coding Plan（订阅制）**与**开放平台余额**是两套体系。
> Coding Plan 是订阅额度制，**不涉及金额**，所以没有"余额"可读，但有"额度百分比"可读。

## GLM Coding Plan 的官方用量接口

依据：Z.ai 官方仓库 [`zai-org/zai-coding-plugins`](https://github.com/zai-org/zai-coding-plugins)
的 `plugins/glm-plan-usage`（官方 `/glm-plan-usage:usage-query` 命令就用它）。

| 端点 | 内容 | query |
|---|---|---|
| `GET {base}/api/monitor/usage/model-usage` | 模型用量 | `startTime`、`endTime` |
| `GET {base}/api/monitor/usage/tool-usage` | MCP 工具用量 | 同上 |
| `GET {base}/api/monitor/usage/quota/limit` | **额度** | 无 |

`base` = `https://open.bigmodel.cn`（国内）或 `https://api.z.ai`（国际）。

请求头（★ **不是** `Bearer` 前缀）：

```
Authorization: <Coding Plan API Key>
Accept-Language: en-US,en
```

两个端点都要求 `success == true` **且** `code == 200`，否则视为失败。

#### `quota/limit` 的 `data.limits[]`

```jsonc
{"code":200,"success":true,"data":{
  "planName":"Pro",                  // 也可能叫 plan / plan_type / packageName / level
  "limits":[
    {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25,
     "nextResetTime":1785816000000},
    {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":9,
     "nextResetTime":1786291200000},
    // 积分制套餐（Lite 等）返回 CREDIT_LIMIT，字段语义与 TOKENS_LIMIT 完全相同：
    {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":2000,
     "currentValue":0,"remaining":2000,"percentage":0},
    {"type":"TIME_LIMIT","unit":5,"number":1,"percentage":5}   // MCP（月窗口）
  ]
}}
```

**窗口由 `unit` + `number` 编码，不是数组顺序**：

| unit | 含义 | 换算（分钟） |
|---|---|---|
| 1 | day | ×1440 |
| 3 | hour | ×60 |
| 5 | minute | ×1 |
| 6 | week | ×10080 |

→ `unit=3, number=5` = 300 分钟 = **5 小时会话**；
  `unit=6, number=1` = 10080 分钟 = **周**；
  `TIME_LIMIT` + `unit=5, number=1` = **MCP 月窗口**（特殊标记，非 1 分钟）。

★ **`type` 同时可能是 `CREDIT_LIMIT`** —— 积分制套餐（如 Lite）用它代替 `TOKENS_LIMIT`。
  **只认 `TOKENS_LIMIT` 会让积分制用户完全读不到官方额度。**

★ `percentage` 可直接用；也可用 `usage`/`remaining`/`currentValue` 重算（更可靠）：
  `used = usage − remaining`（或 `currentValue`），`percent = used / usage`。

★ `nextResetTime` 是 **epoch 毫秒** → 重置倒计时。建议加**合理性校验**：
  5 小时窗口的重置不可能在 10 小时之后（防止时区处理出错时显示荒谬倒计时）。

#### `model-usage` 的矩阵结构

```jsonc
{"code":200,"success":true,"data":{
  "x_time": ["2026-09-19 10:00", ...],                    // 时间轴标签
  "modelDataList": [
    {"modelName":"glm-5.3", "tokensUsage":[0, 120, ...]}   // 与 x_time 下标对齐
  ]
}}
```

★ **这是「矩阵」而不是逐条记录** —— `tokensUsage[i]` 对应 `x_time[i]`。
  按 `list`/`records`/`items` 去找记录会**完全读不到**。

查询参数：`startTime`/`endTime`（**当地时区** `yyyy-MM-dd HH:mm:ss`）。
实测可用范围：**1 天（逐小时）与 30 天（逐日）**。

#### 账户余额（仅国内站）

`GET https://www.bigmodel.cn/api/biz/account/query-customer-account-report`

- ⚠️ 主机是 **`www.bigmodel.cn`**（控制台），**不是** `open.bigmodel.cn`（API）
- `success == true` → `data.availableBalance`（回退 `data.balance`）、
  `data.rechargeAmount`、`data.giveAmount`、`data.totalSpendAmount`
- ★ **仅国内站有**；`api.z.ai` 无对应端点 → 国际站无法显示金额

##### 为什么能确定国际站没有余额端点

`api.z.ai` 的 catch-all **是按前缀而非按路由**的，所以「非 404」只能证明前缀存在：

| 路径 | body |
|---|---|
| `/api/definitely-not-real-xyz` | `code 500 / 404 NOT_FOUND` |
| `/api/monitor`（连这一层都算） | `code 401 / token expired` |
| `/api/monitor/usage/quota/bogus` | `code 401` |
| `/api/biz` 及其下**任意**路径 | `code 401` |

→ `/api/biz/**` 下任意路径都返回 401，**401 无法证明具体端点存在**。
   加之 `docs.z.ai` 无任何 billing/account 接口 → 结论：**国际站无账户余额端点**。

（额度/用量端点之所以可信，是因为官方插件 + 两个独立第三方实现佐证，
**而不是**因为 401。）

依据：`steipete/CodexBar`（Swift，生产实现 `Plugins/zai.js`）与
`tddworks/ClaudeBar`（Swift，含 fixture 测试）—— 两个独立实现且字段一致。

### 站点分区

| | 国内站 | 国际站 |
|---|---|---|
| API host | `open.bigmodel.cn` | `api.z.ai` |
| 额度 / 用量端点 | ✅ 路径完全相同 | ✅ |
| 账户余额 | ✅（`www.bigmodel.cn` 控制台） | ❌ 无 |
| 计价币种 | CNY | USD |

差异集中在 `ZaiRegion`（`defaultBaseURL` / `currency` / `hasAccountBalance`），
由 `ZaiRegion.detect(base:)` 按 host 推断（未知 host → 国际站）。
额度与用量接口**路径一致**，所以除 host 与余额外无需分叉。

> ★ **单一 app（2026-09-25 起）**：不再分国内版 / 国际版两个构建。
> - **站点**由表单里的**地址下拉**决定（选项即两个官方 URL，写入 `baseURL`）：新增时默认
>   **跟随系统地区**（中国大陆 → 国内站，其余 → 国际站），老配置按已存的 `baseURL` 推断（`ZaiRegion.detect`）；
> - **界面语言**（跟随系统 / 简体中文 / English）与**展示币种**（¥ CNY / $ USD）
>   在设置页切换，持久化后立即生效；
> - 币种偏好**只作「数据源未提供币种」时的默认值，不做汇率换算**，也**不联动**站点。
> - 详见 `docs/prds/merged-bilingual-single-app-v1.0-prd.md`。

### 本项目的接入方式

**只读官方 API —— 需要 Coding Plan API Key；不再读 ZCode 本地账本。**

| 项 | 做法 |
|---|---|
| 凭据 | 用户**手动粘贴 Coding Plan API Key**（同 Cursor 粘 cookie 的模式）；表单强制必填 |
| 地址 | 表单里像选厂商一样在**两个官方 URL** 里选（下拉菜单：`open.bigmodel.cn` / `api.z.ai`），无需手打地址；新增默认跟随系统地区 |
| 额度 | 官方 `quota/limit` → 直接是真实百分比，不再折算 |
| 套餐档位 | **不再需要用户手选** —— 官方返回 `usage` 上限与 `planName` |
| 模型用量 | 官方 `model-usage`（30 天）→ 与本地历史合并 |
| 账户余额 | **仅国内站**（`www.bigmodel.cn` 控制台端点）→ `totalCost`；国际站恒为 0 |
| 失败行为 | 额度必需：失败即报错（**不显示假 0**）；用量/余额可选：失败不影响额度 |

> ★ **国际站不显示金额是设计选择，不是缺陷**：Coding Plan 为订阅制，
> 计划内调用不产生金额（官方 FAQ：不扣账户余额）。加上国际站本就无余额端点，
> 所以金额列留空。又因 Z.ai 有 token 用量时 MODELS 行显示百分比而非金额，
> **界面上本就不会出现金额**，无需额外隐藏逻辑。

代码：`ZaiQuotaFetcher.swift`（解析 + 请求）、`ZaiPlanSource.swift`（组装）、
`ZaiUsageHistory.swift`（本地累积）。

#### 已删除（相对上一版）

- **ZCode 本地 SQLite 账本**读取（连带 `SQLiteReadOnly.swift` 整份删除 —— 它只服务这一个源）
- **credit 折算**（`ZaiCreditCalculator`）与**套餐档位**（`ZaiPlanTier`）：
  改用官方百分比后，折算、档位、`needsPlanTier`/`zaiPlanTier` 全部不再需要
- 顺带修掉了 credit 折算**漏算 MCP 工具消耗**的老问题（官方百分比已包含）

#### 热力图延长（本地存储）

官方 `model-usage` 的查询上限是 **30 天**，而热力图默认铺 24 周 → 单次响应永远填不满。

做法：把每次拿到的「模型 × 日期」合并进 `ZaiUsageHistory` 并落盘
（`AppConstants.zaiUsageHistoryKey`），**同一 (模型, 日期) 取 max**：

- 官方对已过去的日期返回终值、对当天返回递增中的值 → max 保证单调不回退
- 重复抓取**幂等**，不会重复累加

效果：首次使用只有 30 天，**用得越久热力图越长**。

⚠️ 日期键用**当地零时 epoch 秒**，不是 `tokenDayKey` 那种「epoch / 86400」的日序号 ——
后者无法精确反推（UTC+8 下 `dayKey * 86400` 会落回前一天，差一天）。有回归测试固定这点。

### 已知限制

- ⚠️ **`model-usage` 只覆盖 30 天** → 热力图的历史长度取决于 App 已累积多久；
  换机器/清数据会从 30 天重新开始。
- ⚠️ **余额仅国内站有**。`api.z.ai`（国际站）没有对应端点，`totalCost` 恒为 0。
- ⚠️ **MCP 工具用量未单独展示**：`TIME_LIMIT` 已解析（`ZaiOfficialQuota.mcpWindow`）
  但不映射到额度条，避免与 5h/周两个 token 窗口混淆。
- ⚠️ **团队（Team）套餐未支持**：需要额外传 `Bigmodel-Organization` /
  `Bigmodel-Project` 请求头，且 quota 要带 `?type=2`、model-usage 要带 `&type=3`。
- ⚠️ **Coding Plan Key 与平台其他 API Key 不通用**（官方 Warning）。
  Key 在 z.ai / bigmodel.cn → Coding Plan → Plan Overview 处创建。
- ⚠️ **限时活动会改变消耗语义**：活动期内每日 23:00–09:00，ZCode 里用 GLM-5.3-Flash
  **无限量**、其他 Agent **额度翻倍** → 该时段官方百分比可能看起来「涨得比用量慢」。

## 端点探测方法

不要靠猜，也**不要只看状态码**。用对照实验 + 看 body：

```bash
probe() { curl -sS -m 12 -o /tmp/b -w '%{http_code}\n' \
  -H 'Authorization: Bearer sk-invalid' "$1"; head -c 200 /tmp/b; }

probe "https://api.vendor.com/v1/real-endpoint"        # 真实路径
probe "https://api.vendor.com/v1/definitely-bogus-xyz" # 编造路径（对照组）
```

实测过的三种行为 —— **没有通用判据**：

| 主机 | 真实路径 | 编造路径 | 可用判据 |
|---|---|---|---|
| `openrouter.ai`、`api.siliconflow.cn` | 401 | **404** | ✅ 状态码即可 |
| `open.bigmodel.cn` | 401 | **401** | ❌ 全废（统一鉴权） |
| `api.z.ai` | 200 | **200** | ❌ 全废（`/api/*` catch-all）→ **只能看 body** |

`api.z.ai` 的判据是 body 里的 JSON `code`：

- `{"code":401,"msg":"token expired or incorrect"}` → **端点存在**，仅鉴权失败
- `{"code":500,"msg":"404 NOT_FOUND"}` → **路由不存在**

按可靠性排序的调查手段：

1. **官方自己的仓库/插件源码** —— 最权威（Z.ai 的用量接口就是这么找到的）
2. 官方 `/openapi.json` 或文档站（`docs.X/llms.txt` 可列出全部页面）
3. 开源网关源码（如 OneAPI 的 `router/*.go`）
4. 探测 —— 前三者都不可得时才用，且必须带对照组
