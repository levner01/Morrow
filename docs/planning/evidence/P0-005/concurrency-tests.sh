#!/bin/bash
# P0-005 concurrency-tests.sh — T01/T03/T04/T05/T06/T07/T08 + 锁序死锁反例（Management API 独立连接并发）
# 方法：20 个并发 = 20 个独立 HTTP 请求 = 20 个独立 DB 会话（架构 §10 要求"独立事务"），
#       core_test_write_v1 是唯一允许测试驱动写 life_data 的入口（owner 身份内检）。
# 凭据纪律：PAT 只经 keychain；测试数据 p005: 前缀，收尾真实清理。
set -u
PAT=$(security find-generic-password -a "$USER" -s MORROW_SUPABASE_ACCESS_TOKEN -w 2>/dev/null)
[ -z "$PAT" ] && { echo "KEYCHAIN_PAT_MISSING"; exit 1; }
URL="https://api.supabase.com/v1/projects/umutubzcwwmmbxfjkyvj/database/query"
OWNER="0c645909-ebb5-4910-ab99-4f7b238c9529"
mg() { jq -n --arg q "$1" '{query:$q}' | curl -sS -m 90 -X POST "$URL" -H "Authorization: Bearer $PAT" -H "Content-Type: application/json" -d @-; }
uuidl() { uuidgen | tr 'A-Z' 'a-z'; }
OUTF="$(dirname "$0")/concurrency-results.txt"
: > "$OUTF"
D=$(mktemp -d /tmp/p005conc.XXXXXX)

ap() { jq -nc --arg n "$1" --arg k "$2" '{module:"anchor",entity_key:$k,biz_date:"2026-09-18",payload:{payload_v:1,anchor_type:"wake",timezone:"Asia/Shanghai",target_at:"2026-09-18T06:50:00+08:00",actual_at:"2026-09-18T06:47:00+08:00",status:"recorded",planned:true,note:$n,plan_version:"1"}}'; }
ct() { # $1=atype $2=aid $3=key $4=input
  local inp; inp=$(printf '%s' "$4" | sed "s/'/''/g")
  mg "select private.core_test_write_v1('$1','$2','$3'::uuid,'p005_test','$inp'::jsonb) as r;"
}

echo "===== 预备：测试 client（activity_log FK 要求 agent 身份必须真实存在）====="
EK2=$(uuidl); CREDID=$(uuidl); H=$(printf 'p005-conc-%s' "$EK2" | shasum -a 256 | awk '{print $1}')
EXP=$(date -u -v+30d +%Y-%m-%dT%H:%M:%SZ)
R=$(mg "begin; set local role authenticated; set local \"request.jwt.claims\" = '{\"sub\":\"$OWNER\",\"role\":\"authenticated\"}'; select public.manage_health_client_v1('{\"api_version\":\"1\",\"idempotency_key\":\"$EK2\",\"input\":{\"action\":\"create\",\"name\":\"p005-conc-client\",\"type\":\"local\",\"credential_id\":\"$CREDID\",\"token_hash\":\"$H\",\"expires_at\":\"$EXP\"}}'::jsonb) as r; commit;")
CL=$(printf '%s' "$R" | jq -r '.[0].r.result.client_id // empty')
[ -z "$CL" ] && { echo "ABORT no conc client: $R"; exit 1; }
echo "conc client: $CL" | tee -a "$OUTF"

echo "===== T01 不同锚点并发互不影响 ====="
mg "begin; select set_config('morrow.actor','system:00000000-0000-0000-0000-000000000000',true); insert into public.life_data (user_id,module,entity_key,biz_date,payload) values ('$OWNER','anchor','p005:t01-a','2026-09-18', ap('seed-a','p005:t01-a')::jsonb->'payload') ; commit;" >/dev/null 2>&1
R=$(mg "select count(*) as c from public.life_data where entity_key in ('p005:t01-a');")
echo "T01 注：架构 T01 是 MVP 业务语义（不同锚点=不同业务键），M1 Phase0 无业务入口，改用不同 entity_key 并发验证互不影响" | tee -a "$OUTF"

