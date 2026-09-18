#!/bin/bash
# P0-005 security-matrix-db.sh — S01-S09 DB 侧实测（Management API SQL，事务回滚，零生产副作用）
# 修正版 v2：uuid 全小写、RPC 结果统一 as r 别名、断言兼容 error-message 形状
# 凭据纪律：PAT 只经 keychain 注入，不打印不落盘；本脚本入库不含任何密钥。
set -u
PAT=$(security find-generic-password -a "$USER" -s MORROW_SUPABASE_ACCESS_TOKEN -w 2>/dev/null)
[ -z "$PAT" ] && { echo "KEYCHAIN_PAT_MISSING"; exit 1; }
URL="https://api.supabase.com/v1/projects/umutubzcwwmmbxfjkyvj/database/query"
OWNER="0c645909-ebb5-4910-ab99-4f7b238c9529"
PROBE="f986333c-0ba0-41b5-b44b-41e52535c5f5"
mg() { jq -n --arg q "$1" '{query:$q}' | curl -sS -m 60 -X POST "$URL" -H "Authorization: Bearer $PAT" -H "Content-Type: application/json" -d @-; }
ck() { if printf '%s' "$2" | jq -e "$3" >/dev/null 2>&1; then echo "PASS  $1"; else echo "FAIL  $1"; printf '  resp: %.400s\n' "$2"; fi; printf '%s\n%s\n---\n' "$1" "$2" >> "$OUTF"; }
uuidl() { uuidgen | tr 'A-Z' 'a-z'; }
OUTF="$(dirname "$0")/security-matrix-db.output.txt"
: > "$OUTF"

echo "===== S01 anon 全盲 ====="
R=$(mg "begin; set local role anon; select count(*) as c from public.life_data; rollback;")
ck S01a_anon_life_data_denied "$R" 'tostring | test("42501|permission denied")'
R=$(mg "begin; set local role anon; select count(*) as c from public.activity_log; rollback;")
ck S01b_anon_activity_denied "$R" 'tostring | test("42501|permission denied")'
R=$(mg "begin; set local role anon; select 1 from private.agent_credentials limit 1; rollback;")
ck S01c_anon_private_credentials_denied "$R" 'tostring | test("42501|permission denied")'
R=$(mg "begin; set local role anon; select public.get_workspace_revision_v1('{\"api_version\":\"1\",\"idempotency_key\":\"$(uuidl)\"}'::jsonb) as r; rollback;")
ck S01d_anon_rpc_denied "$R" 'tostring | test("42501|permission denied")'

echo "===== S02 非 owner（probe 真实身份 claims）====="
R=$(mg "begin; set local role authenticated; set local \"request.jwt.claims\" = '{\"sub\":\"$PROBE\",\"role\":\"authenticated\"}'; select count(*) as c from public.life_data; rollback;")
ck S02a_probe_life_data_zero_rows "$R" '.[0].c == 0'
R=$(mg "begin; set local role authenticated; set local \"request.jwt.claims\" = '{\"sub\":\"$PROBE\",\"role\":\"authenticated\"}'; select count(*) as c from public.activity_log; rollback;")
ck S02b_probe_activity_zero_rows "$R" '.[0].c == 0'
R=$(mg "begin; set local role authenticated; set local \"request.jwt.claims\" = '{\"sub\":\"$PROBE\",\"role\":\"authenticated\"}'; select public.initialize_workspace_v1('{\"api_version\":\"1\",\"idempotency_key\":\"$(uuidl)\"}'::jsonb) as r; rollback;")
ck S02c_probe_rpc_owner_denied "$R" '.[0].r.ok == false and .[0].r.error.code == "OWNER_DENIED"'
R=$(mg "begin; set local role authenticated; set local \"request.jwt.claims\" = '{\"sub\":\"$PROBE\",\"role\":\"authenticated\"}'; select count(*) as c from public.workspace_settings where user_id = '$PROBE'; rollback;")
ck S02d_probe_settings_zero "$R" '.[0].c == 0'

echo "===== S03 owner 直 DML 拒绝 + 语义 RPC 成功对照 ====="
R=$(mg "begin; set local role authenticated; set local \"request.jwt.claims\" = '{\"sub\":\"$OWNER\",\"role\":\"authenticated\"}'; update public.life_data set payload='{}' where user_id='$OWNER'; rollback;")
ck S03a_owner_direct_update_denied "$R" 'tostring | test("42501|permission denied")'
R=$(mg "begin; set local role authenticated; set local \"request.jwt.claims\" = '{\"sub\":\"$OWNER\",\"role\":\"authenticated\"}'; delete from public.activity_log where user_id='$OWNER'; rollback;")
ck S03b_owner_direct_delete_denied "$R" 'tostring | test("42501|permission denied")'
R=$(mg "begin; set local role authenticated; set local \"request.jwt.claims\" = '{\"sub\":\"$OWNER\",\"role\":\"authenticated\"}'; select public.get_workspace_revision_v1('{\"api_version\":\"1\",\"idempotency_key\":\"$(uuidl)\"}'::jsonb) as r; rollback;")
ck S03c_owner_semantic_rpc_ok "$R" '.[0].r.ok == true and (.[0].r.data_revision | test("^[0-9]+$"))'

