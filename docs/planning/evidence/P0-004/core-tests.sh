#!/bin/bash
# P0-004 Core 框架实证矩阵 —— 每用例独立 Management API 调用，原始响应落盘。
# 方法: public RPC 经 SET LOCAL ROLE authenticated + request.jwt.claims 模拟 owner JWT；
#       core_test_write_v1 为测试专用入口（仅 postgres 可执行），驱动 LWW/OCC/并发/回滚。
# 凭据纪律: PAT 只经 keychain 注入，不打印不落盘；测试 token_hash 为本地 sha256 测试值。
set -u
PAT=$(security find-generic-password -a "$USER" -s MORROW_SUPABASE_ACCESS_TOKEN -w 2>/dev/null)
[ -z "$PAT" ] && { echo "KEYCHAIN_PAT_MISSING"; exit 1; }
URL="https://api.supabase.com/v1/projects/umutubzcwwmmbxfjkyvj/database/query"
OWNER="0c645909-ebb5-4910-ab99-4f7b238c9529"
NONOWNER="11111111-2222-4333-8444-555555555555"
NIL="00000000-0000-0000-0000-000000000000"
PASS=0; FAIL=0
TMPD=$(mktemp -d /tmp/p4test.XXXXXX)

mg() { jq -n --arg q "$1" '{query:$q}' | curl -sS -X POST "$URL" -H "Authorization: Bearer $PAT" -H "Content-Type: application/json" -d @-; }
rpc_as() { # $1=role $2=sub $3=fn $4=envelope
  local env_sql; env_sql=$(printf '%s' "$4" | sed "s/'/''/g")
  mg "begin; set local role $1; set local \"request.jwt.claims\" = '{\"sub\":\"$2\",\"role\":\"$1\"}'; select public.$3('$env_sql'::jsonb) as r; commit;"
}
rpc_owner() { rpc_as authenticated "$OWNER" "$1" "$2"; }
ct() { # $1=atype $2=aid $3=key $4=input-json
  local inp; inp=$(printf '%s' "$4" | sed "s/'/''/g")
  mg "select private.core_test_write_v1('$1','$2','$3'::uuid,'p4_test','$inp'::jsonb) as r;"
}
ck() { # $1=name $2=response $3=jq-filter
  if printf '%s' "$2" | jq -e "$3" >/dev/null 2>&1; then echo "PASS  $1"; PASS=$((PASS+1));
  else echo "FAIL  $1"; printf '  resp: %.500s\n' "$2"; FAIL=$((FAIL+1)); fi
}
uuid() { uuidgen | tr 'A-F' 'a-f'; }
ap() { # $1=note $2=entity_key
  jq -nc --arg n "$1" --arg k "$2" '{module:"anchor",entity_key:$k,biz_date:"2026-09-17",payload:{payload_v:1,anchor_type:"wake",timezone:"Asia/Shanghai",target_at:"2026-09-17T06:50:00+08:00",actual_at:"2026-09-17T06:47:00+08:00",status:"recorded",planned:true,note:$n,plan_version:"1"}}'
}
env_init() { jq -nc --arg k "$1" '{api_version:"1",idempotency_key:$k,input:{timezone:"Asia/Shanghai",tracking_started_on:"2026-09-17",weekday_codes:{mon:"ordinary_workday",tue:"ordinary_workday",wed:"ordinary_workday",thu:"ordinary_workday",fri:"ordinary_workday",sat:"weekend",sun:"weekend"}}}'; }
rev_now() { mg "select data_revision::text as r from public.workspace_state where user_id='$OWNER';" | jq -r '.[0].r'; }
cnt() { mg "$1" | jq -r '.[0].n'; }
EXP89=$(date -u -v+89d +"%Y-%m-%dT%H:%M:%SZ")
RUNSALT=$(uuid)
H1=$(printf 'p0test-token-1-%s' "$RUNSALT" | shasum -a 256 | awk '{print $1}')
H2=$(printf 'p0test-token-2-%s' "$RUNSALT" | shasum -a 256 | awk '{print $1}')

echo "===== 0. 清场（postgres 运维：scoped owner，保留 workspace_owner/workspace_state 行） ====="
# 首轮 K 系列已占用 H1-H5 凭据 hash 的 unique 约束；E-H 经异常回滚无残留。
# DELETE 无 trigger（BEFORE UPDATE / AFTER INSERT|UPDATE 不覆盖），无需 actor 上下文。
R=$(mg "delete from private.request_receipts where user_id='$OWNER'; delete from public.activity_log where user_id='$OWNER'; delete from private.agent_credentials where agent_id in (select id from public.agent_clients where user_id='$OWNER'); delete from public.agent_clients where user_id='$OWNER'; delete from public.life_data where user_id='$OWNER'; delete from public.workspace_settings where user_id='$OWNER'; update public.workspace_state set data_revision=0, updated_at=now() where user_id='$OWNER'; select (select count(*) from private.request_receipts)::text as rc, (select count(*) from public.activity_log)::text as ac, (select count(*) from public.agent_clients)::text as cc, (select count(*) from public.life_data)::text as lc, (select count(*) from public.workspace_settings)::text as sc, (select data_revision::text from public.workspace_state where user_id='$OWNER') as rev;")
ck Z0_clean_slate "$R" '.[0].rc=="0" and .[0].ac=="0" and .[0].cc=="0" and .[0].lc=="0" and .[0].sc=="0" and .[0].rev=="0"'

