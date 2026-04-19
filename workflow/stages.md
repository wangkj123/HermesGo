# Team Stages

## Stage 0: Intake

- 明确目标、范围、限制和不可做事项
- 门禁：目标必须可验证

## Stage 1: Plan

- 拆块、排依赖、定 owner
- 门禁：每块必须有输入、输出、依赖和验收标准

## Stage 2: Contracts

- 冻结 API、状态、错误、交接点
- 门禁：未冻结契约不得并行实现

## Stage 3: Implementation

- 各块按边界实现
- 门禁：跨块改动要回到契约层

## Stage 4: Supervision

- 监控运行、失败、超时、自动重试和可见反馈
- 门禁：失败必须可见且可追踪

## Stage 5: Verification

- 先契约测，再集成测，最后端到端
- 门禁：没过测试不能进入审查

## Stage 6: Review

- 基于证据做裁决
- 门禁：没有日志、测试和结果摘要时不得批准

## Stage 7: Archive

- 输出归档文档，沉淀方案、结果和风险
- 门禁：过程记录不能缺失
