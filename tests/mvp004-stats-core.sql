-- MVP-004 统计 Core 验收测试（真实 SQL，Management API postgres 角色驱动）
-- 运行方式：整个 DO 块作为一个语句提交；末尾 RAISE EXCEPTION 携带 MVP004_PROOF JSON，
--   全部写入随事务回滚 → 对真实库零残留（MVP-001 同款测试模式）。
-- 隔离：事务内 UPDATE tracking_started_on=2026-08-15 + DELETE 全部 anchor/day_type（含真实使用数据），
--   回滚后真实库零变化；synthetic 行 entity_key 标记 'mvp004test:%'。
-- 覆盖：F09（45 天连续不裁 30）/ F12（provisional 不提前断链 + 补全后 +1）/ F14（迟到计分子，
--   记录率≠达标率）/ F10（未访问日计分母）/ 非训练日分母 2 / interval unknown 不伪装达标 /
--   历史补记重算 / heatmap 形状（30 格含今日、not_started、settled/provisional）/ 参数校验 /
--   public RPC 链路 / OWNER_DENIED / 只读不物化。

do $$
declare
  v_owner uuid;
  v_proof jsonb := '[]'::jsonb;
  v_env jsonb;
  v_r jsonb;
  v_days jsonb;
  v_stats jsonb;
  v_d date;
  v_plan jsonb;
  v_wx boolean;
  v_today date := (now() at time zone 'Asia/Shanghai')::date;
  v_cnt int;
  v_before int;
  v_workout_date date;
  v_rate numeric;
  v_met_rate numeric;
  v_late int;
  v_streak int;
  v_need int;
  v_nonworkout_denominators jsonb;