echo "===== A. RPC 角色白名单 / grants ====="
R=$(rpc_as anon "$NONOWNER" initialize_workspace_v1 "$(env_init "$(uuid)")")
ck A1_anon_rpc_denied "$R" 'tostring | test("42501|permission denied")'
R=$(mg "begin; set local role authenticated; set local \"request.jwt.claims\" = '{\"sub\":\"$OWNER\",\"role\":\"authenticated\"}'; select * from private.receipt_begin('$OWNER','human','$OWNER','$(uuid)'::uuid,'x','{}'::jsonb); rollback;")
ck A2_helper_no_execute "$R" 'tostring | test("42501|permission denied")'
R=$(mg "begin; set local role authenticated; set local \"request.jwt.claims\" = '{\"sub\":\"$OWNER\",\"role\":\"authenticated\"}'; select private.core_test_write_v1('human','$OWNER','$(uuid)'::uuid,'x','{}'::jsonb); rollback;")
ck A3_test_entry_no_execute "$R" 'tostring | test("42501|permission denied")'
R=$(rpc_as service_role "$NIL" initialize_workspace_v1 "$(env_init "$(uuid)")")
ck A4_service_role_rpc_denied "$R" 'tostring | test("42501|permission denied")'

echo "===== B. Human 直 DML 拒绝（P0-003 回归） ====="
R=$(mg "begin; set local role authenticated; set local \"request.jwt.claims\" = '{\"sub\":\"$OWNER\",\"role\":\"authenticated\"}'; update public.life_data set payload='{}' where user_id='$OWNER'; rollback;")
ck B1_owner_direct_dml_denied "$R" 'tostring | test("42501|permission denied")'

echo "===== C. 伪造拒绝 ====="
ENVF=$(jq -nc --arg k "$(uuid)" '{api_version:"1",idempotency_key:$k,input:{timezone:"Asia/Shanghai",tracking_started_on:"2026-09-17",user_id:"'$NONOWNER'",weekday_codes:{mon:"ordinary_workday",tue:"ordinary_workday",wed:"ordinary_workday",thu:"ordinary_workday",fri:"ordinary_workday",sat:"weekend",sun:"weekend"}}}')
R=$(rpc_owner initialize_workspace_v1 "$ENVF")
ck C1_forged_user_id_rejected "$R" '.[0].r.ok==false and .[0].r.error.code=="VALIDATION_FAILED"'
ENVF2=$(jq -nc --arg k "$(uuid)" '{api_version:"1",idempotency_key:$k,expected_version:"0",input:{timezone:"Asia/Shanghai",tracking_started_on:"2026-09-17",weekday_codes:{mon:"ordinary_workday",tue:"ordinary_workday",wed:"ordinary_workday",thu:"ordinary_workday",fri:"ordinary_workday",sat:"weekend",sun:"weekend"}}}')
R=$(rpc_owner initialize_workspace_v1 "$ENVF2")
ck C2_human_expected_version_rejected "$R" '.[0].r.ok==false and .[0].r.error.code=="VALIDATION_FAILED"'
ENVC3=$(env_init "$(uuid)"); ENVC3_SQL=$(printf '%s' "$ENVC3" | sed "s/'/''/g")
R=$(mg "begin; set local role authenticated; set local \"request.jwt.claims\" = '{\"sub\":\"$OWNER\",\"role\":\"authenticated\"}'; select private.cmd_initialize_workspace_v1('$NONOWNER','$ENVC3_SQL'::jsonb) as r; rollback;")
ck C3_forged_puid_denied "$R" '.[0].r.ok==false and .[0].r.error.code=="OWNER_DENIED"'
R=$(rpc_as authenticated "$NONOWNER" initialize_workspace_v1 "$(env_init "$(uuid)")")
ck C4_nonowner_denied "$R" '.[0].r.ok==false and .[0].r.error.code=="OWNER_DENIED"'

