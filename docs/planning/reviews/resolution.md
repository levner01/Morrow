# 主控裁决：独立预审问题处置

日期：2026-09-15。下列均为**规划静态复审**，不是代码/数据库/线上验收。原预审保留原貌，以本处置及01/02终稿为执行基线。

| 问题 | 最终处理 | 实施责任 |
|---|---|---|
| 工程包把14天门禁前移Phase0 | 服从V2，仅MVP→Phase1开始；M1含7天真实使用 | P0-009/MVP-006 |
| 19:30结束与22:15关灯冲突 | 训练结束目标19:15；实际睡眠间隔另评估 | MVP-001/004 |
| 记录率混达标率、30天裁连续 | 固定C03；迟到算记录，连续可超过30天 | MVP-004 |
| 日型锁死导致起床后不能临时训练 | 锁既有目标和分母下限，允许今日单向追加训练 | MVP-001/002 |
| 跨午夜与补记使统计含糊 | 生活日次日12点结算，今日00点切页，补记重算并使旧门禁计算失效 | MVP-001/004/006 |
| Edge认证与DB写之间撤销竞态 | DB内同锁序FOR UPDATE重验；撤销提交后不能新提交 | P0-004/005/007 |
| Human响应丢失重试覆盖 | Human同样幂等；unknown先只读收据/最新值并确认，未提交分支承认LWW风险 | MVP-003 |
| service_role绕过RLS | 不把RLS当全部授权；显式owner/scope/grants/definer隔离 | P0-004/005 |
| token进入通用幂等响应 | 管理脚本本机生成保存秘密，RPC只收hash/locator，回非敏感配置 | P0-004/007 |
| BIGINT先JSON解析损精度 | 固定列security_invoker视图/SQL投影cast text后输出 | P0-003/MVP-005 |
| 初始化锁不存在state行 | 部署先预置state，初始化锁既有行只执行一次 | P0-003/004 |
| 多语句Context不是同一快照 | Human workspace_state FOR SHARE；Agent按统一写锁流程 | MVP-001 |
| 行锁与read-only/STABLE RPC冲突 | public/private函数VOLATILE+POST RPC；外层health GET→内层POST | P0-007/MVP-001 |
| P0双机读写依赖未实现锚点命令 | 使用已存在Human health管理RPC创建/停用临时health配置，不重开测试入口 | P0-008 |
| receipt过期/softdelete复活 | 不清理receipt；未来保留key墓碑；业务键永久占位，显式恢复 | P0-003/004/005 |

预审输入：[产品预审](product-preflight.md)、[安全预审](security-preflight.md)。

无已知未处置的规划阻塞；线上可达性、权限测试、调度和真实使用全部仍是待施工验证。

## 2026-09-16 完成审计补充

本次按原附件逐项检查覆盖，未发现整块命名交付物缺失；发现并补齐以下合同/施工责任遗漏：

| 遗漏 | 处置与落点 | 状态 |
|---|---|---|
| P0-003负责命令/响应Schema却未引用C04/05/06 | 补任务输入，Phase2仍仅冻结合同 | 已补齐 |
| record_open_v1仅有调用方而无Core施工owner | 归MVP-001并加入每日device去重验收，MVP-002只接入 | 已补齐 |
| 成功响应/receipt重放可能绕read scope | C06规定每次按当前scope重投影，S09/P0-005覆盖 | 已补齐 |
| health客户端激活与create/rotate/revoke参数含糊 | C05.1固定参数、非敏感响应和创建/已有client锁序；三张相关卡新增必读 | 已补齐 |
| today_context建议读取scope未列入集合 | 增加read:advice，仍Phase2才开放 | 已补齐 |

两份原文SHA256与前轮记录一致。全部15项产品施工任务仍PLANNED；本次完成的是开工前职责，不是M1产品验收。
