# DSH 数据源依赖合规与后备方案

> **状态：只做合规准备，不分叉（不 vendor）。**
>
> TokenHamster 的 DSH 数据源依赖一个第三方 npm 插件。这份文档在**现在**把来源、
> 版本、许可证和退出路径记录清楚 —— 等到作者停更或改格式再补，往往已经晚了。

---

## 1. 依赖清单

### 1.1 运行期实际依赖（主路径）

| 项 | 值 |
|---|---|
| npm 包名 | `@ychris12138/dsh-usage-stats` |
| 固定版本 | `0.3.3` |
| Tarball SHA-1 | `922a62fbfeb8d36af479340ae47b00801281e354` |
| Tarball integrity | `sha512-HMjAAc5fy7RglztdHfgUh4I2ul3a5N2wSz1H2JSqpCqxxdCmHJwC1AwX06eb16AGBgixpcwfnZBcegx/oVbs0A==` |
| 仓库 | <https://github.com/Ychris12138/dsh-usage-stats> |
| 许可证 | MIT |
| 版权行 | `Copyright (c) 2026 dsh-usage-stats contributors` |
| 作者 | ychris12138（`12245039@zju.edu.cn`） |
| 发布 | `2026-09-12T08:20:12Z` |
| 我们消费的产物 | `$DSH_HOME/storages/usage-stats-cache.json`（`version = 5`） |

**TokenHamster 不分发该插件的任何代码**，只在运行时读它落盘的文件。

★ **已知的缺陷版本（npm `deprecated`）**：

| 版本 | 被标记的原因 | 严重度 |
|---|---|---|
| `0.2.6` | `Broken DSH bundle YAML for scoped package name` | 插件装不上 |
| `0.2.7` | `Client bundle registers the legacy unscoped module ID and fails to load in DSH Desktop` | **插件加载失败（DSH Desktop）** |

两者都已给出升级路径（→ `0.2.7+` / `0.2.8+`），我们 pin 的 `0.3.3` 不受影响。

★ **注意区分历史**：另一个插件 `@liuguangzhe/dsh-token-usage` 的 `0.1.0` 曾**导致 DSH 启动崩溃**。
那是**那个**插件的缺陷，与本插件无关 —— 本插件的问题是**插件自己加载失败**，宿主 DSH 始终完好。
不要把两者的故障模式混记。

> ⚠️ 补全项：`gitHead`（发布时的 git commit）需用
> `npm view "@ychris12138/dsh-usage-stats@0.3.3" gitHead` 取回后登记在此。
> 上表两个哈希已从 npm registry 核实，足够用于校验 tarball 完整性。

### 1.2 许可证全文

```text
MIT License

Copyright (c) 2026 dsh-usage-stats contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 2. 已评估过但没有采用的替代品

**保留它们的原因**：它们的源码是「DSH 会话日志物理格式」的现成参考实现。
真要自己解析时，这些比文档准确。

### 2.1 `@kaguyaluna2333/dsh-token-stats` — `lib/log-reader.js` ★ 最有价值

| 项 | 值 |
|---|---|
| 仓库 | <https://github.com/kaguyaluna2333/dsh-token-stats> |
| 许可证 | MIT |
| 为什么没选 | **零落盘** —— 全流程只有 `readFileSync` + `readdir`，唯一缓存是内存里 15 秒；只暴露斜杠命令 / HTTP / 设置页三条路 |

**它记录下来的格式事实（已并入 TokenHamster 的注释与测试）**：

- zstd 容器 = **完整 frame 的拼接**，每个持久化追加批次一个 frame
- ★ **单次 `zstdDecompressSync` 只解得出第一个 frame** ← 自研不可行的核心原因
- 用 **header walk** 定位帧边界（「与持久化后端自身相同的做法」）
- 存在 **torn tail**（崩溃导致的截断帧），读者应忽略
- 值行类型：`text-chunks` / `reasoning-chunks` / `tool-call-chunks`
- 关注事件全集：`assistant/chunk`、`assistant/message`、`request/context`、
  `request/header`、`session/title`、`user/message`、`turn/start`、`turn/end`
- **折叠语义**：同一 `(turn, step)` 的后续样本**替换**而非累加；reasoning 是输出的细分项，不重复计入

### 2.2 `l956615272-hub/dsh-token-usage` — `lib/core/scan.js`

| 项 | 值 |
|---|---|
| npm 包名 | `@liuguangzhe/dsh-token-usage` |
| 仓库 | <https://github.com/l956615272-hub/dsh-token-usage> |
| 许可证 | MIT |
| 版权行 | `Copyright (c) 2026 l956615272-hub` |
| 为什么没选 | 综合次优：**0 star / 0 fork**、2 个版本 / 1 天、口径只累加三桶（漏 `cacheWrite`）、静态声明只兼容 `0.1.5-rc.1/-rc.2`（超出即静默失效）。它的 `cache.json` 路径是可用落盘点，但整体不如 1.1 |

**它记录下来的格式事实**：usage 在 `data.usage`；
模型在 `data.message.source.provider` / `.model`。

---

## 3. 口径差异（换源时必须注意）

三个实现的 `totalTokens` 口径**互不相同**：

| 实现 | 口径 |
|---|---|
| `@liuguangzhe/dsh-token-usage` | **累计求和三桶** `input + output + cacheRead`（漏 `cacheWrite`） |
| `@kaguyaluna2333/dsh-token-stats` / 官方 `token-meter` | **折叠后的最终值**（chunk 与 message 是替换关系） |
| **`@ychris12138/dsh-usage-stats`（当前采用）** | **折叠后的最终值 + 四桶完整** `input + output + cacheRead + cacheWrite` |

→ 换源时**数字会整体跳变**，新旧数据**绝不能混进同一个累计**。

**这就是 `ModelTokenLedger.metricVersion` 存在的原因**：口径变更时递增该版本，
旧账本在加载时被丢弃并重算 —— 宁可重算，也不把两种口径相加。

---

## 4. 分层插槽（为将来换来源留的缝）

数据源已按「取数」与「解析」分离：

```text
TokenHamster/DSHUsageStatsSource.swift
  ├── DSHUsageStatsCache / Session / Day / Buckets   ← 「解析」形状（缓存结构）
  ├── evaluate(cacheData:pluginInstalled:latestLogModification:)  ← 纯函数，可用性判定
  └── aggregate(sessions:calendar:)                  ← 纯函数，聚合
