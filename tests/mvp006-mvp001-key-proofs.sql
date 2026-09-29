-- MVP-006 工程窄验收 / mvp001 关键 proof 复验（A16 补充证据）
--
-- 背景：tests/mvp001-business-core.sql T00 前置要求真库零数据（MVP-001 验收时成立）；
-- 现真库有 A26 真实使用数据（2026-09-23 物化 3 anchor + 1 day_type），全量原样复跑不可行。
-- 本探针取 mvp001 关键 proof 在当前真库演进态下复验（覆盖映射记入 result.md）：
--   T01 真实历史日 context 只读投影（F01 分母/next_action/stats）
--   T02 未物化日 context 只读不物化（C-02 计划落地 2）
--   T03 F01 打卡语义：deviation -3 / target_met / plan_locked 首日锁 / 审计同事务
--   T04 Human 幂等 replay：同 key 重放零二次写（A06）
--   T05 F08 归属窗口：次日 00:30 归前日 / 跨本地日拒
--   T06 F02 迟到仍计分子：deviation +20 / recorded 但未达标
--   T07 信封纪律：未知字段拒 / Human 禁 expected_version
-- 全部写入随事务回滚（单 DO 块 + 末尾 RAISE 携带 MVP006_KEY_PROOFS），零残留。

do $$
declare
  v_owner uuid;
  v_proof jsonb := '[]'::jsonb;
  v_env jsonb;
  v_r jsonb;
  v_ctx jsonb;
  v_a jsonb;
  v_key uuid;
  v_req uuid;
  v_ver text;
  v_audit int;
