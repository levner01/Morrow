-- MVP-004 返工 / migration 0015：complete 语义统一为「多记不罚」（>=）——统计不说谎红线
--
-- 【缺陷】complete 判定严格等号（rec = den）与前端 heatmap.js cellState 的 rec >= den 语义矛盾：
--   某日分母 2、存在 3 条 live planned+actual 行（2 项计划 + 1 条外来多余行：补记/导入/数据修复均可产生）
--   → heatmap 涂「全记录」实底，Core 却判 incomplete → streak 断链。同一天格子是绿的、连续天数断了。
-- 【真库触发物】p0test:anchor-f1（biz_date=2026-09-17 周四，planned=true，actual 非空，live）；
--   真库 tracking 起日 2026-09-21 故当前未炸，起日回拨或任何多余 live 行即触发。
-- 【根因】0013 L218 起用等号时全部测试在干净铺数据下跑（无外来行场景），缺陷随 MVP-001 验收潜伏至今。
--
-- 【ARCHITECTURE ALERT 裁决】（result.md §9 留档，等 Review 签核）：
--   1. 0013 文件本身不动（不改已应用 migration 的铁律）；0015 以 create or replace 同签名替换函数体，
--      grants 不因 replace 丢失（同签名 replace 保留 ACL），尾部幂等重申 revoke 保险。
--   2. 同款等号共 4 处，一次修齐，避免"修一半仍自相矛盾"：
--      - private.mvp_stats        walk 段 complete（0013 L218，Review 点名）
--      - private.mvp_stats_extend walk 段 complete（0014 L199，Review 点名）
--      - private.mvp_stats_extend today_complete（0014 L182，同款：今日多记会被误判未完成 → 文案说谎）
--      - private.mvp_heatmap_30   格 provisional 判定（0014 L104，同款：多记日会被错标"在途"虚线）
--   3. 语义裁决：complete := rec >= den（多记不罚）。recorded_count 仍如实输出原始行数（不 cap），
--      分子可大于分母——数据异常如实投影，不藏。
begin;

-- ========== 1. private.mvp_stats（0013 继承缺陷修复：仅 walk 段 complete 由 = 改 >=，其余逐字不变） ==========
create or replace function private.mvp_stats(
  p_uid uuid, p_settings public.workspace_settings, p_from date, p_to date)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_planned int := 0; v_recorded int := 0; v_met int := 0;
  v_int_met int := 0; v_int_not int := 0; v_int_unknown int := 0;
  v_streak int := 0;
  v_d date; v_plan jsonb; v_wx boolean; v_need int;
  v_rec_cnt int; v_met_cnt int;
  v_w_act timestamptz; v_l_act timestamptz;
  v_now timestamptz := now();
  v_today date; v_complete boolean; v_settled boolean;
