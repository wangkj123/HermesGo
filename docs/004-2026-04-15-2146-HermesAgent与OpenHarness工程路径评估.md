# Hermes Agent 与 OpenHarness 工程路径评估

**文档编号**：004

**生成者**：AI Codex GPT-5.4

**生成日期**：2026-04-15-2146

**最后修改**：2026-04-15-2146

**参考文档**：
- docs/002-2026-04-15-2039-Codex多智能体编排评估.md
- docs/003-2026-04-15-2117-AutoSkill驱动的规则自动更新方案.md

**目的**：评估 Hermes Agent 与 OpenHarness 分别在工程上解决什么问题，如何使用，以及哪条路径更适合实际落地。

**说明**：本文基于官方站点与 GitHub 仓库资料做工程判断，不复现视频里的具体跑分。

## 1. 结论

1.1 这两个东西不是同一层。

1.2 Hermes Agent 更像“会记忆、会学技能、会调度任务的 agent 运行时”。

1.3 OpenHarness 更像“跨多个 agent harness 的统一 API / 规范层”。

1.4 如果你要的是一个会自己干活、记住偏好、能长期演化的代理系统，优先看 Hermes Agent。

1.5 如果你要的是把 Claude Code、Goose、Letta、LangChain Deep Agent 等接到同一套接口上，优先看 OpenHarness。

1.6 如果你要做的是“可切换后端的 agent 平台”，更合理的做法是：用 OpenHarness 做接口层，用 Hermes 这种 runtime 做行为层。

## 2. Hermes Agent 是什么

2.1 Hermes Agent 是 Nous Research 做的自改进 AI agent。

2.2 它的重点不是“统一规范”，而是“运行时能力”。

2.3 官方和仓库里强调的能力包括：

2.3.1 记忆跨会话保留。

2.3.2 技能从经验中生成并持续改进。

2.3.3 内置学习循环。

2.3.4 终端、消息平台、定时任务、子代理并行。

2.4 它适合做长期使用的个人代理、团队代理、自动研究、自动报告、自动运维一类工作流。

## 3. Hermes Agent 怎么用

3.1 最快路径是官方托管入口，再决定要不要自托管。

3.2 本地或服务器侧自托管时，官方仓库提供安装脚本与 CLI。

3.3 常见入口是：

3.3.1 `hermes`：直接进入对话/命令行。

3.3.2 `hermes setup`：完整初始化。

3.3.3 `hermes tools`：配置工具集。

3.3.4 `hermes gateway`：启用 Telegram、Discord、Slack 等消息入口。

3.3.5 `hermes skills`：浏览和管理技能。

3.4 如果你想让它更像“会自己进化的工作流”，重点不是单次对话，而是持续运行、持续记忆、持续积累技能。

3.5 它更适合“一个 agent 扛很多事”，不太适合拿来做纯接口标准化。

## 4. OpenHarness 是什么

4.1 OpenHarness 是一个面向 AI agent harness 的开放 API 规范。

4.2 它的目标不是替你做任务，而是让不同 harness 之间能互操作。

4.3 它想解决的问题很明确：

4.3.1 每个 harness 都有自己的 API 和惯例。

4.3.2 接入时需要重复写适配。

4.3.3 切换底座容易被厂商绑定。

4.3.4 很难客观比较不同 harness 的能力。

4.4 它提供的是统一接口、能力声明、兼容矩阵和适配器思路。

## 5. OpenHarness 怎么用

5.1 它的基本思路是“写一次，换 adapter 就能跑到不同 harness 上”。

5.2 官方站点给出的示例是 Python / TypeScript 适配器方式。

5.3 工程上你会先选一个 adapter，然后用统一的执行接口发起请求。

5.4 如果后面想换 Claude Code、Goose、Letta、LangChain Deep Agent，通常只需要换适配层，而不是重写业务代码。

5.5 它更适合平台型、平台中台型、或者需要多后端评估的系统。

## 6. 两条路径怎么选

6.1 你要“一个能长期演化的 agent”，选 Hermes Agent 路线。

6.2 你要“一个统一不同 harness 的协议层”，选 OpenHarness 路线。

6.3 你要“既能演化，又能换后端”，两者可以组合，但职责要分清。

6.4 我更建议的工程顺序是：

6.4.1 先用 OpenHarness 这类规范层把接口统一。

6.4.2 再在某个具体 runtime 里做记忆、技能、自进化。

6.4.3 最后把规则演化、技能沉淀、评估门禁做成独立流程。

## 7. 风险判断

7.1 Hermes Agent 的风险是功能很全，容易变成“大而全的一体化代理”，但接口标准化不是它的首要目标。

7.2 OpenHarness 的风险是规范和生态还年轻，偏“标准草案 + 适配框架”，落地成熟度要自己评估。

7.3 如果你的目标是尽快做出可控结果，不要先纠结谁更“前沿”，先看你的需求是 runtime 还是 adapter layer。

## 8. 归档说明

8.1 本文已经按仓库规则归档。

8.2 对应的 DOCX 版本会同步生成。

8.3 如果你愿意，我下一步可以把这篇再压成一页“选型表”，方便你后面直接拿来做项目决策。

## 9. 参考链接

- https://hermes-agent.ai/
- https://github.com/NousResearch/hermes-agent
- https://openharness.ai/
- https://github.com/jeffrschneider/OpenHarness