echo "===== D. 可信 actor 上下文（trigger 层） ====="
R=$(mg "insert into public.life_data (user_id,module,entity_key,biz_date,payload,source_type,source_id) values ('$OWNER','anchor','p0test:no-actor','2026-09-17','{\"payload_v\":1}'::jsonb,'human','$OWNER');")
ck D1_insert_without_actor_rejected "$R" 'tostring | test("actor_context_missing")'
R=$(mg "begin; select set_config('morrow.actor','system:$NIL',true); insert into public.life_data (user_id,module,entity_key,biz_date,payload,source_type,source_id) values ('$OWNER','anchor','p0test:actor-src','2026-09-17','{\"payload_v\":1}'::jsonb,'human','$OWNER'); select source_type, source_id::text, version::text from public.life_data where entity_key='p0test:actor-src'; commit;")
ck D2_source_forced_from_actor "$R" '.[0].source_type=="system" and .[0].source_id=="'$NIL'" and .[0].version=="1"'

echo "===== L. initialize_workspace（先并发，再重复/重放） ====="
KA=$(uuid); KB=$(uuid)
ENVA=$(env_init "$KA"); ENVB=$(env_init "$KB")
( rpc_owner initialize_workspace_v1 "$ENVA" > "$TMPD/init_a.json" ) &
( rpc_owner initialize_workspace_v1 "$ENVB" > "$TMPD/init_b.json" ) &
wait
OKA=$(jq -r '.[0].r.ok' "$TMPD/init_a.json" 2>/dev/null); OKB=$(jq -r '.[0].r.ok' "$TMPD/init_b.json" 2>/dev/null)
SC=$(cnt "select count(*)::text as n from public.workspace_settings;")
if { [ "$OKA" = "true" ] && [ "$OKB" = "false" ]; } || { [ "$OKA" = "false" ] && [ "$OKB" = "true" ]; } && [ "$SC" = "1" ]; then
  echo "PASS  L1_concurrent_init_only_once (a.ok=$OKA b.ok=$OKB settings=$SC)"; PASS=$((PASS+1))
else
  echo "FAIL  L1_concurrent_init_only_once (a.ok=$OKA b.ok=$OKB settings=$SC)"; head -c 400 "$TMPD/init_a.json" "$TMPD/init_b.json"; FAIL=$((FAIL+1))
fi
LOSERS_CODE=$(jq -r 'if .[0].r.ok==false then .[0].r.error.code else "winner" end' "$TMPD/init_a.json" 2>/dev/null)
if [ "$OKA" = "true" ]; then WIN_ENV="$ENVA"; else WIN_ENV="$ENVB"; fi
R=$(rpc_owner initialize_workspace_v1 "$(env_init "$(uuid)")")
ck L2_second_init_rejected "$R" '.[0].r.ok==false and .[0].r.error.code=="ALREADY_EXISTS"'
R=$(rpc_owner initialize_workspace_v1 "$WIN_ENV")
ck L3_same_key_replay "$R" '.[0].r.ok==true and .[0].r.replayed==true and .[0].r.result.record.version=="1"'
R=$(mg "select version::text as v, timezone, schedule_history from public.workspace_settings where user_id='$OWNER';")
ck L4_settings_row "$R" '.[0].v=="1" and .[0].timezone=="Asia/Shanghai" and (.[0].schedule_history|length)==1'

