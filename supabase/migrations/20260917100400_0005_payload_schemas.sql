-- P0-003 / migration 0005: private.payload_schemas 装载 contracts/v1 快照
-- 合同: 01-architecture.md §3.9（migration 固化 contracts 快照及 hash，运行期不读文件）
-- hash 口径: sha256(contracts/v1/payloads/<file> 的 UTF-8 原始字节), 与 contracts/v1/manifest.json 一致
begin;
insert into private.payload_schemas (module, payload_v, schema, schema_hash) values
  ('anchor', 1, $contract$
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "morrow.life_data anchor payload_v=1",
  "description": "锚点 payload 结构合同（02-contracts.md C-02）。仅表达单字段结构约束；recorded⇔actual_at 非空、not_applicable⇒planned=false、status 由 Core 导出等跨字段不变量由语义 Core 强制，不在此表达。",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "payload_v",
    "anchor_type",
    "timezone",
    "target_at",
    "actual_at",
    "status",
    "planned",
    "note",
    "plan_version"
  ],
  "properties": {
    "payload_v": { "const": 1 },
    "anchor_type": { "enum": ["wake", "workout_end", "lights_off"] },
    "timezone": { "const": "Asia/Shanghai" },
    "target_at": {
      "type": ["string", "null"],
      "pattern": "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\\.[0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"
    },
    "actual_at": {
      "type": ["string", "null"],
      "pattern": "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\\.[0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"
    },
    "status": { "enum": ["pending", "recorded", "not_applicable"] },
    "planned": { "type": "boolean" },
    "note": { "type": "string", "minLength": 0, "maxLength": 2000 },
    "plan_version": {
      "type": "string",
      "pattern": "^(0|[1-9][0-9]*)$"
    }
  }
}
$contract$::jsonb, '9e0d08aa4124c2aace70dd2af83dac0850142c4b8caaebab8fb2260644615611'),
  ('day_type', 1, $contract$
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "morrow.life_data day_type payload_v=1",
  "description": "每日计划快照 payload 结构合同（02-contracts.md C-02）。anchors 为固定 3 元素数组且顺序固定为 wake/workout_end/lights_off；训练日 workout_end=19:15、非训练日为 null 等跨字段规则由语义 Core 强制。",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "payload_v",
    "code",
    "name",
    "timezone",
    "template_version",
    "workout_expected",
    "sleep_target",
    "anchors",
    "plan_locked"
  ],
  "properties": {
    "payload_v": { "const": 1 },
    "code": {
      "enum": ["ordinary_workday", "workout_workday", "weekend", "weekend_workout"]
    },
    "name": { "type": "string", "minLength": 1, "maxLength": 40 },
    "timezone": { "const": "Asia/Shanghai" },
    "template_version": {
      "type": "string",
      "pattern": "^(0|[1-9][0-9]*)$"
    },
    "workout_expected": { "type": "boolean" },
    "sleep_target": { "const": "22:15" },
    "anchors": {
      "type": "array",
      "minItems": 3,
      "maxItems": 3,
      "prefixItems": [
        {
          "type": "object",
          "additionalProperties": false,
          "required": ["type", "required", "target_local_time"],
          "properties": {
            "type": { "const": "wake" },
            "required": { "type": "boolean" },
            "target_local_time": {
              "type": ["string", "null"],
              "pattern": "^([01][0-9]|2[0-3]):[0-5][0-9]$"
            }
          }
        },
        {
          "type": "object",
          "additionalProperties": false,
          "required": ["type", "required", "target_local_time"],
          "properties": {
            "type": { "const": "workout_end" },
            "required": { "type": "boolean" },
            "target_local_time": {
              "type": ["string", "null"],
              "pattern": "^([01][0-9]|2[0-3]):[0-5][0-9]$"
            }
          }
        },
        {
          "type": "object",
          "additionalProperties": false,
          "required": ["type", "required", "target_local_time"],
          "properties": {
            "type": { "const": "lights_off" },
            "required": { "type": "boolean" },
            "target_local_time": {
              "type": ["string", "null"],
              "pattern": "^([01][0-9]|2[0-3]):[0-5][0-9]$"
            }
          }
        }
      ],
      "items": false
    },
    "plan_locked": { "type": "boolean" }
  }
}
$contract$::jsonb, 'd53b1f5a854f2b3a984aa21255f6e2ec479ff7da52b06163cb92d1bc81352781');
commit;