begin
  if p_to < p_from then
    return jsonb_build_object(
      'scope', jsonb_build_object('from', p_from, 'to', p_to),
      'planned_count', 0, 'recorded_count', 0, 'met_count', 0, 'recording_rate', null,
      'interval_met_count', 0, 'interval_not_met_count', 0, 'interval_unknown_count', 0,
      'streak_days', 0);
  end if;
  if p_to > p_from + 400 then
    raise exception 'stats_range_too_large' using errcode = 'P0001';
  end if;
  v_today := (v_now at time zone 'Asia/Shanghai')::date;

  v_d := p_from;
  while v_d <= p_to loop
    v_plan := private.resolve_day_plan(p_settings, v_d);
    if v_plan is not null then
      v_wx := (v_plan ->> 'workout_expected')::boolean;
      v_need := case when v_wx then 3 else 2 end;
      v_planned := v_planned + v_need;
      select
        count(*) filter (where (a.payload ->> 'planned')::boolean
                          and a.payload ->> 'actual_at' is not null),
        count(*) filter (where (a.payload ->> 'planned')::boolean
                          and a.payload ->> 'actual_at' is not null
                          and a.payload ->> 'target_at' is not null
                          and (a.payload ->> 'actual_at')::timestamptz
                              <= (a.payload ->> 'target_at')::timestamptz),
        max((a.payload ->> 'actual_at')::timestamptz)
          filter (where a.payload ->> 'anchor_type' = 'workout_end'),
        max((a.payload ->> 'actual_at')::timestamptz)
          filter (where a.payload ->> 'anchor_type' = 'lights_off')
      into v_rec_cnt, v_met_cnt, v_w_act, v_l_act
        from public.life_data a
       where a.user_id = p_uid and a.module = 'anchor'
         and a.biz_date = v_d and a.deleted_at is null;
      v_recorded := v_recorded + coalesce(v_rec_cnt, 0);
      v_met := v_met + coalesce(v_met_cnt, 0);
      if v_wx and (v_w_act is not null or v_l_act is not null) then
        if v_w_act is not null and v_l_act is not null then
          if extract(epoch from (v_l_act - v_w_act)) / 60 >= 180 then
            v_int_met := v_int_met + 1;
          else
            v_int_not := v_int_not + 1;
          end if;
        else
          v_int_unknown := v_int_unknown + 1;  -- F06：记录缺失时 interval 只能 unknown
        end if;
      end if;
    end if;
    v_d := v_d + 1;
  end loop;

  -- 连续记录天数：自 min(p_to, today) 回走；已结算未完成断链，未结算未完成跳过（不提前断链）
  v_d := least(p_to, v_today);
  while v_d >= p_from loop
    v_plan := private.resolve_day_plan(p_settings, v_d);
    exit when v_plan is null;
    v_need := case when (v_plan ->> 'workout_expected')::boolean then 3 else 2 end;
    select count(*) filter (where (a.payload ->> 'planned')::boolean
                             and a.payload ->> 'actual_at' is not null)
    into v_rec_cnt
      from public.life_data a
     where a.user_id = p_uid and a.module = 'anchor'
       and a.biz_date = v_d and a.deleted_at is null;
    -- 0015 修复：complete = 多记不罚（>=），与 heatmap cellState 同一语义；多余 live 行不再断链
    v_complete := coalesce(v_rec_cnt, 0) >= v_need;
    if v_complete then
      v_streak := v_streak + 1;
    else
      v_settled := v_now >= ((v_d + 1)::text || ' 12:00:00+08:00')::timestamptz;
      exit when v_settled;
    end if;
    v_d := v_d - 1;
  end loop;

  return jsonb_build_object(
    'scope', jsonb_build_object('from', p_from, 'to', p_to),
    'planned_count', v_planned,
    'recorded_count', v_recorded,
    'met_count', v_met,
    'recording_rate', case when v_planned = 0 then null
                           else v_recorded::numeric / v_planned end,
    'interval_met_count', v_int_met,
    'interval_not_met_count', v_int_not,
    'interval_unknown_count', v_int_unknown,
    'streak_days', v_streak);
end;
$$;

-- ========== 2. private.mvp_heatmap_30（0014 L104 同款修复：格 complete/provisional 判定 >=） ==========
create or replace function private.mvp_heatmap_30(
  p_uid uuid, p_settings public.workspace_settings, p_from date, p_to date)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_days jsonb := '[]'::jsonb;
  v_d date;
  v_plan jsonb;
  v_wx boolean;
  v_need int;
  v_rec int; v_met int; v_late int;
  v_w_act timestamptz; v_l_act timestamptz;
  v_interval text;
  v_settled boolean; v_complete boolean;
  v_has_data boolean;
  v_dt_code text;
  v_now timestamptz := now();
  v_today date := (now() at time zone 'Asia/Shanghai')::date;
