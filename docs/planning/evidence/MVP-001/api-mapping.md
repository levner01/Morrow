# MVP-001 API 映射（DB 业务 Core → contract schema → curl 复现）

- 生成：2026-09-23，执行方 Trae + Kimi K3
- Base：`https://umutubzcwwmmbxfjkyvj.supabase.co`（project ref 见 supabase/.temp/linked-project.json）
- 统一形态：**全部走 `POST /rest/v1/rpc/<fn>`**（含只读 context，不用 GET）
- 统一信封：`{"p_envelope": {"api_version":"1","idempotency_key":"<uuid>","input":{...}}}`
  - Human 命令**禁止** `expected_version` 字段（出现即 `VALIDATION_FAILED`）
  - 信封 schema：`contracts/v1/commands/command-envelope-v1.schema.json`
- 统一响应：`contracts/v1/results/success-envelope-v1.schema.json` / `contracts/v1/results/error-envelope-v1.schema.json`
- 凭据：`$ANON`=keychain `MORROW_PUBLISHABLE_KEY`；`$JWT`=owner 登录所得 access_token（示例见文末 0）。凭据只走 env，不落本文件。

## 一览表

| RPC | input schema | result payload | 写/读 |
|---|---|---|---|
| `initialize_workspace_v1`（P0 已有） | commands/initialize-workspace-v1.schema.json | workspace 初始化摘要 | 写 |
| `set_day_type_v1` | commands/set-day-type-v1.schema.json | payloads/day-type-v1.schema.json | 写 |
| `check_anchor_v1` | commands/check-anchor-v1.schema.json | payloads/anchor-v1.schema.json | 写 |
| `clear_anchor_v1` | commands/clear-anchor-v1.schema.json | payloads/anchor-v1.schema.json | 写 |
| `update_anchor_note_v1` | commands/update-anchor-note-v1.schema.json | payloads/anchor-v1.schema.json | 写 |
| `record_open_v1` | commands/record-open-v1.schema.json | `{recorded,deduped,device_id,biz_date,open_id}` | 写 |
| `get_today_context_v1` | commands/get-today-context-v1.schema.json | context 投影（含 day_type/anchors/stats/next_action/data_revision） | 读（FOR SHARE） |

## 0. 登录取 JWT（前置）

```bash
curl -sS -X POST "$BASE/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON" -H "Content-Type: application/json" \
  -d "{\"email\":\"$OWNER_EMAIL\",\"password\":\"$OWNER_PASSWORD\"}"
# → .access_token 即 $JWT
```

## 1. initialize_workspace_v1（已有，P0 链建立，本卡未改）

```bash
curl -sS -X POST "$BASE/rest/v1/rpc/initialize_workspace_v1" \
  -H "apikey: $ANON" -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
  -d '{"p_envelope":{"api_version":"1","idempotency_key":"'"$(uuidgen | tr A-F a-f)"'","input":{"timezone":"Asia/Shanghai","tracking_started_on":"2026-09-21","weekday_codes":["workout_workday","ordinary_workday","workout_workday","ordinary_workday","ordinary_workday","weekend","weekend"]}}}'
```

## 2. set_day_type_v1（仅今日；已锁仅单向追加训练）

```bash
curl -sS -X POST "$BASE/rest/v1/rpc/set_day_type_v1" \
  -H "apikey: $ANON" -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
  -d '{"p_envelope":{"api_version":"1","idempotency_key":"'"$(uuidgen | tr A-F a-f)"'","input":{"biz_date":"2026-09-23","code":"workout_workday"}}}'
```

## 3. check_anchor_v1（锚点打卡；status/target/version 由 Core 导出）

```bash
curl -sS -X POST "$BASE/rest/v1/rpc/check_anchor_v1" \
  -H "apikey: $ANON" -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
  -d '{"p_envelope":{"api_version":"1","idempotency_key":"'"$(uuidgen | tr A-F a-f)"'","input":{"biz_date":"2026-09-23","anchor_type":"wake","actual_at":"2026-09-23T06:47:00+08:00","note":"自然醒"}}}'
```

