#!/bin/bash
# P0-003 RLS/权限实证探针 —— 每案例独立 Management API 调用，原始响应落盘。
# 方法: SET LOCAL ROLE authenticated + request.jwt.claims 模拟 JWT 会话（auth.uid() 由 claims.sub 派生）。
# 凭据纪律: PAT 只经 keychain 注入进程环境，不打印、不落盘。
# 注意: 本脚本不含任何密钥；token 值不出现在参数/输出中。
set -u
PAT=$(security find-generic-password -a "$USER" -s MORROW_SUPABASE_ACCESS_TOKEN -w 2>/dev/null)
if [ -z "$PAT" ]; then echo "KEYCHAIN_PAT_MISSING"; exit 1; fi
URL="https://api.supabase.com/v1/projects/umutubzcwwmmbxfjkyvj/database/query"
OWNER="0c645909-ebb5-4910-ab99-4f7b238c9529"
NONOWNER="11111111-2222-4333-8444-555555555555"

run() { # $1=case_id $2=expectation $3=sql
  echo "===== $1 ====="
  echo "expect: $2"
  echo "sql: $3"
  echo "response:"
  jq -n --arg q "$3" '{query:$q}' | curl -sS -X POST "$URL" -H "Authorization: Bearer $PAT" -H "Content-Type: application/json" -d @-
  echo; echo
}

OWNER_CLAIMS="{\"sub\":\"$OWNER\",\"role\":\"authenticated\"}"
NONOWNER_CLAIMS="{\"sub\":\"$NONOWNER\",\"role\":\"authenticated\"}"

run A1_owner_read_grants "uid=owner; life_data/clients/activity 可 SELECT(0 行); workspace_state data_revision=0" \
"begin; set local role authenticated; set local \"request.jwt.claims\" = '$OWNER_CLAIMS'; select auth.uid()::text as uid, (select count(*) from public.life_data) as life_rows, (select data_revision from public.workspace_state) as data_revision, (select count(*) from public.agent_clients) as clients, (select count(*) from public.activity_log) as logs; rollback;"

run B1_owner_read_credentials "ERROR 42501（private 无 grant，owner 也不可读凭据）" \
"begin; set local role authenticated; set local \"request.jwt.claims\" = '$OWNER_CLAIMS'; select count(*) from private.agent_credentials; rollback;"

run B2_owner_read_receipts "ERROR 42501" \
"begin; set local role authenticated; set local \"request.jwt.claims\" = '$OWNER_CLAIMS'; select count(*) from private.request_receipts; rollback;"

run B3_owner_read_payload_schemas "ERROR 42501" \
"begin; set local role authenticated; set local \"request.jwt.claims\" = '$OWNER_CLAIMS'; select count(*) from private.payload_schemas; rollback;"

run B4_owner_direct_insert_life_data "ERROR 42501（owner 直接 DML 拒绝，写仅经 Core RPC）" \
"begin; set local role authenticated; set local \"request.jwt.claims\" = '$OWNER_CLAIMS'; insert into public.life_data (id, user_id, module, entity_key, biz_date, payload, source_type, source_id) values ('aaaaaaaa-1111-4111-8111-111111111111', '$OWNER', 'anchor', 'wake:2026-09-16', '2026-09-16', '{}', 'human', '$OWNER'); rollback;"

run B5_owner_direct_update_state "ERROR 42501" \
"begin; set local role authenticated; set local \"request.jwt.claims\" = '$OWNER_CLAIMS'; update public.workspace_state set data_revision = 99; rollback;"

run B6_owner_direct_insert_activity "ERROR 42501（仅 Core 追加）" \
"begin; set local role authenticated; set local \"request.jwt.claims\" = '$OWNER_CLAIMS'; insert into public.activity_log (id, user_id, actor_type, actor_id, action, resource) values ('bbbbbbbb-1111-4111-8111-111111111111', '$OWNER', 'human', '$OWNER', 'probe', 'probe'); rollback;"

run B7_owner_read_agent_advice "ERROR 42501（M1 封闭，无 grant）" \
"begin; set local role authenticated; set local \"request.jwt.claims\" = '$OWNER_CLAIMS'; select count(*) from public.agent_advice; rollback;"

run B8_owner_read_export_advice_view "ERROR 42501（封闭表导出视图未授予 authenticated）" \
"begin; set local role authenticated; set local \"request.jwt.claims\" = '$OWNER_CLAIMS'; select count(*) from public.export_agent_advice_v1; rollback;"

run B9_owner_read_export_rules_view "ERROR 42501" \
"begin; set local role authenticated; set local \"request.jwt.claims\" = '$OWNER_CLAIMS'; select count(*) from public.export_automation_rules_v1; rollback;"

run C1_nonowner_select_life_data "0 行（有 SELECT grant 但 RLS 过滤；不可见他人数据，非错误）" \
"begin; set local role authenticated; set local \"request.jwt.claims\" = '$NONOWNER_CLAIMS'; select count(*) as rows from public.life_data; rollback;"

run C2_nonowner_select_state "0 行" \
"begin; set local role authenticated; set local \"request.jwt.claims\" = '$NONOWNER_CLAIMS'; select count(*) as rows from public.workspace_state; rollback;"

run C3_nonowner_direct_insert "ERROR 42501" \
"begin; set local role authenticated; set local \"request.jwt.claims\" = '$NONOWNER_CLAIMS'; insert into public.life_data (id, user_id, module, entity_key, biz_date, payload, source_type, source_id) values ('cccccccc-1111-4111-8111-111111111111', '$NONOWNER', 'anchor', 'wake:2026-09-16', '2026-09-16', '{}', 'human', '$NONOWNER'); rollback;"

run D0_seed_probe_row "以部署角色插入探针行 version=9007199254740993(>2^53)，供导出视图实证" \
"insert into public.life_data (id, user_id, module, entity_key, biz_date, payload, version, source_type, source_id) values ('dddddddd-1111-4111-8111-111111111111', '$OWNER', 'anchor', 'wake:2026-09-15', '2026-09-15', '{\"payload_v\":1,\"anchor_type\":\"wake\",\"timezone\":\"Asia/Shanghai\",\"target_at\":\"2026-09-15T06:50:00+08:00\",\"actual_at\":\"2026-09-15T06:47:00+08:00\",\"status\":\"recorded\",\"planned\":true,\"note\":\"\",\"plan_version\":\"3\"}'::jsonb, 9007199254740993, 'system', '$OWNER');"

run D1_owner_export_view_bigint "export_life_data_v1 返回 version 为 text '9007199254740993'（pg_typeof=text）" \
"begin; set local role authenticated; set local \"request.jwt.claims\" = '$OWNER_CLAIMS'; select id, version, pg_typeof(version)::text as version_type from public.export_life_data_v1 where id = 'dddddddd-1111-4111-8111-111111111111'; rollback;"

run D2_nonowner_export_view "0 行（security_invoker 继承底表 RLS）" \
"begin; set local role authenticated; set local \"request.jwt.claims\" = '$NONOWNER_CLAIMS'; select count(*) as rows from public.export_life_data_v1; rollback;"

run D3_cleanup_probe_row "删除探针行，count=0" \
"delete from public.life_data where id = 'dddddddd-1111-4111-8111-111111111111'; select count(*) as remaining from public.life_data;"

run E1_export_views_security_invoker "7 个 export_* 视图均带 security_invoker=true" \
"select relname, reloptions from pg_class where relkind = 'v' and relname like 'export\\_%' order by relname;"

echo "DONE"
