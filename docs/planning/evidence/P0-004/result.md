# P0-004 收据：唯一 Core 的身份、事务、版本、审计与幂等框架

- 任务卡：docs/planning/tasks/P0-004.md
- 模型：Kimi K3（施工）；凭据：keychain `MORROW_SUPABASE_ACCESS_TOKEN`（值不落盘、不进命令行参数）
- 输入：02-contracts.md C-04/C-05/C-05.1/C-06/C-10；01-architecture.md §3.10/§4/§5/§10.1；P0-003 Schema（PASS，commit 8f6be16 / review 0ca7664）

## 头部裁决（开工令）执行回执

| 裁决 | 执行 | 证据 |
|---|---|---|
| 版本触发器本次必须落地（V2.1 BEFORE UPDATE 原子递增） | 已落地：life_data/settings/agent_clients BEFORE UPDATE 强制 `NEW.version := OLD.version + 1`（0008 §2） | T03 实测见下 |
| 验收含"并发 UPDATE 无重号"实测 | 已实测：20 并发 human LWW 更新同一行 | `T03_20concurrent_unique_versions` PASS：20 unique，range 4..23，base=3 final=23，ok=20；T04 双 agent 同 expected_version 并发一成功一 `VERSION_CONFLICT`，final=24 |
| Dashboard 孤儿 PROBE_TOKEN secret 待需求方手动删（不阻塞施工） | 未动（需求方动作） | 待凯哥 Dashboard → Edge Functions → Secrets 删除 |
| 不建业务 HTTP/MCP、不暴露 private helper、不改已应用 migration | 遵守：0 个 Edge Function；helper 全撤 PUBLIC/anon/authenticated/service_role；0001-0007 未改，0008/0009/0010 为追加 | grants 收口段（0008 §9、0010 末尾）；A1-A4/B1 实证 |

## 交付物

| 文件 | 说明 |
|---|---|
| supabase/migrations/20260917110000_0008_core_framework.sql | Core 框架：actor GUC、6 trigger 函数 + 7 trigger、receipt_begin/complete/reject、helper 组、4 个 private cmd_*、core_test_write_v1、4 个 public invoker、grants 收口 |
| supabase/migrations/20260917120000_0009_core_framework_fix.sql | 缺陷修复①②（见下） |
| supabase/migrations/20260917130000_0010_manage_prereject_fix.sql | 缺陷修复③（见下）+ 新增 helper `cmd_pre_reject` |
| scripts/health-client-token.mjs | C-05.1 token 签发/轮换/撤销最小脚本（create/rotate/revoke-client/revoke-credential）；token `mrw_v1.<cred_uuid>.<b64url>` 本地生成 → sha256 hex 经 RPC 入库；明文先 keychain 暂存、成功转存、失败清除；只打印一次 |
| docs/planning/evidence/P0-004/core-tests.sh | 65 断言实证矩阵（可重跑：头部清场 scoped owner + token hash 随机化） |
| docs/planning/evidence/P0-004/core-tests.output.txt | 第三轮原始输出：PASS=64 FAIL=0 |

## 缺陷与修复证据链（三轮实测）

1. **0008 首轮**：K 系列全过；D2/L/E/F/G/H/I/J 挂。根因二处——
   - 42703：`trg_after_write_audit` 共用 IF 条件 `TG_TABLE_NAME='agent_clients' and NEW.name ...`，PL/pgSQL IF 交 SQL 求值器、AND 不短路，life_data/settings 行求值 `NEW.name` 报错。**0009 修复**：嵌套 IF，外层只判安全标识符。
   - 42883：pg_jsonschema 0.3.3 `jsonb_matches_schema(schema json, instance jsonb)` 第一参数是 json 非 jsonb。**0009 修复**：`v_schema::json`。
2. **0009 第二轮**：59/60。K6e（revoke 未知 client）报 P0001 `receipt_state_invalid`——manage 的 not-found/形状预检 4 处分支在 `receipt_begin` 之前以非空 key 调 `cmd_finish_err`，`receipt_reject` 找不到 processing 行。**0010 修复**：新增 `cmd_pre_reject`（调用方已持 state 锁 → receipt_begin → 状态分发 → 拒绝落据），锁序 state→receipt 不变；4 分支改走它。
3. **0010 第三轮**：64/64 PASS（新增 K6f 拒绝重放、K9a/b/c 预检回归）。

## 验收矩阵结果（第三轮，全绿 64/64）

- A1-A4 grants：anon/service_role RPC 拒、authenticated 不可 EXECUTE helper/测试入口
- B1：Human 直 DML 拒绝（P0-003 回归）
- C1-C4 伪造拒绝：自报 user_id / Human 带 expected_version / p_uid≠auth.uid() / 非 owner
- D1-D2 actor 上下文：缺 GUC 拒写；trigger 强制 source_type/source_id=actor、version=1
- L1-L4 initialize：双并发一成功一 ALREADY_EXISTS 且 settings=1；重复拒；同 key 重放；schedule_history 长度 1
- K1-K9 manage：create/重放不多写/同 key 异 input 409/rotate 收紧旧凭据 24h/同 key 并发 create 单 client/create‖rotate 无死锁/revoke 幂等/未知 client 404+拒绝重放/三预检分支 VALIDATION_FAILED
- E1-E6 版本：agent create v1→human LWW v2→no-op 不增→agent OCC v3→过期 VERSION_CONFLICT（附 current_version）；单一审计来源 3 条
- F1-F2 幂等：重放不多写；同 key 异 input IDEMPOTENCY_KEY_REUSED
- G1-G2：create0 不覆盖；tombstone 拒 create（RESOURCE_DELETED）且删除本身增版
- H1-H2：fault='after_business_write' 注入后 rev/receipts/life/activity 四计数不变（整体回滚）
- T03/T04：见头部裁决回执
- M1-M3：响应/receipts/activity_log 均不含 token_hash
- N1-N3：只读命令无副作用（receipts/rev 不变）；unknown key 404；revision 十进制字符串
- O1：last_seen 仅变化不增 client 版、无配置日志、bump revision（86→87→90→91 区间实测）
- Z0/Z1：清场与 settings 复位（保留 workspace_owner/workspace_state 行）

