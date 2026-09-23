-- MVP-001 业务 Core 验收测试（真实 SQL，Management API postgres 角色驱动）
-- 运行方式：整个 DO 块作为一个语句提交；末尾 RAISE EXCEPTION 携带 MVP001_PROOF JSON，
--   全部写入随事务回滚 → 对真实库零残留（P0-007 同款测试模式）。
-- 身份模拟：set_config('request.jwt.claims', ..., true) 令 auth.uid() 返回真实 owner，
--   走通 cmd_* 的 p_uid=auth.uid()+workspace_owner 复核（非绕过，是 Supabase auth.uid() 的标准 GUC 来源）。
-- 覆盖：F01–F08 / F10 / F11 / F13 / F14、record_open 去重/拒绝、未知字段拒写、
--   幂等 replay/conflict、一致锁 FOR SHARE、占位不物化、首日锁、单向追加、clear 不改分母。
-- 未覆盖（NOT_RUN，result.md 说明）：WORKSPACE_NOT_INITIALIZED 分支（真实库已初始化，构造第二
--   owner 需写 auth.users/workspace_state，超出本卡范围，留 Review 裁决）。

do $$
declare
  v_owner uuid;
  v_proof jsonb := '[]'::jsonb;
  v_env jsonb;
  v_r jsonb;
  v_ctx jsonb;
  v_a jsonb;             -- 单锚点元素
  v_key uuid;
  v_i int;
  v_fake uuid;
  v_err text;
  v_req uuid;
  v_ver_before text;
  v_wake_id uuid;
  v_long_note text;