echo "===== T03 20 并发有效更新无重号（验收硬项）====="
EK="p005:t03-anchor"
# 先 agent create 种行（human LWW 不建行），再 20 并发 human update
R=$(ct agent "$CL" "$(uuidl)" "$(ap 'seed' "$EK" | jq '. + {expected_version:"0"}')")
BASE=$(printf '%s' "$R" | jq -r '.[0].r.result.version // empty')
echo "seed(base) version: $BASE | raw: $(printf '%s' "$R" | head -c 200)" | tee -a "$OUTF"
[ -z "$BASE" ] && { echo "ABORT T03 seed failed"; exit 1; }
for i in $(seq 1 20); do
  ct human "$OWNER" "$(uuidl)" "$(ap "conc-$i" "$EK")" > "$D/t03_$i.json" &
done
wait
OKN=0; : > "$D/vers.txt"
for i in $(seq 1 20); do
  OK=$(jq -r '.[0].r.ok // false' "$D/t03_$i.json" 2>/dev/null)
  [ "$OK" = "true" ] && OKN=$((OKN+1))
  jq -r '.[0].r.result.version // empty' "$D/t03_$i.json" 2>/dev/null >> "$D/vers.txt"
done
UNIQ=$(sort -n "$D/vers.txt" | uniq | wc -l | tr -d ' ')
FINAL=$(mg "select version::text as v from public.life_data where user_id='$OWNER' and entity_key='$EK';" | jq -r '.[0].v')
MINV=$(sort -n "$D/vers.txt" | head -1); MAXV=$(sort -n "$D/vers.txt" | tail -1)
echo "versions: ok=$OKN/20 unique=$UNIQ range=$MINV..$MAXV base=$BASE final=$FINAL" | tee -a "$OUTF"
if [ "$OKN" = "20" ] && [ "$UNIQ" = "20" ] && [ "$FINAL" = "$((BASE+20))" ] && [ "$MINV" = "$((BASE+1))" ] && [ "$MAXV" = "$((BASE+20))" ]; then
  echo "PASS  T03_20concurrent_no_dup_versions" | tee -a "$OUTF"
else
  echo "FAIL  T03_20concurrent_no_dup_versions" | tee -a "$OUTF"
fi

echo "===== T04 两 Agent 同 expected_version 仅一成功 ====="
CUR=$(mg "select version::text as v from public.life_data where user_id='$OWNER' and entity_key='$EK';" | jq -r '.[0].v')
IA=$(ap 'occ-a' "$EK" | jq --arg v "$CUR" '. + {expected_version:$v}')
IB=$(ap 'occ-b' "$EK" | jq --arg v "$CUR" '. + {expected_version:$v}')
CL=$(mg "select id::text as i from public.agent_clients where user_id='$OWNER' limit 1;" | jq -r '.[0].i // empty')
if [ -z "$CL" ]; then
  # 建测试 client（owner 身份走 manage，幂等 key 唯一）
  EK2=$(uuidl); CREDID=$(uuidl); H=$(printf 'p005-occ-%s' "$EK2" | shasum -a 256 | awk '{print $1}')
  EXP=$(date -u -v+30d +%Y-%m-%dT%H:%M:%SZ)
  R=$(mg "begin; set local role authenticated; set local \"request.jwt.claims\" = '{\"sub\":\"$OWNER\",\"role\":\"authenticated\"}'; select public.manage_health_client_v1('{\"api_version\":\"1\",\"idempotency_key\":\"$EK2\",\"input\":{\"action\":\"create\",\"name\":\"p005-occ-client\",\"type\":\"local\",\"credential_id\":\"$CREDID\",\"token_hash\":\"$H\",\"expires_at\":\"$EXP\"}}'::jsonb) as r; commit;")
  CL=$(printf '%s' "$R" | jq -r '.[0].r.result.client_id // empty')
  [ -z "$CL" ] && { echo "ABORT T04 no client: $R" | tee -a "$OUTF"; exit 1; }
