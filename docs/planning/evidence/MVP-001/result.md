# MVP-001 result.md

# 执行方填写区（Trae + Kimi K3，2026-09-23）

## 任务 / commit / 环境 / 模型

- 任务：MVP-001 DB 侧业务 Core——锚点打卡 / 日型计划 / 分母锁 / record_open 去重 / 今日上下文。**不含任何前端**（前端归 MVP-002）。
- commit：`4d2793a`（migration 0013 + tests + api-mapping + task-index IN_PROGRESS）；本文件随下一 commit `MVP-001:` 前缀提交。
- 执行环境：公司机 macOS，Node v22，Supabase Management API（应用 migration / 跑测试）+ PostgREST RPC（烟测）。
- 模型：Trae + Kimi K3（执行）；UTC 2026-09-23 08:30–10:00。
- 真实初始化事实（本卡前置动作）：`initialize_workspace_v1` HTTP 200，tracking_started_on=2026-09-21、周一/三/五训练日，request_id `4afe6335-9d49-49ad-a7d3-2eba1b1750a8`（初始化动作本身在写入 result 前完成，属工作区一次性事实）。

## 施工范围对照（卡条款 → 落实）

| 卡条款 | 落实 | 证据 |
|---|---|---|
| task-index PLANNED→IN_PROGRESS | task-index.json 单行变更 | commit 4d2793a diff |
| migration 0013 起新增，不改历史 | 仅新增 `20260923150000_0013_mvp_business_core.sql`；0001–0012 零改动 | git status + `supabase migration list` 等效 Management API 校验 |
| set_day_type_v1 仅今日、无访问日期也有计划分母 | `cmd_set_day_type_v1`：`v_biz <> v_today` 拒；`resolve_day_plan` 纯函数解析任意日期默认计划 | T01/T10 实测 |
| check_anchor_v1 三锚点打卡 | 固定 wake/workout_end/lights_off；actual>now()+60s 拒；wake/workout_end 本地日归属；lights_off 窗口 [当日12:00,次日12:00) | T03–T08 |
| clear_anchor_v1 只清实际值不删计划 | 软清 actual/status→pending，plan_locked 与分母不变 | T10 断言 clear_keeps_denominator |
| update_anchor_note_v1 LWW | 同记录仅改 note，其余字段 Core 保留重建 | T12 note_lww/no_change |
| get_today_context_v1 Context 投影 | FOR SHARE + 占位 version='0'/materialized:false + stats + next_action + data_revision 字符串 | T01/T02/T13/T14 + HTTP 烟测 |
| record_open_v1 去重 | 部分唯一索引 `(user_id, metadata->>'device_id', metadata->>'biz_date') where action='human.opened'` + unique_violation 捕获；不同日/不同 device 新建；OWNER_DENIED；device_id 仅去重标识 | T11 + HTTP 烟测 2a/2b/2c |
| 首记物化快照 / 单向加训练（分母+1）/ 不能减分母改历史 | `materialize_day` ON CONFLICT 自愈；首 actual 翻 plan_locked；已锁仅 workout_expected false→true；追加保留原 plan_version provenance | T03/T10 |
| 训练结束目标 19:15 / 实际睡眠间隔独立评估 | payload 冻结 19:15；interval_to_lights_off_minutes 与 met 分离，≥180min 达标 | T04–T07 |
| 次日关灯归属前日（12:00 边界） | lights_off ∈ [当日12:00, 次日12:00)；00:30 归前日 dev+135 | T08 |
| 旧客户端未知 payload 安全拒写 | input 白名单（jsonb_object_keys 计数）；伪造 status/version → VALIDATION_FAILED | T12b |
| Context FOR SHARE 一致锁 | `lock … FOR SHARE`；pg_locks 实测 RowShareLock；tuple 级与写方互斥 | T02 |
| HTTP 走 POST RPC（非 get:true） | 全部 7 个 RPC 仅 POST /rest/v1/rpc | api-mapping.md |
| 固定三锚点 / 健身是结束时间 / 22:15 关灯 | `mvp_day_payload` 冻结常量与中文名；anchors 固定 3 元素顺序 | migration §2 |
| contracts 零新增 | 6 command schema + 2 payload + envelope 均已在 manifest 登记（P0 链预置）；本卡未新建 contract 文件 | manifest.json grep 26 行命中 |
| 凭据纪律 | 三条 keychain 透传 + MORROW_OWNER_EMAIL；仅 env 注入；无明文落盘 | 本文件与 api-mapping 均无凭据 |
| 真实数据不落 git | 测试单事务零残留；烟测仅 1 条 device_id=`mvp001-smoke-test` 标记行 | 见下「烟测残留」 |

