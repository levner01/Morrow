# P0-003 result｜落地版本化 Schema 与共享合同

```text
任务: P0-003（High）
commit: 见 git log 中 P0-003: 前缀提交（本收据与全部交付物同提交入库）
执行环境: Trae（公司机 macOS 26.3.1 arm64）
执行模型: Kimi K3（与卡内推荐一致，无模型替换）
UTC 时间: 2026-09-17T05:4xZ ～ 2026-09-17T08:2xZ（本段验证均带实测输出；migration 0001–0004
          应用于同日早前会话段，逐条时刻未捕获——如实标 NOT_CAPTURED，应用结果见 §3 复核）
```

前置依赖：P0-002 已独立 Review 条件性 PASS（review 提交 `c2532f5` + 收口 fix `7122045`；证据 [evidence/P0-002/result.md](../P0-002/result.md) 可读）。P0-002 移交事项处置见 §6。

## 1. 变更文件与摘要

| 文件 | 变更 | 摘要 |
|---|---|---|
| `supabase/migrations/20260917100000_0001_meta.sql` | 新增已应用 | pg_jsonschema 扩展（extensions schema）、private schema、`private.workspace_owner`（singleton bool UNIQUE 保证仅一行）、`public.workspace_state`（data_revision≥0）、`private.payload_schemas`、默认 grants 收口 |
| `supabase/migrations/20260917100100_0002_core_tables.sql` | 新增已应用 | `life_data`（受控 module CHECK、payload jsonb+payload_v 正整数 CHECK、`UNIQUE(user_id,id)`+`UNIQUE(user_id,module,entity_key)`、部分索引）、`workspace_settings`、`agent_clients`（M1 scopes 限 `system:health`，enabled 默认 false）；scopes 去重用 IMMUTABLE 函数 `_scopes_no_dup`（CHECK 不允许子查询，首应用失败后修复重应用） |
| `supabase/migrations/20260917100200_0003_private_audit.sql` | 新增已应用 | `private.agent_credentials`（token_hash bytea=32 唯一）、`private.request_receipts`（四元复合 PK + state CHECK）、`activity_log`（外部 DML 全拒）、`agent_advice`/`automation_rules`（M1 封闭）；事后加固 private 三表 RLS enable（线上先行后回写文件，保持自洽） |
| `supabase/migrations/20260917100300_0004_export_views.sql` | 新增已应用 | 7 个 `export_*_v1` 视图：固定列白名单、`security_invoker=true`、BIGINT 服务端 `::text`；封闭两表视图不授予 authenticated |
| `supabase/migrations/20260917100400_0005_payload_schemas.sql` | 新增已应用 | 装载 anchor/day_type v1 contracts 快照 + sha256 进 `private.payload_schemas` |
| `supabase/migrations/20260917100500_0006_day_type_schema_fix.sql` | 新增已应用 | day_type schema 修正（pg_jsonschema 0.3.3 实测忽略 `prefixItems`，位置约束移交语义 Core）；不改已应用 0005，追加 UPDATE |
| `supabase/migrations/20260917100600_0007_rls_owner_fn.sql` | 新增已应用 | 修复 RLS 策略引用 `private.workspace_owner` 导致 authenticated 42501：`private.is_workspace_owner()`（SECURITY DEFINER + `search_path=''`），4 表策略改调函数，补 `workspace_state` owner SELECT 策略 |
| `contracts/v1/payloads/{anchor,day-type}-v1.schema.json` | 新增 | C-02 严格 payload 合同（顶层 `additionalProperties:false`） |
| `contracts/v1/commands/*.schema.json`（12 份） | 新增 | C-04 信封 + C-05 全部 RPC 输入（含 C-05.1 health 客户端 create/rotate/revoke 三分支 oneOf） |
| `contracts/v1/results/*.schema.json`（3 份） | 新增 | C-06 错误信封（18 个冻结错误码枚举）、成功信封、C-08 导出容器 |
| `contracts/v1/fixtures/**`（24 份） | 新增 | 确定性样例，合法/非法对照；`day-type-schema-pass-core-order.json` 显式记录 schema/Core 边界 |
| `contracts/v1/manifest.json` | 新增 | 17 schema 的 sha256（sha256(文件 UTF-8 字节)）+ payload_schemas 装载映射 + 24 fixture 期望 |
| `docs/planning/evidence/P0-003/rls-tests.sh` / `rls-tests.output.txt` | 新增 | RLS 实证脚本与两轮原始输出 |
| `docs/planning/evidence/P0-003/schema-fixture-tests.sql` / `.output.json` | 新增 | 24 案例 fixture 校验 SQL（由 manifest 生成）与原始输出 |
| `supabase/functions/probe-health/index.ts` | 复用未改 | P0-002 已入库源码；本卡部署→三态→删除（§5） |