## 设计落点（架构事实记录）

- 可信 actor：transaction-local GUC `morrow.actor`（`type:uuid`）+ `morrow.request_id`；trigger 缺上下文即拒（纵深防御，grant/RLS 为第一防线）
- 唯一日志来源：资源变更全走 AFTER trigger 写 activity_log + bump data_revision；Core 显式事件仅非资源动作（credential.create/rotate/revoke、command.rejected、core_test.no_change）；activity_log 自身 INSERT 只 bump 不递归（T11）
- 锁序：create = state→receipt→insert；rotate/revoke = client→credentials(按 id 升序)→state→receipt；K7/K8 并发实证无死锁
- Human LWW（带 expected_version → 422 VALIDATION_FAILED）/ Agent OCC（必带，create 用 "0"）
- 幂等：PK (user_id, actor_type, actor_id, idempotency_key)；request_hash=sha256({operation,input})；ON CONFLICT 等 in-flight 落定后重放；业务拒绝正常提交留 rejected receipt（可重放），技术故障抛异常整体回滚
- 函数 owner = postgres（托管环境"独立 NOLOGIN Core owner"的事实载体，同 P0-003 记录）

## 未验证 / 边界声明

- `scripts/health-client-token.mjs`：NOT_RUN（需 owner JWT 真实调用；属宿主侧动作，留给 M1 health Agent 接入任务）
- 20 并发为 Management API 串行驱动的 shell 并发，非生产级压测；结论仅证"无重号 + 无死锁"语义
- expired receipt 分支（IDEMPOTENCY_RESULT_EXPIRED）：NOT_RUN（无 48h 时间机；代码路径与 conflict 同构）
- P0-003 遗留 NOT_RUN 项（immutable column trigger 本轮已由 E/T03 覆盖实证；isolation 空库重建仍 NOT_VERIFIED，维持 P0-003 收据结论）

## 下一步

- 停等双 Review（Hermes + GLM-5.3 深审；WorkBuddy DeepSeek V4.1 Flash 独立反例初审）
- 凯哥手动删除 Dashboard 孤儿 PROBE_TOKEN secret
- task-index 未动，由 Review 方更新

---

# P0-004 Review 深审 — Hermes GLM-5.3 独立实测汇总

**Review 模型**: GLM-5.3（异于执行 Kimi K3 ✓）
**Review 方法**: 全部为 Review 方自跑 Management API SQL / git blob / 文件系统命令，不采信收据文字；深审条件继承 P0-003 Review 裁决（version trigger 实测 + 并发无重号为 P0-004 DoD 硬项）。
**独立复跑证据**: [review-rerun-core-tests.output.txt](review-rerun-core-tests.output.txt)（Review 方亲手重跑 64 断言，SUMMARY: PASS=64 FAIL=0，与施工输出逐项吻合，含 H2 rev=40、O1 90→91、T03/T04 输出同构）。

## 一、实测合规项（我亲手复核）

| # | 项 | 实测方法 | 结果 | 判定 |
|---|---|---|---|---|
| 1 | 0009/0010 真已应用 | pg_proc：`cmd_pre_reject`/`core_test_write_v1`/`receipt_begin` 现场定义含 `::json` 修复 | 生产函数即文件最终版 | PASS |
| 2 | 8 项业务 trigger 全启用 | pg_trigger 全景（tgenabled=O） | life_data×3/settings×2/clients×2/activity×1 全在 | PASS |
| 3 | T03 并发无重号（深审条件 1） | 亲手复跑 20 并发 UPDATE 同行 | 20 unique、range base+1..base+20、final 吻合 | **PASS** |
| 4 | T04 OCC 单赢家（深审条件 2） | 亲手复跑双 agent 同 expected | 一 ok 一 VERSION_CONFLICT，final=expected+1 | **PASS** |
| 5 | 64 断言独立复跑 | 重跑 core-tests.sh（keychain PAT） | **64/64 PASS**，与施工输出同构 | PASS |
| 6 | `cmd_pre_reject` conflict 分发 | R3：同 key 异 input 事务内探针 | `IDEMPOTENCY_KEY_REUSED`（正确） | PASS |
| 7 | `cmd_pre_reject` expired 分发 | R4：receipt state='expired' 构造 | `IDEMPOTENCY_RESULT_EXPIRED`（正确，无需时间机） | **PASS（施工方标 NOT_RUN 的项，我实测通过）** |
| 8 | `cmd_pre_reject` ACL | has_function_privilege 三角色 | anon/authenticated/service_role 全 false | PASS |
| 9 | initialize expired 分支 | R1：state 构造 + 同 input 重调 | `IDEMPOTENCY_RESULT_EXPIRED`，业务未重跑 | PASS |
| 10 | revoked→rotate 拒绝 | R5：事务内 create→revoke→rotate | `RESOURCE_DELETED`（C-05.1 语义正确） | PASS |
| 11 | revoked→create 同名=新 client | R5：create 返回新 client_id | 不复活旧 client，新身份合法 | PASS |
| 12 | credentials 不可读（S05） | authenticated SELECT 探针 | 42501 | PASS |
| 13 | activity_log 不可删（S05 扩展） | authenticated DELETE 探针 | 42501 | PASS |
| 14 | anon 全盲（S01） | anon SELECT life_data | 42501 | PASS |
| 15 | private 函数 bulk ACL | R6：has_function_privilege 全扫 | 仅 4 cmd_* + is_workspace_owner(authenticated) 对 auth 开放，其余全拒 | PASS |
| 16 | BIGINT 精度（>2^53） | data_revision=2^63-1 → ::text | 19 字符逐字符精确 | PASS |
| 17 | activity_log FK（agent 伪造拒绝） | R2 失败输出顺带证实 | 虚构 agent_id 插入被 FK 23503 拦截——审计行 agent 必须真实存在 | PASS（意外收获） |
| 18 | settings 版本 trigger 回归 | R10：真实行 update | v1→v2 | PASS |
| 19 | 0001-0007 未改 | git diff 8f6be16..3372df6 -- migrations | 仅 0008/0009/0010 新增 | PASS |
| 20 | 凭据红线 | git 全历史 blob 扫 sbp_/sb_publishable_/eyJ JWT 模式 | 仅 P0-002 收据里的前缀字面量与 fixture 截断示意，无真实值 | PASS |
| 21 | task-index 未被施工方动 | git status + diff HEAD | 干净 | PASS |
| 22 | health-client-token.mjs 语法 | node --check | 通过；脚本纪律合规（token 本地生成、只传 hash、keychain 暂存、失败清理） | PASS |

