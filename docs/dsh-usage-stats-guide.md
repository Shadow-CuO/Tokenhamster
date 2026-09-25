# DSH 用量插件安装指南

> 适用于 TokenHamster 的 **DeepSeek Harness（DSH）** 数据源。
>
> ★ 本文是独立站支持页面的内容源。**页面 URL 必须保持稳定（不带版本号）** ——
> TokenHamster 内部通过单一常量 `AppConstants.dshPluginGuideURL` 指向它。
> 插件改包名、发坏版本、DSH 升版等变化都靠**改这里**响应，不必发新版 App。

---

## 1. 为什么需要装一个插件

TokenHamster 不自己解析 DSH 的会话日志，而是读第三方插件
**`@ychris12138/dsh-usage-stats`** 落盘的聚合缓存：

```text
$DSH_HOME/storages/usage-stats-cache.json      # 默认 ~/.dsh/storages/usage-stats-cache.json
```

**原因**：DSH 的会话日志默认是**多帧 Zstandard**
（`session.v3.jsonl.zstd`，整个文件是若干完整 zstd frame 的拼接，单次解压只能得到第一帧），
且存在多代文件（v0/v1/v2/v3）与 resume/fork 副本会重复计数。
这个插件已经把这些都处理好了，并额外完成：

- 同一 `(turn, step)` 的后续样本**替换**而非累加（先减旧再加新）
- 按「本地日历日 × 供应商/模型」聚合
- 四类 token 桶完整保留（输入 / 输出 / 缓存读 / 缓存写）

所以 TokenHamster 只需要读一个普通 JSON 文件 —— **不需要 DSH 正在运行**，
也不需要 HTTP、端口或任何信任协商。

---

## 2. 安装

### 2.1 先找到你的 profile

DSH 的插件装在 profile 里。先列出已有 profile：

```sh
ls ~/.dsh/profiles
```

常见的有 `web`（浏览器 GUI，`dsh web` 用）和 `desktop`（DSH Desktop 用）。
**装错 profile 会导致「装好了但永远没数据」** —— 因为那个 profile 根本没被加载。

> 把 `$DSH_HOME` 设成过别的目录？那就用 `$DSH_HOME/profiles`，
> 下面的命令同理把 `~/.dsh` 换成 `$DSH_HOME`。

### 2.2 安装插件

```sh
dsh plugin --profile web add "@ychris12138/dsh-usage-stats@0.3.3"
```

- 把 `web` 换成你实际要用的 profile 名。
- **包名必须带 `@ychris12138/` 前缀**：无 scope 的 `dsh-usage-stats` 已被另一个项目占用，
  装错会拿到**完全不同的插件**。
- `@0.3.3` 是 TokenHamster 实测过的版本。想跟最新版可用 `@latest`，
  但**有风险**（见第 6 节）。

### 2.3 重启 DSH

```sh
# 浏览器 GUI：停掉再起
# （如果你是用 dsh web 前台跑的，Ctrl-C 然后重跑即可）
```

DSH Desktop 则**完全退出应用再重新打开**。

⚠️ **重启是必须的**：DSH 的 loader 树在进程启动时固定，新插件行不会被热加载。

---

## 3. 验证是否生效

### 3.1 看缓存文件

```sh
ls -l ~/.dsh/storages/usage-stats-cache.json
```

重启 DSH 跑过至少一轮对话后，这个文件应该出现，且修改时间会持续更新。

### 3.2 看插件自己的面板

重启后在 DSH 里打开**设置 → Token 统计**，应该能看到总量、按天趋势、按模型表格。

### 3.3 和 TokenHamster 对拍

TokenHamster 的 DSH 累计值应当**等于插件面板里的累计值**。
两边不一致时优先相信插件面板 —— TokenHamster 只是它的读者。

---

## 4. 升级

```sh
dsh plugin --profile web update "@ychris12138/dsh-usage-stats"
```

---

## 5. 回退到指定版本

该插件有版本因缺陷被 npm 标记为 `deprecated`（例如某个版本在 DSH Desktop 上会加载失败）。
`deprecated` 只是**警告**，并不会阻止安装 —— 真遇到问题时，**回退是最快的救火手段**：

```sh
dsh plugin --profile web add "@ychris12138/dsh-usage-stats@0.3.3"
```

把 `0.3.3` 换成你想回退到的版本号。查看可用版本与被标记的原因：

```sh
npm view "@ychris12138/dsh-usage-stats" versions
npm view "@ychris12138/dsh-usage-stats" deprecated
```

将 `web` 换成你实际使用的 profile 名，然后**重启 DSH**。

---

## 6. 版本选择建议

| 选项 | 说明 |
|---|---|
| `@0.3.3`（推荐） | TokenHamster 实测过的版本。稳定，但可能落后于作者的修复 |
| `@latest` | 总是最新。**但它有版本因缺陷被标记 deprecated**，未经验证时可能踩到 |

### 该插件的失败长什么样

★ 注意区分：**它出问题时的表现是「插件装了但不工作」，不是 DSH 崩掉。**
DSH 本体不受影响，你看到的是：

- TokenHamster 报「插件数据未更新，请重启 DSH 或升级插件」
- TokenHamster 报「缓存正在重建，请稍后刷新」且一直不消失

真遇到时的处理顺序：