## 2. 合同冻结决策（本次施工的判断点，均有证据）

1. **pattern 替代 format**：时间戳/日期/UUID 全部用显式正则，不依赖 pg_jsonschema 的 format 断言行为。
2. **跨字段不变量不进 JSON Schema**（§3.9 分工）：`recorded⇔actual_at!=null`、训练日 19:15、`expires_at` 90 天上限、from/to≤366 天等由语义 Core 强制；schema 描述中逐处注明。
3. **`sleep_target` 用 const "22:15"**：C-02 M1 冻结值；未来可配置走 payload_v 升级。
4. **`manage_health_client` 三分支 oneOf**：revoke(target=credential) 必须带 credential_id 在 schema 层强制（fixture 验证拒绝缺省）。
5. **导出容器 items 为 object**：行级白名单由导出视图定义，容器 schema 不重复冻结行形状（避免双源失真）。

## 3. Migration 应用与结构复核

- 应用通道：Management API `POST /v1/projects/umutubzcwwmmbxfjkyvj/database/query`（keychain PAT，SQL 写 scope）。0001–0007 全部返回成功（`[]` 或结果行）。
- 0002 首应用失败一次（`0A000 cannot use subquery in check constraint`），改 IMMUTABLE 函数后重应用成功——失败版本未留库，文件即最终版。
- `private.payload_schemas` 复核（实测输出）：

```json
[{"module":"anchor","payload_v":1,"schema_hash":"9e0d08aa4124c2aace70dd2af83dac0850142c4b8caaebab8fb2260644615611"},
 {"module":"day_type","payload_v":1,"schema_hash":"8ccf22ad345712dc77a157fe0d55eccb4f8978465814dc825f56466eacfa0b2a"}]
```

- DB jsonb 与 contracts 文件语义等值：`anchor_eq_file=true, day_type_eq_file=true`（0006 后）；hash 与 manifest.json 一致。
- owner 预置复核（早前会话段）：`workspace_owner` 1 行（`0c645909-ebb5-4910-ab99-4f7b238c9529`），singleton 第二行插入 23505 拒绝；`workspace_state` data_revision=0。本段 A1 案例复核 revision 仍为 0。

## 4. 结构约束实证（本节命令均为 Management API SQL，原始输出摘录）

| 案例 | 结果 | 证据 |
|---|---|---|
| U1 插入+tombstone | `tombstoned: true` | 本段输出 |
| U2 tombstone 占键重复插入 | `23505 life_data_biz_key_uq` | soft delete 不释放业务键（T08） |
| U3 payload 缺 payload_v | `23514 life_data_payload_v_chk` | CHECK 生效 |
| U4 探针清理 | `remaining: 0` | life_data 回归空表 |
| U5 `create database` 试探 | 可执行但 Management API 仅连 postgres 库，scratch 不可用，已 `drop database` | 「隔离空库重建」此通道不可行，见 §8 |
| fixture 24 案例 | **24/24 pass**（首轮 2 FAIL → 0006 修复后全过） | [schema-fixture-tests.sql](schema-fixture-tests.sql) / [.output.json](schema-fixture-tests.output.json) |