begin
  select o.user_id into v_owner from private.workspace_owner o limit 1;
  if not found then
    raise exception 'SETUP_FAIL: workspace_owner 为空';
  end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner::text, 'role', 'authenticated')::text, true);
  -- 裸 DML 也过 BEFORE trigger（trg_settings_bu / trg_life_data_bi / *_aw 均调 current_actor），
  -- 必须补 actor 上下文；request_id 可空（trigger 内 nullif 处理）。
  -- 注意：trg_life_data_bi 会以 actor 覆写 source_type/source_id（'human'/owner），
  -- synthetic 行仅靠 entity_key 'mvp004test:%' 识别。
  perform private.cmd_set_actor('human', v_owner);

  -- ========== T00 setup：事务内改跟踪起日 + 隐藏真实数据（回滚全撤销） ==========
  update public.workspace_settings
     set tracking_started_on = '2026-08-15',
         schedule_history = jsonb_build_array(jsonb_build_object(
           'effective_from', '2026-08-15',
           'weekday_codes', jsonb_build_object(
             'mon','workout_workday','tue','ordinary_workday','wed','workout_workday',
             'thu','ordinary_workday','fri','ordinary_workday','sat','weekend','sun','weekend')))
   where user_id = v_owner;
  if not found then
    raise exception 'SETUP_FAIL: workspace_settings 不存在';
  end if;
  delete from public.life_data
   where user_id = v_owner and module in ('anchor','day_type');
  v_proof := v_proof || jsonb_build_object('T00_setup', 'pass', 'owner', v_owner, 'today', v_today);

  -- ========== T01 / F09：45 天连续 → streak=45，30 天窗口不裁剪 ==========
  -- 铺 v_today-44 .. v_today 每天全记录（训练日 3 项 / 非训练日 2 项，全部达标）
  v_d := v_today - 44;
  while v_d <= v_today loop
    v_plan := private.resolve_day_plan(
      (select s from public.workspace_settings s where s.user_id = v_owner), v_d);
    v_wx := (v_plan ->> 'workout_expected')::boolean;
    insert into public.life_data (user_id, module, entity_key, biz_date, payload, source_type, source_id)
    values
      (v_owner, 'anchor', 'mvp004test:' || v_d || ':wake', v_d,
       jsonb_build_object('payload_v',1,'anchor_type','wake','planned',true,
         'target_at', v_d::text || 'T06:50:00+08:00',
         'actual_at', v_d::text || 'T06:47:00+08:00',
         'status','recorded','note','','plan_version','1'), 'system', gen_random_uuid()),
      (v_owner, 'anchor', 'mvp004test:' || v_d || ':lights_off', v_d,
       jsonb_build_object('payload_v',1,'anchor_type','lights_off','planned',true,
         'target_at', v_d::text || 'T22:15:00+08:00',
         'actual_at', v_d::text || 'T22:10:00+08:00',
         'status','recorded','note','','plan_version','1'), 'system', gen_random_uuid());
    if v_wx then
      insert into public.life_data (user_id, module, entity_key, biz_date, payload, source_type, source_id)
      values
        (v_owner, 'anchor', 'mvp004test:' || v_d || ':workout_end', v_d,
         jsonb_build_object('payload_v',1,'anchor_type','workout_end','planned',true,
           'target_at', v_d::text || 'T19:15:00+08:00',
           'actual_at', v_d::text || 'T19:00:00+08:00',
           'status','recorded','note','','plan_version','1'), 'system', gen_random_uuid());
    end if;
    v_d := v_d + 1;
  end loop;

  -- 30 天窗口（from=v_today-29）调 history：streak 必须走满 45，不被窗口裁掉
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('from', v_today - 29, 'to', v_today));
  v_r := private.cmd_get_anchor_history_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean then
    raise exception 'ASSERT T01 history 失败: %', v_r;
  end if;
  v_stats := v_r -> 'result' -> 'stats';
  v_streak := (v_stats ->> 'streak_days')::int;
  if v_streak <> 45 then
    raise exception 'ASSERT F09 失败（45 天连续应返回 45，实际 %）: %', v_streak, v_stats;
  end if;
  if (v_stats ->> 'today_complete')::boolean is not true
     or (v_stats ->> 'today_provisional')::boolean is not false then
    raise exception 'ASSERT T01 today 状态失败: %', v_stats;
  end if;
  v_proof := v_proof || jsonb_build_object('T01_F09_streak45', 'pass',
    'streak_days', v_streak, 'window', '30d', 'recording_rate', v_stats ->> 'recording_rate');

  -- ========== T02 / F12：今日未完成 → streak 截至昨日 8 天；补全今日 → 9 ==========
  delete from public.life_data
   where user_id = v_owner and module = 'anchor' and entity_key like 'mvp004test:%';
  -- 断链墙：v_today-9 缺 lights_off（已结算）
  v_d := v_today - 9;
  insert into public.life_data (user_id, module, entity_key, biz_date, payload, source_type, source_id)
  values
    (v_owner, 'anchor', 'mvp004test:' || v_d || ':wake', v_d,
     jsonb_build_object('payload_v',1,'anchor_type','wake','planned',true,
       'target_at', v_d::text || 'T06:50:00+08:00',
       'actual_at', v_d::text || 'T06:47:00+08:00',
       'status','recorded','note','','plan_version','1'), 'system', gen_random_uuid());
  -- v_today-8 .. v_today-1 每天全记录（8 天连续）
  v_d := v_today - 8;
  while v_d <= v_today - 1 loop
    v_plan := private.resolve_day_plan(
      (select s from public.workspace_settings s where s.user_id = v_owner), v_d);
    v_wx := (v_plan ->> 'workout_expected')::boolean;
    insert into public.life_data (user_id, module, entity_key, biz_date, payload, source_type, source_id)
    values
      (v_owner, 'anchor', 'mvp004test:' || v_d || ':wake', v_d,
       jsonb_build_object('payload_v',1,'anchor_type','wake','planned',true,
         'target_at', v_d::text || 'T06:50:00+08:00',
         'actual_at', v_d::text || 'T06:47:00+08:00',
         'status','recorded','note','','plan_version','1'), 'system', gen_random_uuid()),
      (v_owner, 'anchor', 'mvp004test:' || v_d || ':lights_off', v_d,
       jsonb_build_object('payload_v',1,'anchor_type','lights_off','planned',true,
         'target_at', v_d::text || 'T22:15:00+08:00',
         'actual_at', v_d::text || 'T22:10:00+08:00',
         'status','recorded','note','','plan_version','1'), 'system', gen_random_uuid());
    if v_wx then
      insert into public.life_data (user_id, module, entity_key, biz_date, payload, source_type, source_id)
      values
        (v_owner, 'anchor', 'mvp004test:' || v_d || ':workout_end', v_d,
         jsonb_build_object('payload_v',1,'anchor_type','workout_end','planned',true,
           'target_at', v_d::text || 'T19:15:00+08:00',
           'actual_at', v_d::text || 'T19:00:00+08:00',
           'status','recorded','note','','plan_version','1'), 'system', gen_random_uuid());
    end if;
    v_d := v_d + 1;
  end loop;
  -- 今日无记录 → provisional
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('from', v_today - 29, 'to', v_today));
  v_r := private.cmd_get_anchor_history_v1(v_owner, v_env);
  v_stats := v_r -> 'result' -> 'stats';
  v_streak := (v_stats ->> 'streak_days')::int;
  if v_streak <> 8 then
    raise exception 'ASSERT F12 失败（今日未完成应显示截至昨日 8 天，实际 %）: %', v_streak, v_stats;
  end if;
  if (v_stats ->> 'today_complete')::boolean is not false
     or (v_stats ->> 'today_provisional')::boolean is not true then
    raise exception 'ASSERT F12 provisional 失败: %', v_stats;
  end if;
  v_proof := v_proof || jsonb_build_object('T02a_F12_provisional', 'pass',
    'streak_days', v_streak, 'today_provisional', true);

  -- 补全今日 → streak=9（连续不归零，+1 语义）
  v_plan := private.resolve_day_plan(
    (select s from public.workspace_settings s where s.user_id = v_owner), v_today);
  v_wx := (v_plan ->> 'workout_expected')::boolean;
  insert into public.life_data (user_id, module, entity_key, biz_date, payload, source_type, source_id)
  values
    (v_owner, 'anchor', 'mvp004test:' || v_today || ':wake', v_today,
     jsonb_build_object('payload_v',1,'anchor_type','wake','planned',true,
       'target_at', v_today::text || 'T06:50:00+08:00',
       'actual_at', v_today::text || 'T06:47:00+08:00',
       'status','recorded','note','','plan_version','1'), 'system', gen_random_uuid()),
    (v_owner, 'anchor', 'mvp004test:' || v_today || ':lights_off', v_today,
     jsonb_build_object('payload_v',1,'anchor_type','lights_off','planned',true,
       'target_at', v_today::text || 'T22:15:00+08:00',
       'actual_at', v_today::text || 'T22:10:00+08:00',
       'status','recorded','note','','plan_version','1'), 'system', gen_random_uuid());
  if v_wx then
    insert into public.life_data (user_id, module, entity_key, biz_date, payload, source_type, source_id)
    values
      (v_owner, 'anchor', 'mvp004test:' || v_today || ':workout_end', v_today,
       jsonb_build_object('payload_v',1,'anchor_type','workout_end','planned',true,
         'target_at', v_today::text || 'T19:15:00+08:00',
         'actual_at', v_today::text || 'T19:00:00+08:00',
         'status','recorded','note','','plan_version','1'), 'system', gen_random_uuid());
  end if;
  v_r := private.cmd_get_anchor_history_v1(v_owner, v_env);
  v_stats := v_r -> 'result' -> 'stats';
  v_streak := (v_stats ->> 'streak_days')::int;
  if v_streak <> 9 then
    raise exception 'ASSERT F12 失败（今日补全后应为 9，实际 %）: %', v_streak, v_stats;
  end if;
  v_proof := v_proof || jsonb_build_object('T02b_F12_complete_plus1', 'pass', 'streak_days', v_streak);

  -- ========== T03 / F14：迟到记录仍计分子，记录率≠达标率 ==========
  delete from public.life_data
   where user_id = v_owner and module = 'anchor' and entity_key like 'mvp004test:%';
  -- v_today-3 全部迟到（actual>target）
  v_d := v_today - 3;
  v_plan := private.resolve_day_plan(
    (select s from public.workspace_settings s where s.user_id = v_owner), v_d);
  v_wx := (v_plan ->> 'workout_expected')::boolean;
  v_need := case when v_wx then 3 else 2 end;
  insert into public.life_data (user_id, module, entity_key, biz_date, payload, source_type, source_id)
  values
    (v_owner, 'anchor', 'mvp004test:' || v_d || ':wake', v_d,
     jsonb_build_object('payload_v',1,'anchor_type','wake','planned',true,
       'target_at', v_d::text || 'T06:50:00+08:00',
       'actual_at', v_d::text || 'T07:10:00+08:00',
       'status','recorded','note','','plan_version','1'), 'system', gen_random_uuid()),
    (v_owner, 'anchor', 'mvp004test:' || v_d || ':lights_off', v_d,
     jsonb_build_object('payload_v',1,'anchor_type','lights_off','planned',true,
       'target_at', v_d::text || 'T22:15:00+08:00',
       'actual_at', v_d::text || 'T23:00:00+08:00',
       'status','recorded','note','','plan_version','1'), 'system', gen_random_uuid());
  if v_wx then
    insert into public.life_data (user_id, module, entity_key, biz_date, payload, source_type, source_id)
    values
      (v_owner, 'anchor', 'mvp004test:' || v_d || ':workout_end', v_d,
       jsonb_build_object('payload_v',1,'anchor_type','workout_end','planned',true,
         'target_at', v_d::text || 'T19:15:00+08:00',
         'actual_at', v_d::text || 'T19:30:00+08:00',
         'status','recorded','note','','plan_version','1'), 'system', gen_random_uuid());
  end if;
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('from', v_d, 'to', v_d));
  v_r := private.cmd_get_anchor_history_v1(v_owner, v_env);
  v_stats := v_r -> 'result' -> 'stats';
  v_rate := (v_stats ->> 'recording_rate')::numeric;
  v_met_rate := (v_stats ->> 'met_rate')::numeric;
  v_late := (v_stats ->> 'recorded_late_count')::int;
  if (v_stats ->> 'planned_count')::int <> v_need
     or (v_stats ->> 'recorded_count')::int <> v_need
     or (v_stats ->> 'met_count')::int <> 0
     or v_rate <> 1
     or v_met_rate <> 0
     or v_late <> v_need then
    raise exception 'ASSERT F14 失败（迟到应计分子且记录率≠达标率）: %', v_stats;
  end if;
  v_proof := v_proof || jsonb_build_object('T03_F14_late_counts_recorded', 'pass',
    'recording_rate', v_rate, 'met_rate', v_met_rate, 'recorded_late_count', v_late);

  -- ========== T04 / F10：未访问日照算分母 ==========
  -- 窗口 v_today-5 .. v_today-3：只在 v_today-3 有数据（上一步），其余两天从未打开
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('from', v_today - 5, 'to', v_today - 3));
  v_r := private.cmd_get_anchor_history_v1(v_owner, v_env);
  v_stats := v_r -> 'result' -> 'stats';
  -- 分母 = 三天各自动态计划之和（必须含两个未访问日）
  declare
    v_expected_planned int := 0;
    v_dd date;
  begin
    v_dd := v_today - 5;
    while v_dd <= v_today - 3 loop
      v_plan := private.resolve_day_plan(
        (select s from public.workspace_settings s where s.user_id = v_owner), v_dd);
      v_expected_planned := v_expected_planned
        + case when (v_plan ->> 'workout_expected')::boolean then 3 else 2 end;
      v_dd := v_dd + 1;
    end loop;
    if (v_stats ->> 'planned_count')::int <> v_expected_planned
       or (v_stats ->> 'recorded_count')::int <> v_need then
      raise exception 'ASSERT F10 失败（未访问日必须计分母 %，实际 %）: %',
        v_expected_planned, v_stats ->> 'planned_count', v_stats;
    end if;
    v_proof := v_proof || jsonb_build_object('T04_F10_unopened_in_denominator', 'pass',
      'planned_count', v_expected_planned, 'recorded_count', v_need);
  end;

  -- ========== T05：非训练日分母 2（heatmap 格 workout_expected=false → denominator=2） ==========
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('from', v_today - 7, 'to', v_today));
  v_r := private.cmd_get_anchor_history_v1(v_owner, v_env);
  v_days := v_r -> 'result' -> 'days';
  select jsonb_agg(distinct (e ->> 'denominator')::int) into v_nonworkout_denominators
    from jsonb_array_elements(v_days) e
   where (e ->> 'workout_expected')::boolean is false
     and (e ->> 'not_started')::boolean is false;
  if v_nonworkout_denominators <> '[2]'::jsonb then
    raise exception 'ASSERT T05 失败（非训练日分母必须恒 2）: %', v_nonworkout_denominators;
  end if;
  -- 非训练日 interval_state 必须 none（训练间隔不评估）
  if exists (select 1 from jsonb_array_elements(v_days) e
              where (e ->> 'workout_expected')::boolean is false
                and e ->> 'interval_state' <> 'none') then
    raise exception 'ASSERT T05 失败（非训练日 interval 必须 none）';
  end if;
  v_proof := v_proof || jsonb_build_object('T05_nonworkout_denominator2', 'pass');

  -- ========== T06：interval unknown 不伪装达标 ==========
  delete from public.life_data
   where user_id = v_owner and module = 'anchor' and entity_key like 'mvp004test:%';
  -- 找最近一个训练日（从 v_today-1 回走）
  v_d := v_today - 1;
  loop
    v_plan := private.resolve_day_plan(
      (select s from public.workspace_settings s where s.user_id = v_owner), v_d);
    exit when (v_plan ->> 'workout_expected')::boolean;
    v_d := v_d - 1;
  end loop;
  v_workout_date := v_d;
  -- 只记 workout_end（不记 lights_off）→ interval unknown
  insert into public.life_data (user_id, module, entity_key, biz_date, payload, source_type, source_id)
  values
    (v_owner, 'anchor', 'mvp004test:' || v_d || ':workout_end', v_d,
     jsonb_build_object('payload_v',1,'anchor_type','workout_end','planned',true,
       'target_at', v_d::text || 'T19:15:00+08:00',
       'actual_at', v_d::text || 'T19:00:00+08:00',
       'status','recorded','note','','plan_version','1'), 'system', gen_random_uuid());
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('from', v_d, 'to', v_d));
  v_r := private.cmd_get_anchor_history_v1(v_owner, v_env);
  v_days := v_r -> 'result' -> 'days';
  v_stats := v_r -> 'result' -> 'stats';
  if v_days -> 0 ->> 'interval_state' <> 'unknown' then
    raise exception 'ASSERT T06 失败（缺 lights_off 必须 unknown）: %', v_days -> 0;
  end if;
  if (v_stats ->> 'interval_unknown_count')::int <> 1
     or (v_stats ->> 'interval_met_count')::int <> 0 then
    raise exception 'ASSERT T06 失败（unknown 不伪装达标）: %', v_stats;
  end if;
  v_proof := v_proof || jsonb_build_object('T06_interval_unknown', 'pass',
    'workout_date', v_workout_date, 'interval_unknown_count', 1, 'interval_met_count', 0);

  -- ========== T07：历史补记触发重算（streak 2 → 3） ==========
  delete from public.life_data
   where user_id = v_owner and module = 'anchor' and entity_key like 'mvp004test:%';
  -- 断链墙：v_today-4 缺 lights_off；v_today-3 缺 lights_off（待补记）；v_today-2/v_today-1 全记录
  for i in 1..4 loop
    v_d := v_today - i;
    v_plan := private.resolve_day_plan(
      (select s from public.workspace_settings s where s.user_id = v_owner), v_d);
    v_wx := (v_plan ->> 'workout_expected')::boolean;
    insert into public.life_data (user_id, module, entity_key, biz_date, payload, source_type, source_id)
    values
      (v_owner, 'anchor', 'mvp004test:' || v_d || ':wake', v_d,
       jsonb_build_object('payload_v',1,'anchor_type','wake','planned',true,
         'target_at', v_d::text || 'T06:50:00+08:00',
         'actual_at', v_d::text || 'T06:47:00+08:00',
         'status','recorded','note','','plan_version','1'), 'system', gen_random_uuid());
    if v_wx then
      insert into public.life_data (user_id, module, entity_key, biz_date, payload, source_type, source_id)
      values
        (v_owner, 'anchor', 'mvp004test:' || v_d || ':workout_end', v_d,
         jsonb_build_object('payload_v',1,'anchor_type','workout_end','planned',true,
           'target_at', v_d::text || 'T19:15:00+08:00',
           'actual_at', v_d::text || 'T19:00:00+08:00',
           'status','recorded','note','','plan_version','1'), 'system', gen_random_uuid());
    end if;
    if i <= 2 then  -- 仅 v_today-2 / v_today-1 有 lights_off
      insert into public.life_data (user_id, module, entity_key, biz_date, payload, source_type, source_id)
      values
        (v_owner, 'anchor', 'mvp004test:' || v_d || ':lights_off', v_d,
         jsonb_build_object('payload_v',1,'anchor_type','lights_off','planned',true,
           'target_at', v_d::text || 'T22:15:00+08:00',
           'actual_at', v_d::text || 'T22:10:00+08:00',
           'status','recorded','note','','plan_version','1'), 'system', gen_random_uuid());
    end if;
  end loop;
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('from', v_today - 29, 'to', v_today));
  v_r := private.cmd_get_anchor_history_v1(v_owner, v_env);
  v_before := (v_r #>> '{result,stats,streak_days}')::int;
  if v_before <> 2 then
    raise exception 'ASSERT T07 前置失败（补记前 streak 应为 2，实际 %）', v_before;
  end if;
  -- 补记历史：v_today-3 lights_off
  v_d := v_today - 3;
  insert into public.life_data (user_id, module, entity_key, biz_date, payload, source_type, source_id)
  values
    (v_owner, 'anchor', 'mvp004test:' || v_d || ':lights_off', v_d,
     jsonb_build_object('payload_v',1,'anchor_type','lights_off','planned',true,
       'target_at', v_d::text || 'T22:15:00+08:00',
       'actual_at', v_d::text || 'T22:10:00+08:00',
       'status','recorded','note','','plan_version','1'), 'system', gen_random_uuid());
  v_r := private.cmd_get_anchor_history_v1(v_owner, v_env);
  v_streak := (v_r #>> '{result,stats,streak_days}')::int;
  if v_streak <> 3 then
    raise exception 'ASSERT T07 失败（历史补记后 streak 应重算为 3，实际 %）', v_streak;
  end if;
  v_proof := v_proof || jsonb_build_object('T07_history_backfill_recompute', 'pass',
    'streak_before', v_before, 'streak_after', v_streak);

  -- ========== T08：heatmap 形状（30 格含今日 / not_started / settled / provisional） ==========
  delete from public.life_data
   where user_id = v_owner and module = 'anchor' and entity_key like 'mvp004test:%';
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('from', v_today - 29, 'to', v_today));
  v_r := private.cmd_get_anchor_history_v1(v_owner, v_env);
  v_days := v_r -> 'result' -> 'days';
  if jsonb_array_length(v_days) <> 30 then
    raise exception 'ASSERT T08 失败（30 格，实际 %）', jsonb_array_length(v_days);
  end if;
  if v_days -> 0 ->> 'biz_date' <> (v_today - 29)::text
     or v_days -> 29 ->> 'biz_date' <> v_today::text
     or (v_days -> 29 ->> 'is_today')::boolean is not true then
    raise exception 'ASSERT T08 失败（含今日 30 个工作区日期）: % | %',
      v_days -> 0 ->> 'biz_date', v_days -> 29;
  end if;
  -- 今日无记录 → provisional=true；已结算日（v_today-2 及更早）settled=true
  if (v_days -> 29 ->> 'provisional')::boolean is not true then
    raise exception 'ASSERT T08 失败（今日无记录必须 provisional）: %', v_days -> 29;
  end if;
  if (v_days -> 27 ->> 'settled')::boolean is not true then
    raise exception 'ASSERT T08 失败（v_today-2 必须已 settled）: %', v_days -> 27;
  end if;
  -- 昨日格：settled 边界取决于测试运行时刻是否已过今日 12:00（Asia/Shanghai），动态对账；
  -- 昨日无记录（未完成）→ provisional 必须 = not settled（F12 在途不提前断链）
  if (v_days -> 28 ->> 'settled')::boolean
     <> (now() >= (v_today::text || ' 12:00:00+08:00')::timestamptz) then
    raise exception 'ASSERT T08 失败（昨日 settled 与次日12:00结算规则不符）: %', v_days -> 28;
  end if;
  if (v_days -> 28 ->> 'provisional')::boolean
     <> not (v_days -> 28 ->> 'settled')::boolean then
    raise exception 'ASSERT T08 失败（昨日 provisional 必须 = not settled）: %', v_days -> 28;
  end if;
  v_proof := v_proof || jsonb_build_object('T08_heatmap_shape', 'pass',
    'days', 30, 'first', v_days -> 0 ->> 'biz_date', 'last', v_days -> 29 ->> 'biz_date');

  -- not_started：tracking_started_on（2026-08-15）之前的格子
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('from', '2026-08-14', 'to', '2026-08-16'));
  v_r := private.cmd_get_anchor_history_v1(v_owner, v_env);
  v_days := v_r -> 'result' -> 'days';
  if (v_days -> 0 ->> 'not_started')::boolean is not true
     or (v_days -> 0 ->> 'denominator')::int <> 0
     or (v_days -> 1 ->> 'not_started')::boolean is not false then
    raise exception 'ASSERT T08b 失败（起日前必须 not_started 且无分母）: %', v_days;
  end if;
  v_proof := v_proof || jsonb_build_object('T08b_not_started', 'pass');

  -- ========== T09：参数校验（拒未来 / 跨度 / from>to / 未知字段 / cursor 接受） ==========
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('from', v_today - 5, 'to', v_today + 1));
  v_r := private.cmd_get_anchor_history_v1(v_owner, v_env);
  if (v_r ->> 'ok')::boolean or v_r #>> '{error,code}' <> 'VALIDATION_FAILED' then
    raise exception 'ASSERT T09 失败（to>today 必须拒）: %', v_r;
  end if;
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('from', v_today - 400, 'to', v_today));
  v_r := private.cmd_get_anchor_history_v1(v_owner, v_env);
  if (v_r ->> 'ok')::boolean or v_r #>> '{error,code}' <> 'VALIDATION_FAILED' then
    raise exception 'ASSERT T09 失败（跨度>366 必须拒）: %', v_r;
  end if;
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('from', v_today, 'to', v_today - 1));
  v_r := private.cmd_get_anchor_history_v1(v_owner, v_env);
  if (v_r ->> 'ok')::boolean or v_r #>> '{error,code}' <> 'VALIDATION_FAILED' then
    raise exception 'ASSERT T09 失败（from>to 必须拒）: %', v_r;
  end if;
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('from', v_today - 5, 'to', v_today, 'hacker', true));
  v_r := private.cmd_get_anchor_history_v1(v_owner, v_env);
  if (v_r ->> 'ok')::boolean or v_r #>> '{error,code}' <> 'VALIDATION_FAILED' then
    raise exception 'ASSERT T09 失败（未知字段必须拒）: %', v_r;
  end if;
  -- cursor 接受但恒 next_cursor=null（MVP 不分页）
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('from', v_today - 5, 'to', v_today,
      'cursor', 'eyJsYXN0X2lkIjoiM2Y2YjJjMWUifQ'));
  v_r := private.cmd_get_anchor_history_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean
     or (v_r -> 'result' ? 'next_cursor') is not true
     or v_r -> 'result' -> 'next_cursor' <> 'null'::jsonb then
    raise exception 'ASSERT T09 失败（cursor 应接受且 next_cursor 恒 null）: %', v_r;
  end if;
  v_proof := v_proof || jsonb_build_object('T09_validation', 'pass',
    'reject_future', true, 'reject_span', true, 'reject_inverted', true,
    'reject_unknown_field', true, 'cursor_accepted_null', true);

  -- ========== T10：public RPC 链路 + OWNER_DENIED + data_revision 字符串 ==========
  select count(*) into v_before from public.life_data where user_id = v_owner;
  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('from', v_today - 29, 'to', v_today));
  v_r := public.get_anchor_history_v1(v_env);
  if not (v_r ->> 'ok')::boolean
     or (v_r -> 'result' -> 'days') is null
     or (v_r -> 'result' -> 'stats') is null
     or jsonb_typeof(v_r -> 'result' -> 'data_revision') <> 'string' then
    raise exception 'ASSERT T10 失败（public RPC 形状）: %', v_r;
  end if;
  -- 只读不物化
  select count(*) into v_cnt from public.life_data where user_id = v_owner;
  if v_cnt <> v_before then
    raise exception 'ASSERT T10 失败（history 只读不得物化 % → %）', v_before, v_cnt;
  end if;
  -- 非 owner → OWNER_DENIED
  perform set_config('request.jwt.claims',
    json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
  v_r := public.get_anchor_history_v1(v_env);
  if (v_r ->> 'ok')::boolean or v_r #>> '{error,code}' <> 'OWNER_DENIED' then
    raise exception 'ASSERT T10 失败（非 owner 必须 OWNER_DENIED）: %', v_r;
  end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_owner::text, 'role', 'authenticated')::text, true);
  v_proof := v_proof || jsonb_build_object('T10_public_rpc_owner_denied_readonly', 'pass');

  raise exception 'MVP004_PROOF %', v_proof;
end;
$$;