```

换来源时**只改这一层**，`AgentSnapshot` 以上（卡片、模型板块、账本、UI）完全不动。
`evaluate` 与 `aggregate` 都是纯函数，所以换来源时只要给新 fixture 就能验证。

---

## 5. 退出路径（按代价从低到高）

### 5.1 换到另一个落盘插件

只要目标插件有「可离线读取的落盘产物」，改 `DSHUsageStatsSource` 的解析层即可。

★ **准入硬判据**：
1. **有落盘产物。** 零落盘、只暴露 HTTP / 斜杠命令的插件，**无论代码多好都不能选** ——
   否则要引入「DSH 在运行 + 端口发现 + loopback 信任栅栏」三个不可控项。
2. **失败模式可检测。** 优先「显示冻结旧值」（可比对会话日志 mtime 检出），
   而不是「静默显示 0」（与「真的没用过」无法区分）。

### 5.2 用 Node 自己解码 zstd

**已确认可行**，但暂不实现：

- Swift 端没有 ZSTD（Apple `Compression` 框架只提供 LZ4 / zlib / LZMA / Brotli / LZFSE 等）
- **但用户机器必然有 Node ≥ 22.19** —— 这是 DSH 自己的 `engines.node` 要求，没 Node 跑不了 DSH
- **Node 22 内置 `zstdDecompressSync`**

→ 可以起一个 Node 子进程做多帧解码 + 折叠，输出 JSON 给 TokenHamster。
代价：从「依赖第三方插件存在」换成「依赖 Node 子进程 + 自己维护折叠逻辑」。

（`@kaguyaluna2333/dsh-token-stats` 还显式导出了 `./aggregate` 与 `./log-reader`
两个零依赖的纯函数子路径，理论上可直接 `import` 复用 —— 但仍需自写 driver。）

### 5.3 Fork 上游

**MIT 允许**修改、分发、再用、商用，但必须同时满足：

1. **保留原版权声明与 LICENSE 全文**
2. **不得暗示原作者为你的改动背书**
3. **必须换包名**（不能再用 `@ychris12138/...`；也无 scope 名已被占用）

★ **真实维护面不是 DSH 内部 API** ——
该插件零内核导入、无第三方运行时依赖、`lib` 是预构建产物。
真正会变的是**会话日志物理格式的换代**（v0/v1/v2/v3，现已 v3）。
所以 fork 的维护量主要在「跟格式」，不在「跟 API」。

---

## 6. 监控清单（出现这些信号就该动手）

| 信号 | 含义 | 动作 |
|---|---|---|
| 仓库 3 个月无 commit | 可能停更 | 评估 5.2 或 5.3 |
| 插件启动报兼容错误 | DSH 接口变动 | 先升级插件；不行则评估 5.2 |
| 缓存的 `version` 变成 6 | 结构换代 | **先更新 TokenHamster**（已同时支持 N/N-1） |
| 包名再次变更 | 无 scope 名被占之类 | 改 `DSHUsageStatsSource.pluginPackageName` + 支持文档 |
| 新版本被 npm 标记 `deprecated` | 作者已确认缺陷 | 检查我们 pin 的版本是否受影响；必要时提高 pin 或发文档提示 |
| TokenHamster 报「数据未更新」持续不消失 | persistence seam 变了 | 到上游提 issue / 评估 5.2 |

查看是否有版本被标记：

```sh
npm view "@ychris12138/dsh-usage-stats" deprecated
```

---

## 7. 维护约定

- **包名与版本只在一处定义**：`DSHUsageStatsSource.pluginPackageName` /
  `.verifiedPluginVersion`，安装器与 UI 都从这里取。
- ⚠️ **缓存路径只依赖两个字面量**：目录名 `storages/` 与文件名 `usage-stats-cache.json`
  —— 两者**都不在包名推导链上**。所以上游改包名不影响读缓存，
  但改这两个字面量就会失效（位置：`DSHUsageStatsSource.cachePath(dshHome:)`）。
- 支持文档（`docs/dsh-usage-stats-guide.md`）是**不发版即可更新**的唯一通道，
  排障内容优先改那里。