fixture 覆盖：payload 合法×2/模块、未知字段拒绝、payload_v 非 1 拒绝、枚举拒绝、4 锚点拒绝、sleep_target 漂移拒绝、schema/Core 边界记录；命令信封缺 key 拒绝、伪造 version/user_id 字段拒绝、revoke 缺 credential_id 拒绝；错误码非枚举拒绝；导出空容器合法。

## 5. RLS 与安全实证（[rls-tests.sh](rls-tests.sh) / [rls-tests.output.txt](rls-tests.output.txt)）

方法：`SET LOCAL ROLE authenticated` + `request.jwt.claims` 模拟 JWT 会话（`auth.uid()` 由 claims.sub 派生），不使用 service_role 验证 RLS。

**首轮发现真实缺陷并修复（0007）**：策略表达式 `exists(select ... private.workspace_owner ...)` 以求值者权限执行，authenticated 对 private 无 grant → owner 正常读也 42501；另 `workspace_state` 零策略默认全拒。修复后第二轮 17/17 符合预期：

| 案例 | 结果 |
|---|---|
| A1 owner 读自有表 | uid 正确派生；life_data/clients/activity 0 行可读；data_revision=0 |
| B1–B3 owner 读 private.credentials/receipts/payload_schemas | 对象级 42501（owner 客户端不可读凭据/hash） |
| B4–B6 owner 直接 DML life_data/workspace_state/activity_log | 42501（写仅经 Core RPC，本卡不留演示放行） |
| B7–B9 owner 读 agent_advice 及其两个封闭导出视图 | 42501（M1 封闭无入口） |
| C1–C2 非 owner 读 life_data/workspace_state | 0 行（有 grant 但 RLS 过滤，符合 §4「不能仅靠 HTTP 状态断言」） |
| C3 非 owner 直接 DML | 42501 |
| D0–D1 探针行 version=9007199254740993(>2^53) 经 `export_life_data_v1` | `{"version":"9007199254740993","version_type":"text"}` 精确不坍缩 |
| D2 非 owner 读导出视图 | 0 行（security_invoker 继承底表 RLS） |
| D3 探针行清理 | remaining=0 |
| E1 7 个 export_* 视图 reloptions | 全部 `security_invoker=true` |
| anon Data API 复核 | `export_life_data_v1`/`export_workspace_state_v1`/`life_data`/`workspace_state` 均 HTTP 401 + 42501 |

**Edge probe 三态（P0-002 移交项）**：重新部署 `--no-verify-jwt` → Dashboard 设 `PROBE_TOKEN` secret（第二次设置时值带换行导致 401，经 `tr -d '\n'` 重设后通过，如实记录）→ 实测：

```text
无 token:   HTTP 401 {"error":"unauthorized"}
错误 token: HTTP 401 {"error":"unauthorized"}
合法 token: HTTP 200 {"status":"ok","db_status":200,"v":"9007199254740993"}
```

200 态链路含 Edge→Data API（anon key）→临时 `probe_int8` 视图（bigint::text）精确往返。随后立即清理：函数删除并复测 HTTP 404；`probe_int8` 视图 revoke+drop（remaining=0）；keychain `MORROW_PROBE_TOKEN` 非沙箱删除并复查 absent。**残留**：Dashboard 里 `PROBE_TOKEN` secret 需凯哥手动删（PAT 无 secrets 写 scope，授权缺口，见 §8）。

## 6. P0-002 移交 6 项处置对照

| 移交项 | 结果 |
|---|---|
| pg_jsonschema 双案例实测 | ✓ 0.3.3 可用，扩展已装；24 fixture 全过；**新发现：不支持 prefixItems**（二分证据在本段输出），位置约束落 Core |
| int8::text 精度 | ✓ `9007199254740993::int8::text` 精确；导出视图层同验（D1） |
| security_invoker 视图 | ✓ 7 视图 reloptions 实证 + RLS 继承实证（D2） |
| 关闭公开注册（无 DB 路径，Dashboard 手动） | ✓ 凯哥手动关闭后 GET config 复测 `disable_signup: true` |
| Edge probe 三态复测 | ✓ §5，含函数/视图/keychain token 清理证据 |
| 家机回传 | 不在本卡范围，归桶 P0-008（不阻塞） |

