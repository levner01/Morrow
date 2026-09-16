# First 15 Tasks

严格按以下顺序执行。每项标题链接是可单独复制给对应Agent的完整Task卡；本页为启动索引。前置任务有PASS证据后才进入下一项，失败在原任务修复闭环。模型依据凯哥提供清单，未做性能/在线可用性验证。

## 01. [P0-001](tasks/P0-001.md)

建立可持续施工的仓库与环境基线。

执行：Trae + GLM-5.3 Flash。

Review：WorkBuddy + DeepSeek V4.1 Flash。

完成后才能进入：**P0-002**。

## 02. [P0-002](tasks/P0-002.md)

验证真实Supabase、Auth、Edge及双机访问前提。

执行：Trae + Kimi K3。

Review：Hermes + GLM-5.3。

完成后才能进入：**P0-003**。

## 03. [P0-003](tasks/P0-003.md)

落地版本化Schema与共享合同。

执行：Trae + Kimi K3。

Review：Hermes + GLM-5.3。

完成后才能进入：**P0-004**。

## 04. [P0-004](tasks/P0-004.md)

实现唯一Core的身份、事务、版本、审计与幂等框架。

执行：Trae + Kimi K3。

Review：Hermes + GLM-5.3 深审；WorkBuddy + DeepSeek V4.1 Flash 独立反例初审。

完成后才能进入：**P0-005**。

## 05. [P0-005](tasks/P0-005.md)

用独立安全与并发测试封住核心风险。

执行：Hermes + GLM-5.3。

Review：WorkBuddy + Kimi K3；原实现作者修复后Hermes重新验证。

完成后才能进入：**P0-006**。

## 06. [P0-006](tasks/P0-006.md)

建立可降级静态登录壳和同源单HTML发行。

执行：Trae + Kimi K2.7 Code。

Review：WorkBuddy + DeepSeek V4.1 Flash；Hy4检查失败页面。

完成后才能进入：**P0-007**。

## 07. [P0-007](tasks/P0-007.md)

注册health-only Agent并实际运行常驻Keepalive。

执行：Hermes + Kimi K3。

Review：WorkBuddy + GLM-5.3；安全改动由Hermes不同于作者的GLM-5.3审查。

完成后才能进入：**P0-008**。

## 08. [P0-008](tasks/P0-008.md)

完成双机访问和故障恢复的真实交付验证。

执行：Trae + Kimi K2.7 Code。

Review：WorkBuddy + GLM-5.3。

完成后才能进入：**P0-009**。

## 09. [P0-009](tasks/P0-009.md)

Phase0门禁签核并交付MVP开工包。

执行：Hermes + GLM-5.3。

Review：WorkBuddy + Kimi K3；凯哥仅补真实设备/账号缺口。

完成后才能进入：**MVP-001**。

## 10. [MVP-001](tasks/MVP-001.md)

实现锚点、日型计划及统一业务语义。

执行：Trae + Kimi K3。

Review：Hermes + GLM-5.3；WorkBuddy + DeepSeek V4.1 Flash 复核样例。

完成后才能进入：**MVP-002**。

## 11. [MVP-002](tasks/MVP-002.md)

交付三锚点主导的今日行动页面。

执行：Trae + Kimi K2.7 Code。

Review：WorkBuddy + Hy4（视觉）；Hermes + GLM-5.3（业务）。

完成后才能进入：**MVP-003**。

## 12. [MVP-003](tasks/MVP-003.md)

完成三态同步、持久草稿与未知结果处理。

执行：Trae + Kimi K3。

Review：Hermes + GLM-5.3；WorkBuddy + DeepSeek V4.1 Flash 独立场景复核。

完成后才能进入：**MVP-004**。

## 13. [MVP-004](tasks/MVP-004.md)

完成30天热力图与不失真的记录统计。

执行：Trae + GLM-5.3。

Review：Hermes + DeepSeek V4 Pro；WorkBuddy + Hy4 视觉复核。

完成后才能进入：**MVP-005**。

## 14. [MVP-005](tasks/MVP-005.md)

交付一致、全量、无凭据的JSON导出。

执行：Trae + GLM-5.3。

Review：Hermes + DeepSeek V4 Pro；WorkBuddy + Kimi K3 安全复核。

完成后才能进入：**MVP-006**。

## 15. [MVP-006](tasks/MVP-006.md)

完成集成发布、七天真实使用和M1联合验收。

执行：Hermes + Kimi K3 组织验证；Trae + 原任务模型修复。

Review：Hermes + GLM-5.3 主审；WorkBuddy + Hy4 UI见证；凯哥确认真实使用事实。

完成后才能进入：**M1完成；Phase1仍锁定，另需14天/80%/凯哥确认**。