1. 重启 DSH
2. 升级到最新版
3. 回退到本应用已验证的版本（见第 5 节）
4. 仍不行 → 到[插件仓库](https://github.com/Ychris12138/dsh-usage-stats/issues)反馈

TokenHamster 的安装引导里默认选中已验证版本，选最新版会显示风险提示。
---

## 7. 卸载

```sh
dsh plugin --profile web remove "@ychris12138/dsh-usage-stats"
```

然后重启 DSH。

> TokenHamster 侧的表现：DSH 卡片会显示「未安装 dsh-usage-stats 插件」，
> **不会静默变成 0**。历史累计量也不会丢 —— 它已经落进 TokenHamster 自己的 token 账本。

---

## 8. 兼容矩阵

| TokenHamster | 插件版本 | DSH 版本 | 缓存 `version` | 状态 |
|---|---|---|---|---|
| 当前 | `0.3.3` | `>= 0.1.0-rc.6` | `5` | ✅ 支持 |
| 当前 | `< 0.3.3`（已知旧版） | 同上 | `< 5` | ⚠️ 插件会自行重建缓存，TokenHamster 显示「缓存正在重建」 |
| 当前 | 未来版本 | 同上 | `> 5` | ⚠️ 缓存结构有变 → 提示「插件版本比本应用新，请更新 TokenHamster」 |

**TokenHamster 同时支持 N / N-1 个缓存版本** —— 你先升哪一边都不会立刻不可用。

插件对 DSH 的兼容判断是**能力探测**而非版本号比较，
所以 DSH 小版本升级通常不受影响。

---

## 9. 常见问题

### 「插件已安装但没有缓存」

- DSH 装完还没重启 → **重启 DSH**（最常见）
- 装进了没被使用的 profile → 用第 2.1 节的方法确认 profile 名
- DSH 启动了但还没产生任何对话 → 随便跑一轮对话

### 「缓存正在重建，请稍后刷新」

`pricingFingerprint`（价格指纹）变化时，插件会**丢弃全部 sessions 并从会话事件重新折叠**。
另外高频读取只扫活跃会话，所以刚重启后可能连续几秒读到空。
**这是正常的收敛过程**，等一会儿或点一次刷新即可。

### 「插件数据未更新，请重启 DSH 或升级插件」

TokenHamster 发现你的会话日志比缓存里记录的用量样本**新很多**，
说明插件读不到新事件（它通过 DSH 的 session persistence 接口取数，
该接口变动时就可能失效）。处理顺序：

1. 重启 DSH
2. 升级插件到最新版
3. 仍不行 → 到 [插件仓库](https://github.com/Ychris12138/dsh-usage-stats/issues) 反馈

### 「插件版本比本应用新，请更新 TokenHamster」

缓存的 `version` 大于 TokenHamster 支持的版本，说明插件改了缓存结构。
**更新 TokenHamster** 即可，不要手动改缓存文件。

### 安装命令报 `command not found: dsh`

`dsh` 不在你的 PATH 里。先确认：

```sh
which dsh
```

若为空，说明没装 DSH CLI 或 PATH 没配好。
在 Finder 图标启动的 App 里可能出现路径差异 —— TokenHamster 会通过**登录 shell**
执行命令，所以它看到的是你终端里的 PATH。

### 安装命令跑完了，但 TokenHamster 说「安装没有生效」

TokenHamster 以**文件系统事实**为准（profile 下是否有这个包的目录），
不拿退出码冒充成功。请检查：

1. profile 名对不对（第 2.1 节）
2. 手动重跑弹窗里给出的那条命令，看它到底输出了什么
3. 二次校验：`npx --yes github:Ychris12138/dsh-usage-stats --check`

---

## 10. 交给编码 Agent 的安装提示词

以下内容改编自插件 README 的「Agent 友好安装」章节（MIT，
Copyright (c) 2026 dsh-usage-stats contributors）。可直接粘贴给 Codex / Claude Code 等本地 Agent：

```text
安装或更新 dsh-usage-stats，来源：
https://github.com/Ychris12138/dsh-usage-stats

约束：
- DSH_HOME 从环境变量取；没有就用 ~/.dsh。
- 不要读取、打印、编辑或索要 .credentials.yaml、auth.json、cookie 或任何 API key。
- 不要通过反向代理暴露该插件。
- 未经我同意，不要重启或结束已有的 dsh 进程。

步骤：
1. 确认 node、npx、dsh 可用。
2. 优先安装 npm 上的精确稳定版：
   dsh plugin --profile web add "@ychris12138/dsh-usage-stats@0.3.3"
   （或更新已有的 scoped 包）
3. 只有我明确要求测试未发布源码时，才用 github:Ychris12138/dsh-usage-stats。
4. dsh plugin 不可用时，经我同意再用兼容安装器：
   npx --yes github:Ychris12138/dsh-usage-stats
5. 不要同时保留 bundle 安装和手工的 Cordis entry。
6. 用 npx 路径时，确认包已安装且只有一个 Cordis entry，再跑一次 --check。
7. 报告确切的包名/版本、安装路径和解析后的 profile 路径。
8. 如果 dsh web 正在运行，说明需要重启，然后停下。
```

---

## 11. 边界说明

- TokenHamster **不会**替你重启 DSH（那会中断你正在跑的任务）。
- TokenHamster **不打包**该插件的任何代码，只调用官方 `dsh plugin add`。
- TokenHamster **不手动删旧版本**，交给包管理器。
- TokenHamster **不读**插件的凭据、余额或费用相关配置 —— 它只用 token 用量。

---

## 附：插件信息

| 项 | 值 |
|---|---|
| npm 包名 | `@ychris12138/dsh-usage-stats` |
| 实测版本 | `0.3.3` |
| 仓库 | <https://github.com/Ychris12138/dsh-usage-stats> |
| 许可证 | MIT（Copyright (c) 2026 dsh-usage-stats contributors） |
| 缓存路径 | `$DSH_HOME/storages/usage-stats-cache.json` |
| 缓存版本 | `5` |