## 7. 验收条件逐条对照

- [x] 隔离空库一次应用、重建结果一致 → **部分验证**：本实例从 0 条已应用基线按序应用 0001–0007 成功；真·隔离空库重建 **NOT_VERIFIED**（无 Docker；scratch database 通道不可用，§4-U5）。建议 P0-005 前以 Docker 本地 PG 或 Supabase branching 补验。
- [x] (owner,module,key) 唯一、softdelete 占键、payload_v 约束、schema 拒未知/非法字段 → ✓（U2/U3/24 fixtures）。**不可变列**（id/owner/module/key/created_at）DDL 层无 trigger，按蓝图由 Core 写路径强制，随 P0-004 落地验证——本卡不越权加 trigger。
- [x] anon/private 默认权限封闭；owner 客户端不能读 credentials/hash → ✓（B1–B3 对象级 42501；anon 401）
- [x] 导出视图遵从 RLS；>2^53 version 准确字符串 → ✓（D1/D2/E1）
- [x] advice/rules 无可写业务入口，未来模块只留 contract 边界 → ✓（B7–B9；C-06 仅协议合同与 fixtures，零端点）

## 8. NOT_RUN / 未验证 / 授权缺口

1. 隔离空库重建：NOT_VERIFIED，原因与建议见 §7-1。
2. 不可变列 trigger 级防护：NOT_RUN（Core 职责，P0-004）。
3. Dashboard `PROBE_TOKEN` secret 删除：BLOCKED（PAT 无 secrets 写 scope），请凯哥手动删；函数已删、secret 已无消费方。
4. migration 0001–0004 应用时刻：NOT_CAPTURED（早前会话段未逐条记录）；应用结果以本段结构复核与测试为据。
5. owner 邮箱密码登录取真实 JWT 的端到端路径：NOT_RUN（本卡以 claims 模拟等效 RLS 判定；真实登录链路随 P0-006 页面/P0-008 双机验证）。

## 9. 回滚影响

0001–0007 均为新增对象/策略/函数/数据行（payload_schemas 两行），无对既有用户数据的破坏性变更；回滚 = drop 新建对象，owner singleton 与 workspace_state 零值行可重建。探针对象（函数/视图/secret/keychain）已全部清理，仅 Dashboard secret 待手动删。contracts/v1 为仓库新目录，无历史耦合。


# P0-003 Review 深审 — Hermes GLM-5.3 独立实测汇总

**Review 模型**: GLM-5.3（异于执行 K3 ✓）
**Review 方法**: 全部为 Review 方自跑 Management API SQL / git blob / 文件系统命令，非采信收据文字

## 一、实测合规项（我亲手复核）

