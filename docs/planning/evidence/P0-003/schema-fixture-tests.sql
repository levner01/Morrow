-- P0-003 contracts/v1 fixture 校验（23 案例）。来源: contracts/v1/manifest.json
-- got = pg_jsonschema 判定结果; expect = 合同预期; pass = (got = expect)
select 01 as n, 'payloads/anchor-valid-wake-recorded.json' as case_id, extensions.jsonb_matches_schema((select schema::json from private.payload_schemas where module = 'anchor' and payload_v = 1), $fix$
{
  "payload_v": 1,
  "anchor_type": "wake",
  "timezone": "Asia/Shanghai",
  "target_at": "2026-09-15T06:50:00+08:00",
  "actual_at": "2026-09-15T06:47:00+08:00",
  "status": "recorded",
  "planned": true,
  "note": "",
  "plan_version": "3"
}
$fix$::jsonb) as got, true as expect
union all
select 02 as n, 'payloads/anchor-valid-workout-not-applicable.json' as case_id, extensions.jsonb_matches_schema((select schema::json from private.payload_schemas where module = 'anchor' and payload_v = 1), $fix$
{
  "payload_v": 1,
  "anchor_type": "workout_end",
  "timezone": "Asia/Shanghai",
  "target_at": null,
  "actual_at": null,
  "status": "not_applicable",
  "planned": false,
  "note": "",
  "plan_version": "3"
}
$fix$::jsonb) as got, true as expect
union all
select 03 as n, 'payloads/anchor-invalid-unknown-field.json' as case_id, extensions.jsonb_matches_schema((select schema::json from private.payload_schemas where module = 'anchor' and payload_v = 1), $fix$
{
  "payload_v": 1,
  "anchor_type": "wake",
  "timezone": "Asia/Shanghai",
  "target_at": "2026-09-15T06:50:00+08:00",
  "actual_at": "2026-09-15T06:47:00+08:00",
  "status": "recorded",
  "planned": true,
  "note": "",
  "plan_version": "3",
  "source": "web"
}
$fix$::jsonb) as got, false as expect
union all
select 04 as n, 'payloads/anchor-invalid-payload-v.json' as case_id, extensions.jsonb_matches_schema((select schema::json from private.payload_schemas where module = 'anchor' and payload_v = 1), $fix$
{
  "payload_v": 2,
  "anchor_type": "wake",
  "timezone": "Asia/Shanghai",
  "target_at": "2026-09-15T06:50:00+08:00",
  "actual_at": "2026-09-15T06:47:00+08:00",
  "status": "recorded",
  "planned": true,
  "note": "",
  "plan_version": "3"
}
$fix$::jsonb) as got, false as expect
union all
select 05 as n, 'payloads/anchor-invalid-status-enum.json' as case_id, extensions.jsonb_matches_schema((select schema::json from private.payload_schemas where module = 'anchor' and payload_v = 1), $fix$
{
  "payload_v": 1,
  "anchor_type": "wake",
  "timezone": "Asia/Shanghai",
  "target_at": "2026-09-15T06:50:00+08:00",
  "actual_at": "2026-09-15T06:47:00+08:00",
  "status": "done",
  "planned": true,
  "note": "",
  "plan_version": "3"
}
$fix$::jsonb) as got, false as expect
union all
select 06 as n, 'payloads/day-type-valid-workout-workday.json' as case_id, extensions.jsonb_matches_schema((select schema::json from private.payload_schemas where module = 'day_type' and payload_v = 1), $fix$
{
  "payload_v": 1,
  "code": "workout_workday",
  "name": "训练工作日",
  "timezone": "Asia/Shanghai",
  "template_version": "1",
  "workout_expected": true,
  "sleep_target": "22:15",
  "anchors": [
    { "type": "wake", "required": true, "target_local_time": "06:50" },
    { "type": "workout_end", "required": true, "target_local_time": "19:15" },
    { "type": "lights_off", "required": true, "target_local_time": "22:15" }
  ],
  "plan_locked": false
}
$fix$::jsonb) as got, true as expect
union all
select 07 as n, 'payloads/day-type-valid-ordinary-workday.json' as case_id, extensions.jsonb_matches_schema((select schema::json from private.payload_schemas where module = 'day_type' and payload_v = 1), $fix$
{
  "payload_v": 1,
  "code": "ordinary_workday",
  "name": "普通工作日",
  "timezone": "Asia/Shanghai",
  "template_version": "1",
  "workout_expected": false,
  "sleep_target": "22:15",
  "anchors": [
    { "type": "wake", "required": true, "target_local_time": "06:50" },
    { "type": "workout_end", "required": false, "target_local_time": null },
    { "type": "lights_off", "required": true, "target_local_time": "22:15" }
  ],
  "plan_locked": true
}
$fix$::jsonb) as got, true as expect
union all
select 08 as n, 'payloads/day-type-invalid-four-anchors.json' as case_id, extensions.jsonb_matches_schema((select schema::json from private.payload_schemas where module = 'day_type' and payload_v = 1), $fix$
{
  "payload_v": 1,
  "code": "workout_workday",
  "name": "训练工作日",
  "timezone": "Asia/Shanghai",
  "template_version": "1",
  "workout_expected": true,
  "sleep_target": "22:15",
  "anchors": [
    { "type": "wake", "required": true, "target_local_time": "06:50" },
    { "type": "workout_end", "required": true, "target_local_time": "19:15" },
    { "type": "lights_off", "required": true, "target_local_time": "22:15" },
    { "type": "wake", "required": false, "target_local_time": null }
  ],
  "plan_locked": false
}
$fix$::jsonb) as got, false as expect
union all
select 09 as n, 'payloads/day-type-invalid-sleep-target.json' as case_id, extensions.jsonb_matches_schema((select schema::json from private.payload_schemas where module = 'day_type' and payload_v = 1), $fix$
{
  "payload_v": 1,
  "code": "ordinary_workday",
  "name": "普通工作日",
  "timezone": "Asia/Shanghai",
  "template_version": "1",
  "workout_expected": false,
  "sleep_target": "22:30",
  "anchors": [
    { "type": "wake", "required": true, "target_local_time": "06:50" },
    { "type": "workout_end", "required": false, "target_local_time": null },
    { "type": "lights_off", "required": true, "target_local_time": "22:15" }
  ],
  "plan_locked": true
}
$fix$::jsonb) as got, false as expect
union all
select 10 as n, 'payloads/day-type-schema-pass-core-order.json' as case_id, extensions.jsonb_matches_schema((select schema::json from private.payload_schemas where module = 'day_type' and payload_v = 1), $fix$
{
  "payload_v": 1,
  "code": "workout_workday",
  "name": "训练工作日",
  "timezone": "Asia/Shanghai",
  "template_version": "1",
  "workout_expected": true,
  "sleep_target": "22:15",
  "anchors": [
    { "type": "lights_off", "required": true, "target_local_time": "22:15" },
    { "type": "wake", "required": true, "target_local_time": "06:50" },
    { "type": "workout_end", "required": true, "target_local_time": "19:15" }
  ],
  "plan_locked": false
}
$fix$::jsonb) as got, true as expect
union all
select 11 as n, 'commands/command-envelope-valid.json' as case_id, extensions.jsonb_matches_schema($schema$
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "morrow command envelope v1",
  "description": "统一命令事务信封（02-contracts.md C-04）。expected_version 仅 Agent 命令必填（OCC），Human 命令省略（LWW 由服务端身份决定）；是否必填按命令语义由 Core 判定，信封层保持可选。input 形状见各命令 schema。",
  "type": "object",
  "additionalProperties": false,
  "required": ["api_version", "idempotency_key", "input"],
  "properties": {
    "api_version": { "const": "1" },
    "idempotency_key": {
      "type": "string",
      "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
    },
    "expected_version": {
      "type": "string",
      "pattern": "^(0|[1-9][0-9]*)$"
    },
    "input": { "type": "object" }
  }
}
$schema$::json, $fix$
{
  "api_version": "1",
  "idempotency_key": "3f6b2c1e-7a4d-4e8b-9c0f-1a2b3c4d5e6f",
  "expected_version": "7",
  "input": {
    "biz_date": "2026-09-15",
    "anchor_type": "wake",
    "actual_at": "2026-09-15T06:47:00+08:00",
    "note": ""
  }
}
$fix$::jsonb) as got, true as expect
union all
select 12 as n, 'commands/command-envelope-invalid-missing-key.json' as case_id, extensions.jsonb_matches_schema($schema$
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "morrow command envelope v1",
  "description": "统一命令事务信封（02-contracts.md C-04）。expected_version 仅 Agent 命令必填（OCC），Human 命令省略（LWW 由服务端身份决定）；是否必填按命令语义由 Core 判定，信封层保持可选。input 形状见各命令 schema。",
  "type": "object",
  "additionalProperties": false,
  "required": ["api_version", "idempotency_key", "input"],
  "properties": {
    "api_version": { "const": "1" },
    "idempotency_key": {
      "type": "string",
      "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
    },
    "expected_version": {
      "type": "string",
      "pattern": "^(0|[1-9][0-9]*)$"
    },
    "input": { "type": "object" }
  }
}
$schema$::json, $fix$
{
  "api_version": "1",
  "input": {
    "biz_date": "2026-09-15",
    "anchor_type": "wake",
    "actual_at": "2026-09-15T06:47:00+08:00"
  }
}
$fix$::jsonb) as got, false as expect
union all
select 13 as n, 'commands/check-anchor-valid.json' as case_id, extensions.jsonb_matches_schema($schema$
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "check_anchor_v1 input",
  "description": "02-contracts.md C-05/C-04。命令只收 actual_at、note 等允许字段；status/source/version/target 等 Core 导出或不可变字段禁止提交（additionalProperties:false 拦截）。",
  "type": "object",
  "additionalProperties": false,
  "required": ["biz_date", "anchor_type", "actual_at"],
  "properties": {
    "biz_date": {
      "type": "string",
      "pattern": "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$"
    },
    "anchor_type": { "enum": ["wake", "workout_end", "lights_off"] },
    "actual_at": {
      "type": "string",
      "pattern": "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\\.[0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"
    },
    "note": { "type": "string", "minLength": 0, "maxLength": 2000 }
  }
}
$schema$::json, $fix$
{
  "biz_date": "2026-09-15",
  "anchor_type": "wake",
  "actual_at": "2026-09-15T06:47:00+08:00",
  "note": ""
}
$fix$::jsonb) as got, true as expect
union all
select 14 as n, 'commands/check-anchor-invalid-forged-field.json' as case_id, extensions.jsonb_matches_schema($schema$
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "check_anchor_v1 input",
  "description": "02-contracts.md C-05/C-04。命令只收 actual_at、note 等允许字段；status/source/version/target 等 Core 导出或不可变字段禁止提交（additionalProperties:false 拦截）。",
  "type": "object",
  "additionalProperties": false,
  "required": ["biz_date", "anchor_type", "actual_at"],
  "properties": {
    "biz_date": {
      "type": "string",
      "pattern": "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$"
    },
    "anchor_type": { "enum": ["wake", "workout_end", "lights_off"] },
    "actual_at": {
      "type": "string",
      "pattern": "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\\.[0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"
    },
    "note": { "type": "string", "minLength": 0, "maxLength": 2000 }
  }
}
$schema$::json, $fix$
{
  "biz_date": "2026-09-15",
  "anchor_type": "wake",
  "actual_at": "2026-09-15T06:47:00+08:00",
  "note": "",
  "version": "9",
  "user_id": "0c645909-ebb5-4910-ab99-4f7b238c9529"
}
$fix$::jsonb) as got, false as expect
union all
select 15 as n, 'commands/set-day-type-valid.json' as case_id, extensions.jsonb_matches_schema($schema$
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "set_day_type_v1 input",
  "description": "02-contracts.md C-05。仅今日可设置；已锁计划只允许单向追加训练，门禁由 Core 判定。",
  "type": "object",
  "additionalProperties": false,
  "required": ["biz_date", "code"],
  "properties": {
    "biz_date": {
      "type": "string",
      "pattern": "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$"
    },
    "code": {
      "enum": ["ordinary_workday", "workout_workday", "weekend", "weekend_workout"]
    }
  }
}
$schema$::json, $fix$
{
  "biz_date": "2026-09-15",
  "code": "workout_workday"
}
$fix$::jsonb) as got, true as expect
union all
select 16 as n, 'commands/initialize-workspace-valid.json' as case_id, extensions.jsonb_matches_schema($schema$
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "initialize_workspace_v1 input",
  "description": "02-contracts.md C-05 + 01-architecture.md §3.2。weekday_codes 为初始周配置，必须明确 7 个 weekday 到 day_type code 的映射；仅首次初始化可执行。",
  "type": "object",
  "additionalProperties": false,
  "required": ["timezone", "tracking_started_on", "weekday_codes"],
  "properties": {
    "timezone": { "const": "Asia/Shanghai" },
    "tracking_started_on": {
      "type": "string",
      "pattern": "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$"
    },
    "weekday_codes": {
      "type": "object",
      "additionalProperties": false,
      "required": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"],
      "properties": {
        "mon": { "enum": ["ordinary_workday", "workout_workday", "weekend", "weekend_workout"] },
        "tue": { "enum": ["ordinary_workday", "workout_workday", "weekend", "weekend_workout"] },
        "wed": { "enum": ["ordinary_workday", "workout_workday", "weekend", "weekend_workout"] },
        "thu": { "enum": ["ordinary_workday", "workout_workday", "weekend", "weekend_workout"] },
        "fri": { "enum": ["ordinary_workday", "workout_workday", "weekend", "weekend_workout"] },
        "sat": { "enum": ["ordinary_workday", "workout_workday", "weekend", "weekend_workout"] },
        "sun": { "enum": ["ordinary_workday", "workout_workday", "weekend", "weekend_workout"] }
      }
    }
  }
}
$schema$::json, $fix$
{
  "timezone": "Asia/Shanghai",
  "tracking_started_on": "2026-09-15",
  "weekday_codes": {
    "mon": "workout_workday",
    "tue": "ordinary_workday",
    "wed": "workout_workday",
    "thu": "ordinary_workday",
    "fri": "workout_workday",
    "sat": "weekend",
    "sun": "weekend_workout"
  }
}
$fix$::jsonb) as got, true as expect
union all
select 17 as n, 'commands/record-open-valid.json' as case_id, extensions.jsonb_matches_schema($schema$
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "record_open_v1 input",
  "description": "02-contracts.md C-05。每 device 每 biz_date 至多一次的 Human 主动打开证据；重复调用幂等不刷日志。",
  "type": "object",
  "additionalProperties": false,
  "required": ["device_id", "biz_date"],
  "properties": {
    "device_id": { "type": "string", "minLength": 1, "maxLength": 200 },
    "biz_date": {
      "type": "string",
      "pattern": "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$"
    }
  }
}
$schema$::json, $fix$
{
  "device_id": "macbook-air-m2-office",
  "biz_date": "2026-09-15"
}
$fix$::jsonb) as got, true as expect
union all
select 18 as n, 'commands/manage-health-client-create-valid.json' as case_id, extensions.jsonb_matches_schema($schema$
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "manage_health_client_v1 input",
  "description": "02-contracts.md C-05.1（M1 冻结）。仅限已校验 Human owner；expires_at 必须在 server_now 之后且不超过 90 天，由 Core 判定；schema 只约束结构。拒绝请求自报 user_id/actor/scopes/token 明文（additionalProperties:false 拦截）。",
  "oneOf": [
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["action", "name", "type", "credential_id", "token_hash", "expires_at"],
      "properties": {
        "action": { "const": "create" },
        "name": { "type": "string", "minLength": 1, "maxLength": 80 },
        "type": { "enum": ["local", "remote", "scheduled"] },
        "credential_id": {
          "type": "string",
          "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        },
        "token_hash": { "type": "string", "pattern": "^[0-9a-f]{64}$" },
        "expires_at": {
          "type": "string",
          "pattern": "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\\.[0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"
        }
      }
    },
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["action", "client_id", "credential_id", "token_hash", "expires_at"],
      "properties": {
        "action": { "const": "rotate" },
        "client_id": {
          "type": "string",
          "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        },
        "credential_id": {
          "type": "string",
          "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        },
        "token_hash": { "type": "string", "pattern": "^[0-9a-f]{64}$" },
        "expires_at": {
          "type": "string",
          "pattern": "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\\.[0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"
        }
      }
    },
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["action", "client_id", "target"],
      "properties": {
        "action": { "const": "revoke" },
        "client_id": {
          "type": "string",
          "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        },
        "target": { "const": "client" }
      }
    },
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["action", "client_id", "target", "credential_id"],
      "properties": {
        "action": { "const": "revoke" },
        "client_id": {
          "type": "string",
          "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        },
        "target": { "const": "credential" },
        "credential_id": {
          "type": "string",
          "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        }
      }
    }
  ]
}
$schema$::json, $fix$
{
  "action": "create",
  "name": "hermes-office-health",
  "type": "scheduled",
  "credential_id": "8c1d2e3f-4a5b-4c6d-8e9f-0a1b2c3d4e5f",
  "token_hash": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
  "expires_at": "2026-12-15T00:00:00+08:00"
}
$fix$::jsonb) as got, true as expect
union all
select 19 as n, 'commands/manage-health-client-revoke-credential-valid.json' as case_id, extensions.jsonb_matches_schema($schema$
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "manage_health_client_v1 input",
  "description": "02-contracts.md C-05.1（M1 冻结）。仅限已校验 Human owner；expires_at 必须在 server_now 之后且不超过 90 天，由 Core 判定；schema 只约束结构。拒绝请求自报 user_id/actor/scopes/token 明文（additionalProperties:false 拦截）。",
  "oneOf": [
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["action", "name", "type", "credential_id", "token_hash", "expires_at"],
      "properties": {
        "action": { "const": "create" },
        "name": { "type": "string", "minLength": 1, "maxLength": 80 },
        "type": { "enum": ["local", "remote", "scheduled"] },
        "credential_id": {
          "type": "string",
          "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        },
        "token_hash": { "type": "string", "pattern": "^[0-9a-f]{64}$" },
        "expires_at": {
          "type": "string",
          "pattern": "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\\.[0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"
        }
      }
    },
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["action", "client_id", "credential_id", "token_hash", "expires_at"],
      "properties": {
        "action": { "const": "rotate" },
        "client_id": {
          "type": "string",
          "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        },
        "credential_id": {
          "type": "string",
          "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        },
        "token_hash": { "type": "string", "pattern": "^[0-9a-f]{64}$" },
        "expires_at": {
          "type": "string",
          "pattern": "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\\.[0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"
        }
      }
    },
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["action", "client_id", "target"],
      "properties": {
        "action": { "const": "revoke" },
        "client_id": {
          "type": "string",
          "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        },
        "target": { "const": "client" }
      }
    },
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["action", "client_id", "target", "credential_id"],
      "properties": {
        "action": { "const": "revoke" },
        "client_id": {
          "type": "string",
          "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        },
        "target": { "const": "credential" },
        "credential_id": {
          "type": "string",
          "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        }
      }
    }
  ]
}
$schema$::json, $fix$
{
  "action": "revoke",
  "client_id": "2b3c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d6e",
  "target": "credential",
  "credential_id": "8c1d2e3f-4a5b-4c6d-8e9f-0a1b2c3d4e5f"
}
$fix$::jsonb) as got, true as expect
union all
select 20 as n, 'commands/manage-health-client-invalid-revoke-missing-credential.json' as case_id, extensions.jsonb_matches_schema($schema$
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "manage_health_client_v1 input",
  "description": "02-contracts.md C-05.1（M1 冻结）。仅限已校验 Human owner；expires_at 必须在 server_now 之后且不超过 90 天，由 Core 判定；schema 只约束结构。拒绝请求自报 user_id/actor/scopes/token 明文（additionalProperties:false 拦截）。",
  "oneOf": [
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["action", "name", "type", "credential_id", "token_hash", "expires_at"],
      "properties": {
        "action": { "const": "create" },
        "name": { "type": "string", "minLength": 1, "maxLength": 80 },
        "type": { "enum": ["local", "remote", "scheduled"] },
        "credential_id": {
          "type": "string",
          "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        },
        "token_hash": { "type": "string", "pattern": "^[0-9a-f]{64}$" },
        "expires_at": {
          "type": "string",
          "pattern": "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\\.[0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"
        }
      }
    },
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["action", "client_id", "credential_id", "token_hash", "expires_at"],
      "properties": {
        "action": { "const": "rotate" },
        "client_id": {
          "type": "string",
          "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        },
        "credential_id": {
          "type": "string",
          "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        },
        "token_hash": { "type": "string", "pattern": "^[0-9a-f]{64}$" },
        "expires_at": {
          "type": "string",
          "pattern": "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\\.[0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"
        }
      }
    },
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["action", "client_id", "target"],
      "properties": {
        "action": { "const": "revoke" },
        "client_id": {
          "type": "string",
          "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        },
        "target": { "const": "client" }
      }
    },
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["action", "client_id", "target", "credential_id"],
      "properties": {
        "action": { "const": "revoke" },
        "client_id": {
          "type": "string",
          "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        },
        "target": { "const": "credential" },
        "credential_id": {
          "type": "string",
          "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        }
      }
    }
  ]
}
$schema$::json, $fix$
{
  "action": "revoke",
  "client_id": "2b3c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d6e",
  "target": "credential"
}
$fix$::jsonb) as got, false as expect
union all
select 21 as n, 'commands/get-anchor-history-valid.json' as case_id, extensions.jsonb_matches_schema($schema$
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "get_anchor_history_v1 input",
  "description": "02-contracts.md C-05。from/to 跨度最大 366 天的限制为跨字段规则，由 Core 判定。",
  "type": "object",
  "additionalProperties": false,
  "required": ["from", "to"],
  "properties": {
    "from": {
      "type": "string",
      "pattern": "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$"
    },
    "to": {
      "type": "string",
      "pattern": "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$"
    },
    "cursor": { "type": "string", "minLength": 1, "maxLength": 200 }
  }
}
$schema$::json, $fix$
{
  "from": "2026-08-15",
  "to": "2026-09-15",
  "cursor": "eyJsYXN0X2lkIjoiM2Y2YjJjMWUifQ"
}
$fix$::jsonb) as got, true as expect
union all
select 22 as n, 'results/error-version-conflict-valid.json' as case_id, extensions.jsonb_matches_schema($schema$
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "morrow error envelope v1",
  "description": "统一错误模型（02-contracts.md C-06）。code 集合为 M1 冻结枚举（含 C-08 EXPORT_TOO_LARGE）；details 按 read scope 裁剪由 Core 保证，message 不得含 SQL/token/密码/他人记录。",
  "type": "object",
  "additionalProperties": false,
  "required": ["ok", "error"],
  "properties": {
    "ok": { "const": false },
    "error": {
      "type": "object",
      "additionalProperties": false,
      "required": ["code", "message", "retryable", "request_id"],
      "properties": {
        "code": {
          "enum": [
            "INVALID_REQUEST",
            "UNAUTHENTICATED",
            "SCOPE_DENIED",
            "OWNER_DENIED",
            "RESOURCE_NOT_FOUND",
            "ROUTE_NOT_ENABLED",
            "VERSION_CONFLICT",
            "ALREADY_EXISTS",
            "IDEMPOTENCY_KEY_REUSED",
            "DAY_PLAN_LOCKED",
            "IDEMPOTENCY_RESULT_EXPIRED",
            "RESOURCE_DELETED",
            "PAYLOAD_UNSUPPORTED",
            "VALIDATION_FAILED",
            "RATE_LIMITED",
            "STORAGE_UNAVAILABLE",
            "AUDIT_UNAVAILABLE",
            "EXPORT_TOO_LARGE"
          ]
        },
        "message": { "type": "string", "minLength": 1, "maxLength": 500 },
        "retryable": { "type": "boolean" },
        "request_id": {
          "type": "string",
          "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        },
        "details": { "type": "object" }
      }
    }
  }
}
$schema$::json, $fix$
{
  "ok": false,
  "error": {
    "code": "VERSION_CONFLICT",
    "message": "记录已更新，请重新读取",
    "retryable": false,
    "request_id": "3f6b2c1e-7a4d-4e8b-9c0f-1a2b3c4d5e6f",
    "details": {
      "resource_id": "5a4b3c2d-1e0f-4a9b-8c7d-6e5f4a3b2c1d",
      "current_version": "8"
    }
  }
}
$fix$::jsonb) as got, true as expect
union all
select 23 as n, 'results/error-invalid-unknown-code.json' as case_id, extensions.jsonb_matches_schema($schema$
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "morrow error envelope v1",
  "description": "统一错误模型（02-contracts.md C-06）。code 集合为 M1 冻结枚举（含 C-08 EXPORT_TOO_LARGE）；details 按 read scope 裁剪由 Core 保证，message 不得含 SQL/token/密码/他人记录。",
  "type": "object",
  "additionalProperties": false,
  "required": ["ok", "error"],
  "properties": {
    "ok": { "const": false },
    "error": {
      "type": "object",
      "additionalProperties": false,
      "required": ["code", "message", "retryable", "request_id"],
      "properties": {
        "code": {
          "enum": [
            "INVALID_REQUEST",
            "UNAUTHENTICATED",
            "SCOPE_DENIED",
            "OWNER_DENIED",
            "RESOURCE_NOT_FOUND",
            "ROUTE_NOT_ENABLED",
            "VERSION_CONFLICT",
            "ALREADY_EXISTS",
            "IDEMPOTENCY_KEY_REUSED",
            "DAY_PLAN_LOCKED",
            "IDEMPOTENCY_RESULT_EXPIRED",
            "RESOURCE_DELETED",
            "PAYLOAD_UNSUPPORTED",
            "VALIDATION_FAILED",
            "RATE_LIMITED",
            "STORAGE_UNAVAILABLE",
            "AUDIT_UNAVAILABLE",
            "EXPORT_TOO_LARGE"
          ]
        },
        "message": { "type": "string", "minLength": 1, "maxLength": 500 },
        "retryable": { "type": "boolean" },
        "request_id": {
          "type": "string",
          "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        },
        "details": { "type": "object" }
      }
    }
  }
}
$schema$::json, $fix$
{
  "ok": false,
  "error": {
    "code": "NOT_A_REAL_CODE",
    "message": "不存在的错误码",
    "retryable": false,
    "request_id": "3f6b2c1e-7a4d-4e8b-9c0f-1a2b3c4d5e6f"
  }
}
$fix$::jsonb) as got, false as expect
union all
select 24 as n, 'results/export-container-empty-valid.json' as case_id, extensions.jsonb_matches_schema($schema$
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "morrow export container schema-v1",
  "description": "导出文件容器合同（02-contracts.md C-08），文件名 life-workspace_YYYY-MM-DD_schema-v1.json。BIGINT 已在上游 security_invoker 视图 SQL 端 cast 为 text；行级字段白名单由各导出视图定义，此处约束容器结构。credentials/token/receipt 响应等秘密字段不属于本容器。",
  "type": "object",
  "additionalProperties": false,
  "required": ["schema_version", "exported_at", "app_version", "workspace", "data", "counts", "integrity"],
  "properties": {
    "schema_version": { "const": 1 },
    "exported_at": {
      "type": "string",
      "pattern": "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\\.[0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"
    },
    "app_version": { "type": "string", "minLength": 1, "maxLength": 100 },
    "workspace": {
      "type": "object",
      "additionalProperties": false,
      "required": ["owner_id", "timezone", "data_revision"],
      "properties": {
        "owner_id": {
          "type": "string",
          "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        },
        "timezone": { "type": "string", "minLength": 1, "maxLength": 64 },
        "data_revision": { "type": "string", "pattern": "^(0|[1-9][0-9]*)$" }
      }
    },
    "data": {
      "type": "object",
      "additionalProperties": false,
      "required": ["life_data", "agent_advice", "activity_log", "automation_rules", "agent_clients", "workspace_settings"],
      "properties": {
        "life_data": { "type": "array", "items": { "type": "object" } },
        "agent_advice": { "type": "array", "items": { "type": "object" } },
        "activity_log": { "type": "array", "items": { "type": "object" } },
        "automation_rules": { "type": "array", "items": { "type": "object" } },
        "agent_clients": { "type": "array", "items": { "type": "object" } },
        "workspace_settings": { "type": "array", "items": { "type": "object" } }
      }
    },
    "counts": {
      "type": "object",
      "additionalProperties": false,
      "required": ["life_data", "agent_advice", "activity_log", "automation_rules", "agent_clients", "workspace_settings"],
      "properties": {
        "life_data": { "type": "integer", "minimum": 0 },
        "agent_advice": { "type": "integer", "minimum": 0 },
        "activity_log": { "type": "integer", "minimum": 0 },
        "automation_rules": { "type": "integer", "minimum": 0 },
        "agent_clients": { "type": "integer", "minimum": 0 },
        "workspace_settings": { "type": "integer", "minimum": 0 }
      }
    },
    "integrity": {
      "type": "object",
      "additionalProperties": false,
      "required": ["algorithm", "canonicalization", "data_sha256"],
      "properties": {
        "algorithm": { "const": "SHA-256" },
        "canonicalization": { "const": "RFC8785" },
        "data_sha256": { "type": "string", "pattern": "^[0-9a-f]{64}$" }
      }
    }
  }
}
$schema$::json, $fix$
{
  "schema_version": 1,
  "exported_at": "2026-09-15T12:00:00.000Z",
  "app_version": "p0-003-fixture",
  "workspace": {
    "owner_id": "0c645909-ebb5-4910-ab99-4f7b238c9529",
    "timezone": "Asia/Shanghai",
    "data_revision": "42"
  },
  "data": {
    "life_data": [],
    "agent_advice": [],
    "activity_log": [],
    "automation_rules": [],
    "agent_clients": [],
    "workspace_settings": []
  },
  "counts": {
    "life_data": 0,
    "agent_advice": 0,
    "activity_log": 0,
    "automation_rules": 0,
    "agent_clients": 0,
    "workspace_settings": 0
  },
  "integrity": {
    "algorithm": "SHA-256",
    "canonicalization": "RFC8785",
    "data_sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  }
}
$fix$::jsonb) as got, true as expect
order by 1;
