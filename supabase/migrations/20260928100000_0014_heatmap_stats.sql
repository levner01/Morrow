-- MVP-004：30 天热力图投影 + 不失真统计扩展 + get_anchor_history_v1（C-03 / F09 / F10 / F12）
-- 纯新增，不动 0001..0013 任何函数；contracts 零新增（get-anchor-history-v1 schema/fixture P0 链已预置）。
--
-- 统计不失真红线（02-contracts.md C-03）：
-- 1. streak 准确连续：从 min(p_to, today) 回走到 tracking_started_on 或断链，**不受 p_from 窗口裁剪**（F09：45 天连续返回 45）。
-- 2. 结算点 = 次日 12:00（Asia/Shanghai）；未结算且未完成 = provisional 不断链也不计数（F12）。
-- 3. recording_rate 与 met_rate 分离：recorded 计分子不看达标；met 只计 actual<=target；迟到 actual 仍计 recorded（F14）。
-- 4. 未开始日（tracking_started_on 之前）无分母不涂失败色；未访问日照算分母（F10）。
-- 5. interval unknown 不伪装达标：训练日只记一项 → unknown；两项都没记 → none（不进 unknown 统计，与 0013 mvp_stats 对齐）。
-- 6. UI 零计算：planned/recorded/met/streak/interval 全部 Core 输出。

begin;

-- ========== 1. 逐日投影 helper（MVP UI 固定 30 天；参数泛化供 history ≤366 天复用） ==========
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

      -- interval_state 与 0013 mvp_stats 对齐：训练日且至少一项有记录才评估；全没记 = none
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

      v_complete := coalesce(v_rec, 0) = v_need;
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

-- ========== 2. 统计扩展 helper（mvp_stats 基础 + met_rate/late/today 状态；streak 不受窗口裁剪） ==========
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
  -- 基础窗口统计（planned/recorded/met/recording_rate/interval_*）复用 0013 已验收逻辑
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
    v_today_complete := coalesce(v_rec, 0) = v_need;
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
    v_complete := coalesce(v_rec, 0) = v_need;
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

-- ========== 3. 历史读命令（from/to 必填，跨度 ≤366 天 Core 判定，拒未来窗口） ==========
create or replace function private.cmd_get_anchor_history_v1(p_uid uuid, p_envelope jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_request_id uuid := gen_random_uuid();
  v_input jsonb;
  v_from date; v_to date; v_today date;
  v_settings public.workspace_settings%rowtype;
  v_rev bigint;
  v_days jsonb;
  v_stats jsonb;
begin
  if p_uid is null or p_uid is distinct from auth.uid()
     or not exists (select 1 from private.workspace_owner o where o.user_id = p_uid) then
    return private.err_envelope('OWNER_DENIED', '仅工作区 owner 可执行', false, v_request_id);
  end if;
  if p_envelope is null or jsonb_typeof(p_envelope) <> 'object'
     or (p_envelope ->> 'api_version') is distinct from '1'
     or not (p_envelope ? 'idempotency_key')
     or (p_envelope ->> 'idempotency_key') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     or p_envelope ? 'expected_version'
     or (p_envelope ? 'input') and jsonb_typeof(p_envelope -> 'input') <> 'object' then
    return private.err_envelope('VALIDATION_FAILED', 'envelope 形状非法', false, v_request_id);
  end if;
  v_input := coalesce(p_envelope -> 'input', '{}'::jsonb);
  if (select count(*) from jsonb_object_keys(v_input) k where k not in ('from', 'to', 'cursor')) > 0
     or not (v_input ? 'from') or not (v_input ? 'to')
     or (v_input ->> 'from') !~ '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'
     or (v_input ->> 'to') !~ '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'
     or ((v_input ? 'cursor') and (jsonb_typeof(v_input -> 'cursor') <> 'string'
         or length(v_input ->> 'cursor') > 200)) then
    return private.err_envelope('VALIDATION_FAILED', 'input 字段非法（from/to/cursor）', false, v_request_id);
  end if;

  v_from := (v_input ->> 'from')::date;
  v_to := (v_input ->> 'to')::date;
  v_today := (now() at time zone 'Asia/Shanghai')::date;
  if v_from > v_to then
    return private.err_envelope('VALIDATION_FAILED', 'from 不能晚于 to', false, v_request_id);
  end if;
  if v_to > v_from + 365 then
    return private.err_envelope('VALIDATION_FAILED', '窗口跨度最大 366 天', false, v_request_id);
  end if;
  if v_to > v_today then
    -- F12 语义：未来日期不存在连续规则，不许给未来配色
    return private.err_envelope('VALIDATION_FAILED', 'to 不能超过今日（未来日无统计）', false, v_request_id);
  end if;

  -- 一致锁：FOR SHARE workspace_state，与 context/写同一锁边界
  perform 1 from public.workspace_state s where s.user_id = p_uid for share;
  if not found then
    raise exception 'workspace_state_missing' using errcode = 'P0001';
  end if;
  select s.data_revision into v_rev from public.workspace_state s where s.user_id = p_uid;

  select * into v_settings from public.workspace_settings s where s.user_id = p_uid;
  if not found then
    return private.err_envelope('WORKSPACE_NOT_INITIALIZED', '工作区尚未初始化', false, v_request_id);
  end if;

  v_days := private.mvp_heatmap_30(p_uid, v_settings, v_from, v_to);
  v_stats := private.mvp_stats_extend(p_uid, v_settings, v_from, v_to);

  return jsonb_build_object(
    'ok', true, 'request_id', v_request_id, 'server_time', now()::text,
    'result', jsonb_build_object(
      'from', v_from,
      'to', v_to,
      'timezone', v_settings.timezone,
      'tracking_started_on', v_settings.tracking_started_on,
      'data_revision', v_rev::text,
      'days', v_days,
      'stats', v_stats,
      -- MVP 窗口 ≤366 天一次拿完，不分页；cursor 入参接受但当前恒 null（result.md 留档）
      'next_cursor', null));
end;
$$;

-- ========== 4. public invoker 壳（SECURITY INVOKER → private definer） ==========
create or replace function public.get_anchor_history_v1(p_envelope jsonb)
returns jsonb
language plpgsql volatile security invoker set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', jsonb_build_object(
      'code', 'UNAUTHENTICATED', 'message', '需要登录', 'retryable', false,
      'request_id', gen_random_uuid()));
  end if;
  return private.cmd_get_anchor_history_v1(v_uid, p_envelope);
end;
$$;

-- ========== 5. grants 收口（照 0013 纪律） ==========
revoke all on function public.get_anchor_history_v1(jsonb) from public, anon, authenticated, service_role;
grant execute on function public.get_anchor_history_v1(jsonb) to authenticated;

revoke all on function private.cmd_get_anchor_history_v1(uuid, jsonb) from public, anon, authenticated, service_role;
grant execute on function private.cmd_get_anchor_history_v1(uuid, jsonb) to authenticated;

-- private helper：不授予任何客户端角色（撤销默认 PUBLIC EXECUTE）
revoke all on function private.mvp_heatmap_30(uuid, public.workspace_settings, date, date) from public, anon, authenticated, service_role;
revoke all on function private.mvp_stats_extend(uuid, public.workspace_settings, date, date) from public, anon, authenticated, service_role;

commit;
