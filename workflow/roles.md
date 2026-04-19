# Team Roles

## Core Roles

- `ArchitectureLead`
  - 负责目标、边界、成功标准、模块拆分和契约冻结
  - 不直接替代实现者完成代码

- `DeliveryManager`
  - 负责阶段推进、任务拆分、依赖顺序和运行节奏
  - 不替代架构和代码决策

- `Implementer`
  - 负责单块实现与本块测试
  - 只在冻结契约内改动自己的边界

- `Supervisor`
  - 负责运行状态、日志、超时、失败和自动重试
  - 不做业务设计

- `Tester`
  - 负责契约测试、集成测试、端到端测试和验证结论
  - 不代替实现者改主逻辑

- `Reviewer`
  - 负责门禁裁决和审查结论
  - 只基于证据做 `approve`、`changes_required`、`blocked`

- `Archivist`
  - 负责进度日志、阶段文档、验证报告和最终归档
  - 不替代代码和测试事实

## Minimum Ownership Rules

- 每个阶段必须有明确 owner
- 监工、测试、审查不能和实现混成同一条口头结论
- 没有日志、验证和审查记录的结果，不算完成