echo "===== K. manage_health_client（create/rotate/revoke/幂等/锁序并发） ====="
K1KEY=$(uuid); CRED1=$(uuid)
ENVK1=$(jq -nc --arg k "$K1KEY" --arg c "$CRED1" --arg h "$H1" --arg e "$EXP89" '{api_version:"1",idempotency_key:$k,input:{action:"create",name:"p0test-health",type:"local",credential_id:$c,token_hash:$h,expires_at:$e}}')
R=$(rpc_owner manage_health_client_v1 "$ENVK1")
ck K1_create "$R" '.[0].r.ok==true and .[0].r.result.enabled==true and .[0].r.result.scopes==["system:health"] and .[0].r.result.version=="1"'
CLIENT=$(printf '%s' "$R" | jq -r '.[0].r.result.client_id // empty')
[ -z "$CLIENT" ] && { echo "ABORT: no client_id"; exit 1; }
CC1=$(cnt "select count(*)::text as n from public.agent_clients;")
R=$(rpc_owner manage_health_client_v1 "$ENVK1")
CC2=$(cnt "select count(*)::text as n from public.agent_clients;")
ck K2_replay_no_dup "$R" '.[0].r.ok==true and .[0].r.replayed==true and .[0].r.result.client_id=="'$CLIENT'"'
[ "$CC1" = "$CC2" ] && { echo "PASS  K2b_replay_no_extra_client"; PASS=$((PASS+1)); } || { echo "FAIL  K2b_replay_no_extra_client ($CC1->$CC2)"; FAIL=$((FAIL+1)); }
ENVK3=$(jq -nc --arg k "$K1KEY" --arg c "$(uuid)" --arg h "$H2" --arg e "$EXP89" '{api_version:"1",idempotency_key:$k,input:{action:"create",name:"p0test-health-x",type:"local",credential_id:$c,token_hash:$h,expires_at:$e}}')
R=$(rpc_owner manage_health_client_v1 "$ENVK3")
ck K3_same_key_diff_input_409 "$R" '.[0].r.ok==false and .[0].r.error.code=="IDEMPOTENCY_KEY_REUSED"'
CRED2=$(uuid)
ENVK4=$(jq -nc --arg k "$(uuid)" --arg cl "$CLIENT" --arg c "$CRED2" --arg h "$H2" --arg e "$EXP89" '{api_version:"1",idempotency_key:$k,input:{action:"rotate",client_id:$cl,credential_id:$c,token_hash:$h,expires_at:$e}}')
R=$(rpc_owner manage_health_client_v1 "$ENVK4")
ck K4_rotate "$R" '.[0].r.ok==true and .[0].r.result.credential_id=="'$CRED2'" and .[0].r.result.version=="1"'
R=$(mg "select (expires_at <= now() + interval '24 hours' + interval '1 minute') as t from private.agent_credentials where id='$CRED1';")
ck K4b_old_cred_tightened_24h "$R" '.[0].t==true'
# K7 同 key 并发 create：只有一个 client/凭据
K7KEY=$(uuid); CRED3=$(uuid); H3=$(printf 'p0test-token-3-%s' "$RUNSALT" | shasum -a 256 | awk '{print $1}')
ENVK7=$(jq -nc --arg k "$K7KEY" --arg c "$CRED3" --arg h "$H3" --arg e "$EXP89" '{api_version:"1",idempotency_key:$k,input:{action:"create",name:"p0test-conc",type:"scheduled",credential_id:$c,token_hash:$h,expires_at:$e}}')
CC_B=$(cnt "select count(*)::text as n from public.agent_clients;")
( rpc_owner manage_health_client_v1 "$ENVK7" > "$TMPD/k7a.json" ) &
( rpc_owner manage_health_client_v1 "$ENVK7" > "$TMPD/k7b.json" ) &
wait
CC_A=$(cnt "select count(*)::text as n from public.agent_clients;")
K7A_CL=$(jq -r '.[0].r.result.client_id // empty' "$TMPD/k7a.json" 2>/dev/null)
K7B_CL=$(jq -r '.[0].r.result.client_id // empty' "$TMPD/k7b.json" 2>/dev/null)
K7_OK=$(jq -r '.[0].r.ok' "$TMPD/k7a.json" 2>/dev/null)$(jq -r '.[0].r.ok' "$TMPD/k7b.json" 2>/dev/null)
if [ "$K7A_CL" = "$K7B_CL" ] && [ -n "$K7A_CL" ] && [ "$K7_OK" = "truetrue" ] && [ "$CC_A" = "$((CC_B+1))" ]; then
  echo "PASS  K7_concurrent_same_key_create_single"; PASS=$((PASS+1))
else
  echo "FAIL  K7_concurrent_same_key_create_single ($K7_OK $K7A_CL/$K7B_CL cnt $CC_B->$CC_A)"; FAIL=$((FAIL+1))
fi
# K8 create ‖ rotate 并发：无反向锁等待（双方完成）
CRED4=$(uuid); H4=$(printf 'p0test-token-4-%s' "$RUNSALT" | shasum -a 256 | awk '{print $1}')
CRED5=$(uuid); H5=$(printf 'p0test-token-5-%s' "$RUNSALT" | shasum -a 256 | awk '{print $1}')
ENVK8A=$(jq -nc --arg k "$(uuid)" --arg c "$CRED4" --arg h "$H4" --arg e "$EXP89" '{api_version:"1",idempotency_key:$k,input:{action:"create",name:"p0test-conc2",type:"remote",credential_id:$c,token_hash:$h,expires_at:$e}}')
ENVK8B=$(jq -nc --arg k "$(uuid)" --arg cl "$CLIENT" --arg c "$CRED5" --arg h "$H5" --arg e "$EXP89" '{api_version:"1",idempotency_key:$k,input:{action:"rotate",client_id:$cl,credential_id:$c,token_hash:$h,expires_at:$e}}')
( rpc_owner manage_health_client_v1 "$ENVK8A" > "$TMPD/k8a.json" ) &
( rpc_owner manage_health_client_v1 "$ENVK8B" > "$TMPD/k8b.json" ) &
wait
K8A_OK=$(jq -r '.[0].r.ok // false' "$TMPD/k8a.json" 2>/dev/null); K8B_OK=$(jq -r '.[0].r.ok // false' "$TMPD/k8b.json" 2>/dev/null)
if [ "$K8A_OK" = "true" ] && [ "$K8B_OK" = "true" ]; then echo "PASS  K8b_both_completed"; PASS=$((PASS+1)); else echo "FAIL  K8b_both_completed (a=$K8A_OK b=$K8B_OK)"; head -c 300 "$TMPD/k8a.json" "$TMPD/k8b.json"; FAIL=$((FAIL+1)); fi
# K5 revoke credential（CRED1）×2
ENVK5=$(jq -nc --arg k "$(uuid)" --arg cl "$CLIENT" --arg c "$CRED1" '{api_version:"1",idempotency_key:$k,input:{action:"revoke",client_id:$cl,target:"credential",credential_id:$c}}')
R=$(rpc_owner manage_health_client_v1 "$ENVK5")
ck K5_revoke_credential "$R" '.[0].r.ok==true and .[0].r.result.no_change==false'
R=$(rpc_owner manage_health_client_v1 "$ENVK5")
ck K5b_revoke_replay "$R" '.[0].r.ok==true and .[0].r.replayed==true'
ENVK5C=$(jq -nc --arg k "$(uuid)" --arg cl "$CLIENT" --arg c "$CRED1" '{api_version:"1",idempotency_key:$k,input:{action:"revoke",client_id:$cl,target:"credential",credential_id:$c}}')
R=$(rpc_owner manage_health_client_v1 "$ENVK5C")
ck K5c_revoke_again_no_change "$R" '.[0].r.ok==true and .[0].r.result.no_change==true'