begin
  if p_to < p_from then
    return '[]'::jsonb;
  end if;
  if p_to > p_from + 400 then
    raise exception 'heatmap_range_too_large' using errcode = 'P0001';
  end if;

  v_d := p_from;
  while v_d <= p_to loop
    v_plan := private.resolve_day_plan(p_settings, v_d);
    if v_plan is null then
      -- 未开始日：无分母、不涂失败色（C-03 指标段）
      v_days := v_days || jsonb_build_object(
        'biz_date', v_d,
        'not_started', true,
        'has_data', false,
        'settled', v_now >= ((v_d + 1)::text || ' 12:00:00+08:00')::timestamptz,
        'provisional', false,
        'is_today', v_d = v_today,
        'day_type_code', null,
        'workout_expected', false,
        'denominator', 0,
        'recorded_count', 0,
        'met_count', 0,
        'recorded_late_count', 0,
        'interval_state', 'none');
    else
      v_wx := (v_plan ->> 'workout_expected')::boolean;
      v_need := case when v_wx then 3 else 2 end;

      select
        count(*) filter (where (a.payload ->> 'planned')::boolean
                          and a.payload ->> 'actual_at' is not null),
        count(*) filter (where (a.payload ->> 'planned')::boolean
                          and a.payload ->> 'actual_at' is not null
                          and a.payload ->> 'target_at' is not null
                          and (a.payload ->> 'actual_at')::timestamptz
                              <= (a.payload ->> 'target_at')::timestamptz),
        count(*) filter (where (a.payload ->> 'planned')::boolean
                          and a.payload ->> 'actual_at' is not null
                          and a.payload ->> 'target_at' is not null
                          and (a.payload ->> 'actual_at')::timestamptz
                              > (a.payload ->> 'target_at')::timestamptz),
        max((a.payload ->> 'actual_at')::timestamptz)
          filter (where a.payload ->> 'anchor_type' = 'workout_end'),
        max((a.payload ->> 'actual_at')::timestamptz)
          filter (where a.payload ->> 'anchor_type' = 'lights_off')
      into v_rec, v_met, v_late, v_w_act, v_l_act
        from public.life_data a
       where a.user_id = p_uid and a.module = 'anchor'
         and a.biz_date = v_d and a.deleted_at is null;

      -- interval_state 与 mvp_stats 对齐：训练日且至少一项有记录才评估；全没记 = none
      if not v_wx or (v_w_act is null and v_l_act is null) then
        v_interval := 'none';
      elsif v_w_act is null or v_l_act is null then
        v_interval := 'unknown';  -- F06：缺一项只能 unknown，不伪装达标
      elsif extract(epoch from (v_l_act - v_w_act)) / 60 >= 180 then
        v_interval := 'met';
      else
        v_interval := 'not_met';
      end if;

      -- 日型 code：物化行优先，否则计划派生（与 context 同一事实源）
      select d.payload ->> 'code' into v_dt_code
        from public.life_data d
       where d.user_id = p_uid and d.module = 'day_type'
         and d.entity_key = v_d::text and d.deleted_at is null;
      v_dt_code := coalesce(v_dt_code, v_plan ->> 'code');

      -- 0015 修复：complete = 多记不罚（>=）；多记日不再被错标 provisional「在途」
      v_complete := coalesce(v_rec, 0) >= v_need;
      v_settled := v_now >= ((v_d + 1)::text || ' 12:00:00+08:00')::timestamptz;
      v_has_data := coalesce(v_rec, 0) > 0
        or exists (select 1 from public.life_data d
                    where d.user_id = p_uid and d.module = 'day_type'
                      and d.entity_key = v_d::text and d.deleted_at is null);

      v_days := v_days || jsonb_build_object(
        'biz_date', v_d,
        'not_started', false,
        'has_data', v_has_data,
        'settled', v_settled,
        'provisional', (not v_settled) and (not v_complete),  -- 在途未完成（F12 不提前断链）
        'is_today', v_d = v_today,
        'day_type_code', v_dt_code,
        'workout_expected', v_wx,
        'denominator', v_need,
        'recorded_count', coalesce(v_rec, 0),
        'met_count', coalesce(v_met, 0),
        'recorded_late_count', coalesce(v_late, 0),
        'interval_state', v_interval);
    end if;
    v_d := v_d + 1;
  end loop;

  return v_days;
end;
$$;

-- ========== 3. private.mvp_stats_extend（0014 L182/L199 同款修复：today_complete 与 walk complete >=） ==========
create or replace function private.mvp_stats_extend(
  p_uid uuid, p_settings public.workspace_settings, p_from date, p_to date)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_base jsonb;
  v_late int;
  v_met_rate numeric;
  v_today date := (now() at time zone 'Asia/Shanghai')::date;
  v_now timestamptz := now();
  v_plan jsonb;
  v_need int; v_rec int;
  v_today_complete boolean; v_today_provisional boolean;
  v_streak int := 0;
  v_d date;
  v_complete boolean; v_settled boolean;