## 变更文件

| 文件 | 说明 |
|---|---|
| `supabase/migrations/20260923150000_0013_mvp_business_core.sql` | 新增（未改历史）：索引 + 4 private helper + 5 写 cmd + 1 读 cmd + 6 public invoker + grants |
| `tests/mvp001-business-core.sql` | 新增：单 DO 块 T00–T14，末尾 RAISE 携带 proof 全回滚 |
| `docs/planning/evidence/MVP-001/api-mapping.md` | 新增：7 RPC → schema → curl + 实测错误码表 |
| `docs/planning/task-index.json` | MVP-001 PLANNED→IN_PROGRESS（状态翻 PASS 归 Review 方） |

未动：`assets/**`、`dist/**`、`agent_clients`、01-architecture.md、02-contracts.md、全部已应用 migration。

## migration 应用验证（Management API 实测）

应用返回 HTTP 201。对象落库核验（pg_proc/pg_index/has_function_privilege）：
- 16 函数全部存在：`mvp_day_payload` / `resolve_day_plan` / `materialize_day` / `mvp_stats` / `cmd_set_day_type_v1` / `cmd_check_anchor_v1` / `cmd_clear_anchor_v1` / `cmd_update_anchor_note_v1` / `cmd_record_open_v1` / `cmd_get_today_context_v1` + 6 public invoker。
- 部分唯一索引 `activity_log_human_opened_uq` 存在且 indisvalid。
- grants：6 public invoker 仅 authenticated 可执行；4 helper（mvp_day_payload/resolve_day_plan/materialize_day/mvp_stats）对 authenticated 全撤；cmd_* 授 authenticated（供 RPC 层 DEFINER 链），public/anon 全撤。

## 测试命令与原始输出（不摘要）

### SQL 验收套件（第 4 次运行，前 3 次失败修复记录见末节）

命令（PAT 走 keychain，全文 POST Management API）：

```bash
node --input-type=module -e '
import { readFileSync } from "node:fs";
import { execSync } from "node:child_process";
const sql = readFileSync("tests/mvp001-business-core.sql", "utf8");
const pat = execSync("security find-generic-password -a morrow -s MORROW_SUPABASE_ACCESS_TOKEN -w", { encoding: "utf8" }).trim();
const res = await fetch("https://api.supabase.com/v1/projects/umutubzcwwmmbxfjkyvj/database/query", {
  method: "POST",
  headers: { Authorization: `Bearer ${pat}`, "Content-Type": "application/json" },
  body: JSON.stringify({ query: sql }),
});
console.log("HTTP", res.status);
console.log(await res.text());
'
```

原始输出（HTTP 400 为预期模式：末尾 RAISE EXCEPTION 携带 proof → 单事务全回滚零残留）：