## 4. clear_anchor_v1（只清实际值，不删计划/分母）

```bash
curl -sS -X POST "$BASE/rest/v1/rpc/clear_anchor_v1" \
  -H "apikey: $ANON" -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
  -d '{"p_envelope":{"api_version":"1","idempotency_key":"'"$(uuidgen | tr A-F a-f)"'","input":{"biz_date":"2026-09-23","anchor_type":"wake"}}}'
```

## 5. update_anchor_note_v1（同记录 LWW 仅改 note）

```bash
curl -sS -X POST "$BASE/rest/v1/rpc/update_anchor_note_v1" \
  -H "apikey: $ANON" -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
  -d '{"p_envelope":{"api_version":"1","idempotency_key":"'"$(uuidgen | tr A-F a-f)"'","input":{"record_id":"<anchor record uuid>","note":"改备注"}}}'
```

## 6. record_open_v1（同 device 同日换幂等 key 也至多 1 条 human.opened）

```bash
curl -sS -X POST "$BASE/rest/v1/rpc/record_open_v1" \
  -H "apikey: $ANON" -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
  -d '{"p_envelope":{"api_version":"1","idempotency_key":"'"$(uuidgen | tr A-F a-f)"'","input":{"device_id":"my-device","biz_date":"2026-09-23"}}}'
# 响应 result.deduped=false 为首次记录；同 device_id+biz_date 再调（任意新幂等 key）→ deduped=true 不刷日志
```

## 7. get_today_context_v1（只读；POST RPC；FOR SHARE 一致锁；不物化）

```bash
curl -sS -X POST "$BASE/rest/v1/rpc/get_today_context_v1" \
  -H "apikey: $ANON" -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
  -d '{"p_envelope":{"api_version":"1","idempotency_key":"'"$(uuidgen | tr A-F a-f)"'","input":{}}}'
# input.biz_date 可选（缺省=工作区时区今日）；未打开日返回占位 version="0"/materialized=false
```

## 错误码速查（本卡实测触发；业务拒绝均为 HTTP 200 + `ok:false` 信封，收据记 rejected）

| code | 触发 |
|---|---|
| `UNAUTHENTICATED` | 无 JWT / JWT 失效 |
| `OWNER_DENIED` | 非 workspace_owner 调写命令 |
| `VALIDATION_FAILED` | 信封形状非法；带 expected_version；**input 白名单外字段（伪造 status/version 等 Core 导出字段）**；字段格式非法；note 超 2000；set_day_type 非今日；早于跟踪起日；actual_at 未来/不归属该生活日/超出关灯窗口 |
| `IDEMPOTENCY_KEY_REUSED` | 同幂等键绑定不同 input |
| `IDEMPOTENCY_RESULT_EXPIRED` | 收据已过期重放 |
| `WORKSPACE_NOT_INITIALIZED` | 未初始化即写/读（本卡 NOT_RUN，见 result.md） |
| `DAY_PLAN_LOCKED` | 首记后试图改型/减分母/非单向追加 |
| `ANCHOR_NOT_APPLICABLE` | 对 n/a 锚点打卡 |
| `RESOURCE_NOT_FOUND` | update_anchor_note 的 record_id 不存在 |
| `RESOURCE_DELETED` | 目标记录已软删 |

> 注：任务卡 2.3 提到的 `PAYLOAD_SCHEMA_MISMATCH` 在 contract 层体现为 `additionalProperties:false`（schema 校验职责）；RPC 层对越权字段统一返回 `VALIDATION_FAILED` 并在 message 列出允许字段。HTTP 状态恒 200（业务拒绝需入库成 rejected 收据，不走 HTTP 错误码）。此差异已留 result.md 供 Review 裁决。