begin
  select o.user_id into v_owner from private.workspace_owner o limit 1;
  if not found then
    raise exception 'SETUP_FAIL: workspace_owner 为空';
  end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner::text, 'role', 'authenticated')::text, true);
  perform private.cmd_set_actor('human', v_owner);

  -- T00 前置：真实数据演进态如实断言（2026-09-23 周三训练日：3 anchor + 1 day_type，均无 actual）
  if (select count(*) from public.life_data d
      where d.user_id = v_owner and d.biz_date = '2026-09-23'
        and d.entity_key not like 'p0test:%') <> 4 then
    raise exception 'SETUP_FAIL: 2026-09-23 真实使用数据非预期 4 行（anchor×3 + day_type×1）';
  end if;
  if (select count(*) from public.life_data d
      where d.user_id = v_owner and d.biz_date = '2026-09-24'
        and d.entity_key not like 'p0test:%') <> 0 then
    raise exception 'SETUP_FAIL: 2026-09-24 应无数据（测试写路径载体日）';
  end if;
  v_proof := v_proof || jsonb_build_object('T00_setup', 'pass', 'owner', v_owner,
    'real_data', '2026-09-23 ×4 rows (A26 evidence)');

  -- ========== T01：真实历史日（9/23 训练日）context 只读投影 ==========
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('biz_date','2026-09-23'));
  v_ctx := private.cmd_get_today_context_v1(v_owner, v_env);
  if not (v_ctx ->> 'ok')::boolean then
    raise exception 'ASSERT T01 context 失败: %', v_ctx;
  end if;
  v_ctx := v_ctx -> 'result';
  if v_ctx #>> '{day_type,code}' <> 'workout_workday'
     or (v_ctx #>> '{stats,planned_count}')::int <> 8      -- 累计窗口 9/21..9/23：3+2+3
     or (v_ctx #>> '{stats,recorded_count}')::int <> 0 then
    raise exception 'ASSERT T01 失败（9/23 累计窗口分母 8、零记录）: %', v_ctx;
  end if;
  if v_ctx #>> '{next_action,kind}' <> 'record_anchor'
     or v_ctx #>> '{next_action,biz_date_relation}' <> 'past' then
    raise exception 'ASSERT T01 next_action 失败: %', v_ctx -> 'next_action';
  end if;
  v_proof := v_proof || jsonb_build_object('T01_real_day_context', 'pass',
    'day_type', 'workout_workday', 'planned_cumulative', 8, 'recorded', 0);

  -- ========== T02：未物化日（9/24 周四普通日）只读不物化 ==========
  select count(*) into v_audit from public.life_data d
   where d.user_id = v_owner and d.entity_key not like 'p0test:%';
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('biz_date','2026-09-24'));
  v_ctx := (private.cmd_get_today_context_v1(v_owner, v_env)) -> 'result';
  if (v_ctx #>> '{day_type,materialized}')::boolean
     or v_ctx #>> '{day_type,code}' <> 'ordinary_workday'
     or (v_ctx #>> '{stats,planned_count}')::int <> 10 then   -- 累计 9/21..9/24：8+2
    raise exception 'ASSERT T02 失败（9/24 普通日占位、累计分母 10）: %', v_ctx;
  end if;
  if (select count(*) from public.life_data d
      where d.user_id = v_owner and d.entity_key not like 'p0test:%') <> v_audit then
    raise exception 'ASSERT T02 失败（context 只读不得物化）';
  end if;
  v_proof := v_proof || jsonb_build_object('T02_readonly_no_materialize', 'pass',
    'rows_before_after', v_audit);

  -- ========== T03 / F01：9/24 wake 06:47（目标 06:50）→ deviation -3 / 首日锁 / 审计同事务 ==========
  v_key := gen_random_uuid();
  v_env := jsonb_build_object('api_version','1','idempotency_key',v_key,
    'input', jsonb_build_object('biz_date','2026-09-24','anchor_type','wake',
      'actual_at','2026-09-24T06:47:00+08:00'));
  v_r := private.cmd_check_anchor_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean
     or v_r #>> '{result,record,payload,status}' <> 'recorded'
     or v_r #>> '{result,record,version}' <> '2' then          -- insert v1 + LWW update → v2
    raise exception 'ASSERT T03 F01 失败: %', v_r;
  end if;
  v_req := (v_r ->> 'request_id')::uuid;
  select count(*) into v_audit from public.activity_log l where l.request_id = v_req;
  if v_audit < 6 then
    raise exception 'ASSERT T03 审计同事务失败（% 行 < 6）', v_audit;
  end if;
  v_ctx := (private.cmd_get_today_context_v1(v_owner, jsonb_build_object('api_version','1',
    'idempotency_key',gen_random_uuid(),'input', jsonb_build_object('biz_date','2026-09-24')))) -> 'result';
  select e into v_a from jsonb_array_elements(v_ctx -> 'anchors') e where e ->> 'anchor_type'='wake';
  if (v_a ->> 'deviation_minutes')::numeric <> -3 or not (v_a ->> 'target_met')::boolean then
    raise exception 'ASSERT T03 偏差/达标失败: %', v_a;
  end if;
  if not (v_ctx #>> '{day_type,plan_locked}')::boolean
     or not (v_ctx #>> '{day_type,materialized}')::boolean then
    raise exception 'ASSERT T03 首日锁失败: %', v_ctx -> 'day_type';
  end if;
  v_proof := v_proof || jsonb_build_object('T03_F01_wake_deviation_lock', 'pass',
    'deviation_minutes', -3, 'target_met', true, 'plan_locked', true,
    'audit_rows_same_request', v_audit);

  -- ========== T04 / A06：同 key 幂等 replay → 零二次写 ==========
  v_ver := v_r #>> '{result,record,version}';
  v_r := private.cmd_check_anchor_v1(v_owner, v_env);   -- 同 envelope 同 key 重放
  if not (v_r ->> 'ok')::boolean
     or v_r #>> '{result,record,version}' <> v_ver then
    raise exception 'ASSERT T04 幂等 replay 失败（版本漂移）: %', v_r;
  end if;
  if (select count(*) from public.activity_log l where l.request_id = (v_r ->> 'request_id')::uuid) > 0
     and (v_r ->> 'request_id')::uuid <> v_req then
    raise exception 'ASSERT T04 失败（replay 产生新请求审计）';
  end if;
  if (select count(*) from public.activity_log l where l.request_id = v_req) <> v_audit then
    raise exception 'ASSERT T04 失败（replay 追加审计 % ≠ %）',
      (select count(*) from public.activity_log l where l.request_id = v_req), v_audit;
  end if;
  v_proof := v_proof || jsonb_build_object('T04_idempotent_replay', 'pass',
    'version_stable', v_ver, 'audit_rows_unchanged', true);

  -- ========== T05 / F08：归属窗口（次日 00:30 归前日 / 跨本地日拒） ==========
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('biz_date','2026-09-24','anchor_type','wake',
      'actual_at','2026-09-25T06:47:00+08:00'));
  v_r := private.cmd_check_anchor_v1(v_owner, v_env);
  if (v_r ->> 'ok')::boolean or v_r #>> '{error,code}' <> 'VALIDATION_FAILED' then
    raise exception 'ASSERT T05 wake 跨本地日必须拒: %', v_r;
  end if;
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('biz_date','2026-09-24','anchor_type','lights_off',
      'actual_at','2026-09-25T00:30:00+08:00'));
  v_r := private.cmd_check_anchor_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean then
    raise exception 'ASSERT T05 次日 00:30 打卡失败: %', v_r;
  end if;
  v_ctx := (private.cmd_get_today_context_v1(v_owner, jsonb_build_object('api_version','1',
    'idempotency_key',gen_random_uuid(),'input', jsonb_build_object('biz_date','2026-09-24')))) -> 'result';
  select e into v_a from jsonb_array_elements(v_ctx -> 'anchors') e where e ->> 'anchor_type'='lights_off';
  if (v_a ->> 'deviation_minutes')::numeric <> 135 then
    raise exception 'ASSERT T05 偏差 +135 失败: %', v_a;
  end if;
  v_proof := v_proof || jsonb_build_object('T05_F08_attribution_window', 'pass',
    'deviation_minutes', 135, 'wake_crossday_reject', true);

  -- ========== T06 / F02：迟到仍计分子（deviation +20 / recorded 未达标） ==========
  -- 9/24 wake 已记 06:47（T03）；LWW 更新为 07:10（迟到）→ 记录仍在分子、达标变 false
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('biz_date','2026-09-24','anchor_type','wake',
      'actual_at','2026-09-24T07:10:00+08:00'));
  v_r := private.cmd_check_anchor_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean then raise exception 'ASSERT T06 打卡失败: %', v_r; end if;
  v_ctx := (private.cmd_get_today_context_v1(v_owner, jsonb_build_object('api_version','1',
    'idempotency_key',gen_random_uuid(),'input', jsonb_build_object('biz_date','2026-09-24')))) -> 'result';
  select e into v_a from jsonb_array_elements(v_ctx -> 'anchors') e where e ->> 'anchor_type'='wake';
  if (v_a ->> 'deviation_minutes')::numeric <> 20 or (v_a ->> 'target_met')::boolean
     or v_a ->> 'status' <> 'recorded' then
    raise exception 'ASSERT T06 失败（迟到须 recorded 但未达标）: %', v_a;
  end if;
  if (v_ctx #>> '{stats,recorded_count}')::int <> 2
     or (v_ctx #>> '{stats,met_count}')::int <> 0 then
    raise exception 'ASSERT T06 stats 失败（分子 2 / 达标 0）: %', v_ctx -> 'stats';
  end if;
  v_proof := v_proof || jsonb_build_object('T06_F02_late_counts_recorded', 'pass',
    'deviation_minutes', 20, 'recorded_count', 2, 'met_count', 0);

  -- ========== T07：信封纪律（未知字段拒 / Human 禁 expected_version） ==========
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('biz_date','2026-09-24','anchor_type','wake',
      'actual_at','2026-09-24T06:47:00+08:00','hacker',true));
  v_r := private.cmd_check_anchor_v1(v_owner, v_env);
  if (v_r ->> 'ok')::boolean or v_r #>> '{error,code}' <> 'VALIDATION_FAILED' then
    raise exception 'ASSERT T07 未知字段必须拒: %', v_r;
  end if;
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'expected_version','9',
    'input', jsonb_build_object('biz_date','2026-09-24','anchor_type','wake',
      'actual_at','2026-09-24T06:47:00+08:00'));
  v_r := private.cmd_check_anchor_v1(v_owner, v_env);
  if (v_r ->> 'ok')::boolean or v_r #>> '{error,code}' <> 'VALIDATION_FAILED' then
    raise exception 'ASSERT T07 Human 禁 expected_version: %', v_r;
  end if;
  v_proof := v_proof || jsonb_build_object('T07_envelope_discipline', 'pass',
    'unknown_field_reject', true, 'human_expected_version_reject', true);

  raise exception 'MVP006_KEY_PROOFS %', v_proof;
end;
$$;