## 二、发现的问题

### 🟡 P1级 — `core_test_write_v1` 缺 expired 分支（协议缺陷，非阻断）

R2b 实锤：identical-input expired receipt 重放时，`core_test_write_v1` 无 expired 分支 → 业务逻辑完整执行一遍 → `receipt_complete` 炸 P0001 `receipt_state_invalid` → 整体回滚。生产无残留（回滚兜底），但违反 C-04 "超期请求返回 409 IDEMPOTENCY_RESULT_EXPIRED 绝不能重跑" 的协议语义——返回的是技术错误而非合同封套。

**性质界定**：`core_test_write_v1` 是测试专用入口（仅 postgres 可执行，grant 全撤），生产四命令的 expired 分发均已实测正确（R1/R4）。M1 无收据清理任务（C-04），expired 生产不可达。**裁定：不构成 P0-004 DoD 违背，不阻断 PASS**。

**移交 P0-005 必测清单**：
1. `core_test_write_v1` 补 expired 分支（与 initialize/manage 同构三分发）——修复项，非纯测试项。
2. P0-005 并发反例测试需覆盖：expired receipt 同 input 重放、processing 残留的 `receipt_in_progress_stuck` 路径（0.2s×2 短等后技术故障回滚）。

### 🟡 观察项（不要求修复）

1. **envelope 形状拒绝不建 receipt**：envelope 畸形时 key 未解析无法建 namespace，重复畸形请求会重复写 `command.rejected` 审计行。合同未要求畸形请求幂等，M1 单用户可接受。
2. **C3 测试命名误导**：`C3_forged_puid_denied` 实测的是 non-owner 分支（p_uid≠auth.uid()），行为正确，命名与语义错位。
3. **复跑后线上测试残留**：复跑矩阵 Z0 清场在开头、Z1 只复位 settings；跑完留 receipts=50/activity=57/clients=3/life=4，与施工方跑后同构（下次 Z0 可清）。验收测试数据非生产数据，风险可控。
4. **`core_test_write_v1` 绕过 auth.uid()**：以 postgres 直驱设计（身份由 workspace_owner 内部复核），M1 期验收通道，P0-009 Phase0 门禁时需做退役/保留决策。
5. **模型路由纠偏**：Kimi K3 施工符合 03-execution §2 路由（DB/事务=K3），收据如实记录。Review 方 skill 内过时的"Trae=GLM-5.3"路由信息已修正。

## 三、Review 结论

**P0-004：PASS（条件性）**

- P0-003 Review 钉死的两大深审条件（version trigger 落地 + 并发无重号实测）均已在 Review 方亲手复跑下精确成立，64/64 独立复现。
- 施工方标 NOT_RUN 的 expired 分支（initialize/manage/cmd_pre_reject），我用事务内 state 构造法实测通过——比施工方声明走得更远。
- `core_test_write_v1` expired 缺口为测试入口协议缺陷，移交 P0-005 必测清单，不阻断。
- 唯一需求方动作不变：**Dashboard 孤儿 PROBE_TOKEN secret 手动删除**（凯哥）。

**条件（下期 DoD 硬项）**：P0-005 安全与并发反例测试必须包含本 Review 的 R2b 缺陷修复验证 + processing 残留路径 + expired 全分支覆盖，否则 P0-005 不允许 PASS。

**Review 提交物**：本文件 Review 区块 + task-index P0-004 → PASS（review_pass_commit=3372df6）+ 复跑输出留档。

---

# WorkBuddy 反例初审记录（DeepSeek V4.1 Flash）

