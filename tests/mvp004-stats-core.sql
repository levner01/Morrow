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
  -- 0015 回归纪律：DELETE 排除 p0test 铁证 fixture——保留真库雷 p0test:anchor-f1
  --（2026-09-17，planned=true∧actual 非空∧live），供 T13 在雷真实存在下验证 >= 修复
  delete from public.life_data
   where user_id = v_owner and module in ('anchor','day_type')
     and entity_key not like 'p0test:%';
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

  -- ========== T12 / 0015 回归：超记日多记不罚（rec > den 不断链、不误标在途） ==========
  -- 构造：v_today-5..v_today 全记录；v_today-3 与今日各补 1 条多余 live 行（rec=den+1，
  -- 模拟补记/导入/数据修复产生的重复行）。修前：两日 complete=(den+1=den)=false →
  -- v_today-3 已结算断链（streak=2）、今日被误标 provisional；修后（>=）：streak=6、
  -- today_complete=true、两格 provisional=false。
  delete from public.life_data
   where user_id = v_owner and module = 'anchor' and entity_key like 'mvp004test:%';
  v_d := v_today - 5;
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
  -- 多余行 ×2：同 anchor_type 重复、planned=true、actual 达标（rec 口径必计入）
  insert into public.life_data (user_id, module, entity_key, biz_date, payload, source_type, source_id)
  values
    (v_owner, 'anchor', 'mvp004test:' || (v_today - 3) || ':extra', v_today - 3,
     jsonb_build_object('payload_v',1,'anchor_type','wake','planned',true,
       'target_at', (v_today - 3)::text || 'T06:50:00+08:00',
       'actual_at', (v_today - 3)::text || 'T06:48:00+08:00',
       'status','recorded','note','','plan_version','1'), 'system', gen_random_uuid()),
    (v_owner, 'anchor', 'mvp004test:' || v_today || ':extra', v_today,
     jsonb_build_object('payload_v',1,'anchor_type','wake','planned',true,
       'target_at', v_today::text || 'T06:50:00+08:00',
       'actual_at', v_today::text || 'T06:48:00+08:00',
       'status','recorded','note','','plan_version','1'), 'system', gen_random_uuid());

  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('from', v_today - 5, 'to', v_today));
  v_r := private.cmd_get_anchor_history_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean then
    raise exception 'ASSERT T12 history 失败: %', v_r;
  end if;
  v_stats := v_r -> 'result' -> 'stats';
  v_days := v_r -> 'result' -> 'days';
  declare
    v_d3_need int;
    v_dt_need int;
    v_cell3 jsonb := v_days -> 2;   -- 窗口 v_today-5 起，v_today-3 = 下标 2
    v_cellt jsonb := v_days -> 5;   -- 今日 = 下标 5
  begin
    v_plan := private.resolve_day_plan(
      (select s from public.workspace_settings s where s.user_id = v_owner), v_today - 3);
    v_d3_need := case when (v_plan ->> 'workout_expected')::boolean then 3 else 2 end;
    v_plan := private.resolve_day_plan(
      (select s from public.workspace_settings s where s.user_id = v_owner), v_today);
    v_dt_need := case when (v_plan ->> 'workout_expected')::boolean then 3 else 2 end;
    -- 0015 L199+0013 walk 修复：超记日不断链，streak=6（修前=2）
    if (v_stats ->> 'streak_days')::int <> 6 then
      raise exception 'ASSERT T12 失败（超记日不得断链，streak 应=6，实际 %）: %',
        v_stats ->> 'streak_days', v_stats;
    end if;
    -- 0015 L182 修复：今日多记 → today_complete=true（修前 false）
    if (v_stats ->> 'today_complete')::boolean is not true
       or (v_stats ->> 'today_provisional')::boolean is not false then
      raise exception 'ASSERT T12 失败（今日多记应 complete，today 状态说谎）: %', v_stats;
    end if;
    -- 格级：recorded 如实不 cap（den+1）；0015 L104 修复：未结算多记日不得错标 provisional
    if (v_cell3 ->> 'recorded_count')::int <> v_d3_need + 1
       or (v_cell3 ->> 'denominator')::int <> v_d3_need
       or (v_cell3 ->> 'provisional')::boolean is not false then
      raise exception 'ASSERT T12 失败（超记格 recorded 应=den+1 且不标在途）: %', v_cell3;
    end if;
    if (v_cellt ->> 'recorded_count')::int <> v_dt_need + 1
       or (v_cellt ->> 'provisional')::boolean is not false then
      raise exception 'ASSERT T12 失败（今日超记格不得标 provisional）: %', v_cellt;
    end if;
    v_proof := v_proof || jsonb_build_object('T12_over_recorded_no_penalty', 'pass',
      'streak_days', 6, 'today_complete', true,
      'cell_t-3_recorded', v_d3_need + 1, 'cell_today_recorded', v_dt_need + 1,
      'note', 'recorded 如实输出 den+1 不 cap；修前 streak=2 且今日误标在途');
  end;

  -- ========== T13 / 0015 回归：真库雷 p0test:anchor-f1 排雷（不 DELETE p0test 前提） ==========
  -- 雷：p0test:anchor-f1（biz_date=2026-09-17，周四 isodow=4——Review 通知误记为周六，
  -- ordinary_workday 与 weekend 同为分母 2，结论不受影响；planned=true∧actual 非空∧live）。
  -- 先断言雷在预期状态（防未来清雷导致本测试假绿），再铺 09-17 两项计划行 → rec=3（2 计划+1 雷）。
  if not exists (select 1 from public.life_data d
                 where d.user_id = v_owner and d.entity_key = 'p0test:anchor-f1'
                   and d.biz_date = '2026-09-17' and d.deleted_at is null
                   and (d.payload ->> 'planned')::boolean
                   and d.payload ->> 'actual_at' is not null) then
    raise exception 'SETUP_FAIL: 真库雷 p0test:anchor-f1 不在预期状态（缺失/变形/已删），T13 无法踩雷';
  end if;
  delete from public.life_data
   where user_id = v_owner and module = 'anchor' and biz_date = '2026-09-17'
     and entity_key like 'mvp004test:%';
  insert into public.life_data (user_id, module, entity_key, biz_date, payload, source_type, source_id)
  values
    (v_owner, 'anchor', 'mvp004test:2026-09-17:wake', '2026-09-17',
     jsonb_build_object('payload_v',1,'anchor_type','wake','planned',true,
       'target_at', '2026-09-17T06:50:00+08:00',
       'actual_at', '2026-09-17T06:47:00+08:00',
       'status','recorded','note','','plan_version','1'), 'system', gen_random_uuid()),
    (v_owner, 'anchor', 'mvp004test:2026-09-17:lights_off', '2026-09-17',
     jsonb_build_object('payload_v',1,'anchor_type','lights_off','planned',true,
       'target_at', '2026-09-17T22:15:00+08:00',
       'actual_at', '2026-09-17T22:10:00+08:00',
       'status','recorded','note','','plan_version','1'), 'system', gen_random_uuid());

  v_env := jsonb_build_object('api_version','1','idempotency_key',gen_random_uuid(),
    'input', jsonb_build_object('from', '2026-09-17', 'to', '2026-09-17'));
  v_r := private.cmd_get_anchor_history_v1(v_owner, v_env);
  if not (v_r ->> 'ok')::boolean then
    raise exception 'ASSERT T13 history 失败: %', v_r;
  end if;
  v_days := v_r -> 'result' -> 'days';
  v_stats := v_r -> 'result' -> 'stats';
  -- 断言 1：雷被真实计入 rec（3=2 计划+1 雷，非擦肩而过）；格 complete 语义 = rec>=den 不标在途
  if (v_days -> 0 ->> 'recorded_count')::int <> 3
     or (v_days -> 0 ->> 'denominator')::int <> 2
     or (v_days -> 0 ->> 'provisional')::boolean is not false then
    raise exception 'ASSERT T13 失败（雷日 recorded 应=3、denominator=2、不标在途）: %', v_days -> 0;
  end if;
  -- 断言 2：complete=true 直接证据——单天窗口 walk 穿过 09-17（streak=1；修前等号判死 → streak=0）
  -- walk 下界 tracking_started_on=08-15：09-16 无记录已结算 → 恰停在 1，无需额外铺数据
  if (v_stats ->> 'streak_days')::int <> 1 then
    raise exception 'ASSERT T13 失败（雷日应 complete=true，单天窗口 streak 应=1，实际 %）: %',
      v_stats ->> 'streak_days', v_stats;
  end if;
  v_proof := v_proof || jsonb_build_object('T13_p0test_landmine_defused', 'pass',
    'landmine', 'p0test:anchor-f1@2026-09-17', 'recorded_count', 3, 'denominator', 2,
    'streak_single_day', 1, 'dow', 'thu(isodow=4，Review 通知误记周六，denominator 同为 2)');

  raise exception 'MVP004_PROOF %', v_proof;
end;
$$;