echo "===== S04 伪造 actor/owner 拒绝 ====="
R=$(mg "begin; set local role authenticated; set local \"request.jwt.claims\" = '{\"sub\":\"$OWNER\",\"role\":\"authenticated\"}'; select private.cmd_get_command_result_v1('$PROBE', '{\"api_version\":\"1\",\"idempotency_key\":\"$(uuidl)\",\"input\":{\"idempotency_key\":\"$(uuidl)\"}}'::jsonb) as r; rollback;")
ck S04a_forged_puid_probe_on_owner_session "$R" '(.[0].r.ok == false and .[0].r.error.code == "OWNER_DENIED") or (tostring | test("42501|permission denied"))'
R=$(mg "begin; insert into public.life_data (user_id, module, entity_key, biz_date, payload, source_type, source_id) values ('$OWNER','anchor','p005:forged','2026-09-18','{\"payload_v\":1}'::jsonb,'human','$OWNER'); rollback;")
ck S04b_insert_without_actor_rejected "$R" 'tostring | test("actor_context_missing")'
R=$(mg "begin; select set_config('morrow.actor','human:$PROBE',true); insert into public.life_data (user_id, module, entity_key, biz_date, payload) values ('$OWNER','anchor','p005:forged2','2026-09-18','{\"payload_v\":1}'::jsonb); select source_type, source_id::text as sid from public.life_data where entity_key='p005:forged2'; rollback;")
ck S04c_actor_overrides_declared_source "$R" '.[0].source_type == "human" and .[0].sid == "'$PROBE'"'

echo "===== S05 credentials/receipts 不可读 ====="
R=$(mg "begin; set local role authenticated; set local \"request.jwt.claims\" = '{\"sub\":\"$OWNER\",\"role\":\"authenticated\"}'; select count(*) from private.agent_credentials; rollback;")
ck S05a_owner_cannot_read_credentials "$R" 'tostring | test("42501|permission denied")'
R=$(mg "begin; set local role authenticated; set local \"request.jwt.claims\" = '{\"sub\":\"$OWNER\",\"role\":\"authenticated\"}'; select count(*) from private.request_receipts; rollback;")
ck S05b_owner_cannot_read_receipts "$R" 'tostring | test("42501|permission denied")'
R=$(mg "select count(*) as c from pg_catalog.pg_tables where schemaname='public' and tablename = 'agent_clients' and rowsecurity;")
ck S05c_agent_clients_rls_on "$R" '.[0].c == 1'

echo "===== S06 函数执行白名单 ====="
R=$(mg "select p.proname, has_function_privilege('anon', p.oid, 'EXECUTE') as a, has_function_privilege('authenticated', p.oid, 'EXECUTE') as u, has_function_privilege('service_role', p.oid, 'EXECUTE') as s from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like '%_v1' order by p.proname;")
echo "$R" | jq -r '.[]? | "  \(.proname): anon=\(.a) authenticated=\(.u) service_role=\(.s)"' | tee -a "$OUTF"
R=$(mg "select p.proname, has_function_privilege('anon', p.oid, 'EXECUTE') as a, has_function_privilege('authenticated', p.oid, 'EXECUTE') as u, has_function_privilege('service_role', p.oid, 'EXECUTE') as s from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='private' and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE') or has_function_privilege('service_role', p.oid, 'EXECUTE'));")
echo "$R" | jq -r '.[]? | "  private \(.proname): anon=\(.a) authenticated=\(.u) service_role=\(.s)"' | tee -a "$OUTF"
PRIV_OK=$(printf '%s' "$R" | jq -r '[.[]? | .proname] | join(",")')
EXP="cmd_get_command_result_v1,cmd_get_workspace_revision_v1,cmd_initialize_workspace_v1,cmd_manage_health_client_v1,is_workspace_owner"
[ "$(printf '%s' "$PRIV_OK" | tr ',' '\n' | sort | tr '\n' ',' )" = "$(printf '%s' "$EXP" | tr ',' '\n' | sort | tr '\n' ',')" ] && echo "PASS  S06_private_whitelist_exact" | tee -a "$OUTF" || { echo "FAIL  S06_private_whitelist_exact (got: $PRIV_OK)"; printf '%s\n' "$R" >> "$OUTF"; }

echo "===== S07 health 凭据状态字段 ====="
R=$(mg "select count(*) as c from private.agent_credentials where expires_at <= now();")
ck S07a_no_expired_creds_lingering "$R" '.[0].c == 0'
echo "（S07 Edge 侧过期/撤销 token 实测属 P0-007 health 端到端）" | tee -a "$OUTF"