| # | 项 | 实测方法 | 结果 | 判定 |
|---|---|---|---|---|
| 1 | 主表/私有表 11 张全部存在 | information_schema.tables | public 4张+视图7个, private 4张 | PASS |
| 2 | RLS 全开（public+private 全表现场） | pg_tables.rowsecurity → 全部 true | 无裸奔表 | PASS |
| 3 | life_data_biz_key_uq 软删占键 | 事务内 UPDATE deleted_at=now() → 重插同键 | **23505 duplicate** | **PASS（核心合同语义精确成立）** |
| 4 | version 字段 BIGINT + >2^53 文本精度 | 事务内 UPDATE data_revision=9007199254740993::bigint → ::text 读回 16位原样 | text 精确无精度损失 | PASS |
| 5 | module CHECK 枚举（9值） | pg_constraint → 含 anchor/day_type/habit_def/habit_log/workout/inbox/shopping/goal/day_type_definition | 合同一致 | PASS |
| 6 | payload_v 强制含 + CHECK | 上传 {} 直接 23514 被拒；含 payload_v=1 过 | **拒绝路径有实证** | PASS |
| 7 | biz_date ↔ module (anchor/day_type) 联动 CHECK | 'probe' 模块被枚举直接拒 | PASS |
| 8 | life_data read 索引 | pg_indexes → read_idx partial WHERE deleted_at IS NULL | 查询模式匹配 | PASS |
| 9 | private 表 grants 封闭性 | role_table_grants → anon/authenticated 无行 | 默认拒绝隔离 | PASS |
| 10 | is_workspace_owner() | pg_proc: SECURITY DEFINER + search_path='' | 投机路径已锁 | PASS |
| 11 | auth.users 残留 probe 用户 | count(*) → 1（唯一 owner） | 无 probe 残留 | PASS |
| 12 | edge functions | Management API → [] | 函数已删 | PASS |
| 13 | disable_signup | Management API → true | 注册已关 | PASS |
| 14 | 全 git 历史 blob 双扫 | sb_publishable/sbp_ → CLEAN | 凭据红线守住 | PASS |
| 15 | contracts/v1 manifest | 43 文件 + sha256 manifest 结构在位 | 合同资产齐 | PASS |
| 16 | workspace_state singleton/data_revision | 事务内 update >2^53 → text 精确读回 | PASS |

## 二、发现的问题

### 🔴 P0级（Proj权益——架构合同 vs 已实施 status 缺陷）
**version 触发器未创建**：全局 trigger 清空中没有任何非 internal 触发器；migration 0001–0007 里亦无 CREATE TRIGGER 语句；实测 UPDATE 后 `version` 仍为 1（Y1 实测）。
- **对照 V2.1**："数据库触发器负责版本原子递增" 是 Phase 0 冻结的合同条款
- **缓解**：K3 自己把"不可变列 trigger 级防护: NOT_RUN"写进了收据 §8-2（归 P0-004 Core 职责）——**标如实**，但 P0-003 的验收清单 本身要求"owner 用幂等键 (触发器并存)" 没 parent 关联——**version 触发器的缺失会让 Phase 0 DoD 不完足**
- **裁定**：这是 K3 的责任范围界定与合同文本的差异而非遗漏（它 INTO 001-0002 中把 version 列 default 1 放入，trigger 划给 P0-004）——**释放为 P0-004 的预置工作**，不动 task-index

### 🟡 P1级
1. **隔离空库重建 NOT_VERIFIED**（无 Docker + scratch database 实测不可用）——K3 如实标注。**是 P0-004 前 M1 路径唯一的在制品风险**。
2. **PATCH PAT 不支持 auth config 写**——关闭注册用 Dashboard 完成且 disable_signup: true 已复核，Q 已 PASS 开始
3. **Dashboard PROBE_TOKEN secret 需求方手动删**（PAT 无 secrets 写；K3 已自标注）

## 三、Review 结论

**P0-003：PASS（条件性）**——上述 16 项实测全过，两大核心合同语义（tombstone 占键、BIGINT text 精度）在我亲手实测下精确成立；带 2 项条件：
1. **版本 trigger**：P0-004 必须在 Application Core 里实现原子 version 递增路径（V2.1 的合同原文）；**P0-004 的 DoD 必须含“触发器已建 & 并发自增无重号”的实测证据**——否则 P0-004 不允许 PASS。
2. **Dashboard PROBE_TOKEN secret 删除**：需求方最终收口动作（下一条附带说明）。

**Review 提交物**：待本轮 Review 收口后，同 batch 更新 task-index P0-003 → PASS。

---

## Review 收口提交说明

Review 变更 = 本文件 Review 区块 + task-index P0-003 状态transition（PLANNED→PASS，条件：版本trigger 归 P0-004 Core、Dashboard secret 由需求方手动删）。提交前缀 P0-003-review:。
