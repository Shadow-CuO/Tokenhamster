# Provider Icons

将 AI 厂商 logo 放在本目录（文件名见下表），App 会自动打包并在 AGENTS 卡片 / MODELS 栏 / 设置面板中显示品牌图；缺图时自动回退 SF Symbol，无需改任何代码。

**建议规格**：透明背景 PNG、正方形、尺寸 ≥ 128×128。
**渲染方式**：统一按*模板图*（只取 alpha 通道）渲染 → 由 `ProviderIcon(tint:)` 着色，**单色跟随主题明暗**（深色模式偏白、浅色模式偏深灰）。因此**图标内容应当用纯色填充**（本目录现有图标为白色填充），不需要、也不应使用品牌原色。

## 文件清单

| 文件名 | 对应厂商 / 场景 |
|--------|----------------|
| `openai.png` | OpenAI（亦用于 GPT / o1 / o3 / o4 / davinci 系列模型行） |
| `claude.png` | Anthropic Claude（API 源 + 本地 Claude Code + sonnet/opus/haiku 模型行） |
| `codex.png` | Codex（与 `openai.png` 同图 —— Codex 官方标识即 OpenAI 标） |
| `gemini.png` | Google Gemini / Gemma |
| `deepseek.png` | DeepSeek（API 源 + DeepSeek Harness） |
| `kimi.png` | Moonshot Kimi |
| `copilot.png` | GitHub Copilot |
| `cursor.png` | Cursor |
| `zai.png` | Z.ai Coding Plan / 智谱 GLM（官方 Z 字形） |
| `xai.png` | xAI Grok |
| `qwen.png` | 阿里通义千问 |
| `mistral.png` | Mistral / Mixtral / Codestral / Devstral |
| `meta.png` | Meta Llama |
| `ollama.png` | Ollama 本地运行时 |
| `openrouter.png` | OpenRouter |
| `siliconflow.png` | 硅基流动 SiliconFlow |

## 模型行按厂商识别

MODELS 栏的每一行会**按模型名**自动识别厂商标（见 `BrandMark.detect(in:)`），
例如同一个 Codex 数据源里 `gpt-5.6` 显示 OpenAI 标、`glm-4.6` 显示 Z.ai 标；
识别不出时才回退数据源自身的 logo。新增前缀规则改 `ProviderIcons.swift` 即可。