echo "===== E. 有效更新增版 / no-op 不增（agent create + human LWW + agent OCC） ====="
EK="p0test:anchor-1"
R=$(ct agent "$CLIENT" "$(uuid)" "$(ap 'e1' "$EK" | jq '. + {expected_version:"0"}')")
ck E1_agent_create "$R" '.[0].r.ok==true and .[0].r.result.result=="created" and .[0].r.result.version=="1"'
R=$(ct human "$OWNER" "$(uuid)" "$(ap 'e2' "$EK")")
ck E2_human_update "$R" '.[0].r.ok==true and .[0].r.result.result=="changed" and .[0].r.result.version=="2"'
R=$(ct human "$OWNER" "$(uuid)" "$(ap 'e2' "$EK")")
ck E3_noop_no_bump "$R" '.[0].r.ok==true and .[0].r.result.result=="no_change" and .[0].r.result.version=="2"'
R=$(ct agent "$CLIENT" "$(uuid)" "$(ap 'e4' "$EK" | jq '. + {expected_version:"2"}')")
ck E4_agent_occ_update "$R" '.[0].r.ok==true and .[0].r.result.version=="3"'
R=$(ct agent "$CLIENT" "$(uuid)" "$(ap 'e5' "$EK" | jq '. + {expected_version:"2"}')")
ck E5_stale_version_conflict "$R" '.[0].r.ok==false and .[0].r.error.code=="VERSION_CONFLICT" and .[0].r.error.details.current_version=="3"'
R=$(ct agent "$CLIENT" "$(uuid)" "$(ap 'e5b' "$EK")")
ck E5b_agent_missing_expected_rejected "$R" '.[0].r.ok==false and .[0].r.error.code=="VALIDATION_FAILED"'
R=$(ct human "$OWNER" "$(uuid)" "$(ap 'e5c' "$EK" | jq '. + {expected_version:"3"}')")
ck E5c_human_with_expected_rejected "$R" '.[0].r.ok==false and .[0].r.error.code=="VALIDATION_FAILED"'
RID=$(mg "select id::text as i from public.life_data where user_id='$OWNER' and entity_key='$EK';" | jq -r '.[0].i')
LC=$(cnt "select count(*)::text as n from public.activity_log where resource='life_data' and resource_id='$RID' and action in ('life_data.insert','life_data.update');")
if [ "$LC" = "3" ]; then echo "PASS  E6_single_audit_source(3)"; PASS=$((PASS+1)); else echo "FAIL  E6_single_audit_source($LC!=3)"; FAIL=$((FAIL+1)); fi

echo "===== F. 幂等（core 框架级） ====="
F1KEY=$(uuid); F1INP=$(ap 'f1' 'p0test:anchor-f1' | jq '. + {expected_version:"0"}')
R1=$(ct agent "$CLIENT" "$F1KEY" "$F1INP")
VC1=$(mg "select count(*)::text as n from public.life_data where entity_key='p0test:anchor-f1';" | jq -r '.[0].n')
R2=$(ct agent "$CLIENT" "$F1KEY" "$F1INP")
VC2=$(mg "select count(*)::text as n from public.life_data where entity_key='p0test:anchor-f1';" | jq -r '.[0].n')
ck F1_replay "$R2" '.[0].r.ok==true and .[0].r.replayed==true'
[ "$VC1" = "1" ] && [ "$VC2" = "1" ] && { echo "PASS  F1b_replay_no_rewrite"; PASS=$((PASS+1)); } || { echo "FAIL  F1b_replay_no_rewrite ($VC1/$VC2)"; FAIL=$((FAIL+1)); }
R=$(ct agent "$CLIENT" "$F1KEY" "$(ap 'f1-diff' 'p0test:anchor-f1' | jq '. + {expected_version:"0"}')")
ck F2_same_key_diff_input_409 "$R" '.[0].r.ok==false and .[0].r.error.code=="IDEMPOTENCY_KEY_REUSED"'