**初审模型**：DeepSeek V4.1 Flash —— 异于执行方 Kimi K3 ✓、异于深审方 GLM-5.3 ✓
**初审方法**：清单 14 项反例全部由初审方**自行构造并实测**（Supabase Management API SQL 端点，POST `{"query":"..."}`），不采信施工收据文字，亦不采信深审结论——仅认自跑输出。
**凭据纪律**：PAT 仅经 keychain 注入**进程环境变量**，不落盘、不打印、不进命令行参数；本记录不含任何 token / key / hash 值。
**探针纪律**：除幂等与并发类（必须提交才能观测重放与竞态）外，全部 `begin; ... rollback;` 包裹；测试残留已精确回收（§7）。
**环境**：`current_user=postgres`，PostgreSQL 17.6。

## 0. 结论

> **PASS** —— 本清单 14 项反例**全部实测成立**，未发现新增 P0/P1 缺陷。

同时附：**2 条 `NEW-FINDING`（均判 P2 / 非阻断）** + **1 条对深审 "expired 分支实测通过" 的限定说明**（§6）。
均不构成 P0-004 DoD 违背，不阻断 PASS。

| 反例项 | 结果 | 关键实测 |
|---|---|---|
| 1 全 git 历史凭据扫描 | ✅ | 4 处命中全为已声明样例，无真实凭据 |
| 2 token 脚本纪律 + 语法 | ✅（附 NEW-FINDING-2） | `node --check` 通过；4 项纪律成立；argv 暴露见 §5 |
| 3 伪造身份 | ✅ | 8 个变体全部 `OWNER_DENIED` / 42501 |
| 4 直 DML | ✅ | 7 个变体全部 42501 |
| 5 actor 上下文 | ✅ | 缺 GUC 拒、自报值被覆盖、畸形 actor 拒 |
| 6 Human LWW / Agent OCC | ✅ | 422 / 422 / `VERSION_CONFLICT`+`current_version` |
| 7 create0 语义 | ✅ | `ALREADY_EXISTS` / `RESOURCE_DELETED`，tombstone 不复活 |
| 8 幂等 | ✅ | `replayed:true` 不重写、异 input `IDEMPOTENCY_KEY_REUSED` |
| 9 锁序 | ✅ | 同 key 并发 create 单 client；create‖rotate 双方完成 |
| 10 grants | ✅ | 4 个 `cmd_*` 对 auth 开放，helper 全 false |
| 11 版本原子性 | ✅ | 20 并发：20 unique、连续 2..21、final 21 |
| 12 receipt 不存 token | ✅ | 真实凭据 hash 零命中、全库 `mrw_v1.` 零命中 |
| 13 `cmd_pre_reject` 锁序前置 | ✅ | 0010 四处调用点全部先持 state 锁 |
| 14 0001-0007 未被修改 | ✅ | diff 仅新增 0008/0009/0010 |

## 1. 凭据纪律（红线）

### 反例 1 — 全 git 历史凭据扫描

```
$ git rev-list --all | while read c; do git grep -l -E "sbp_[a-z0-9]{20,}|sb_publishable_|mrw_v1\.[A-Za-z0-9_-]{20,}" "$c" -- 2>/dev/null; done | sort -u
0ca76646...:docs/planning/evidence/P0-001/result.md
0ca76646...:docs/planning/evidence/P0-002/home-machine-runner.md
0ca76646...:docs/planning/evidence/P0-002/result.md
（另 3372df6 / 9d1a854 等提交同构命中同三文件 + P0-004/result.md）
```

命中内容逐条核对（**全部为已声明样例**，非真实凭据）：

| 文件:行 | 命中值 | 判定 |
|---|---|---|
| P0-001/result.md:160 | `mrw_v1.abcdefghijklmnopqrstuvwxyz123` | fixture **扫描目标文件名**，无 UUID 段、非 token 格式 → 样例 |
| P0-002/home-machine-runner.md:39 | `sb_publishable_0000000000000000000000000000` | 全零串，已声明假测试串 → 样例 |
| P0-002/result.md:30,37 | 同上 + 前缀字面量 | 已声明 → 样例 |
| P0-004/result.md:106 | 扫描**元描述行自身** | 自指命中 → 样例 |

加做**严格格式**扫描（真实 token 必须含 UUID 段）：

```
$ git rev-list --all | while read c; do git grep -h -E "mrw_v1\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.[A-Za-z0-9_-]{20,}" "$c" -- 2>/dev/null; done | sort -u
（空）
$ git grep -n -E "\b[0-9a-f]{64}\b" -- .
（空）
```

**判定：无真实 token 值 → 未触发 BLOCKED。** `.gitignore:14` 已含 `mrw_v1.*`。

### 反例 2 — `scripts/health-client-token.mjs` 纪律复核（含实测语法）

```
$ node --check scripts/health-client-token.mjs
EXIT=0
```

四项纪律逐条读码核实（134 行）：

| 纪律 | 实现位置 | 判定 |
|---|---|---|
| token 本机生成（32B 高熵） | L28-33 `randomBytes(32)` + `randomUUID()` | ✅ |
| RPC 只传 sha256 hex | L32 `createHash('sha256')...digest('hex')`；L82/L105 body 仅含 `token_hash`，**原始 token 不在 RPC body** | ✅ |
| 原始 token 只打印一次 | L89 / L111，仅在成功分支 | ✅ |
| keychain 暂存失败即清 | L77/L101 先暂存 → L92-95/L113-116 `catch` 中 `keychainDelete` | ✅ |

**判定：4 项纪律全部成立**；但发现 argv 暴露问题 → 见 §5 `NEW-FINDING-2`。

## 2. 反例矩阵

### 反例 3 — 伪造身份反例