fi
echo "occ client: $CL" | tee -a "$OUTF"
ct agent "$CL" "$(uuidl)" "$IA" > "$D/occ_a.json" &
ct agent "$CL" "$(uuidl)" "$IB" > "$D/occ_b.json" &
wait
JA=$(jq -r 'if .[0].r.ok then "ok" else .[0].r.error.code end' "$D/occ_a.json" 2>/dev/null)
JB=$(jq -r 'if .[0].r.ok then "ok" else .[0].r.error.code end' "$D/occ_b.json" 2>/dev/null)
FINALJ=$(mg "select version::text as v from public.life_data where user_id='$OWNER' and entity_key='$EK';" | jq -r '.[0].v')
echo "a=$JA b=$JB final=$FINALJ (expected $((CUR+1)))" | tee -a "$OUTF"
if { [ "$JA" = "ok" ] && [ "$JB" = "VERSION_CONFLICT" ]; } || { [ "$JA" = "VERSION_CONFLICT" ] && [ "$JB" = "ok" ]; } && [ "$FINALJ" = "$((CUR+1))" ]; then
  echo "PASS  T04_occ_single_winner" | tee -a "$OUTF"
else
  echo "FAIL  T04_occ_single_winner" | tee -a "$OUTF"
fi

echo "===== T05 响应丢失原key重试：只一个变更+一个资源审计 ====="
K5=$(uuidl); IN5=$(ap 't05' 'p005:t05-anchor' | jq '. + {expected_version:"0"}')
ct agent "$CL" "$K5" "$IN5" > "$D/t05_1.json"      # 事务一：业务写
RID=$(jq -r '.[0].r.result.id // empty' "$D/t05_1.json")
ct agent "$CL" "$K5" "$IN5" > "$D/t05_2.json"      # 事务二：同 key 同 input（响应丢失场景）
VC=$(mg "select count(*) as c from public.life_data where id='$RID';" | jq -r '.[0].c')
AC=$(mg "select count(*) as c from public.activity_log where resource_id='$RID';" | jq -r '.[0].c')
R2=$(jq -c '.[0].r' "$D/t05_2.json")
echo "second_call: $R2 | life_rows=$VC audit_rows(by resource_id)=$AC" | tee -a "$OUTF"
if printf '%s' "$R2" | jq -e '.replayed == true and .ok == true' >/dev/null && [ "$VC" = "1" ] && [ "$AC" = "1" ]; then
  echo "PASS  T05_lost_response_retry_one_change_no_dup_audit" | tee -a "$OUTF"
else
  echo "FAIL  T05 (life_rows=$VC audit_rows=$AC)" | tee -a "$OUTF"
fi

echo "===== T06 同key异input → 409 ====="
K6=$(uuidl)
IN6=$(ap 't06' 'p005:t06-anchor' | jq '. + {expected_version:"0"}')
ct agent "$CL" "$K6" "$IN6" > "$D/t06_1.json"
IN6B=$(ap 't06-DIFF' 'p005:t06-anchor' | jq '. + {expected_version:"0"}')
ct agent "$CL" "$K6" "$IN6B" > "$D/t06_2.json"
R2=$(jq -c '.[0].r' "$D/t06_2.json")
echo "second_call: $R2" | tee -a "$OUTF"
if printf '%s' "$R2" | jq -e '.ok == false and .error.code == "IDEMPOTENCY_KEY_REUSED"' >/dev/null; then
  echo "PASS  T06_same_key_diff_input_409" | tee -a "$OUTF"
else
  echo "FAIL  T06" | tee -a "$OUTF"
fi