echo "===== G. create0 不覆盖 / tombstone ====="
R=$(ct agent "$CLIENT" "$(uuid)" "$(ap 'g1' "$EK" | jq '. + {expected_version:"0"}')")
ck G1_create0_existing_409 "$R" '.[0].r.ok==false and .[0].r.error.code=="ALREADY_EXISTS"'
R=$(ct agent "$CLIENT" "$(uuid)" "$(ap 'g2' 'p0test:anchor-tomb' | jq '. + {expected_version:"0"}')")
ck G2a_seed "$R" '.[0].r.ok==true'
mg "begin; select set_config('morrow.actor','system:$NIL',true); update public.life_data set deleted_at=now() where user_id='$OWNER' and entity_key='p0test:anchor-tomb'; commit;" >/dev/null
R=$(ct agent "$CLIENT" "$(uuid)" "$(ap 'g2b' 'p0test:anchor-tomb' | jq '. + {expected_version:"0"}')")
ck G2b_create_on_tombstone_410 "$R" '.[0].r.ok==false and .[0].r.error.code=="RESOURCE_DELETED"'
R=$(mg "select version::text as v from public.life_data where entity_key='p0test:anchor-tomb';")
ck G2c_tombstone_bumped_version "$R" '.[0].v=="2"'

echo "===== H. 技术故障整体回滚 ====="
REV0=$(rev_now); RC0=$(cnt "select count(*)::text as n from private.request_receipts;")
LC0=$(cnt "select count(*)::text as n from public.life_data;"); AC0=$(cnt "select count(*)::text as n from public.activity_log;")
R=$(ct agent "$CLIENT" "$(uuid)" "$(ap 'h1' 'p0test:anchor-fault' | jq '. + {expected_version:"0",fault:"after_business_write"}')")
ck H1_fault_raises "$R" 'tostring | test("injected_fault")'
REV1=$(rev_now); RC1=$(cnt "select count(*)::text as n from private.request_receipts;")
LC1=$(cnt "select count(*)::text as n from public.life_data;"); AC1=$(cnt "select count(*)::text as n from public.activity_log;")
if [ "$REV0" = "$REV1" ] && [ "$RC0" = "$RC1" ] && [ "$LC0" = "$LC1" ] && [ "$AC0" = "$AC1" ]; then
  echo "PASS  H2_full_rollback (rev=$REV1 receipts=$RC1 life=$LC1 activity=$AC1)"; PASS=$((PASS+1))
else
  echo "FAIL  H2_full_rollback (rev $REV0->$REV1 receipts $RC0->$RC1 life $LC0->$LC1 activity $AC0->$AC1)"; FAIL=$((FAIL+1))
fi

echo "===== I. T03 20 并发有效更新无重号（Review 深审条件 1） ====="
BASE=$(mg "select version::text as v from public.life_data where user_id='$OWNER' and entity_key='$EK';" | jq -r '.[0].v')
for i in $(seq 1 20); do
  ( ct human "$OWNER" "$(uuid)" "$(ap "conc-$i" "$EK")" > "$TMPD/c_$i.json" ) &
done
wait
OKN=0; : > "$TMPD/vers.txt"
for i in $(seq 1 20); do
  OK=$(jq -r '.[0].r.ok // false' "$TMPD/c_$i.json" 2>/dev/null)
  [ "$OK" = "true" ] && OKN=$((OKN+1))
  jq -r '.[0].r.result.version // empty' "$TMPD/c_$i.json" 2>/dev/null >> "$TMPD/vers.txt"
done
UNIQ=$(sort -n "$TMPD/vers.txt" | uniq | wc -l | tr -d ' ')
FINAL=$(mg "select version::text as v from public.life_data where user_id='$OWNER' and entity_key='$EK';" | jq -r '.[0].v')
MINV=$(sort -n "$TMPD/vers.txt" | head -1); MAXV=$(sort -n "$TMPD/vers.txt" | tail -1)
echo "  versions: $UNIQ unique, range $MINV..$MAXV, base=$BASE final=$FINAL ok=$OKN"
if [ "$OKN" = "20" ] && [ "$UNIQ" = "20" ] && [ "$MINV" = "$((BASE+1))" ] && [ "$MAXV" = "$((BASE+20))" ] && [ "$FINAL" = "$((BASE+20))" ]; then
  echo "PASS  T03_20concurrent_unique_versions"; PASS=$((PASS+1))