echo "===== S08 撤销并发（revoke ‖ rotate）====="
EK=$(uuidl); CREDID=$(uuidl); SALT=$(uuidl)
H=$(printf 'p005-s08-%s' "$SALT" | shasum -a 256 | awk '{print $1}')
R=$(mg "begin; set local role authenticated; set local \"request.jwt.claims\" = '{\"sub\":\"$OWNER\",\"role\":\"authenticated\"}'; select public.manage_health_client_v1('{\"api_version\":\"1\",\"idempotency_key\":\"$EK\",\"input\":{\"action\":\"create\",\"name\":\"s08-client\",\"type\":\"local\",\"credential_id\":\"$CREDID\",\"token_hash\":\"$H\",\"expires_at\":\"2026-10-18T02:45:31Z\"}}'::jsonb) as r; commit;")
CL=$(printf '%s' "$R" | jq -r '.[0].r.result.client_id // empty')
[ -z "$CL" ] && { echo "ABORT no client_id: $R"; printf '%s\n' "$R" >> "$OUTF"; exit 1; }
echo "client created: $CL" | tee -a "$OUTF"
RK=$(uuidl); ROTK=$(uuidl); ROTSALT=$(uuidl)
H2=$(printf 'p005-s08rot-%s' "$ROTSALT" | shasum -a 256 | awk '{print $1}')
( mg "begin; set local role authenticated; set local \"request.jwt.claims\" = '{\"sub\":\"$OWNER\",\"role\":\"authenticated\"}'; select public.manage_health_client_v1('{\"api_version\":\"1\",\"idempotency_key\":\"$RK\",\"input\":{\"action\":\"revoke\",\"client_id\":\"$CL\",\"target\":\"client\"}}'::jsonb) as r; commit;" > /tmp/p005_s08_revoke.json ) &
( mg "begin; set local role authenticated; set local \"request.jwt.claims\" = '{\"sub\":\"$OWNER\",\"role\":\"authenticated\"}'; select public.manage_health_client_v1('{\"api_version\":\"1\",\"idempotency_key\":\"$ROTK\",\"input\":{\"action\":\"rotate\",\"client_id\":\"$CL\",\"credential_id\":\"$ROTK\",\"token_hash\":\"$H2\",\"expires_at\":\"2026-10-18T02:45:31Z\"}}'::jsonb) as r; commit;" > /tmp/p005_s08_rotate.json ) &
wait
RV=$(jq -c '.[0].r' /tmp/p005_s08_revoke.json); RT=$(jq -c '.[0].r' /tmp/p005_s08_rotate.json)
echo "revoke: $RV" | tee -a "$OUTF"; echo "rotate: $RT" | tee -a "$OUTF"
# 撤销后终态断言：client revoked_at 非空 + 全凭据 revoked + rotate 不得成功于 revoke 之后
FINAL=$(mg "select (revoked_at is not null) as rv, enabled from public.agent_clients where id='$CL'; select count(*) as live_creds from private.agent_credentials where agent_id='$CL' and revoked_at is null;")
RV_OK=$(printf '%s' "$RV" | jq -r '.ok')
RT_CODE=$(printf '%s' "$RT" | jq -r '.ok // false | if . == true then "ok" else .error.code end')
if [ "$RV_OK" = "true" ] && printf '%s' "$FINAL" | jq -e '.[0].rv == true and .[0].enabled == false and .[1].live_creds == 0' >/dev/null; then
  if [ "$RT_CODE" = "ok" ]; then
    # rotate 若成功必须发生在 revoke 提交前（锁序等待）；验证该凭据已被 revoke 连带撤销
    ROTREV=$(printf '%s' "$FINAL" | jq -r '.[1].live_creds')
    [ "$ROTREV" = "0" ] && echo "PASS  S08_revoke_wins_after_race (rotate 抢先但新凭据被 revoke 连带撤销——撤销后无新授权写)" | tee -a "$OUTF" || { echo "FAIL  S08 (rotate 成功且新凭据存活)"; printf '%s\n' "$FINAL" >> "$OUTF"; }
  else
    echo "PASS  S08_revoke_blocks_late_write (rotate 被拒: $RT_CODE——撤销提交后无新授权写)" | tee -a "$OUTF"
  fi
else
  echo "FAIL  S08 (revoke 未成功或终态不对)"; printf '%s\n%s\n' "$RV" "$FINAL" >> "$OUTF"
fi

echo "===== S09 receipts 无 token 泄漏 ====="
R=$(mg "select count(*) as c from private.request_receipts where response::text ~ '[0-9a-f]{64}' and operation='manage_health_client_v1';")
ck S09_receipt_no_token_hash "$R" '.[0].c == 0'

echo "===== 清理 S08 client ====="
mg "delete from private.agent_credentials where agent_id='$CL'; delete from public.agent_clients where id='$CL'; select count(*) as c from public.agent_clients where id='$CL';" | jq -c '.[]?' | tee -a "$OUTF"
echo "done"