```
3a anon -> public.initialize_workspace_v1
   ERROR: 42501: permission denied for function initialize_workspace_v1            ✅
3b authenticated(NONOWNER) -> public.initialize_workspace_v1
   ok=False code=OWNER_DENIED                                                      ✅
3c authenticated(NONOWNER) -> public.manage_health_client_v1
   ok=False code=OWNER_DENIED                                                      ✅
3d authenticated(NONOWNER) -> public.get_workspace_revision_v1
   ok=False code=OWNER_DENIED                                                      ✅
3e authenticated(NONOWNER) -> public.get_command_result_v1
   ok=False code=OWNER_DENIED                                                      ✅
3f p_uid=OWNER 但 auth.uid()=NONOWNER -> private.cmd_initialize_workspace_v1
   ok=False code=OWNER_DENIED                                                      ✅
3g p_uid=NONOWNER 但 auth.uid()=OWNER -> private.cmd_manage_health_client_v1
   ok=False code=OWNER_DENIED                                                      ✅
```

**加强点（超出清单要求）**：3b 时工作区**已存在**（settings 行已被 Z1 复位但 workspace_state 在），若 owner 校验晚于存在性校验，返回必为 `ALREADY_EXISTS`；实测返回 `OWNER_DENIED`，**证明 owner 校验先于状态校验**。4 个 `cmd_*` 全部覆盖了 `p_uid ≠ auth.uid()` 变体（authenticated 对 `cmd_*` 有 EXECUTE，故该内部校验是唯一防线，已逐一实测）。

### 反例 4 — 直 DML / 私有表读取（S03/S04）

```
4a authenticated UPDATE public.life_data        -> ERROR: 42501 permission denied for table life_data      ✅
4b authenticated DELETE public.activity_log      -> ERROR: 42501 permission denied for table activity_log  ✅
4c authenticated SELECT private.agent_credentials-> ERROR: 42501 permission denied for table agent_credentials ✅
4d authenticated INSERT public.life_data         -> ERROR: 42501 permission denied for table life_data      ✅
4e authenticated SELECT private.request_receipts -> ERROR: 42501 permission denied for table request_receipts ✅
4f anon SELECT public.life_data                  -> ERROR: 42501 permission denied for table life_data      ✅
4g authenticated INSERT public.activity_log      -> ERROR: 42501 permission denied for table activity_log  ✅
```

**加强点**：4e（收据表不可读，防旧结果泄露）、4g（审计伪造直插被拒）为清单外补充，均 42501。

### 反例 5 — actor 上下文（S04）

```
5a postgres INSERT life_data 不带 morrow.actor GUC
   ERROR: P0001: actor_context_missing
   CONTEXT: PL/pgSQL function private.current_actor() line 6 at RAISE                  ✅
5b GUC actor=human:OWNER，自报 source_type='agent', source_id=NONOWNER
   -> [{"source_type":"human","source_id":"0c645909-...","version":"1"}]               ✅ 自报值被强制覆盖
5c GUC actor=system:NIL，自报 human/OWNER
   -> [{"source_type":"system","source_id":"00000000-...0000"}]                        ✅ 覆盖为 actor 值
5e 畸形 actor GUC 'garbage'      -> ERROR: P0001: actor_context_invalid (line 14)      ✅
5f 未知 actor_type 'wizard:<uuid>'-> ERROR: P0001: actor_context_invalid (line 11)     ✅
```

**加强点**：5e/5f 畸形与未知 actor_type 均被 `current_actor()` 拒绝（清单外）。**5d**（`human:NONOWNER` 而 `user_id=OWNER`）被接受，属纵深防御观察项，见 §6 观察项 2。

### 反例 6 — Human LWW / Agent OCC

```
6a agent create exp="0"                -> ok=True  result=created version=1            ✅
6b agent create exp="0"（行已存在）     -> ALREADY_EXISTS details.current_version=1     ✅
6c HUMAN 带 expected_version           -> VALIDATION_FAILED                            ✅（422）
6d HUMAN 不带（LWW）                   -> ok=True  result=changed version=2            ✅
6e AGENT 缺 expected_version           -> VALIDATION_FAILED                            ✅（422）
6f AGENT expected_version=1（过期）     -> VERSION_CONFLICT details.current_version=2    ✅
6g AGENT expected_version=2（新鲜）     -> ok=True  version=3                            ✅
6h HUMAN 同 payload 重发               -> ok=True  result=no_change version=3（不增版） ✅
   final: version=3；audit(insert+update)=3 条 —— 单一审计来源成立                  ✅
```

### 反例 7 — create0 语义（T08 变体）

```
7a agent create exp="0"                      -> ok=True created version=1              ✅
7b create0 对已存在行                        -> ALREADY_EXISTS                         ✅
   （soft delete: update deleted_at）
7c create0 对 tombstone                      -> RESOURCE_DELETED                       ✅
   事后该行：version=2, tomb=True, payload.note="seed"（**原 payload 未被复活**）        ✅
7d EXTENSION agent UPDATE(exp=current) 对 tombstone -> RESOURCE_DELETED                ✅
7e EXTENSION human LWW 对 tombstone                 -> RESOURCE_DELETED                ✅
   7d/7e 后仍为 version=2 tomb=True note="seed" —— 无「幽灵编辑」                      ✅
```

**加强点**：7d/7e 为清单外——即使带**正确**的 `expected_version`，Agent/Human 对 tombstone 的 update 仍被 `RESOURCE_DELETED` 拒绝，未出现复活路径。

### 反例 8 — 幂等（T06/F 系）