else
  echo "FAIL  T03_20concurrent_unique_versions"; FAIL=$((FAIL+1))
fi

echo "===== J. T04 双 agent 同 expected_version 并发：仅一成功 ====="
CUR=$(mg "select version::text as v from public.life_data where user_id='$OWNER' and entity_key='$EK';" | jq -r '.[0].v')
INPJ_A=$(ap 'occ-a' "$EK" | jq --arg v "$CUR" '. + {expected_version:$v}')
INPJ_B=$(ap 'occ-b' "$EK" | jq --arg v "$CUR" '. + {expected_version:$v}')
( ct agent "$CLIENT" "$(uuid)" "$INPJ_A" > "$TMPD/occ_a.json" ) &
( ct agent "$CLIENT" "$(uuid)" "$INPJ_B" > "$TMPD/occ_b.json" ) &
wait
JA=$(jq -r 'if .[0].r.ok then "ok" else .[0].r.error.code end' "$TMPD/occ_a.json" 2>/dev/null)
JB=$(jq -r 'if .[0].r.ok then "ok" else .[0].r.error.code end' "$TMPD/occ_b.json" 2>/dev/null)
FINALJ=$(mg "select version::text as v from public.life_data where user_id='$OWNER' and entity_key='$EK';" | jq -r '.[0].v')
echo "  a=$JA b=$JB final=$FINALJ (expected $((CUR+1)))"
if { [ "$JA" = "ok" ] && [ "$JB" = "VERSION_CONFLICT" ]; } || { [ "$JA" = "VERSION_CONFLICT" ] && [ "$JB" = "ok" ]; } && [ "$FINALJ" = "$((CUR+1))" ]; then
  echo "PASS  T04_occ_single_winner"; PASS=$((PASS+1))
else
  echo "FAIL  T04_occ_single_winner"; FAIL=$((FAIL+1))
fi

echo "===== K6. revoke client ×2（锁序 client→credentials→state→receipt） ====="
ENVK6=$(jq -nc --arg k "$(uuid)" --arg cl "$CLIENT" '{api_version:"1",idempotency_key:$k,input:{action:"revoke",client_id:$cl,target:"client"}}')
R=$(rpc_owner manage_health_client_v1 "$ENVK6")
ck K6_revoke_client "$R" '.[0].r.ok==true and .[0].r.result.no_change==false and .[0].r.result.version=="2"'
R=$(mg "select enabled, (revoked_at is not null) as rv from public.agent_clients where id='$CLIENT';")
ck K6b_client_disabled "$R" '.[0].enabled==false and .[0].rv==true'
R=$(mg "select count(*)::text as n from private.agent_credentials where agent_id='$CLIENT' and revoked_at is null;")
ck K6c_all_creds_revoked "$R" '.[0].n=="0"'
ENVK6B=$(jq -nc --arg k "$(uuid)" --arg cl "$CLIENT" '{api_version:"1",idempotency_key:$k,input:{action:"revoke",client_id:$cl,target:"client"}}')
R=$(rpc_owner manage_health_client_v1 "$ENVK6B")
ck K6d_revoke_again_no_change "$R" '.[0].r.ok==true and .[0].r.result.no_change==true'
K6EKEY=$(uuid); K6ECL=$(uuid)
ENVK6E=$(jq -nc --arg k "$K6EKEY" --arg cl "$K6ECL" '{api_version:"1",idempotency_key:$k,input:{action:"revoke",client_id:$cl,target:"client"}}')
R=$(rpc_owner manage_health_client_v1 "$ENVK6E")
ck K6e_revoke_unknown_client_404 "$R" '.[0].r.ok==false and .[0].r.error.code=="RESOURCE_NOT_FOUND"'
R=$(rpc_owner manage_health_client_v1 "$ENVK6E")
ck K6f_reject_replay "$R" '.[0].r.ok==false and .[0].r.error.code=="RESOURCE_NOT_FOUND" and .[0].r.replayed==true'
# K9 预检分支回归（0010 修复 receipt_state_invalid 的同类路径）
R=$(rpc_owner manage_health_client_v1 "$(jq -nc --arg k "$(uuid)" '{api_version:"1",idempotency_key:$k,input:{action:"nuke"}}')")
ck K9a_bad_action_rejected "$R" '.[0].r.ok==false and .[0].r.error.code=="VALIDATION_FAILED"'
R=$(rpc_owner manage_health_client_v1 "$(jq -nc --arg k "$(uuid)" --arg h "$H1" --arg e "$EXP89" '{api_version:"1",idempotency_key:$k,input:{action:"create",name:"x",type:"local",credential_id:"00000000-0000-4000-8000-000000000099",token_hash:$h,expires_at:$e,user_id:"'$OWNER'"}}')")
ck K9b_unknown_field_rejected "$R" '.[0].r.ok==false and .[0].r.error.code=="VALIDATION_FAILED"'
R=$(rpc_owner manage_health_client_v1 "$(jq -nc --arg k "$(uuid)" '{api_version:"1",idempotency_key:$k,input:{action:"revoke",client_id:"not-a-uuid",target:"client"}}')")
ck K9c_bad_client_id_rejected "$R" '.[0].r.ok==false and .[0].r.error.code=="VALIDATION_FAILED"'

