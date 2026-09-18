#!/bin/bash
# P0-005 expired 缺陷复现（P0-004 移交项）——证实 core_test_write_v1 缺 expired 分支
# 方法：事务内构造 state='expired' 的 identical-input 收据，重放观察是否穿透业务写
# 预期（合同 C-04）：返回 IDEMPOTENCY_RESULT_EXPIRED + 绝不重跑
# 实测（缺陷）：业务写穿透执行 → receipt_complete 找不到 processing 行 → P0001 receipt_state_invalid 回滚
set -u
PAT=$(security find-generic-password -a "$USER" -s MORROW_SUPABASE_ACCESS_TOKEN -w 2>/dev/null)
[ -z "$PAT" ] && { echo "KEYCHAIN_PAT_MISSING"; exit 1; }
URL="https://api.supabase.com/v1/projects/umutubzcwwmmbxfjkyvj/database/query"
OWNER="0c645909-ebb5-4910-ab99-4f7b238c9529"
mg() { jq -n --arg q "$1" '{query:$q}' | curl -sS -m 60 -X POST "$URL" -H "Authorization: Bearer $PAT" -H "Content-Type: application/json" -d @-; }
uuidl() { uuidgen | tr 'A-Z' 'a-z'; }
OUTF="$(dirname "$0")/expired-defect.output.txt"
: > "$OUTF"
D=$(mktemp -d /tmp/p005exp.XXXXXX)

# 预备：真实测试 client（activity_log FK）
EK=$(uuidl); CREDID=$(uuidl); H=$(printf 'p005-exp-%s' "$EK" | shasum -a 256 | awk '{print $1}')
EXP=$(date -u -v+30d +%Y-%m-%dT%H:%M:%SZ)
R=$(mg "begin; set local role authenticated; set local \"request.jwt.claims\" = '{\"sub\":\"$OWNER\",\"role\":\"authenticated\"}'; select public.manage_health_client_v1('{\"api_version\":\"1\",\"idempotency_key\":\"$EK\",\"input\":{\"action\":\"create\",\"name\":\"p005-exp-client\",\"type\":\"local\",\"credential_id\":\"$CREDID\",\"token_hash\":\"$H\",\"expires_at\":\"$EXP\"}}'::jsonb) as r; commit;")
CL=$(printf '%s' "$R" | jq -r '.[0].r.result.client_id // empty')
[ -z "$CL" ] && { echo "ABORT no client: $R"; exit 1; }
echo "client: $CL" | tee -a "$OUTF"

K=$(uuidl)
PAYLOAD='{"module":"anchor","entity_key":"p005:expired","biz_date":"2026-09-18","payload":{"payload_v":1,"anchor_type":"wake","timezone":"Asia/Shanghai","target_at":"2026-09-18T06:50:00+08:00","actual_at":"2026-09-18T06:47:00+08:00","status":"recorded","planned":true,"note":"exp","plan_version":"1"},"expected_version":"0"}'

# 复现：事务内 do 块 — 第一次 create 成功 → 置 expired → 第二次 identical input 重调
R=$(mg "begin;
create temp table t(j jsonb);
do \$\$
begin
  perform set_config('morrow.actor','system:00000000-0000-0000-0000-000000000000', true);
  perform set_config('morrow.request_id', gen_random_uuid()::text, true);
  insert into t select private.core_test_write_v1('agent','$CL','$K'::uuid,'p005_test','$PAYLOAD'::jsonb);
  update private.request_receipts set state='expired' where idempotency_key='$K';
  begin
    insert into t select private.core_test_write_v1('agent','$CL','$K'::uuid,'p005_test','$PAYLOAD'::jsonb);
  exception when others then
    insert into t values (jsonb_build_object('caught_error', sqlstate, 'msg', sqlerrm));
    insert into t select jsonb_build_object('note_written', exists(select 1 from public.life_data where entity_key='p005:expired' and (payload->>'note')='exp'));
  end;
end \$\$;
set local role postgres;
select * from t;
rollback;")
echo "call1+expired+call2(trapped):" | tee -a "$OUTF"
printf '%s\n' "$R" | jq -c '.[]?' | tee -a "$OUTF"
printf '%s\n' "$R" | jq -c '.[]?' > "$D/result.json"

# 裁决
CAUGHT=$(printf '%s' "$R" | jq -r '[.[]? | select(.j.caught_error != null) | .j.caught_error] | first // ""' 2>/dev/null)
FIRST_OK=$(printf '%s' "$R" | jq -r '.[0].j.ok // false' 2>/dev/null)
NOTE_WRITTEN=$(printf '%s' "$R" | jq -r '[.[]? | select(.j.note_written != null) | .j.note_written] | first // ""' 2>/dev/null)
if [ "$FIRST_OK" = "true" ] && [ -n "$CAUGHT" ]; then
  echo "VERDICT: DEFECT CONFIRMED — identical-input expired receipt 触发 $CAUGHT（业务穿透 note_written=$NOTE_WRITTEN，非 IDEMPOTENCY_RESULT_EXPIRED）" | tee -a "$OUTF"
  echo "P1: core_test_write_v1 缺 expired 分支，违反 C-04「超期返回409绝不重跑」" | tee -a "$OUTF"
else
  echo "VERDICT: 未复现异常（first_ok=$FIRST_OK caught=$CAUGHT note_written=$NOTE_WRITTEN），需人工复查" | tee -a "$OUTF"
fi

# 清理测试数据（FK 安全顺序）
mg "delete from public.activity_log where user_id='$OWNER' and metadata->>'entity_key'='p005:expired'; delete from private.request_receipts where idempotency_key='$K'; delete from public.life_data where entity_key='p005:expired'; delete from private.agent_credentials where agent_id='$CL'; delete from public.agent_clients where id='$CL';" | jq -c '.[]?' | tee -a "$OUTF"
rm -rf "$D"
echo "done"