begin
  -- 基础窗口统计（planned/recorded/met/recording_rate/interval_*）复用 0013 已验收逻辑（0015 已修 walk）
  v_base := private.mvp_stats(p_uid, p_settings, p_from, p_to);

  -- 记录迟到数（F14：actual>target 仍计 recorded 分子，但不计 met）
  select count(*) into v_late
    from public.life_data a
   where a.user_id = p_uid and a.module = 'anchor'
     and a.biz_date between p_from and p_to
     and a.deleted_at is null
     and (a.payload ->> 'planned')::boolean
     and a.payload ->> 'actual_at' is not null
     and a.payload ->> 'target_at' is not null
     and (a.payload ->> 'actual_at')::timestamptz
         > (a.payload ->> 'target_at')::timestamptz;

  v_met_rate := case when coalesce((v_base ->> 'planned_count')::int, 0) = 0 then null
                     else (v_base ->> 'met_count')::numeric / (v_base ->> 'planned_count')::numeric end;

  -- 今日状态（provisional 语义供 UI 文案"今日完成后 +1"）
  v_plan := private.resolve_day_plan(p_settings, v_today);
  if v_plan is null then
    v_today_complete := null;
    v_today_provisional := null;
  else
    v_need := case when (v_plan ->> 'workout_expected')::boolean then 3 else 2 end;
    select count(*) filter (where (a.payload ->> 'planned')::boolean
                             and a.payload ->> 'actual_at' is not null)
      into v_rec
      from public.life_data a
     where a.user_id = p_uid and a.module = 'anchor'
       and a.biz_date = v_today and a.deleted_at is null;
    -- 0015 修复：今日多记也算完成（>=），文案不再说谎
    v_today_complete := coalesce(v_rec, 0) >= v_need;
    v_today_provisional := not v_today_complete;
  end if;

  -- 准确连续（F09）：从 min(p_to, today) 回走到 tracking_started_on 或断链，
  -- 下界是跟踪起日而非 p_from——30 天窗口不能冒充终身连续（合同 84 行）。
  v_d := least(p_to, v_today);
  while v_d >= p_settings.tracking_started_on loop
    v_plan := private.resolve_day_plan(p_settings, v_d);
    exit when v_plan is null;
    v_need := case when (v_plan ->> 'workout_expected')::boolean then 3 else 2 end;
    select count(*) filter (where (a.payload ->> 'planned')::boolean
                             and a.payload ->> 'actual_at' is not null)
      into v_rec
      from public.life_data a
     where a.user_id = p_uid and a.module = 'anchor'
       and a.biz_date = v_d and a.deleted_at is null;
    -- 0015 修复：complete = 多记不罚（>=），与 heatmap cellState 同一语义；多余 live 行不再断链
    v_complete := coalesce(v_rec, 0) >= v_need;
    if v_complete then
      v_streak := v_streak + 1;
    else
      v_settled := v_now >= ((v_d + 1)::text || ' 12:00:00+08:00')::timestamptz;
      exit when v_settled;  -- 已结算未完成断链；未结算未完成跳过（F12 不提前断链）
    end if;
    v_d := v_d - 1;
  end loop;

  return v_base || jsonb_build_object(
    'met_rate', v_met_rate,
    'recorded_late_count', coalesce(v_late, 0),
    'streak_days', v_streak,
    'today_complete', v_today_complete,
    'today_provisional', v_today_provisional,
    'tracking_started_on', p_settings.tracking_started_on);
end;
$$;

-- ========== 4. grants 保险（同签名 replace 保留 ACL；幂等重申 private 不授客户端纪律） ==========
revoke all on function private.mvp_stats(uuid, public.workspace_settings, date, date) from public, anon, authenticated, service_role;
revoke all on function private.mvp_heatmap_30(uuid, public.workspace_settings, date, date) from public, anon, authenticated, service_role;
revoke all on function private.mvp_stats_extend(uuid, public.workspace_settings, date, date) from public, anon, authenticated, service_role;

commit;