```
8a agent create(key=K1)                -> ok=True  replayed=False                     ✅
8b 同 key 同 input 重放                -> ok=True  replayed=True                      ✅ 且 life rows 1→1（不重写）
8c 同 key 异 input                     -> IDEMPOTENCY_KEY_REUSED                      ✅ 且 receipts(K1)=1
8d manage revoke 未知 client           -> RESOURCE_NOT_FOUND                           ✅
8e 同 key 同 input 重放（拒收据）      -> RESOURCE_NOT_FOUND  replayed=True            ✅ 持久化 receipt state='rejected'
8f 同 key 异 input                     -> IDEMPOTENCY_KEY_REUSED                      ✅
8g 重放不重跑业务：command.rejected 审计行 30 -> 30（**相等**）                          ✅
```

### 反例 9 — 锁序（K7/K8）

```
9a 同 key 并发 create（两个独立请求）
   a: ok=True replayed=True  client=aecaf8aa-98a5-43aa-a392-11af322faaa1
   b: ok=True replayed=False client=aecaf8aa-98a5-43aa-a392-11af322faaa1
   clients 3 -> 4（恰好 +1）
   VERDICT: single client=True, both ok=True                                          ✅
9b create ‖ rotate 并发
   create: ok=True code=None
   rotate: ok=True code=None
   VERDICT both_completed=True（无反向锁等待 / 无死锁）                                ✅
```

### 反例 10 — grants（S06）

`has_function_privilege` 全扫 private schema 23 个函数（anon / authenticated / service_role / public 四角色）：

```
cmd_get_command_result_v1        anon=F auth=T svc=F pub=F     ← 4 个 public invoker 对应的 cmd_*
cmd_get_workspace_revision_v1    anon=F auth=T svc=F pub=F
cmd_initialize_workspace_v1      anon=F auth=T svc=F pub=F
cmd_manage_health_client_v1      anon=F auth=T svc=F pub=F
is_workspace_owner               anon=F auth=T svc=F pub=F     ← RLS helper（见观察项 1）
cmd_pre_reject                   anon=F auth=F svc=F pub=F     ✅ helper 全 false
cmd_finish_err                   anon=F auth=F svc=F pub=F     ✅
receipt_begin / receipt_complete / receipt_reject  anon=F auth=F svc=F pub=F  ✅
core_test_write_v1               anon=F auth=F svc=F pub=F     ✅
lock_workspace_state / write_event / err_envelope / cmd_set_actor / current_actor 全 F ✅
trg_* 6 个                       anon=F auth=F svc=F pub=F     ✅
NON-COMPLIANT (expected only cmd_* with auth-only): NONE 除外 is_workspace_owner
```

public schema：`initialize_workspace_v1 / manage_health_client_v1 / get_command_result_v1 / get_workspace_revision_v1` 对 authenticated=T、anon/svc=F ✅；`_scopes_no_dup` 全 F。

**判定：除 4 个 `cmd_*` + `is_workspace_owner` 外，helper 与测试入口对全部客户端角色 false** —— 实现与「不把私有 helper 直接暴露给浏览器」一致。`is_workspace_owner()` 为 `private` 内 `SECURITY DEFINER` + `search_path=''` 的 `auth.uid()` 判定函数、无参数、仅返回自身是否 owner，不构成越权面（观察项 1）。

### 反例 11 — 版本原子性（深审条件）

```
seed 后 base version = 1
ITEM 11: 20 个并发 human LWW 更新同一 life_data 行
  ok_count      = 20 / 20
  returned      = 20 versions
  unique        = 20
  duplicates    = NONE
  range         = 2..21
  expected range= 2..21
  contiguous    = True
  final version = 21 (must be 21)
  audit update rows = 20 (must be 20 = one per effective update)
```

**判定：无重号、连续、final 与有效更新数一致** → version trigger 的原子递增在并发下成立（初审方独立复现，非采信深审）。

### 反例 12 — receipt 不存 token（S05 扩展）

清单要求扫 `response::text` 与 `metadata::text` 的 64-hex / `mrw_v1.`。初审方用**数据库内真实凭据 hash** 做精确比对（而非固定字面量）：

```
  n_creds                5        ← 凭据表非空，扫描非平凡
  leak_rcpt_response     0        ← receipts.response 不含任何真实 token_hash
  leak_act_metadata      0        ← activity_log.metadata 不含任何真实 token_hash
  raw_mrw_rcpt           0        ← receipts.response 无 mrw_v1. 原文
  raw_mrw_act            0        ← activity_log.metadata 无 mrw_v1. 原文
  strict_64hex_rows      0        ← receipts.response 中无任何 64-hex 形状串
  equals_request_hash    0 / unknown_hex_rows 0
```

**全库列级扫描**（`to_jsonb(row)::text` 覆盖 public/private 七张表的**所有** text/varchar/jsonb 列）：

```
  public.life_data           mrw_v1=0    sbp_=0
  public.agent_clients       mrw_v1=0    sbp_=0
  public.workspace_settings  mrw_v1=0    sbp_=0
  public.activity_log        mrw_v1=0    sbp_=0
  public.workspace_state     mrw_v1=0    sbp_=0
  private.request_receipts   mrw_v1=0    sbp_=0
  private.agent_credentials  mrw_v1=0    sbp_=0
  TOTAL suspicious hits = 0
```

响应键结构核对（`manage_*` 完成响应 keys）：`client_id, credential_id|revoked_at, enabled|no_change, expires_at, scopes, version` —— **无 `token_hash`**。

## 3. 静态复核

### 反例 13 — `cmd_pre_reject` 锁序前置

0010 中 `cmd_pre_reject` 共 **4 处调用**，逐处核对「调用前是否已持 workspace_state 锁」：