```
HTTP 400
{"message":"Failed to run sql query: ERROR:  P0001: MVP001_PROOF [{\"owner\": \"0c645909-ebb5-4910-ab99-4f7b238c9529\", \"T00_setup\": \"pass\"}, {\"materialized\": false, \"planned_count\": 5, \"life_data_rows\": 0, \"T01_F10_unopened_day_in_denominator\": \"pass\"}, {\"mode\": \"RowShareLock\", \"meaning\": \"FOR SHARE 表级锁持有证据；与写方 FOR UPDATE 的互斥发生在同一行的 tuple 级锁（ShareLock vs ExclusiveLock），读写由此串行\", \"T02_context_for_share_lock\": \"pass\"}, {\"target_met\": true, \"plan_locked\": true, \"T03_F01_wake_0647\": \"pass\", \"deviation_minutes\": -3, \"audit_rows_same_request\": 6}, {\"interval_met\": null, \"T04_F06_interval_unknown\": \"pass\"}, {\"interval_met\": true, \"T05_F03_interval_180_met\": \"pass\", \"interval_to_lights_off_minutes\": 180}, {\"interval_met\": false, \"deviation_minutes\": 15, \"T06_F04_late15_interval165\": \"pass\", \"interval_to_lights_off_minutes\": 165}, {\"interval_met\": true, \"lights_target_met\": false, \"workout_deviation\": 15, \"interval_to_lights_off_minutes\": 210, \"T07_F05_interval210_met_lights_unmet\": \"pass\"}, {\"window_reject\": true, \"deviation_minutes\": 135, \"wake_attribution_reject\": true, \"T08_F08_next_day_0030_prev_day\": \"pass\"}, {\"met_count\": 2, \"streak_days\": 2, \"recording_rate\": 1, \"wake_deviation\": 20, \"workout_status\": \"not_applicable\", \"T09_F02_F07_F14\": \"pass\"}, {\"planned_count\": 8, \"locked_reject_codes\": \"DAY_PLAN_LOCKED×3\", \"clear_keeps_denominator\": true, \"append_denominator_plus1\": true, \"T10_F11_append_lock_clear\": \"pass\", \"workout_plan_version_provenance\": \"2\"}, {\"wrong_owner\": \"OWNER_DENIED\", \"T11_record_open\": \"pass\", \"other_day_recorded\": true, \"other_device_recorded\": true, \"same_device_same_day_rows\": 1}, {\"replay\": true, \"conflict\": \"IDEMPOTENCY_KEY_REUSED\", \"note_lww\": true, \"na_reject\": \"ANCHOR_NOT_APPLICABLE\", \"note_no_change\": true, \"note_length_reject\": true, \"forged_status_reject\": true, \"future_actual_reject\": true, \"expected_version_reject\": true, \"T12_reject_and_idempotency\": \"pass\"}, {\"rule\": \"now() at time zone Asia/Shanghai（UTC 16:10→上海次日 00:10 同公式）\", \"today\": \"2026-09-23\", \"T13_F13_workspace_timezone\": \"pass\"}, {\"next_action\": {\"kind\": \"record_anchor\", \"overdue\": false, \"target_at\": \"2026-09-23T19:15:00+08:00\", \"anchor_type\": \"workout_end\", \"biz_date_relation\": \"today\"}, \"data_revision_type\": \"string\", \"T14_today_context_projection\": \"pass\"}]\nCONTEXT:  PL/pgSQL function inline_code_block line 551 at RAISE\n"}
```

14/14 组全绿：T00 setup；T01/F10 未打开日计入分母且占位不物化；T02 FOR SHARE 锁证据；T03/F01 起床 06:47 dev=-3 + 请求-审计原子（同 request_id 6 行）；T04/F06 间隔 unknown；T05/F03 180min 达标；T06/F04 迟到 15min + 165min 不达标；T07/F05 210min 达标 + 关灯 dev+45 不达标；T08/F08 窗口拒 + 跨日 wake 拒 + 00:30 归前日 dev+135；T09/F02/F07/F14 dev+20 + n/a + day_complete + rate=1/met=2/streak=2（记录率与达标率分离）；T10/F11 no_change + 非今日拒 + 锁后追加（plan_version='2' provenance、分母 8）+ DAY_PLAN_LOCKED×3 + clear 分母不变不解锁；T11 record_open 去重/不同日/不同 device/OWNER_DENIED；T12 拒写矩阵（expected_version/伪造 status/未来时间/n-a/超长 note）+ replay + conflict + note LWW；T13/F13 时区今日；T14 next_action 投影 + overdue 自洽 + data_revision 字符串。

### HTTP 烟测（owner JWT 真调，非回滚）

