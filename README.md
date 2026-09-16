# Morrow

单用户、多端同步、Agent Native 的个人生活工作台。第一里程碑 **M1 = Phase 0 + MVP + 连续7天真实使用**。

当前状态：**架构与施工规划已交接，产品实现尚未开始。**

## 开工入口

从 [First 15 Tasks](docs/planning/05-first-15-tasks.md) 的 **P0-001** 开始。每项链接到可单独复制给施工Agent的完整任务卡，包含执行模型、独立Review、验收条件和下一步。

## 交付文件

- [架构裁决与工程蓝图](docs/planning/01-architecture.md)：Core、Repository、Schema/RLS/Auth、Agent、同步、前端、失败恢复与测试。
- [合同V1与边界样例](docs/planning/02-contracts.md)：字段/日期/日型/指标/事务/HTTP与MCP/导出。
- [施工分工与自治规则](docs/planning/03-execution.md)：阶段门禁、风险处理、运行指引、M1返回包。
- [验收矩阵](docs/planning/04-acceptance.md)：28项验收、并发规格、双机与7天证据模板。
- [15项顺序任务](docs/planning/05-first-15-tasks.md) 与 [机器可读任务状态](docs/planning/task-index.json)。
- [规划静态检查](docs/planning/evidence/planning-validation.md)：只证明交接包结构与一致性，不代表产品测试通过。

- [2026-09-16开工前职责完成审计](docs/planning/evidence/completion-audit-2026-09-16.md)：逐项核对原始要求，补齐管理合同、权限投影和施工责任。

## 原始依据

1. [产品深度规划V2](个人生活工作台%20·%20产品深度规划%20V2.md)，优先级最高。
2. [Codex工程前置分析包](Morrow-Codex工程前置分析包.md)，提供上下文，冲突时服从产品。

Codex在M1完成前不参与日常施工；高风险任务由指定施工者和独立审核者完成，不设置等待Codex返回的门禁。M1完成后仍不能直接启动Phase1：必须另满足14天真实使用、锚点记录率≥80%、凯哥本人确认。

## 施工提交与证据约定（P0-001 定义）

- 本仓库为**本地仓库**（`main` 单分支），当前未配置任何远端；创建远端与推送须凯哥明确授权后进行。
- **一个任务一个可 review 的逻辑提交**，提交信息前缀 `<TASK-ID>:`（如 `P0-001: ...`）。
- 修复不并入原提交：另加 `<TASK-ID>: fix ...` 提交；不 squash、不改写已有提交历史。
- 每任务证据落 `docs/planning/evidence/<TASK-ID>/result.md`（格式见 [03-execution.md §3](docs/planning/03-execution.md)）：引用主交付提交的 hash，证据文件作为紧随其后的第二个提交入库。
- `docs/planning/task-index.json` 的任务 status 只由 Review 方签核后更新，施工执行者不自行标记。