begin
  select o.user_id into v_owner from private.workspace_owner o limit 1;
  if not found then
    raise exception 'SETUP_FAIL: workspace_owner 为空';
  end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner::text, 'role', 'authenticated')::text, true);

  -- 前置：真实库已按凯哥决定初始化（tracking_started_on=2026-09-21，一三五训练日）
  if not exists (select 1 from public.workspace_settings s
                 where s.user_id = v_owner and s.tracking_started_on = '2026-09-21') then
    raise exception 'SETUP_FAIL: workspace_settings 未按预期初始化';
  end if;
  -- P0 链铁证 fixture（entity_key 'p0test:%'，biz_date 2026-09-17 < 跟踪起日）属既有证据，排除；
  -- 统计/解析循环只覆盖 >= tracking_started_on，不受影响
  if (select count(*) from public.life_data d
      where d.user_id = v_owner and d.entity_key not like 'p0test:%') <> 0 then
    raise exception 'SETUP_FAIL: life_data 存在非 P0-fixture 行（% 行），测试要求干净起点',
      (select count(*) from public.life_data d
       where d.user_id = v_owner and d.entity_key not like 'p0test:%');
  end if;
  v_proof := v_proof || jsonb_build_object('T00_setup', 'pass', 'owner', v_owner);

  -- ========== T01 / F10：未打开日计入分母；占位不物化 ==========
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('biz_date','2026-09-22'));
  v_ctx := private.cmd_get_today_context_v1(v_owner, v_env);
  if not (v_ctx ->> 'ok')::boolean then
    raise exception 'ASSERT T01 context 失败: %', v_ctx;
  end if;
  v_ctx := v_ctx -> 'result';
  if (v_ctx #>> '{stats,planned_count}')::int <> 5
     or (v_ctx #>> '{stats,recorded_count}')::int <> 0 then
    raise exception 'ASSERT F10 失败（未打开日必须计入分母 3+2=5）: %', v_ctx -> 'stats';
  end if;
  if (v_ctx #>> '{day_type,materialized}')::boolean
     or v_ctx #>> '{day_type,version}' <> '0'
     or v_ctx #>> '{day_type,code}' <> 'ordinary_workday'
     or v_ctx #>> '{day_type,name}' <> '普通工作日' then
    raise exception 'ASSERT T01 day_type 占位失败: %', v_ctx -> 'day_type';
  end if;
  select e into v_a from jsonb_array_elements(v_ctx -> 'anchors') e
   where e ->> 'anchor_type' = 'workout_end';
  if (v_a ->> 'materialized')::boolean or v_a ->> 'version' <> '0'
     or v_a ->> 'status' <> 'not_applicable'
     or v_a -> 'target_at' <> 'null'::jsonb then
    raise exception 'ASSERT T01 workout_end 占位失败: %', v_a;
  end if;
  select e into v_a from jsonb_array_elements(v_ctx -> 'anchors') e
   where e ->> 'anchor_type' = 'wake';
  if v_a ->> 'target_at' <> '2026-09-22T06:50:00+08:00' then
    raise exception 'ASSERT T01 wake 目标失败: %', v_a;
  end if;
  if v_ctx #>> '{next_action,kind}' <> 'record_anchor'
     or v_ctx #>> '{next_action,anchor_type}' <> 'wake'
     or v_ctx #>> '{next_action,biz_date_relation}' <> 'past'
     or not (v_ctx #>> '{next_action,overdue}')::boolean then
    raise exception 'ASSERT T01 next_action 失败: %', v_ctx -> 'next_action';
  end if;
  -- 只读不物化（C-02 计划落地 2）
  if (select count(*) from public.life_data d
      where d.user_id = v_owner and d.entity_key not like 'p0test:%') <> 0 then
    raise exception 'ASSERT T01 失败：只读 context 物化了业务数据';
  end if;
  v_proof := v_proof || jsonb_build_object('T01_F10_unopened_day_in_denominator', 'pass',
    'planned_count', 5, 'materialized', false, 'life_data_rows', 0);

  -- ========== T02：Context 一致锁 FOR SHARE（workspace_state 表级 RowShareLock 持有证据） ==========
  -- SELECT FOR SHARE 在表级恒取 RowShareLock（pg_locks mode 名），持有至事务结束
  if not exists (select 1 from pg_locks
                 where pid = pg_backend_pid()
                   and relation = 'public.workspace_state'::regclass
                   and mode = 'RowShareLock') then
    raise exception 'ASSERT T02 失败：context 读未持有 workspace_state RowShareLock（FOR SHARE 未生效）';
  end if;
  v_proof := v_proof || jsonb_build_object('T02_context_for_share_lock', 'pass',
    'mode', 'RowShareLock',
    'meaning', 'FOR SHARE 表级锁持有证据；与写方 FOR UPDATE 的互斥发生在同一行的 tuple 级锁（ShareLock vs ExclusiveLock），读写由此串行');

  -- ========== T03 / F01：06:47 起床（目标 06:50）→ recorded、达标、偏差 -3；首日锁 ==========
  v_key := gen_random_uuid();
  v_env := jsonb_build_object('api_version','1','idempotency_key',v_key,
    'input', jsonb_build_object('biz_date','2026-09-21','anchor_type','wake',
      'actual_at','2026-09-21T06:47:00+08:00'));
  v_r := private.cmd_check_anchor_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean
     or v_r #>> '{result,record,payload,status}' <> 'recorded'
     or v_r #>> '{result,record,version}' <> '2'          -- insert v1 + LWW update → v2
     or v_r #>> '{result,day_type,plan_locked}' <> 'true' then
    raise exception 'ASSERT F01 失败: %', v_r;
  end if;
  v_req := (v_r ->> 'request_id')::uuid;
  -- 审计与业务同事务：物化 4 insert + 锚点 update + 日型锁 update，同 request_id
  if (select count(*) from public.activity_log l where l.request_id = v_req) < 6 then
    raise exception 'ASSERT F01 审计同事务失败（<6 行）: request_id=%', v_req;
  end if;
  v_ctx := (private.cmd_get_today_context_v1(v_owner, jsonb_build_object('api_version','1',
    'idempotency_key',gen_random_uuid(),'input', jsonb_build_object('biz_date','2026-09-21')))) -> 'result';
  select e into v_a from jsonb_array_elements(v_ctx -> 'anchors') e where e ->> 'anchor_type'='wake';
  if (v_a ->> 'deviation_minutes')::numeric <> -3 or not (v_a ->> 'target_met')::boolean then
    raise exception 'ASSERT F01 偏差/达标失败: %', v_a;
  end if;
  if v_ctx #>> '{day_type,code}' <> 'workout_workday'
     or v_ctx #>> '{day_type,name}' <> '训练工作日'
     or not (v_ctx #>> '{day_type,plan_locked}')::boolean
     or not (v_ctx #>> '{day_type,materialized}')::boolean then
    raise exception 'ASSERT F01 日型失败: %', v_ctx -> 'day_type';
  end if;
  v_proof := v_proof || jsonb_build_object('T03_F01_wake_0647', 'pass',
    'deviation_minutes', -3, 'target_met', true, 'plan_locked', true,
    'audit_rows_same_request', (select count(*) from public.activity_log l where l.request_id = v_req));

  -- ========== T04 / F06 前半：只记训练结束，间隔 unknown ==========
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('biz_date','2026-09-21','anchor_type','workout_end',
      'actual_at','2026-09-21T19:15:00+08:00'));
  v_r := private.cmd_check_anchor_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean then raise exception 'ASSERT F06 打卡失败: %', v_r; end if;
  v_ctx := (private.cmd_get_today_context_v1(v_owner, jsonb_build_object('api_version','1',
    'idempotency_key',gen_random_uuid(),'input', jsonb_build_object('biz_date','2026-09-21')))) -> 'result';
  select e into v_a from jsonb_array_elements(v_ctx -> 'anchors') e where e ->> 'anchor_type'='workout_end';
  if (v_a ->> 'deviation_minutes')::numeric <> 0 or not (v_a ->> 'target_met')::boolean
     or v_a -> 'interval_met' <> 'null'::jsonb
     or v_a -> 'interval_to_lights_off_minutes' <> 'null'::jsonb then
    raise exception 'ASSERT F06 失败（关灯缺失时间隔必须 unknown）: %', v_a;
  end if;
  if (v_ctx #>> '{stats,interval_unknown_count}')::int <> 1 then
    raise exception 'ASSERT F06 interval_unknown_count 失败: %', v_ctx -> 'stats';
  end if;
  v_proof := v_proof || jsonb_build_object('T04_F06_interval_unknown', 'pass', 'interval_met', null);

  -- ========== T05 / F03：19:15 结束 + 22:15 关灯 → 双达标，间隔 180 ==========
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('biz_date','2026-09-21','anchor_type','lights_off',
      'actual_at','2026-09-21T22:15:00+08:00'));
  v_r := private.cmd_check_anchor_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean then raise exception 'ASSERT F03 关灯失败: %', v_r; end if;
  v_ctx := (private.cmd_get_today_context_v1(v_owner, jsonb_build_object('api_version','1',
    'idempotency_key',gen_random_uuid(),'input', jsonb_build_object('biz_date','2026-09-21')))) -> 'result';
  select e into v_a from jsonb_array_elements(v_ctx -> 'anchors') e where e ->> 'anchor_type'='workout_end';
  if (v_a ->> 'interval_to_lights_off_minutes')::numeric <> 180
     or not (v_a ->> 'interval_met')::boolean then
    raise exception 'ASSERT F03 间隔失败: %', v_a;
  end if;
  select e into v_a from jsonb_array_elements(v_ctx -> 'anchors') e where e ->> 'anchor_type'='lights_off';
  if (v_a ->> 'deviation_minutes')::numeric <> 0 or not (v_a ->> 'target_met')::boolean then
    raise exception 'ASSERT F03 关灯达标失败: %', v_a;
  end if;
  v_proof := v_proof || jsonb_build_object('T05_F03_interval_180_met', 'pass',
    'interval_to_lights_off_minutes', 180, 'interval_met', true);

  -- ========== T06 / F04：19:30 结束 + 22:15 关灯 → 目标晚 15、间隔 165 不达标 ==========
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('biz_date','2026-09-21','anchor_type','workout_end',
      'actual_at','2026-09-21T19:30:00+08:00'));
  v_r := private.cmd_check_anchor_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean then raise exception 'ASSERT F04 打卡失败: %', v_r; end if;
  v_ctx := (private.cmd_get_today_context_v1(v_owner, jsonb_build_object('api_version','1',
    'idempotency_key',gen_random_uuid(),'input', jsonb_build_object('biz_date','2026-09-21')))) -> 'result';
  select e into v_a from jsonb_array_elements(v_ctx -> 'anchors') e where e ->> 'anchor_type'='workout_end';
  if (v_a ->> 'deviation_minutes')::numeric <> 15 or (v_a ->> 'target_met')::boolean
     or (v_a ->> 'interval_to_lights_off_minutes')::numeric <> 165
     or (v_a ->> 'interval_met')::boolean then
    raise exception 'ASSERT F04 失败: %', v_a;
  end if;
  v_proof := v_proof || jsonb_build_object('T06_F04_late15_interval165', 'pass',
    'deviation_minutes', 15, 'interval_to_lights_off_minutes', 165, 'interval_met', false);

  -- ========== T07 / F05：19:30 结束 + 23:00 关灯 → 训练仍晚 15、间隔 210 达标、关灯未达标 ==========
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('biz_date','2026-09-21','anchor_type','lights_off',
      'actual_at','2026-09-21T23:00:00+08:00'));
  v_r := private.cmd_check_anchor_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean then raise exception 'ASSERT F05 打卡失败: %', v_r; end if;
  v_ctx := (private.cmd_get_today_context_v1(v_owner, jsonb_build_object('api_version','1',
    'idempotency_key',gen_random_uuid(),'input', jsonb_build_object('biz_date','2026-09-21')))) -> 'result';
  select e into v_a from jsonb_array_elements(v_ctx -> 'anchors') e where e ->> 'anchor_type'='workout_end';
  if (v_a ->> 'deviation_minutes')::numeric <> 15 or (v_a ->> 'target_met')::boolean
     or (v_a ->> 'interval_to_lights_off_minutes')::numeric <> 210
     or not (v_a ->> 'interval_met')::boolean then
    raise exception 'ASSERT F05 训练/间隔失败: %', v_a;
  end if;
  select e into v_a from jsonb_array_elements(v_ctx -> 'anchors') e where e ->> 'anchor_type'='lights_off';
  if (v_a ->> 'deviation_minutes')::numeric <> 45 or (v_a ->> 'target_met')::boolean then
    raise exception 'ASSERT F05 关灯失败: %', v_a;
  end if;
  v_proof := v_proof || jsonb_build_object('T07_F05_interval210_met_lights_unmet', 'pass',
    'workout_deviation', 15, 'interval_to_lights_off_minutes', 210,
    'interval_met', true, 'lights_target_met', false);

  -- ========== T08 / F08：次日 00:30 关灯归前日，偏差 +135；归属窗口拒绝 ==========
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('biz_date','2026-09-21','anchor_type','lights_off',
      'actual_at','2026-09-21T11:00:00+08:00'));   -- 当日上午：不属前日 12:00 后窗口
  v_r := private.cmd_check_anchor_v1(v_owner, v_env);
  if (v_r ->> 'ok')::boolean or v_r #>> '{error,code}' <> 'VALIDATION_FAILED' then
    raise exception 'ASSERT F08 归属窗口拒绝失败: %', v_r;
  end if;
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('biz_date','2026-09-21','anchor_type','wake',
      'actual_at','2026-09-22T06:47:00+08:00'));   -- wake 本地日≠biz_date
  v_r := private.cmd_check_anchor_v1(v_owner, v_env);
  if (v_r ->> 'ok')::boolean or v_r #>> '{error,code}' <> 'VALIDATION_FAILED' then
    raise exception 'ASSERT F08 wake 归属拒绝失败: %', v_r;
  end if;
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('biz_date','2026-09-21','anchor_type','lights_off',
      'actual_at','2026-09-22T00:30:00+08:00'));
  v_r := private.cmd_check_anchor_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean then raise exception 'ASSERT F08 次日 00:30 打卡失败: %', v_r; end if;
  v_ctx := (private.cmd_get_today_context_v1(v_owner, jsonb_build_object('api_version','1',
    'idempotency_key',gen_random_uuid(),'input', jsonb_build_object('biz_date','2026-09-21')))) -> 'result';
  select e into v_a from jsonb_array_elements(v_ctx -> 'anchors') e where e ->> 'anchor_type'='lights_off';
  if (v_a ->> 'deviation_minutes')::numeric <> 135 then
    raise exception 'ASSERT F08 偏差 +135 失败: %', v_a;
  end if;
  v_proof := v_proof || jsonb_build_object('T08_F08_next_day_0030_prev_day', 'pass',
    'deviation_minutes', 135, 'window_reject', true, 'wake_attribution_reject', true);

  -- ========== T09 / F02+F07：非训练日两项完成；分母 2 分子 2；训练 n/a ==========
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('biz_date','2026-09-22','anchor_type','wake',
      'actual_at','2026-09-22T07:10:00+08:00'));
  v_r := private.cmd_check_anchor_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean then raise exception 'ASSERT F02 打卡失败: %', v_r; end if;
  v_ctx := (private.cmd_get_today_context_v1(v_owner, jsonb_build_object('api_version','1',
    'idempotency_key',gen_random_uuid(),'input', jsonb_build_object('biz_date','2026-09-22')))) -> 'result';
  select e into v_a from jsonb_array_elements(v_ctx -> 'anchors') e where e ->> 'anchor_type'='wake';
  if (v_a ->> 'deviation_minutes')::numeric <> 20 or (v_a ->> 'target_met')::boolean
     or v_a ->> 'status' <> 'recorded' then
    raise exception 'ASSERT F02 失败（迟到也计入记录率）: %', v_a;
  end if;
  select e into v_a from jsonb_array_elements(v_ctx -> 'anchors') e where e ->> 'anchor_type'='workout_end';
  if v_a ->> 'status' <> 'not_applicable' or (v_a ->> 'planned')::boolean then
    raise exception 'ASSERT F07 非训练日 n/a 失败: %', v_a;
  end if;
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('biz_date','2026-09-22','anchor_type','lights_off',
      'actual_at','2026-09-22T22:00:00+08:00'));
  v_r := private.cmd_check_anchor_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean then raise exception 'ASSERT F07 关灯失败: %', v_r; end if;
  v_ctx := (private.cmd_get_today_context_v1(v_owner, jsonb_build_object('api_version','1',
    'idempotency_key',gen_random_uuid(),'input', jsonb_build_object('biz_date','2026-09-22')))) -> 'result';
  if v_ctx #>> '{next_action,kind}' <> 'day_complete' then
    raise exception 'ASSERT F07 完成后 next_action 失败: %', v_ctx -> 'next_action';
  end if;
  -- F14（范围 09-21..09-22）：迟到全数完成 → rate=100%，达标率单独计算
  if (v_ctx #>> '{stats,planned_count}')::int <> 5
     or (v_ctx #>> '{stats,recorded_count}')::int <> 5
     or (v_ctx #>> '{stats,recording_rate}')::numeric <> 1
     or (v_ctx #>> '{stats,met_count}')::int <> 2 then
    raise exception 'ASSERT F14 失败: %', v_ctx -> 'stats';
  end if;
  -- 连续记录：09-22/09-21 均完整 → 2（完成日不受结算点影响，时间无关断言）
  if (v_ctx #>> '{stats,streak_days}')::int <> 2 then
    raise exception 'ASSERT streak 失败: %', v_ctx -> 'stats';
  end if;
  v_proof := v_proof || jsonb_build_object('T09_F02_F07_F14', 'pass',
    'wake_deviation', 20, 'workout_status', 'not_applicable',
    'recording_rate', 1, 'met_count', 2, 'streak_days', 2);

  -- ========== T10 / F11：已起床后单向追加训练；减项/改型拒绝；clear 不改分母 ==========
  -- (a) 今日(2026-09-23,周三→默认训练日)先切普通工作日（未锁允许）
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('biz_date','2026-09-23','code','ordinary_workday'));
  v_r := private.cmd_set_day_type_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean or (v_r #>> '{result,no_change}')::boolean
     or v_r #>> '{result,record,payload,code}' <> 'ordinary_workday' then
    raise exception 'ASSERT F11a 失败: %', v_r;
  end if;
  -- (b) 同 code 再设 → no_change
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('biz_date','2026-09-23','code','ordinary_workday'));
  v_r := private.cmd_set_day_type_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean or not (v_r #>> '{result,no_change}')::boolean then
    raise exception 'ASSERT F11b no_change 失败: %', v_r;
  end if;
  -- (c) 非今日拒绝
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('biz_date','2026-09-22','code','workout_workday'));
  v_r := private.cmd_set_day_type_v1(v_owner, v_env);
  if (v_r ->> 'ok')::boolean or v_r #>> '{error,code}' <> 'VALIDATION_FAILED' then
    raise exception 'ASSERT F11c 仅今日失败: %', v_r;
  end if;
  -- (d) 起床打卡 → 计划锁定
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('biz_date','2026-09-23','anchor_type','wake',
      'actual_at','2026-09-23T06:47:00+08:00'));
  v_r := private.cmd_check_anchor_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean or v_r #>> '{result,day_type,plan_locked}' <> 'true' then
    raise exception 'ASSERT F11d 失败: %', v_r;
  end if;
  -- (e) 已锁追加训练：ordinary→workout 允许，分母 +1
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('biz_date','2026-09-23','code','workout_workday'));
  v_r := private.cmd_set_day_type_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean
     or v_r #>> '{result,record,payload,code}' <> 'workout_workday'
     or v_r #>> '{result,record,payload,plan_locked}' <> 'true' then
    raise exception 'ASSERT F11e 追加失败: %', v_r;
  end if;
  v_ctx := (private.cmd_get_today_context_v1(v_owner, jsonb_build_object('api_version','1',
    'idempotency_key',gen_random_uuid(),'input', jsonb_build_object('biz_date','2026-09-23')))) -> 'result';
  select e into v_a from jsonb_array_elements(v_ctx -> 'anchors') e where e ->> 'anchor_type'='workout_end';
  if v_a ->> 'status' <> 'pending' or not (v_a ->> 'planned')::boolean
     or v_a ->> 'target_at' <> '2026-09-23T19:15:00+08:00'
     or v_a ->> 'plan_version' <> '2' then   -- provenance：保留原 plan_version
    raise exception 'ASSERT F11e 训练锚点失败: %', v_a;
  end if;
  -- 分母 +1：09-21..09-23 = 3+2+3=8
  if (v_ctx #>> '{stats,planned_count}')::int <> 8 then
    raise exception 'ASSERT F11e 分母 +1 失败: %', v_ctx -> 'stats';
  end if;
  -- (f) 减项/改型拒绝：workout→ordinary、workout→weekend、workout→weekend_workout 全拒
  for v_i in 1..3 loop
    v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
      'input', jsonb_build_object('biz_date','2026-09-23',
        'code', (array['ordinary_workday','weekend','weekend_workout'])[v_i]));
    v_r := private.cmd_set_day_type_v1(v_owner, v_env);
    if (v_r ->> 'ok')::boolean or v_r #>> '{error,code}' <> 'DAY_PLAN_LOCKED' then
      raise exception 'ASSERT F11f 减项/改型拒绝失败(%): %', v_i, v_r;
    end if;
  end loop;
  -- (g) clear 只清实际值：分母不变、不解锁
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('biz_date','2026-09-23','anchor_type','wake'));
  v_r := private.cmd_clear_anchor_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean or (v_r #>> '{result,no_change}')::boolean
     or v_r #>> '{result,record,payload,status}' <> 'pending'
     or v_r #>> '{result,record,payload,planned}' <> 'true' then
    raise exception 'ASSERT F11g clear 失败: %', v_r;
  end if;
  v_ctx := (private.cmd_get_today_context_v1(v_owner, jsonb_build_object('api_version','1',
    'idempotency_key',gen_random_uuid(),'input', jsonb_build_object('biz_date','2026-09-23')))) -> 'result';
  if (v_ctx #>> '{stats,planned_count}')::int <> 8
     or (v_ctx #>> '{stats,recorded_count}')::int <> 5 then   -- 5 = 09-21×3 + 09-22×2
    raise exception 'ASSERT F11g clear 改分母失败: %', v_ctx -> 'stats';
  end if;
  if not (v_ctx #>> '{day_type,plan_locked}')::boolean then
    raise exception 'ASSERT F11g clear 解锁失败: %', v_ctx -> 'day_type';
  end if;
  -- (h) clear 幂等：再清 → no_change
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('biz_date','2026-09-23','anchor_type','wake'));
  v_r := private.cmd_clear_anchor_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean or not (v_r #>> '{result,no_change}')::boolean then
    raise exception 'ASSERT F11h clear no_change 失败: %', v_r;
  end if;
  -- (i) 迟到补回起床（07:10，未达标但计入）
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('biz_date','2026-09-23','anchor_type','wake',
      'actual_at','2026-09-23T07:10:00+08:00'));
  v_r := private.cmd_check_anchor_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean then raise exception 'ASSERT F11i 补记失败: %', v_r; end if;
  v_proof := v_proof || jsonb_build_object('T10_F11_append_lock_clear', 'pass',
    'append_denominator_plus1', true, 'planned_count', 8,
    'locked_reject_codes', 'DAY_PLAN_LOCKED×3', 'clear_keeps_denominator', true,
    'workout_plan_version_provenance', '2');

  -- ========== T11：record_open 去重 / 不同日新建 / 错误 owner 拒绝 ==========
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('device_id','mvp001-test-dev-a','biz_date','2026-09-23'));
  v_r := private.cmd_record_open_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean or not (v_r #>> '{result,recorded}')::boolean
     or (v_r #>> '{result,deduped}')::boolean then
    raise exception 'ASSERT T11a 失败: %', v_r;
  end if;
  -- 同 device 同日换 key → 仍去重，不刷日志
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('device_id','mvp001-test-dev-a','biz_date','2026-09-23'));
  v_r := private.cmd_record_open_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean or (v_r #>> '{result,recorded}')::boolean
     or not (v_r #>> '{result,deduped}')::boolean then
    raise exception 'ASSERT T11b 换 key 去重失败: %', v_r;
  end if;
  if (select count(*) from public.activity_log l
      where l.user_id = v_owner and l.action = 'human.opened'
        and l.metadata ->> 'device_id' = 'mvp001-test-dev-a'
        and l.metadata ->> 'biz_date' = '2026-09-23') <> 1 then
    raise exception 'ASSERT T11b 日志去重失败（≠1 行）';
  end if;
  -- 不同日可新建
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('device_id','mvp001-test-dev-a','biz_date','2026-09-22'));
  v_r := private.cmd_record_open_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean or not (v_r #>> '{result,recorded}')::boolean then
    raise exception 'ASSERT T11c 不同日新建失败: %', v_r;
  end if;
  -- 不同 device 同日可新建
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('device_id','mvp001-test-dev-b','biz_date','2026-09-23'));
  v_r := private.cmd_record_open_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean or not (v_r #>> '{result,recorded}')::boolean then
    raise exception 'ASSERT T11d 不同 device 失败: %', v_r;
  end if;
  -- 错误 owner 拒绝（device_id 不是身份凭据）：换 sub 后即使带合法 device_id 也拒
  v_fake := gen_random_uuid();
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_fake::text, 'role', 'authenticated')::text, true);
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('device_id','mvp001-test-dev-a','biz_date','2026-09-23'));
  v_r := private.cmd_record_open_v1(v_fake, v_env);
  if (v_r ->> 'ok')::boolean or v_r #>> '{error,code}' <> 'OWNER_DENIED' then
    raise exception 'ASSERT T11e 错误 owner 拒绝失败: %', v_r;
  end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner::text, 'role', 'authenticated')::text, true);
  v_proof := v_proof || jsonb_build_object('T11_record_open', 'pass',
    'same_device_same_day_rows', 1, 'other_day_recorded', true,
    'other_device_recorded', true, 'wrong_owner', 'OWNER_DENIED');

  -- ========== T12：未知字段/伪造字段/未来时间/n-a 拒绝；幂等 replay/conflict；note LWW ==========
  -- (a) envelope 带 expected_version（Human 禁带）
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'expected_version','1',
    'input', jsonb_build_object('biz_date','2026-09-21','anchor_type','wake',
      'actual_at','2026-09-21T06:47:00+08:00'));
  v_r := private.cmd_check_anchor_v1(v_owner, v_env);
  if (v_r ->> 'ok')::boolean or v_r #>> '{error,code}' <> 'VALIDATION_FAILED' then
    raise exception 'ASSERT T12a expected_version 拒绝失败: %', v_r;
  end if;
  -- (b) input 伪造 status（Core 导出字段禁止提交）
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('biz_date','2026-09-21','anchor_type','wake',
      'actual_at','2026-09-21T06:47:00+08:00','status','recorded'));
  v_r := private.cmd_check_anchor_v1(v_owner, v_env);
  if (v_r ->> 'ok')::boolean or v_r #>> '{error,code}' <> 'VALIDATION_FAILED' then
    raise exception 'ASSERT T12b 伪造 status 拒绝失败: %', v_r;
  end if;
  -- (c) 未来 actual_at（>now()+60s）
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('biz_date','2026-09-23','anchor_type','lights_off',
      'actual_at', to_char((now() + interval '2 hours') at time zone 'Asia/Shanghai',
                           'YYYY-MM-DD"T"HH24:MI:SS') || '+08:00'));
  v_r := private.cmd_check_anchor_v1(v_owner, v_env);
  if (v_r ->> 'ok')::boolean or v_r #>> '{error,code}' <> 'VALIDATION_FAILED' then
    raise exception 'ASSERT T12c 未来时间拒绝失败: %', v_r;
  end if;
  -- (d) n/a 锚点拒绝（非训练日 workout_end）
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('biz_date','2026-09-22','anchor_type','workout_end',
      'actual_at','2026-09-22T19:00:00+08:00'));
  v_r := private.cmd_check_anchor_v1(v_owner, v_env);
  if (v_r ->> 'ok')::boolean or v_r #>> '{error,code}' <> 'ANCHOR_NOT_APPLICABLE' then
    raise exception 'ASSERT T12d n/a 拒绝失败: %', v_r;
  end if;
  -- (e) 幂等 replay：T03 同 key 同 input → replayed:true，记录 version 不再变
  select d.version::text into v_ver_before from public.life_data d
   where d.user_id = v_owner and d.module = 'anchor' and d.entity_key = '2026-09-21/wake';
  -- 直接用 T03 的 v_key 与相同 input 重放
  v_env := jsonb_build_object('api_version','1','idempotency_key',v_key,
    'input', jsonb_build_object('biz_date','2026-09-21','anchor_type','wake',
      'actual_at','2026-09-21T06:47:00+08:00'));
  v_r := private.cmd_check_anchor_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean or not (v_r ->> 'replayed')::boolean
     or v_r #>> '{result,record,version}' <> v_ver_before then
    raise exception 'ASSERT T12e replay 失败: % (期望 version=%)', v_r, v_ver_before;
  end if;
  -- (f) 幂等 conflict：同 key 不同 input
  v_env := jsonb_build_object('api_version','1','idempotency_key',v_key,
    'input', jsonb_build_object('biz_date','2026-09-21','anchor_type','wake',
      'actual_at','2026-09-21T06:48:00+08:00'));
  v_r := private.cmd_check_anchor_v1(v_owner, v_env);
  if (v_r ->> 'ok')::boolean or v_r #>> '{error,code}' <> 'IDEMPOTENCY_KEY_REUSED' then
    raise exception 'ASSERT T12f conflict 失败: %', v_r;
  end if;
  -- (g) note LWW + 保留其他字段 + 校验
  select d.id into v_wake_id from public.life_data d
   where d.user_id = v_owner and d.module = 'anchor' and d.entity_key = '2026-09-21/wake';
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('record_id', v_wake_id::text, 'note', '晨跑后补记'));
  v_r := private.cmd_update_anchor_note_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean
     or v_r #>> '{result,record,payload,note}' <> '晨跑后补记'
     or v_r #>> '{result,record,payload,status}' <> 'recorded'
     or v_r #>> '{result,record,payload,actual_at}' <> '2026-09-21T06:47:00+08:00' then
    raise exception 'ASSERT T12g note LWW 失败: %', v_r;
  end if;
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('record_id', v_wake_id::text, 'note', '晨跑后补记'));
  v_r := private.cmd_update_anchor_note_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean or not (v_r #>> '{result,no_change}')::boolean then
    raise exception 'ASSERT T12g note no_change 失败: %', v_r;
  end if;
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('record_id', gen_random_uuid()::text, 'note', 'x'));
  v_r := private.cmd_update_anchor_note_v1(v_owner, v_env);
  if (v_r ->> 'ok')::boolean or v_r #>> '{error,code}' <> 'RESOURCE_NOT_FOUND' then
    raise exception 'ASSERT T12g 不存在记录失败: %', v_r;
  end if;
  v_long_note := repeat('长', 2001);
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('record_id', v_wake_id::text, 'note', v_long_note));
  v_r := private.cmd_update_anchor_note_v1(v_owner, v_env);
  if (v_r ->> 'ok')::boolean or v_r #>> '{error,code}' <> 'VALIDATION_FAILED' then
    raise exception 'ASSERT T12g note 超长失败: %', v_r;
  end if;
  v_proof := v_proof || jsonb_build_object('T12_reject_and_idempotency', 'pass',
    'expected_version_reject', true, 'forged_status_reject', true,
    'future_actual_reject', true, 'na_reject', 'ANCHOR_NOT_APPLICABLE',
    'replay', true, 'conflict', 'IDEMPOTENCY_KEY_REUSED',
    'note_lww', true, 'note_no_change', true, 'note_length_reject', true);

  -- ========== T13 / F13：today 由工作区时区决定；缺省 biz_date=今日 ==========
  v_ctx := (private.cmd_get_today_context_v1(v_owner, jsonb_build_object('api_version','1',
    'idempotency_key',gen_random_uuid()))) -> 'result';
  if v_ctx ->> 'biz_date' <> (now() at time zone 'Asia/Shanghai')::date::text
     or v_ctx ->> 'today' <> (now() at time zone 'Asia/Shanghai')::date::text
     or v_ctx ->> 'timezone' <> 'Asia/Shanghai' then
    raise exception 'ASSERT F13 失败: biz_date=% today=%',
      v_ctx ->> 'biz_date', v_ctx ->> 'today';
  end if;
  v_proof := v_proof || jsonb_build_object('T13_F13_workspace_timezone', 'pass',
    'today', v_ctx ->> 'today', 'rule', 'now() at time zone Asia/Shanghai（UTC 16:10→上海次日 00:10 同公式）');

  -- ========== T14：今日 context 收尾投影（next_action 指向 workout_end；overdue 动态自洽） ==========
  v_ctx := (private.cmd_get_today_context_v1(v_owner, jsonb_build_object('api_version','1',
    'idempotency_key',gen_random_uuid(),'input', jsonb_build_object('biz_date','2026-09-23')))) -> 'result';
  select e into v_a from jsonb_array_elements(v_ctx -> 'anchors') e where e ->> 'anchor_type'='workout_end';
  if v_ctx #>> '{next_action,kind}' <> 'record_anchor'
     or v_ctx #>> '{next_action,anchor_type}' <> 'workout_end' then
    raise exception 'ASSERT T14 next_action 失败: %', v_ctx -> 'next_action';
  end if;
  if (v_ctx #>> '{next_action,overdue}')::boolean
     is distinct from (now() > (v_a ->> 'target_at')::timestamptz) then
    raise exception 'ASSERT T14 overdue 不自洽: % vs target %', v_ctx -> 'next_action', v_a;
  end if;
  -- data_revision 必须是十进制字符串（BIGINT 服务端转字符串）
  if jsonb_typeof(v_ctx -> 'data_revision') is distinct from 'string' then
    raise exception 'ASSERT T14 data_revision 非字符串: %', v_ctx -> 'data_revision';
  end if;
  v_proof := v_proof || jsonb_build_object('T14_today_context_projection', 'pass',
    'next_action', v_ctx -> 'next_action', 'data_revision_type', 'string');

  raise exception 'MVP001_PROOF %', v_proof::text;
end $$;