1) `get_today_context_v1`（缺省 biz_date）→ HTTP 200：`today=2026-09-23`，day_type=workout_workday（周三命中一三五），三锚点占位 `version:"0"`、`materialized:false`，next_action=record_anchor/wake/overdue=true（调用时上海 17:52 已过 06:50），stats scope 2026-09-21..23 planned_count=8（3+2+3），data_revision `"407"`（字符串），request_id `66adc941-2f0e-46c6-88d0-e12143caa751`。

2) `record_open_v1` device_id=`mvp001-smoke-test` biz_date=2026-09-23：
- 首次（key A）→ HTTP 200 `{"recorded":true,"deduped":false,"open_id":"79d9ee66-7cfb-4c27-b906-cddce4d20436"}`，request_id `fa788b1e-2b88-471f-8a7b-8d95337047b5`
- 同 device 同日换 key B → `{"recorded":false,"deduped":true,"open_id":null}`，request_id `4982bb48-9682-4667-b224-972a2cf45005`
- 同 key A 原样重放 → `{"replayed":true,"result":{"recorded":true,...,"open_id":"79d9ee66-7cfb-4c27-b906-cddce4d20436"}}`（stored response 原样返回）

烟测残留（如实）：activity_log 1 行 `human.opened`（device_id=mvp001-smoke-test / 2026-09-23）+ request_receipts 2 行（key A/B）。均为合成标记数据，非真实生活记录。

## 验收条件逐条核对

- [x] F01–F08 / F10 / F11 / F13 / F14 通过（真实 SQL，见 T01–T14 映射；F09/F12 为前端/导出向，本卡范围外）
- [x] 起床后临时训练可追加当日计划（分母+1，T10 planned_count 8）；已有训练不能改型抹分母（DAY_PLAN_LOCKED×3）
- [x] clear 只清实际值不删计划（T10）；更改未来默认不重写历史（resolve_day_plan 按 effective_from 段解析，历史段不可变——T01/T09 历史日期统计不受新设置影响）；未打开日期可算分母（T01/T09）
- [x] Human 只提交允许业务字段（白名单 T12b）；actor/version/target Core 掌管；请求与审计原子（T03 同 request_id 6 行 audit）
- [x] record_open：同 device 同日换 key 至多 1 条（T11 + 烟测 2b）；不同日可新建（T11）；错误 owner 拒绝（T11 OWNER_DENIED）
- [x] Context 一致锁（T02 FOR SHARE）；旧客户端未知 payload 拒写（T12b）
- [x] 固定三锚点 / 健身是结束时间（19:15）/ 22:15 关灯（payload 冻结 + T05–T07）

## NOT_RUN / 未验证项（诚实声明）

1. **WORKSPACE_NOT_INITIALIZED 分支 NOT_RUN**——真实库已初始化；构造第二 owner 需写 auth.users/workspace_state，超出本卡范围。测试文件头部已注记，留 Review 裁决是否接受（0013 该分支与 0008 既有 cmd_initialize 同款前置 exists 判断，风险低）。
2. **并发混合快照的并发端 NOT_RUN**——T02 证明了读侧 FOR SHARE 锁持有与锁模式；真实并发写互斥（tuple 级）未起双会话压测，依赖 PG 锁语义保证。
3. **继承 P0-009 三条 NOT_VERIFIED**：① keepalive 7 天滚动率（Gate-M1，USAGE_PENDING）；② 隔离空库重建未验；③ Edge health verify_jwt=false 冗余风险（P0-007 留档）。

## 决策留档（供 Review 裁决）