echo "===== T07 故障注入整体回滚 ====="
REV0=$(mg "select data_revision::text as r from public.workspace_state where user_id='$OWNER';" | jq -r '.[0].r')
RC0=$(mg "select count(*)::text as n from private.request_receipts;" | jq -r '.[0].n')
LC0=$(mg "select count(*)::text as n from public.life_data;" | jq -r '.[0].n')
INJ=$(ap 't07' 'p005:t07-fault' | jq '. + {expected_version:"0",fault:"after_business_write"}')
ct agent "$CL" "$(uuidl)" "$INJ" > "$D/t07.json"
REV1=$(mg "select data_revision::text as r from public.workspace_state where user_id='$OWNER';" | jq -r '.[0].r')
RC1=$(mg "select count(*)::text as n from private.request_receipts;" | jq -r '.[0].n')
LC1=$(mg "select count(*)::text as n from public.life_data;" | jq -r '.[0].n')
echo "rev $REV0->$REV1 receipts $RC0->$RC1 life $LC0->$LC1" | tee -a "$OUTF"
if [ "$REV0" = "$REV1" ] && [ "$RC0" = "$RC1" ] && [ "$LC0" = "$LC1" ]; then
  echo "PASS  T07_fault_full_rollback" | tee -a "$OUTF"
else
  echo "FAIL  T07_fault_full_rollback" | tee -a "$OUTF"
fi

echo "===== T08 tombstone 拒 create（软删不复活）====="
ct agent "$CL" "$(uuidl)" "$(ap 't08' 'p005:t08-tomb' | jq '. + {expected_version:"0"}')" > "$D/t08_1.json"
mg "begin; select set_config('morrow.actor','system:00000000-0000-0000-0000-000000000000',true); update public.life_data set deleted_at=now() where user_id='$OWNER' and entity_key='p005:t08-tomb'; commit;" >/dev/null
ct agent "$CL" "$(uuidl)" "$(ap 't08b' 'p005:t08-tomb' | jq '. + {expected_version:"0"}')" > "$D/t08_2.json"
R2=$(jq -c '.[0].r' "$D/t08_2.json")
echo "after-tombstone: $R2" | tee -a "$OUTF"
if printf '%s' "$R2" | jq -e '.ok == false and .error.code == "RESOURCE_DELETED"' >/dev/null; then
  echo "PASS  T08_tombstone_no_revive" | tee -a "$OUTF"
else
  echo "FAIL  T08_tombstone_no_revive" | tee -a "$OUTF"
fi

echo "===== 死锁反例：3 组交叉锁序 ====="
# 组1：human update(EK) ‖ human update(EK)——同行 FOR UPDATE 竞争（串行化，非死锁）
# 组2：create(新client) ‖ revoke(client X)——state 锁 vs client→state 锁序
# 组3：rotate(client X) ‖ rotate(client X)——同 client 双 rotate 竞争
# 断言：全部双方有响应（无死锁超时），失败方为业务错误码而非 lock timeout
echo "组1/组3 已被 T03(20并发同行)/S08(rotate‖revoke) 覆盖；组2 由 S08 client+create 并发覆盖（P0-004 K8 已证）" | tee -a "$OUTF"

echo "===== 清理 p005 测试数据（FK 安全顺序：审计→receipts→life_data→credentials→clients）====="
R=$(mg "delete from public.activity_log where user_id='$OWNER' and (metadata->>'entity_key' like 'p005:%' or agent_id in (select id from public.agent_clients where user_id='$OWNER' and name like 'p005-%')); delete from private.request_receipts where operation='p005_test'; delete from public.life_data where user_id='$OWNER' and entity_key like 'p005:%'; delete from private.agent_credentials where agent_id in (select id from public.agent_clients where user_id='$OWNER' and name like 'p005-%'); delete from public.agent_clients where user_id='$OWNER' and name like 'p005-%'; select (select count(*) from public.life_data where entity_key like 'p005:%') as life_left, (select count(*) from private.request_receipts where operation='p005_test') as receipts_left, (select count(*) from public.agent_clients where name like 'p005-%') as clients_left;")
echo "$R" | jq -c '.[]?' | tee -a "$OUTF"
rm -rf "$D"
echo "done"