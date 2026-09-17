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