1. **stats 块进 context**：C-03 指标唯一出口挂在 `get_today_context_v1.result.stats`（scope=tracking_started_on..biz_date）。理由：MVP-002 展示与 F10/F14 同源，避免前端二次聚合。若 Review 认为应拆独立 RPC，改动面=context 函数+本测试，无 schema 变更。
2. **PAYLOAD_SCHEMA_MISMATCH 差异**：卡 2.3 字面为该 code；实现统一 `VALIDATION_FAILED`（与 0008 框架一致），contract 层由 `additionalProperties:false` 承担 schema 拒绝。已在 api-mapping.md 注记。
3. **业务拒绝 HTTP 恒 200**：沿用 0008 cmd_finish_err 模式（拒绝需入库成 rejected 收据，事务正常提交），不走 HTTP 4xx。
4. **失败运行记录**：attempt 1 SETUP_FAIL（P0 链 p0test fixture 行属既有证据不可删，断言改 not like 'p0test:%'）；attempt 2 T02 锁模式名误写 ShareLock（表级恒 RowShareLock，已改并注释准确语义）；attempt 3 T14 `jsonb_typeof(->> )` 类型错误（->> 返回 text，改 `-> 'data_revision'` 单断言）。均已在测试文件内闭环。

## 回滚影响

- migration 0013 为纯新增（新函数/新索引/grants），回滚=DROP 本卡新增 16 函数 + `activity_log_human_opened_uq` 索引；不触碰 0001–0012 对象与数据。
- 烟测残留的 1 行 activity_log（human.opened/mvp001-smoke-test）如需清理：DELETE 该行 + 2 行 receipts（admin 操作，本卡未执行，保留作 HTTP 证据）。
- 工作区初始化事实（settings/plans）为一次性真实配置，非本卡交付物，不在回滚范围。

## Review 区（留空，Review 方填写）

## Review 区（Review 方填写）

- Review 人 / 模型：Hermes GLM-5.3（2026-09-23）
- Review 方法：**不采信收据，独立复跑实测**——① Management API 直查 pg_proc/pg_index/has_function_privilege 核对 16 函数 + `activity_log_human_opened_uq` 索引 + grants 真实落库（anon 六 invoker EXECUTE=0）；② **原样重跑** `tests/mvp001-business-core.sql`（执行方文件零修改），取回 MVP001_PROOF 全 JSON，14/14 组 pass 与收据一致；③ 复跑后残留核验：life_data 仍恰 4 行（均 p0test:% P0 既有证据）、mvp001-smoke-test 恒 1 行（零增量）；④ 真实 initialize 事实核验：tracking_started_on=2026-09-21、schedule_history 单段 09-21；⑤ result.md/api-mapping.md 全文通读与合同 C01–C05/F01–F14 对照。
- 复跑 proof 与收据逐项一致：F01 dev=-3/T03 审计同事务 6 行；F06 unknown；F03 180 met；F04 165 不达标；F05 210 met+关灯 unmet；F08 00:30 归前日 dev+135 + 窗口拒 + 跨日 wake 拒；F02/F07/F14 rate=1 met=2 streak=2 分离成立；F11 追加分母 8、provenance version='2'、DAY_PLAN_LOCKED×3、clear 分母不变不解锁；record_open 去重/不同日/不同 device/OWNER_DENIED；拒写矩阵 + replay + IDEMPOTENCY_KEY_REUSED；F13 时区公式；T14 next_action/data_revision 字符串。
- 对 NOT_RUN 的裁决：三条均接受——①未初始化分支与 0008 框架前置判断同构（低风险，留 Gate-M1 前真实首次使用即天然覆盖）；②并发双会话压测依赖 PG 锁语义（tuple 级 ShareLock vs ExclusiveLock 互斥已由 T02 锁持有证明支撑）；③三条继承项留档正确，随 MVP 系列继续盯。
- 对 2 条决策留档的裁决：**stats 进 context 批准**（C-03 指标唯一出口，MVP-002 依赖，schema 无变更）；**VALIDATION_FAILED 统一实现批准**（0008 框架一致性高于单卡字面，api-mapping 已注记）。
- 烟测残留（1 open 行 + 2 receipts）：批准保留为 HTTP 证据，device_id 标记可识别可排除。
- 结论：**PASS**——验收条件六条全实锤，task-index MVP-001 → PASS，next_task → MVP-002。质量记录：一次过审，无返工项；执行方自报与实测完全吻合（含三次失败运行的诚实留档，属合格工程行为非缺陷）。
