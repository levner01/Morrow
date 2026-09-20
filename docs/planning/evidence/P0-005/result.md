# P0-005 收据：独立安全与并发测试封住核心风险

- 任务卡：docs/planning/tasks/P0-005.md
- 执行：Hermes + GLM-5.3（本卡推荐执行方）；凭据：keychain `MORROW_SUPABASE_ACCESS_TOKEN`（值不落盘、不进命令行参数）
- 输入：02-contracts.md C-10 S01–S09/T01–T10；01-architecture.md §4/§10；P0-003/P0-004 证据与 Core 函数合同

## 头部裁决（执行前对齐）

| 项 | 说明 |
|---|---|
| git HEAD | 实际 `9d1a854`（P0-004 review 后）；开工前提示词写 `0ca7664` 为过时值，已对齐 |
| PROBE_TOKEN | keychain 无此条目（提示词"如已 seeded"分支不成立）。20 并发用 Management API 独立 HTTP 请求 = 20 独立 DB 会话（架构 §10 语义） |
| publishable key | keychain 无。端到端 REST 登录（probe 用户 password grant）需它；本卡用 SQL `SET LOCAL ROLE + request.jwt.claims` 模拟真实 JWT 会话身份（auth.uid() 由 claims.sub 派生，与 PostgREST 层同源），owner HTTP 正向登录留 P0-006/007 登录壳 |
| PAT secrets scope | GET secrets 端点 403（PAT 无 secrets 读 scope）。Dashboard 孤儿 PROBE_TOKEN secret 是否已删，无法从 PAT 侧验证，进 §未验证对账表，需凯哥 Dashboard 确认 |

## 交付物

| 文件 | 说明 |
|---|---|
| `security-matrix-db.sh` / `.output.txt` | S01–S09 DB 侧逐项实测（回滚探针/真实角色/并发），原始输出落盘 |
| `concurrency-tests.sh` / `concurrency-results.txt` | T01/T03/T04/T05/T06/T07/T08 并发与版本原子性原始输出 |
| `expired-defect.sh` / `.output.txt` | P0-004 移交 expired 缺陷正式复现（三次稳定复现） |
| `security-matrix.md` | S01–S09 逐格对照（本文件引用的那份） |
| `result.md` | 本文件 |

## 实测结论汇总

### 安全矩阵 S01–S09（全 PASS，原始输出见 security-matrix-db.output.txt）

| 项 | 结论 | 关键实测 |
|---|---|---|
| S01 anon 全盲 | PASS | life_data/activity_log 无 grant → 42501；private credentials → 42501；RPC → 42501 |
| S02 非 owner 隔离 | PASS | probe 真实 claims（sub=非owner）写读全零行；RPC OWNER_DENIED |
| S03 owner 直 DML 拒绝 + 语义 RPC 成功 | PASS | owner UPDATE/DELETE life_data/activity_log → 42501；语义 RPC ok:true |
| S04 伪造 actor/owner 拒绝 | PASS | 伪造 p_uid → OWNER_DENIED；无 actor GUC 插入 → actor_context_missing；自报 source 被 GUC 覆盖 |
| S05 credentials/receipts 不可读 | PASS | 两表 authenticated → 42501；agent_clients RLS 开启 |
| S06 函数执行白名单 | PASS | private 仅 4 cmd_* + is_workspace_owner 对 authenticated 开放（与 P0-004 一致），helper/trigger/测试入口全拒 |
| S07 health 凭据状态 | PASS | 无过期凭据残留；Edge 侧过期/撤销 token 实测归 P0-007 |
| S08 撤销并发 | PASS | revoke‖rotate 竞态：rotate 抢先完成→revoke 提交点晚 0.16s 连带撤销 rotate 新凭据，终态 live_creds=0（提取了竞态时间戳证据） |
| S09 receipts 无 token 泄漏 | PASS | manage receipt 无 64hex token_hash |

### 并发矩阵 T01/T03/T04/T05/T06/T07/T08（全 PASS）

| 项 | 结论 | 关键实测 |
|---|---|---|
| T03 20 并发有效更新无重号 | **PASS** | 20 独立会话并发 UPDATE 同行：ok=20/20，unique=20，range base+1..base+20，final=base+20 |
| T04 两 Agent 同 expected 仅一成功 | PASS | 一 ok 一 VERSION_CONFLICT，final=expected+1 |
| T05 响应丢失原 key 重试 | PASS | 重放 replayed:true + 1 life 行 + 1 资源审计（判据修正：按 resource_id 不按 entity_key，避免跨轮残留误判） |
| T06 同 key 异 input | PASS | IDEMPOTENCY_KEY_REUSED |
| T07 故障注入整体回滚 | PASS | rev/receipts/life 三计数不变 |
| T08 tombstone 拒 create | PASS | RESOURCE_DELETED，不复活 |
| 死锁反例 3 组 | PASS | 组1(20并发同行)/组3(rotate‖rotate)/组2(revoke‖create) 由 T03/S08/P0-004-K8 覆盖，无 lock timeout |

### 白名单审计（definer/grants/搜索路径/角色继承）

- **private 全部 22 个 SECURITY DEFINER 函数**：`set search_path=''` 无一例外（命令/helper/trigger/测试入口全含）
- **`public.rls_auto_enable`**：owner postgres，plpgsql，`search_path=pg_catalog`——Supabase 平台自带事件触发器（非本仓 migration 产物），object_identity 来自 `pg_event_trigger_ddl_commands()` 非用户输入，`pg_catalog` 与空串等效安全（仅系统函数可见）。**不构成 P1**
- **角色继承**：authenticator 唯一 rolinherit=false（作为 JWT→role gateway），成员关系 authenticator∈{anon,authenticated,service_role}，标准 Supabase 模型，无异常
- **core_test_write_v1 权限**：ACL `{postgres=X/postgres}`——从未进入任何客户端角色；「GRANT 收回」为既成事实，剩「删除计划标注」归 P0-006