echo "===== M. token 保密 ====="
ck M1_response_no_hash "$(cat "$TMPD/k7a.json")" '.[0].r.result | has("token_hash") | not'
R=$(mg "select count(*)::text as n from private.request_receipts where response::text ilike '%$H1%';")
ck M2_receipts_no_token_hash "$R" '.[0].n=="0"'
R=$(mg "select count(*)::text as n from public.activity_log where metadata::text ilike '%$H1%';")
ck M3_activity_no_token_hash "$R" '.[0].n=="0"'

echo "===== N. 只读收据 / revision ====="
NB=$(cnt "select count(*)::text as n from private.request_receipts;"); REVB=$(rev_now)
R=$(rpc_owner get_command_result_v1 "$(jq -nc --arg k "$(uuid)" --arg t "$(uuid)" '{api_version:"1",idempotency_key:$k,input:{idempotency_key:$t}}')")
ck N1_unknown_key_404 "$R" '.[0].r.ok==false and .[0].r.error.code=="RESOURCE_NOT_FOUND"'
NA=$(cnt "select count(*)::text as n from private.request_receipts;"); REVA=$(rev_now)
[ "$NB" = "$NA" ] && [ "$REVB" = "$REVA" ] && { echo "PASS  N1b_readonly_no_side_effect"; PASS=$((PASS+1)); } || { echo "FAIL  N1b_readonly_no_side_effect (receipts $NB->$NA rev $REVB->$REVA)"; FAIL=$((FAIL+1)); }
WINKEY=$KA; [ "$OKA" != "true" ] && WINKEY=$KB
R=$(rpc_owner get_command_result_v1 "$(jq -nc --arg k "$(uuid)" --arg t "$WINKEY" '{api_version:"1",idempotency_key:$k,input:{idempotency_key:$t}}')")
ck N2_known_receipt "$R" '.[0].r.ok==true and .[0].r.result.state=="completed" and .[0].r.result.operation=="initialize_workspace_v1"'
R=$(rpc_owner get_workspace_revision_v1 "$(jq -nc --arg k "$(uuid)" '{api_version:"1",idempotency_key:$k,input:{}}')")
ck N3_revision_string "$R" '.[0].r.ok==true and (.[0].r.data_revision|test("^[0-9]+$"))'

echo "===== O. last_seen 不增 client 版 / 但 bump revision / 无配置日志 ====="
V0=$(mg "select version::text as v from public.agent_clients where id='$CLIENT';" | jq -r '.[0].v')
REV0=$(rev_now); AL0=$(cnt "select count(*)::text as n from public.activity_log where resource='agent_clients' and resource_id='$CLIENT';")
mg "begin; select set_config('morrow.actor','system:$NIL',true); update public.agent_clients set last_seen_at=now() where id='$CLIENT'; commit;" >/dev/null
V1=$(mg "select version::text as v from public.agent_clients where id='$CLIENT';" | jq -r '.[0].v')
REV1=$(rev_now); AL1=$(cnt "select count(*)::text as n from public.activity_log where resource='agent_clients' and resource_id='$CLIENT';")
if [ "$V0" = "$V1" ] && [ "$REV1" = "$((REV0+1))" ] && [ "$AL0" = "$AL1" ]; then
  echo "PASS  O1_last_seen_semantics (v=$V1 rev $REV0->$REV1 logs=$AL1)"; PASS=$((PASS+1))
else
  echo "FAIL  O1_last_seen_semantics (v $V0->$V1 rev $REV0->$REV1 logs $AL0->$AL1)"; FAIL=$((FAIL+1))
fi

echo "===== 复位：删除测试用 settings 行（postgres 运维复位，供未来真实初始化） ====="
R=$(mg "delete from public.workspace_settings where user_id='$OWNER'; select count(*)::text as n from public.workspace_settings;")
ck Z1_settings_reset "$R" '.[0].n=="0"'

echo
echo "===== SUMMARY: PASS=$PASS FAIL=$FAIL ====="
rm -rf "$TMPD"