| 调用点 | 分支 | 前置 state 锁 | 判定 |
|---|---|---|---|
| 0010:89 | `action/target` 非法 | 0010:88 `perform private.lock_workspace_state(p_uid);` | ✅ |
| 0010:94 | `input` 含未声明字段 | 0010:93 同 | ✅ |
| 0010:107 | `client_id` 非法 | 0010:106 同 | ✅ |
| 0010:116 | client 不存在 | 0010:115 同 | ✅ |

全仓 grep 确认无其它文件调用 `cmd_pre_reject`（仅 0010 定义 + 上述 4 处 + grants revoke）。源码注释与实现一致：**state 锁仍在 receipt 之前**，锁序未因该修复而改变。✅

### 反例 14 — 0001-0007 未被修改

```
$ git diff 8f6be16 3372df6 --stat -- supabase/migrations/
 .../20260917110000_0008_core_framework.sql         | 1069 ++++++++++++++++++++
 .../20260917120000_0009_core_framework_fix.sql     |  201 ++++
 .../20260917130000_0010_manage_prereject_fix.sql   |  288 ++++++
 3 files changed, 1558 insertions(+)
```

**仅 3 个新增文件、零删除零修改**，0001-0007 未被动过。✅

### 补充静态/运行核对（清单外）

```
cmd_pre_reject 在 DB 中存在（0010 已应用）                        rows = 1     ✅
expired 分支存在性：cmd_manage_health_client_v1 = HAS
                    cmd_initialize_workspace_v1  = HAS
                    core_test_write_v1           = NO          ← 深审 P1，见 §6
应用版 jsonb_matches_schema 调用点（0009 修复已生效）：
  extensions.jsonb_matches_schema(v_schema::json, p_input -> 'payload')            ✅
触发器 8 个全部 tgenabled='O'（life_data×3 / settings×2 / clients×2 / activity×1） ✅
```

## 4. NEW-FINDING

### NEW-FINDING-1（P2 / 非阻断 / 潜伏）— `response_expires_at` 被写入但**全代码库从不读取**，超期收据会重放旧响应体

**实测**：构造一条 `state='completed'`、`response_expires_at` 已过去 1 小时（completed_at 2 天前）的收据，以**相同 key + 相同 input** 重发：

```
  ok=True code=None replayed=True
  returned result = {"note": "EXPIRED_STALE_BODY", "stale": true}
  >>> VERDICT: over-expired receipt REPLAYED the stale body instead of 409 IDEMPOTENCY_RESULT_EXPIRED
```

**静态佐证**：

```
$ grep -rn "response_expires_at" supabase/migrations/
  0003_private_audit.sql:35:  response_expires_at timestamptz,          ← 仅列定义
  0003_private_audit.sql:38:  ... index request_receipts_exp_idx ...    ← 仅索引
（无任何读取方：无 WHERE / 无比较）

$ grep -rn "'expired'" supabase/migrations/   ← 全部为「读 state='expired'」，无一处写入
  0008:280-281  receipt_begin 读 r.state='expired' → status='expired'
  0008:450 / 0008:599 / 0010:24 / 0010:133  各 cmd_* 的 expired 分发
```

**性质界定**：C-04 明确「M1 不安排收据清理任务」「未来清理只去响应体、保留 key 墓碑」，即 `completed→expired` 的**状态迁移属未来清理任务的职责**。因此本项是**契约已声明（列 + 索引 + 三分发）但链路未接线**的潜伏缺口：M1 无清理任务 → `state='expired'` 生产不可达 → 不构成 P0-004 DoD 违背。

**同时须注意**：C-04 的真正危险项「绝不能重跑」**未被破坏**——实测为重放（`replayed=True`），并未重新执行业务逻辑，因此不产生双写。缺口仅在「超期后仍返回旧响应体、而非 409 并要求重读」这一协议语义。

**判 P2 非阻断的理由**：① P0-004 任务卡验收条件未含超期语义；② C-04 显式把清理推迟到未来；③ 危险路径（重跑）已被幂等阻断。

**建议（并入未来清理任务，非 P0-004 返工）**：清理任务落地时须同时接线「读取侧 `response_expires_at < now()` 判定 → 视为 expired」，否则索引 `request_receipts_exp_idx` 永不被使用、超期语义永远不生效。

### NEW-FINDING-2（P2 / 非阻断）— token 脚本把**原始 token 作为命令行参数**传给 `security(1)`，与 01-architecture.md §"禁止命令行参数" 相抵触

**实测**（用 PATH shim 精确记录 `keychainSave()` 的实参，`scripts/health-client-token.mjs:37` 原样调用形状）：

```
$ cat /tmp/mrwrev/argv_proof.log
ARGV_SEEN: add-generic-password -U -s MORROW_REV_DEMO -a demo -w mrw_v1.<UUID>.DUMMY_SECRET_VALUE_FOR_PROOF
$ grep -q "DUMMY_SECRET_VALUE_FOR_PROOF" argv_proof.log && echo YES
YES — raw token value present in argv
```

进程表可读性验证（同用户任意本地进程）：

```
41165 python3 -c import time; time.sleep(4) mrw_v1.<UUID>.DUMMY_IN_ARGV
--- marker present in its argv? ---
YES: raw token pattern visible in process table
```

**对照约束**：`docs/planning/01-architecture.md:284` —— 「客户端 token 放运行宿主的 secret store / 环境注入，**禁止命令行参数**、git、截图和普通日志」。

