# Agent 插件用的是什么

按插件改动 agent 的哪一层分组。每个插件的描述是来源页面的原话，分组是我的判断；点链接可以看原页面。

## 数据从哪来

| 生态 | 来源 | 用量的含义 |
| --- | --- | --- |
| Claude Code 插件 | [Claude 插件市场](https://claude.com/marketplace/plugins)，529 个全部读取 | 页面上的 installs，未说明统计周期 |
| Claude Code mods | [官方文档](https://code.claude.com/docs/en/plugins/mods/overview)，[内置 mods 源码](https://github.com/anthropics/claude-code/tree/main/mods)，社区目录 [awesome-claude-code-mods](https://github.com/karanb192/awesome-claude-code-mods)（扫描到 7,351 个 mod） | 没有安装量，只有仓库 star |
| DeepSeek Harness | 社区目录 [awesome-dsh-plugin](https://github.com/awesome-dsh-plugin/awesome-dsh-plugin) 和 [dsh-plugin-shop](https://github.com/LivXue/dsh-plugin-shop)，[Show Your Plugins](https://github.com/deepseek-ai/deepseek-harness/discussions) | npm 月下载 |
| Open WebUI | [openwebui.com](https://openwebui.com/search)，按下载量、全部时间排序 | 累计下载 |
| LobeHub | [MCP 市场](https://lobehub.com/mcp?category=all&sort=installCount)，[助手](https://lobehub.com/agent?category=all&sort=mostUsage) | 安装数，使用数 |
| pi | [pi.dev/packages](https://pi.dev/packages) | npm 月下载 |
| OpenCode | npm 关键词 `opencode-plugin`，全部 3,020 个 | npm 月下载 |
| Gemini CLI | [扩展目录](https://geminicli.com/extensions/)，全部 2,194 个 | 仓库 star |
| Cline | [MCP 市场](https://cline.bot/mcp-marketplace) | 下载数 |
| 跨客户端 MCP | npm 下载 API | npm 月下载 |

npm 月下载取自 `https://api.npmjs.org/downloads/point/last-month/<包名>`，区间 2026-10-07 至 2026-11-05。其他数字是 2026-11-07 读的。

## 能力：它能做什么

联网搜索、浏览器、文件、最新文档。在以加工具为主的生态里占前 20 名用量的 62–81%（pi、Cline、LobeHub、Open WebUI Tools）。

| 插件 | 生态 | 原文描述 | 用量 | 链接 |
| --- | --- | --- | --- | --- |
| @playwright/mcp | MCP | Playwright Tools for MCP | 每月 30,854,434 | [npm](https://www.npmjs.com/package/@playwright/mcp) |
| chrome-devtools-mcp | MCP | MCP server for Chrome DevTools | 每月 8,539,704 | [npm](https://www.npmjs.com/package/chrome-devtools-mcp) |
| @upstash/context7-mcp | MCP | MCP server for Context7 | 每月 3,339,996 | [npm](https://www.npmjs.com/package/@upstash/context7-mcp) |
| context7 | Claude Code | Upstash Context7 MCP server for up-to-date documentation lookup. | 安装 417,801 | [市场](https://claude.com/marketplace/plugins/context7) |
| playwright | Claude Code | Browser automation and end-to-end testing MCP server by Microsoft. | 安装 319,887 | [市场](https://claude.com/marketplace/plugins/playwright) |
| pi-mcp-adapter | pi | MCP (Model Context Protocol) adapter extension for Pi coding agent | 每月 1,560,175 | [npm](https://www.npmjs.com/package/pi-mcp-adapter) |
| pi-web-access | pi | Web search, URL fetching, GitHub repo cloning, PDF extraction, YouTube video understanding, and loca… | 每月 1,224,805 | [npm](https://www.npmjs.com/package/pi-web-access) |
| File System | Cline | Provides comprehensive filesystem operations including reading, writing, moving… | 下载 162,674 | [GitHub](https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem) |
| Web Search | Open WebUI | Web Search using SearXNG and Scrap first N Pages | 下载 58K | [页面](https://openwebui.com/posts/web_search_238777c6) |
| Playwright MCP | LobeHub | A Model Context Protocol (MCP) server that provides browser automation… | 安装 5.8k | [页面](https://lobehub.com/mcp/microsoft-playwright-mcp) |
| @liustack/modlens | dsh | Plug-in vision for text-only LLMs, powered by the free Antigravity CLI | 每月 257,562 | [npm](https://www.npmjs.com/package/@liustack/modlens) |
| dsh-free-search | dsh | Free web search for DeepSeek Harness: 27 engines (Bing/DuckDuckGo/AnySearch/SearXNG/Exa/Tavily/… | 每月 96,066 | [npm](https://www.npmjs.com/package/dsh-free-search) |
| last30days-skill | Gemini CLI | Research a topic from the last 30 days across Reddit, X, YouTube, TikTok, Instagram, Hacker News… | star 64,331 | [GitHub](https://github.com/mvanhorn/last30days-skill) |

## 模型：用哪个模型

接别家的订阅、免费模型、越狱。允许换模型的生态里它就是第一：OpenCode 前 20 名的 74%，Open WebUI Functions 的 46%。

| 插件 | 生态 | 原文描述 | 用量 | 链接 |
| --- | --- | --- | --- | --- |
| opencode-workbuddy-auth | OpenCode | OpenCode provider plugins for WorkBuddy's plans: WorkBuddy (CodeBuddy, copilot.tencent.com)… | 每月 884,948 | [npm](https://www.npmjs.com/package/@magpie-community/opencode-workbuddy-auth) |
| opencode-zcode-auth | OpenCode | OpenCode provider plugin: signs in to Z.ai's or BigModel's (智谱) GLM Coding Plan as ZCode does… | 每月 395,321 | [npm](https://www.npmjs.com/package/@magpie-community/opencode-zcode-auth) |
| O3 Pro O1 Pro Support | Open WebUI | OpenAI o1-pro & o3-pro Integration for Open Web UI | 下载 94K，Functions 第一 | [页面](https://openwebui.com/posts/o3_pro_o1_pro_support_fa8d99ba) |
| Anthropic | Open WebUI | Anthropic Manifold Pipe | 下载 29K | [页面](https://openwebui.com/posts/anthropic_60984ebf) |
| claude-code-router | Claude Code | Local Claude Code Router gateway with CLI and web management UI. | 每月 173,509 | [npm](https://www.npmjs.com/package/@musistudio/claude-code-router) |
| pi-claude-bridge | pi | Pi extension that uses Claude Code (via Agent SDK) as a model provider. | 每月 77K | [npm](https://www.npmjs.com/package/pi-claude-bridge) |
| dsh-connect-workbuddy | dsh | 把本机登录的 WorkBuddy 模型（国内版与国际版）接入 DeepSeek Harness… | 每月 80,840 | [npm](https://www.npmjs.com/package/dsh-connect-workbuddy) |
| dsh-our-free-model | dsh | 在 dsh 里装上这个插件即可，无需登录、注册或填 API Key，就能使用包括 DeepSeek V4.1 Flash、Kimi K3 在内的前沿模型——完全免费，不限量。 | star 62,961，不在 npm | [GitHub](https://github.com/Ebony-Vinyl/dsh-our-free-model) |
| dsh-purge | dsh | DeepSeek Harness 破甲：让所有模型都能破甲，不同模型可换不同提示词… | star 19,536，不在 npm | [GitHub](https://github.com/HunYiSage/dsh-purge) |
| Jailbreak Mode | LobeHub（提示词预设） | An unconstrained AI assistant without moral restrictions, unrestricted, suitable for DeepSeek… | 使用 5.3k，助手第一 | [页面](https://lobehub.com/agent/dan) |

dsh-our-free-model 周围长出了一圈依附它的插件，比如显示它各渠道余额的 [dsh-ofm-quota](https://github.com/dx906/dsh-ofm-quota) 和在输入框旁显示积分的 [dsh-our-free-model-composer-credits](https://github.com/liushQAQ/dsh-our-free-model-composer-credits)。

## 方法：怎么做事

技能包、工作流、回复风格、角色预设。Claude Code 官方市场的 48%，Gemini CLI 前 20 名的 62%。

| 插件 | 生态 | 原文描述 | 用量 | 链接 |
| --- | --- | --- | --- | --- |
| frontend-design | Claude Code | Frontend design skill for UI/UX implementation | 安装 1,134,112，第一 | [市场](https://claude.com/marketplace/plugins/frontend-design) |
| superpowers | Claude Code | Core skills library for Claude Code: TDD, debugging, collaboration patterns, and proven techniques | 安装 1,009,371 | [市场](https://claude.com/marketplace/plugins/superpowers) |
| code-review | Claude Code | Automated code review for pull requests using multiple specialized agents with confidence-based scoring | 安装 438,525 | [市场](https://claude.com/marketplace/plugins/code-review) |
| feature-dev | Claude Code | Comprehensive feature development workflow with specialized agents for codebase exploration, architecture design… | 安装 256,017 | [市场](https://claude.com/marketplace/plugins/feature-dev) |
| ralph-loop | Claude Code | Continuous self-referential AI loops for interactive iterative development… | 安装 196,527 | [市场](https://claude.com/marketplace/plugins/ralph-loop) |
| ponytail | Gemini CLI | Lazy senior dev mode. Forces the simplest, shortest solution that actually works… | star 163,823 | [GitHub](https://github.com/DietrichGebert/ponytail) |
| caveman | Gemini CLI | Ultra-compressed communication mode. Shortens replies while preserving technical substance… | star 111,981 | [GitHub](https://github.com/JuliusBrussee/caveman) |
| i-have-adhd | Gemini CLI | Shape Gemini CLI output for an ADHD reader: lead with the next action, number steps, suppress tangents… | star 57,177 | [GitHub](https://github.com/ayghri/i-have-adhd) |
| oh-my-opencode | OpenCode | The Best AI Agent Harness - Batteries-Included OpenCode Plugin with Multi-Model Orchestration… | 每月 238,915 | [npm](https://www.npmjs.com/package/oh-my-opencode) |
| pi-subagents | pi | Pi extension for single-agent delegation and scripted multi-agent workflows | 每月 787,602 | [npm](https://www.npmjs.com/package/pi-subagents) |
| firstmate | Claude Code 等 | firstmate is an agent distro for running a crew of agents. | star 8,464 | [GitHub](https://github.com/kunchenguid/firstmate) |
| Sub Agent | Open WebUI | Run autonomous, tool-heavy tasks in a sub-agent and keep the main chat context clean. | 下载 25K | [页面](https://openwebui.com/posts/sub_agent_7bfeb0b7) |
| 100% Human Writing | LobeHub（提示词预设） | Completely rewrite AI-generated content to feature characteristics of a genuine human author… | 使用 1.2k | [页面](https://lobehub.com/agent/xhb-111) |

## 看得见：花费、用量、上下文

每个生态都有，是最一致的一类需求。

| 插件 | 生态 | 原文描述 | 用量 | 链接 |
| --- | --- | --- | --- | --- |
| ccusage | Claude Code 等 | Analyze coding (agent) CLI token usage and costs from local data | 每月 974,028 | [npm](https://www.npmjs.com/package/ccusage) |
| ccstatusline | Claude Code | A customizable status line formatter for Claude Code CLI | 每月 205,550 | [npm](https://www.npmjs.com/package/ccstatusline) |
| claude-powerline | Claude Code | Beautiful vim-style powerline statusline for Claude Code with real-time usage tracking… | 每月 19,408 | [npm](https://www.npmjs.com/package/@owloops/claude-powerline) |
| claude-hud | Claude Code | A Claude Code plugin that shows what's happening: context usage, rate limits, active tools, running agents, and todo progress, always visible below your input. | star 29,124，不在官方市场 | [GitHub](https://github.com/jarrodwatts/claude-hud) |
| token-optimizer | Claude Code 等 | Token Optimizer cuts the tokens your AI coding assistant wastes, keeps your work alive across sessions and compactions, and shows you where every dollar went on a live dashboard. | star 2,826 | [GitHub](https://github.com/alexgreensh/token-optimizer) |
| dsh-whale-widget | dsh | DSH Web 界面右下角的 DeepSeek 余额小鲸鱼挂件:余额/今日已用/峰谷定价… | 每月 434,627 | [npm](https://www.npmjs.com/package/dsh-whale-widget) |
| dsh-context | dsh | A DeepSeek Harness plugin for context insight and management, with context dashboard and context com… | 每月 390,878 | [npm](https://www.npmjs.com/package/dsh-context) |
| dsh-cost-meter | dsh | DeepSeek Harness 会话费用统计插件:本会话成本、当日费用、历史记录与官方价格同步… | 每月 141,029 | [npm](https://www.npmjs.com/package/dsh-cost-meter) |
| dsh-token-diet | dsh | Token 统计与按会话预算：汇总所有会话、子智能体和自动化任务的用量与成本，并在预算耗尽时停止任务。 | 每月 79,952 | [npm](https://www.npmjs.com/package/dsh-token-diet) |
| Time Token Tracker | Open WebUI | A filter for tracking the response time and token usage of a request. | 下载 13K | [页面](https://openwebui.com/posts/time_token_tracker_1f0b848b) |
| Token Usage Display | Open WebUI | Shows token counts, reasoning/cached breakdowns, context-window utilization, generation ti… | 下载 9.3K | [页面](https://openwebui.com/posts/token_usage_display_a94ea72f) |
| pi-powerline-footer | pi | Powerline-style status bar extension for pi coding agent | 每月 47,622 | [npm](https://www.npmjs.com/package/pi-powerline-footer) |
| opencode-usage-limits | OpenCode | Show OpenCode Go and ClinePass subscription usage (5-hour / weekly / monthly) in the OpenCode TUI… | 每月 8,432 | [npm](https://www.npmjs.com/package/opencode-usage-limits) |
| opencode-notifier | OpenCode | OpenCode plugin that sends system notifications and plays sounds when permission is needed… | 每月 12,559 | [npm](https://www.npmjs.com/package/@mohak34/opencode-notifier) |

Claude Code mods 里，社区目录的分类把 1,071 个（15%）归为用量表。

## 界面：在哪里、怎么交互

只在宿主开放了界面接口的地方多：dsh 下载第一梯队几乎都是这一类；Claude Code mods 里 72% 会画东西；Open WebUI 本月新上架的大多是这一类。Gemini CLI、Codex、Cline 里几乎没有。

| 插件 | 生态 | 原文描述 | 用量 | 链接 |
| --- | --- | --- | --- | --- |
| dshmarket | dsh | Visual plugin market inside DeepSeek Harness — browse, search, and one-click install community plugi… | 每月 1,042,628（会轮询目录，偏高） | [npm](https://www.npmjs.com/package/dshmarket) |
| dsh-better-sidebar | dsh | Better Sidebar for DSH — file tree, editor, changes, tasks and side chat in one column… | 每月 294,875 | [npm](https://www.npmjs.com/package/dsh-better-sidebar) |
| dsh-web-all | dsh | DSH Web UI 全家桶聚合插件：一键安装全部功能插件（task-board / pet / web-ui-settings / skin-center / community-plugins /… | 每月 106,819 | [npm](https://www.npmjs.com/package/@linxin666/dsh-web-all) |
| dsh-genui | dsh | GenUI for DeepSeek Harness: interactive charts, forms, calculators, dashboards, and mini apps render… | 每月 97,843 | [npm](https://www.npmjs.com/package/dsh-genui) |
| dsh-at-file | dsh | Codex-style @path references for the DeepSeek Harness web GUI… | 每月 91,141 | [npm](https://www.npmjs.com/package/dsh-at-file) |
| dsh-tui | dsh | Interactive terminal interface for DeepSeek Harness agents, sessions and tools. | 每月 67,567 | [npm](https://www.npmjs.com/package/@deepseek-harness-tui/dsh-tui) |
| terminal-browser | Claude Code 插件 | A real browser that runs inside your terminal | star 4,472 | [GitHub](https://github.com/zenbu-labs/terminal-browser) |
| Visualize Data | Open WebUI | This function makes charts out of data in the conversation and render it in the chat. | 下载 16K | [页面](https://openwebui.com/posts/visualize_data_4319b6c2) |
| Artifacts V2 | Open WebUI | Artifacts V2 inspired by Claude Artifacts. | 下载 12K | [页面](https://openwebui.com/posts/artifacts_v2_d7104bda) |
| Smart Mind Map | Open WebUI | Intelligently analyzes text content and generates interactive mind maps… | 下载 6.9K | [页面](https://openwebui.com/posts/turn_any_text_into_beautiful_mind_maps_3094c59a) |
| Frontier UI | Open WebUI（本月新） | ChatGPT-style visual answers: photo galleries, street maps with real routes… | 下载 341 | [页面](https://openwebui.com/posts/frontier_ui_chatgpt_style_generative_ui_maps_photo_35572bd7) |
| MCP Server Chart | LobeHub | A Model Context Protocol server for generating charts using AntV. | 安装 2.0k | [页面](https://lobehub.com/mcp/antvis-mcp-server-chart) |
| rpiv-ask-user-question | pi | A structured questionnaire the model can put to you when it would otherwise guess, with typed options… | 每月 169K | [npm](https://www.npmjs.com/package/@juicesharp/rpiv-ask-user-question) |
| plannotator | pi | Plannotator Pi extension - interactive plan review with annotations… | 每月 95.9K | [npm](https://www.npmjs.com/package/@plannotator/pi-extension) |
| glimpseui | pi | Native micro-UI for scripts and agents — cross-platform WebView windows with bidirectional JSON comm… | 每月 67.1K | [npm](https://www.npmjs.com/package/glimpseui) |

## 记忆：记住什么

每个生态都在第二梯队，4–13%。

| 插件 | 生态 | 原文描述 | 用量 | 链接 |
| --- | --- | --- | --- | --- |
| server-memory | MCP | MCP server for enabling memory for Claude through a knowledge graph | 每月 932,185 | [npm](https://www.npmjs.com/package/@modelcontextprotocol/server-memory) |
| claude-md-management | Claude Code | Tools to maintain and improve CLAUDE.md files - audit quality, capture session learnings… | 安装 287,247 | [市场](https://claude.com/marketplace/plugins/claude-md-management) |
| context-mode | 多个 agent | Context window saver for 10 coding agents… | 每月 133,172 | [npm](https://www.npmjs.com/package/context-mode) |
| claude-mem | Claude Code | Memory compression system for Claude Code - persist context across sessions | 每月 104,067 | [npm](https://www.npmjs.com/package/claude-mem) |
| hindsight-coding-agents | 多个 agent | Reflect-only Hindsight long-term memory for coding agents… | 每月 100,127 | [npm](https://www.npmjs.com/package/@vectorize-io/hindsight-coding-agents) |
| dsh-mnemon | dsh | Composable, view-based context for DeepSeek Harness… | 每月 97,255 | [npm](https://www.npmjs.com/package/dsh-mnemon) |
| opencode-dcp | OpenCode | OpenCode plugin that optimizes token usage by pruning obsolete tool outputs from conversation contex… | 每月 40,568 | [npm](https://www.npmjs.com/package/@tarquinen/opencode-dcp) |
| Auto Memory | Open WebUI | Automatically store relevant information as Memories. | 下载 33K | [页面](https://openwebui.com/posts/auto_memory_bfc5a58b) |
| Adaptive Memory v3 | Open WebUI | Adaptive Memory enables dynamic, evolving, personalized memory for LLMs in OpenWebUI… | 下载 11K | [页面](https://openwebui.com/posts/adaptive_memory_v3_9b50f29d) |
| Async Context Compression | Open WebUI | Reduces token consumption in long conversations while maintaining coherence… | 下载 6.8K | [页面](https://openwebui.com/posts/async_context_compression_b1655bc8) |

## 连接：接到哪里

GitHub、Slack，以及 dsh 上的微信、QQ、飞书。5–28%。

| 插件 | 生态 | 原文描述 | 用量 | 链接 |
| --- | --- | --- | --- | --- |
| notion-mcp-server | MCP | Official MCP server for Notion API | 每月 931,428 | [npm](https://www.npmjs.com/package/@notionhq/notion-mcp-server) |
| github | Claude Code | Official GitHub MCP server for repository management. | 安装 319,381 | [市场](https://claude.com/marketplace/plugins/github) |
| telegram | Claude Code | Telegram channel for Claude Code — messaging bridge with built-in access control. | 安装 100,332 | [市场](https://claude.com/marketplace/plugins/telegram) |
| slack | Claude Code | Slack AI tools for users and developers: interact with your workspace via the Slack MCP server… | 安装 92,287 | [市场](https://claude.com/marketplace/plugins/slack) |
| dsh-im | dsh | 把微信、飞书、企微、钉钉、QQ、Telegram、WhatsApp、Slack、Discord、Matrix接入DSH。 | 每月 116,368 | [npm](https://www.npmjs.com/package/@xmanrui/dsh-im) |
| dsh-qqbot | dsh | 在 QQ 私聊和群聊里直接对话 DeepSeek Harness。 | 每月 79,317 | [npm](https://www.npmjs.com/package/@tencent-connect/dsh-qqbot) |
| N8N Pipeline | Open WebUI | An optimized streaming-enabled pipeline for interacting with N8N workflows… | 下载 31K | [页面](https://openwebui.com/posts/n8n_pipeline_21eeb1e5) |
| Figma | Cline | Provides AI assistants with access to Figma design data, enabling accurate code… | 下载 42,999 | [GitHub](https://github.com/GLips/Figma-Context-MCP) |

## 守门：安全

到处都小，2–4%。

| 插件 | 生态 | 原文描述 | 用量 | 链接 |
| --- | --- | --- | --- | --- |
| security-guidance | Claude Code | Security review for Claude-generated code. Pattern-based warnings on edits, LLM-powered diff review on Stop… | 安装 241,800 | [市场](https://claude.com/marketplace/plugins/security-guidance) |
| cc-safety-net | 多个 agent | A coding agent CLI hook - block destructive commands and secret file access | 每月 128,648 | [npm](https://www.npmjs.com/package/cc-safety-net) |
| hookify | Claude Code | Easily create hooks to prevent unwanted behaviors by analyzing conversation patterns | 安装 60,376 | [市场](https://claude.com/marketplace/plugins/hookify) |
| pi-permission-system | pi | Permission enforcement extension for the Pi coding agent. | 每月 48.1K | [npm](https://www.npmjs.com/package/pi-permission-system) |

## 娱乐

只有 dsh 例外：占下载的 7%，桌宠排第二。其他生态几乎没有。

| 插件 | 生态 | 原文描述 | 用量 | 链接 |
| --- | --- | --- | --- | --- |
| dsh-pet | dsh | 吃白饭的蓝色大肥鱼，赖在 DeepSeek Harness 里不走了… | 每月 460,582 | [npm](https://www.npmjs.com/package/dsh-pet) |
| dsh-plugin-wallpaper-engine | dsh | Wallpaper Engine backgrounds for the DSH web GUI… | 每月 138,771 | [npm](https://www.npmjs.com/package/dsh-plugin-wallpaper-engine) |
| dsh-dafeiyu | dsh | A desktop-native BigFish companion driven by DeepSeek Harness session events. | 每月 97,306 | [npm](https://www.npmjs.com/package/dsh-dafeiyu) |
| Chat Pets | Open WebUI（本月新） | Pixel-art companions for Open WebUI. Choose a pet, customize its name and colors, drag it around your chat… | 下载 201 | [页面](https://openwebui.com/posts/chat_pets_231903fd) |
| universal-modder | Gemini CLI | Mod almost any game you own with an AI agent… | star 7,722 | [GitHub](https://github.com/rehan-remade/universal-modder) |

## 读数时要注意

- 安装、下载和 star 衡量的是多少人试过，不是每天用多少次。没有哪个生态公开使用频率。
- 已剔除的虚高：billion-context 每月 310 万次下载，但发了 8,248 个版本；opencode-poe-auth 和 opencode-gitlab-auth 随 OpenCode 一起安装；dsh-plugin-catalog 是被市场轮询的数据文件。
- npm 下载有底噪：dsh 的 18,174 个第三方包中位数是每月 461 次，镜像同步和目录探测本身就会带来几百次。
- 10 月 27 日起 dsh 有几个插件同时暴涨又同步回落，可能是同一个安装器或机器人，没能查清来源。
- Gemini CLI 用的是整个仓库的 star，github-mcp-server 这类的 star 反映的是服务本身，不是扩展。
