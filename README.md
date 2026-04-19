# 一个月提示词恢复工作区（Codex + Cursor）

**目的**：恢复最近约一个月的 Codex 与 Cursor 提示词/对话，组成独立工作区，**目标为恢复简历相关内容**。  
与当前工程 `codex_prompt_recovery`（仅一周、仅 Codex）并列，本目录为「一个月 + 双源」恢复区。

## 目录名与范围

| 项目 | 说明 |
|------|------|
| **时间范围** | 2026-01-20 ～ 2026-02-19（约一个月） |
| **数据源** | Codex 会话（.codex/sessions/2026/01、02）+ Cursor 聊天（AppData/Cursor User/workspaceStorage、globalStorage） |
| **恢复目标** | 简历（及与本工程、创意相关的提示词） |

## 规则与配置（完整工作区）

以下文件自 creative 根目录**原样复制**，打开本目录为工作区时 Cursor/Codex 会按项目根加载，与主工程行为一致：

- **`.cursorrules`**：Cursor/Codex 共用规则
- **`.codexrc`**：Codex 指向 .cursorrules
- **`.codex-system-prompt`**：Codex 系统提示词
- **`AGENTS.md`**：规则入口说明

## 目录结构

| 路径 | 内容 |
|------|------|
| `codex/raw_sessions/` | Codex 一个月内原始 jsonl 会话备份 |
| `codex/index_one_month.md` | Codex 会话清单与时间线索引 |
| `cursor/raw_db/` | Cursor state.vscdb 拷贝（只读备份） |
| `cursor/extracted/` | 从 state.vscdb 提取的聊天/提示词文本（可搜简历） |
| `timeline_merged/` | Codex + Cursor 合并时间线，标注来源与简历相关 |
| `docs/` | 恢复说明、与当前工程对比、简历相关发现 |
| `goal_resume.md` | 恢复目标：简历（记录检索结果与待补项） |

## 与当前工程对比

| 对比项 | 当前工程 codex_prompt_recovery | 本工作区 prompt_recovery_one_month |
|--------|-------------------------------|-------------------------------------|
| 时间 | 一周（2026-02-12～19） | 约一个月（2026-01-20～02-19） |
| 来源 | 仅 Codex | Codex + Cursor |
| 目标 | 投影/创意恢复 | **简历** + 提示词恢复 |
| 位置 | creative/codex_prompt_recovery | creative/prompt_recovery_one_month |

## 使用方式

1. **单独工作区**：可用 Cursor/VSCode 直接「打开文件夹」到本目录 `prompt_recovery_one_month`，作为独立工作区使用。
2. **搜简历**：在 `cursor/extracted/resume_hits.txt`、`docs/简历相关-筛出.md`、`goal_resume.md` 中查看。
3. **只读**：本目录以恢复与比对为主，不删除、不覆盖原始备份。