**性质界定**：窗口极短（`security` 子进程存活期）、发生在操作者本机、M1 单用户；危险面是本地同用户进程可经进程表读取明文 token。注意 `scripts/health-client-token.mjs` 文件头自身声明的是「不落盘、不进日志/git/receipt」，**并未**声明「不进命令行参数」，因此这是脚本与架构文档之间的一处**未对齐**，而非明确的自我矛盾。

**建议**：改用以 stdin 传入（如 `security add-generic-password ... -w` 交互式/stdin 形式）或 `--stdin` 等价路径，避免明文进 argv。

## 5. 对深审结论的独立复核（含限定）

| 深审结论 | 初审方独立复核 | 判定 |
|---|---|---|
| T03 并发无重号 | 自跑 20 并发 → 20 unique、连续 2..21、final 21 | **成立** |
| T04 OCC 单赢家 | 自跑 → 一 `ok` 一 `VERSION_CONFLICT`（§反例 6 同构） | **成立** |
| 生产 cmd 的 expired 分发正确（R1/R4） | 自造 expired 收据 → `IDEMPOTENCY_RESULT_EXPIRED` | **成立** |
| `core_test_write_v1` 缺 expired 分支（P1） | 自造 expired 收据 → `P0001 receipt_state_invalid`（`receipt_reject` line 8）共栈；rollback 后零残留 | **成立（P1 已移交 P0-005，非新增）** |
| grants 仅 4 `cmd_*` + `is_workspace_owner` 对 auth 开放 | 23 函数四角色全扫，结论一致 | **成立** |
| 凭据红线 CLEAN | 全历史 4 处命中全为已声明样例 + 严格格式扫描为空 | **成立** |

> **限定说明（不影响 PASS）**：深审 R1/R4「expired 分支实测通过」的构造方式是**手工插入 `state='expired'` 行**，因此验证的是**分发逻辑**正确性，**并未**验证「超期如何进入 expired 状态」。初审方 NEW-FINDING-1 补充了缺失的一环：无任何代码写入 `state='expired'`、无任何代码读取 `response_expires_at`。深审「expired 生产不可达」的判断结果正确，但成因是**链路未接线**，而非仅「M1 无清理任务」——建议该点随清理任务一并跟踪。

## 6. 初审方自身探针纠错（诚实记录）

初审过程中有 3 处**自身探针缺陷**，已定位并更正，**不作为缺陷申报**：

1. **rollback 导致假缺陷**：初审初期用 `begin; ... rollback;` 包裹 RPC 调用来测幂等重放，因收据随回滚消失，观察到「同 key 同 input 未返回 `replayed:true`」。改用 `commit` 后 `replayed=true` 正确复现（§反例 8）——原现象为**探针伪影**，非缺陷。
2. **宽松正则假阳性**：`regexp_replace(response::text,'[^0-9a-f]','','g') ~ '[0-9a-f]{64}'` 因跨 JSON 片段拼接出 16 行「疑似 64-hex」。改用严格 `response::text ~ '[0-9a-f]{64}'` + 与真实凭据 hash 精确比对后，确认 **0 行**（§反例 12）。
3. **`ps` 演示假阳性**：首版用 `/bin/sh -c 'sleep N' sh <marker>`，`sh` 直接 exec 掉自身导致标记消失，而 `grep -q` 又匹配到管道自身命令行造成「可读」误判。改用 `python3 -c ... <marker>` 保持进程存活后，如实复现 argv 可见（§NEW-FINDING-2）。

## 7. 残留回收与副作用声明

幂等/并发类反例（6/7/8/9/11）必须提交事务才能观测重放与竞态，故产生测试写入。初审方按时间边界（最后一次既有写入 `2026-09-18 01:21:09+00`，初审方全部写入均在 `02:07:00+00` 之后）**精确回收自有产物**：

```
$ （清理 SQL：activity_log -> request_receipts -> life_data -> agent_credentials -> agent_clients）
  === post-cleanup state ===
  life             4          ← 会话开始时 life=4   ✅ 一致
  act              57         ← 会话开始时 act=57   ✅ 一致
  rcpt             50         ← 会话开始时 rcpt=50  ✅ 一致
  clients          3          ← 会话开始时 clients=3 ✅ 一致
  creds            5
  rev              169        ← 会话开始时 rev=91
  my_life_left     0
  my_clients_left  0
  RESIDUE RESTORED = True
```

- 施工方/深审方的既有残留（`p0test:*` 4 行进 life_data、`p0test-*` 3 个 client）**完整保留**，未被波及。
- `data_revision` 为单调计数器，**未回改**为 91（不做伪证）；其增长来自本次实测的有效写入。
- 未修改任何 migration、未改 task-index、未动源文件。
- 本记录不含任何 token / key / PAT / hash 值。

## 8. 初审结论

**P0-004：PASS**

- 清单 14 项反例**全部由初审方自构实测成立**，未发现新增 P0/P1 缺陷。
- 反例 3b / 7d / 7e / 4e / 4g / 5e / 5f 为清单外加强点，同样成立（owner 校验先于状态校验、tombstone 无幽灵编辑、收据表与审计表均不可直写、畸形 actor 被拒）。
- 深审的两大深审条件（version trigger + 并发无重号）与 P1 移交项（`core_test_write_v1` expired 缺口）经独立复现**均成立**；另附对「expired 实测通过」的限定说明（§5）。
- 2 条 `NEW-FINDING` 均判 **P2 / 非阻断**，建议随「收据清理任务」与「health 脚本硬化」一并跟踪，**不构成本卡返工项**。

**初审方提交物**：本文件区块（仅追加，未改动既有内容）+ `git commit`。