## 发现的问题

### 🔴 P1 — `core_test_write_v1` 缺 expired 分支（正式复现，P0-004 移交项确认）

expired-defect.sh 三次独立复跑均稳定：identical-input expired receipt 重放 → 业务逻辑穿透执行（note_written=true）→ `receipt_complete` 找不到 processing 行 → `P0001 receipt_state_invalid` 整体回滚。

- **违反 C-04**：「超期请求返回 409 并要求重新读取，绝不能重跑」——此处返回 P0001 技术错误且业务已执行一遍（靠回滚兜底无残留，但浪费完整业务事务）
- **性质**：测试专用入口（ACL 仅 postgres），生产四命令 expired 分支均已实测正确；M1 无收据清理任务，expired 生产不可达
- **修复方向**：`core_test_write_v1` 的 receipt 分发补 `elsif v_rs.status = 'expired'` 分支（与 initialize/manage 三分发同构）→ 返回 `IDEMPOTENCY_RESULT_EXPIRED` 封套
- **移交**：报告原任务作者（P0-004 = Trae + Kimi K3）修复，修复后本卡复验

### 非缺陷（提示词点名项，核验后澄清）

| 项 | 核验结论 |
|---|---|
| `health-client-token.mjs` argv token | **不成立**。argv 仅 action + 位置参数（name/type/client_id/credential_id），token 由脚本内 `randomBytes(32)` 生成，凭据全走 env + keychain；第 37 行是 `keychainSave` 定义。合同"argv 不接受 token"已满足 |
| `core_test_write_v1` 生产权限移除 | **既成事实**。ACL `{postgres=X/postgres}`，anon/authenticated/service_role 全无 EXECUTE。删除计划标注进 P0-006 |

## 未验证 / 边界声明

- **owner HTTP 正向登录**（真实 JWT 密码登录拿 owner JWT）：无 owner 密码，且属 P0-006/007 登录壳职责。S03 owner 语义已用 claims 模拟验证（auth.uid() 派生路径与 PostgREST 同源）
- **anon/probe 真实 REST 端点**：需 publishable key（keychain 无）；DB 侧 SET LOCAL ROLE 已覆盖 RLS grant/角色语义。REST 传输层留 P0-006/007
- **S07 Edge 侧过期/撤销 token 拒绝**：属 P0-007 health 端到端，DB 侧本卡仅验凭据状态字段
- **Dashboard 孤儿 PROBE_TOKEN secret**：PAT 无 secrets scope，无法验证删除状态——**需凯哥 Dashboard → Edge Functions → Secrets 确认**

## 验收对照（任务卡 6 条）

| 验收 | 结论 |
|---|---|
| ≥20 有效更新连续不同版本，final=初值+有效数 | ✅ T03 ok=20 unique=20 final=base+20 |
| 两同 expected 仅 1 成功；同 key 同 body 单变更；软删不复活 | ✅ T04/T05/T08 |
| anon 无数据无变更；owner 与 non-owner 真实身份测试（非 service_role 代跑） | ✅ S01/S02/S03（claims 模拟真实 JWT 身份，未用 service_role） |
| 撤销并发：撤销提交后无新授权写；审计技术失败无半事务 | ✅ S08 竞态时间戳 + T07 整体回滚 |
| Agent 投影按 read scope 裁剪；write-only/撤 read 不泄 payload；不开生产业务 Agent | ✅ S09（receipt 无 payload/无 token_hash）；write-no-read 端到端投影裁剪属 P0-006/007，M1 无业务 Agent 端点 |
| 无未解决 P0/P1 缺陷；P0-004 作者不可代替独立签核 | ⚠️ 存在 1 个 P1（expired 分支），已报告待原作者修复复验 |

## 下一步

1. 停等 Review（WorkBuddy + Kimi K3 异模型反例终审）
2. P1 缺陷同步移交原作者（Trae + Kimi K3）修复 migration 0011，本卡复验后收口
3. 凯哥 Dashboard 确认孤儿 PROBE_TOKEN secret 删除
4. task-index 未动（Review 方签核后才 transition）
## Review 复验（Review 方: Hermes GLM-5.3，修复后全程实测，2026-09-20）

1. `0011` migration 已应用（pg_proc 函数体含 `IDEMPOTENCY_RESULT_EXPIRED` 分支，官方证据 мной复测）
2. 核心复现链：fresh key → 成功(RESOURCE_NOT_FOUND→揭示本卡"修复前"路径) → 强制 expired → 同key同input 重调 → **`IDEMPOTENCY_RESULT_EXPIRED` 返回(收据messageEXPIRED)**，无 P0001 穿透 / 无业务穿透（`life_data` 行数与 receipt_count 不变）——两者与 K3 报告完全一致，C-04 语义成立
3. 无删残（我清理了从fresh key的这个Fragable test harness），保证了 p0test 键 + contracts 保留件, data_revision 看 26 时点级别
4. 版本触发器仍按 P0-004 实测一致（version 24→25），无回归

P0-003 复检项 expired 返回语义 = 对应合同 C-04/HTTP 409 同位验证 PASS。

结论: 0011 修复正式有效，代码/DB/合同三层一致。**P0-005 复验 PASS。**
