-- MVP-001 / migration 0013：业务 Core——日型计划解析与物化、三锚点打卡、分母锁、record_open 去重、今日上下文
-- 依据：02-contracts.md C-02（锚点/日型 payload、计划落地与分母 7 条）、C-03（达标/统计/下一步，F01–F14）、
--       C-04（统一命令事务）、C-05（Human RPC 表面）；01-architecture.md §5/AD-07；AGENTS.md 固定三锚点。
-- 边界：不改任何已应用 migration（0001–0012 不动）；不建前端；不开 Agent 业务入口；不动 agent_clients/scopes。
-- 冻结常量：wake 06:50 / workout_end 19:15（训练日）/ lights_off 22:15；timezone Asia/Shanghai。
-- code→中文名冻结映射：ordinary_workday=普通工作日、workout_workday=训练工作日、weekend=周末、
--   weekend_workout=周末健身日。workout_workday 之名以 P0-003 已登记 fixture（sha256 入 manifest）为准；
--   产品 V2 原文作"健身工作日"，差异留档，不改已注册 fixture。
-- 骨架模板：严格对齐 0008 cmd_initialize_workspace_v1（身份复核→envelope→actor/request_id→
--   lock_workspace_state→receipt_begin→业务校验→行锁→写→receipt_complete）。

begin;

-- ========== 1. record_open 去重：同 owner/device/生活日至多 1 条 human.opened ==========
create unique index if not exists activity_log_human_opened_uq
  on public.activity_log (user_id, (metadata ->> 'device_id'), (metadata ->> 'biz_date'))
  where action = 'human.opened';

-- ========== 2. 计划解析纯函数（不读库，不含 now()） ==========

-- 日型 payload 唯一构造点：冻结 name/时间常量/anchors 固定 3 元素顺序（schema 只约束公共形状，顺序由 Core 保证）
create or replace function private.mvp_day_payload(p_code text, p_template_version text, p_plan_locked boolean)
returns jsonb
language plpgsql immutable security definer set search_path = '' as $$
declare
  v_workout boolean;
begin
  if p_code not in ('ordinary_workday','workout_workday','weekend','weekend_workout') then
    raise exception 'day_type_code_invalid' using errcode = 'P0001';
  end if;
  v_workout := p_code in ('workout_workday','weekend_workout');
  return jsonb_build_object(
    'payload_v', 1,
    'code', p_code,
    'name', case p_code
      when 'ordinary_workday' then '普通工作日'
      when 'workout_workday'  then '训练工作日'
      when 'weekend'          then '周末'
      when 'weekend_workout'  then '周末健身日' end,
    'timezone', 'Asia/Shanghai',
    'template_version', p_template_version,
    'workout_expected', v_workout,
    'sleep_target', '22:15',
    'anchors', jsonb_build_array(
      jsonb_build_object('type', 'wake',        'required', true,       'target_local_time', '06:50'),
      jsonb_build_object('type', 'workout_end', 'required', v_workout,
        'target_local_time', case when v_workout then '19:15' end),
      jsonb_build_object('type', 'lights_off',  'required', true,       'target_local_time', '22:15')),
    'plan_locked', p_plan_locked);
end;
$$;

-- 纯函数解析：tracking_started_on 后每一天都有默认计划（C-02 计划落地 1）；起日前返回 null
-- template_version = schedule_history 段序号（1 起，decimal string）
create or replace function private.resolve_day_plan(p_settings public.workspace_settings, p_date date)
returns jsonb
language plpgsql immutable security definer set search_path = '' as $$
declare
  v_seg jsonb;
  v_idx int;
  v_dow text;
  v_code text;
begin
  select s.value, s.ordinality::int into v_seg, v_idx
    from jsonb_array_elements(p_settings.schedule_history) with ordinality as s(value, ordinality)
   where (s.value ->> 'effective_from')::date <= p_date
   order by (s.value ->> 'effective_from')::date desc, s.ordinality desc
   limit 1;
  if not found then
    return null;
  end if;
  v_dow := (array['mon','tue','wed','thu','fri','sat','sun'])[extract(isodow from p_date)::int];
  v_code := v_seg -> 'weekday_codes' ->> v_dow;
  if v_code is null then
    raise exception 'schedule_segment_invalid' using errcode = 'P0001';
  end if;
  return private.mvp_day_payload(v_code, v_idx::text, false);
end;
$$;

-- ========== 3. 物化：当日首写同事务落 day_type + 3 锚点初态（C-02 计划落地 3） ==========
-- 已存在行一律不覆盖（ON CONFLICT DO NOTHING），返回 day_type 行（新插或既有）。
-- 调用方必须已：set actor / set request_id / lock_workspace_state / receipt_begin。
create or replace function private.materialize_day(p_uid uuid, p_date date)
returns public.life_data
language plpgsql security definer set search_path = '' as $$
declare
  v_settings public.workspace_settings%rowtype;
  v_plan jsonb;
  v_day public.life_data%rowtype;
  v_anchor text;
  v_planned boolean;
  v_target text;
begin
  select * into v_settings from public.workspace_settings s where s.user_id = p_uid;
  if not found then
    raise exception 'workspace_not_initialized' using errcode = 'P0001';
  end if;
  v_plan := private.resolve_day_plan(v_settings, p_date);
  if v_plan is null then
    return null;  -- 跟踪起日前：无计划可物化
  end if;

  insert into public.life_data (user_id, module, entity_key, biz_date, payload)
  values (p_uid, 'day_type', p_date::text, p_date, v_plan)
  on conflict (user_id, module, entity_key) do nothing
  returning * into v_day;
  if not found then
    select * into v_day from public.life_data d
     where d.user_id = p_uid and d.module = 'day_type' and d.entity_key = p_date::text;
  end if;

  foreach v_anchor in array array['wake','workout_end','lights_off'] loop
    v_planned := v_anchor <> 'workout_end' or (v_plan ->> 'workout_expected')::boolean;
    v_target := case
      when v_anchor = 'wake' then p_date::text || 'T06:50:00+08:00'
      when v_anchor = 'workout_end' and v_planned then p_date::text || 'T19:15:00+08:00'
      when v_anchor = 'lights_off' then p_date::text || 'T22:15:00+08:00'
      else null end;
    insert into public.life_data (user_id, module, entity_key, biz_date, payload)
    values (p_uid, 'anchor', p_date::text || '/' || v_anchor, p_date, jsonb_build_object(
      'payload_v', 1,
      'anchor_type', v_anchor,
      'timezone', 'Asia/Shanghai',
      'target_at', v_target,
      'actual_at', cast(null as text),
      'status', case when v_planned then 'pending' else 'not_applicable' end,
      'planned', v_planned,
      'note', '',
      'plan_version', v_day.version::text))
    on conflict (user_id, module, entity_key) do nothing;
  end loop;
  return v_day;
end;
$$;

-- ========== 4. 统计投影（C-03）：分母由历史计划决定，含从未打开日期（F10） ==========
-- recording_rate = recorded_planned / planned（planned=0 时 null，F14 与达标率分离）；
-- met_count 只计 actual<=target；训练→关灯间隔另列 met/not_met/unknown（F05/F06）；
-- streak 按 C-03 结算点规则：次日 12:00 结算，未结算且未完成=provisional 不断链（F12 语义）。
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
    v_complete := coalesce(v_rec_cnt, 0) = v_need;
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

-- ========== 5. 写命令（Human LWW；actor/version/target/status 全由 Core 掌管） ==========

create or replace function private.cmd_set_day_type_v1(p_uid uuid, p_envelope jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_request_id uuid := gen_random_uuid();
  v_key uuid; v_input jsonb; v_rs record;
  v_biz date; v_code text; v_today date;
  v_day public.life_data%rowtype;
  v_old_code text; v_old_wx boolean; v_new_wx boolean;
  v_no_change boolean := false;
  v_result jsonb;
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
     or not (p_envelope ? 'input')
     or jsonb_typeof(p_envelope -> 'input') <> 'object' then
    perform private.write_event(p_uid, 'human', p_uid, 'command.rejected',
      'command', null, jsonb_build_object('operation', 'set_day_type_v1', 'code', 'VALIDATION_FAILED'));
    return private.err_envelope('VALIDATION_FAILED',
      'envelope 形状非法（api_version/idempotency_key/input；Human 命令不接受 expected_version）',
      false, v_request_id);
  end if;
  v_key := (p_envelope ->> 'idempotency_key')::uuid;
  v_input := p_envelope -> 'input';

  perform private.cmd_set_actor('human', p_uid);
  perform set_config('morrow.request_id', v_request_id::text, true);
  perform private.lock_workspace_state(p_uid);

  select * into v_rs from private.receipt_begin(p_uid, 'human', p_uid, v_key, 'set_day_type_v1', v_input);
  if v_rs.status = 'conflict' then
    return private.cmd_finish_err(p_uid, 'human', p_uid, null, 'set_day_type_v1',
      'IDEMPOTENCY_KEY_REUSED', '同一幂等键绑定了不同请求内容', false, v_request_id);
  elsif v_rs.status = 'expired' then
    return private.cmd_finish_err(p_uid, 'human', p_uid, null, 'set_day_type_v1',
      'IDEMPOTENCY_RESULT_EXPIRED', '收据响应已过期，请重新读取当前状态', false, v_request_id);
  elsif v_rs.status = 'replay' then
    return private.cmd_wrap_replay(v_rs.stored_state, v_rs.stored_response, v_request_id);
  end if;

  -- 旧客户端未知字段安全拒写（白名单）；code 枚举冻结
  if (select count(*) from jsonb_object_keys(v_input) k where k not in ('biz_date','code')) > 0
     or (v_input ->> 'biz_date') is null
     or (v_input ->> 'biz_date') !~ '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'
     or (v_input ->> 'code') is null
     or (v_input ->> 'code') not in ('ordinary_workday','workout_workday','weekend','weekend_workout') then
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'set_day_type_v1',
      'VALIDATION_FAILED', 'input 字段非法（biz_date/code）', false, v_request_id);
  end if;
  v_biz := (v_input ->> 'biz_date')::date;
  v_code := v_input ->> 'code';

  if not exists (select 1 from public.workspace_settings s where s.user_id = p_uid) then
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'set_day_type_v1',
      'WORKSPACE_NOT_INITIALIZED', '工作区尚未初始化', false, v_request_id);
  end if;
  v_today := (now() at time zone 'Asia/Shanghai')::date;  -- F13：工作区时区今日
  if v_biz is distinct from v_today then
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'set_day_type_v1',
      'VALIDATION_FAILED', '仅可设置今日日型', false, v_request_id);
  end if;

  v_day := private.materialize_day(p_uid, v_biz);
  if v_day is null then
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'set_day_type_v1',
      'VALIDATION_FAILED', '该日期早于跟踪起日，无默认计划', false, v_request_id);
  end if;
  select * into v_day from public.life_data d where d.id = v_day.id for update;
  v_old_code := v_day.payload ->> 'code';
  v_old_wx := (v_day.payload ->> 'workout_expected')::boolean;
  v_new_wx := v_code in ('workout_workday','weekend_workout');

  if v_old_code = v_code then
    v_no_change := true;
  elsif (v_day.payload ->> 'plan_locked')::boolean then
    -- 已锁：仅允许单向追加训练（非训练→训练），其余改型/减项拒绝（F11、C-02 计划落地 4）
    if v_old_wx or not v_new_wx then
      return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'set_day_type_v1',
        'DAY_PLAN_LOCKED', '当日计划已锁定：只允许追加训练，不能减少或改型', false, v_request_id);
    end if;
    update public.life_data d
       set payload = private.mvp_day_payload(v_code, d.payload ->> 'template_version', true)
     where d.id = v_day.id
    returning * into v_day;
    -- 只把原 n/a 训练项翻为 required/target；保留原 plan_version 作 provenance（C-02 计划落地 5）
    update public.life_data d
       set payload = d.payload || jsonb_build_object(
             'target_at', to_jsonb(v_biz::text || 'T19:15:00+08:00'),
             'status', to_jsonb('pending'::text),
             'planned', to_jsonb(true))
     where d.user_id = p_uid and d.module = 'anchor'
       and d.entity_key = v_biz::text || '/workout_end'
       and d.deleted_at is null
       and d.payload ->> 'status' = 'not_applicable';
  else
    -- 未锁：全切，全部 pending/n-a 锚点目标/适用性/plan_version 同步到新计划版本
    update public.life_data d
       set payload = private.mvp_day_payload(v_code, d.payload ->> 'template_version', false)
     where d.id = v_day.id
    returning * into v_day;
    update public.life_data d
       set payload = jsonb_build_object(
             'payload_v', 1,
             'anchor_type', d.payload ->> 'anchor_type',
             'timezone', 'Asia/Shanghai',
             'target_at', case
               when d.payload ->> 'anchor_type' = 'wake' then to_jsonb(v_biz::text || 'T06:50:00+08:00')
               when d.payload ->> 'anchor_type' = 'workout_end'
                 then case when v_new_wx then to_jsonb(v_biz::text || 'T19:15:00+08:00') else 'null'::jsonb end
               else to_jsonb(v_biz::text || 'T22:15:00+08:00') end,
             'actual_at', 'null'::jsonb,
             'status', case
               when d.payload ->> 'anchor_type' = 'workout_end' and not v_new_wx
                 then to_jsonb('not_applicable'::text)
               else to_jsonb('pending'::text) end,
             'planned', case
               when d.payload ->> 'anchor_type' = 'workout_end' then to_jsonb(v_new_wx)
               else to_jsonb(true) end,
             'note', d.payload -> 'note',
             'plan_version', to_jsonb(v_day.version::text))
     where d.user_id = p_uid and d.module = 'anchor'
       and d.biz_date = v_biz and d.deleted_at is null
       and d.payload ->> 'status' in ('pending','not_applicable');
  end if;

  v_result := jsonb_build_object(
    'no_change', v_no_change,
    'record', jsonb_build_object(
      'id', v_day.id, 'module', v_day.module, 'entity_key', v_day.entity_key,
      'biz_date', v_day.biz_date, 'payload', v_day.payload,
      'version', v_day.version::text, 'updated_at', v_day.updated_at));
  perform private.receipt_complete(p_uid, 'human', p_uid, v_key, v_result);
  return jsonb_build_object(
    'ok', true, 'request_id', v_request_id, 'server_time', now()::text,
    'replayed', false, 'result', v_result);
end;
$$;

create or replace function private.cmd_check_anchor_v1(p_uid uuid, p_envelope jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_request_id uuid := gen_random_uuid();
  v_key uuid; v_input jsonb; v_rs record;
  v_biz date; v_anchor text; v_actual timestamptz; v_today date;
  v_local timestamp;
  v_day public.life_data%rowtype;
  v_row public.life_data%rowtype;
  v_new_payload jsonb;
  v_no_change boolean := false;
  v_result jsonb;
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
     or not (p_envelope ? 'input')
     or jsonb_typeof(p_envelope -> 'input') <> 'object' then
    perform private.write_event(p_uid, 'human', p_uid, 'command.rejected',
      'command', null, jsonb_build_object('operation', 'check_anchor_v1', 'code', 'VALIDATION_FAILED'));
    return private.err_envelope('VALIDATION_FAILED',
      'envelope 形状非法（api_version/idempotency_key/input；Human 命令不接受 expected_version）',
      false, v_request_id);
  end if;
  v_key := (p_envelope ->> 'idempotency_key')::uuid;
  v_input := p_envelope -> 'input';

  perform private.cmd_set_actor('human', p_uid);
  perform set_config('morrow.request_id', v_request_id::text, true);
  perform private.lock_workspace_state(p_uid);

  select * into v_rs from private.receipt_begin(p_uid, 'human', p_uid, v_key, 'check_anchor_v1', v_input);
  if v_rs.status = 'conflict' then
    return private.cmd_finish_err(p_uid, 'human', p_uid, null, 'check_anchor_v1',
      'IDEMPOTENCY_KEY_REUSED', '同一幂等键绑定了不同请求内容', false, v_request_id);
  elsif v_rs.status = 'expired' then
    return private.cmd_finish_err(p_uid, 'human', p_uid, null, 'check_anchor_v1',
      'IDEMPOTENCY_RESULT_EXPIRED', '收据响应已过期，请重新读取当前状态', false, v_request_id);
  elsif v_rs.status = 'replay' then
    return private.cmd_wrap_replay(v_rs.stored_state, v_rs.stored_response, v_request_id);
  end if;

  -- 只收 actual_at/note 等允许字段；status/source/version/target 禁止提交（C-02/C-04）
  if (select count(*) from jsonb_object_keys(v_input) k
      where k not in ('biz_date','anchor_type','actual_at','note')) > 0
     or (v_input ->> 'biz_date') is null
     or (v_input ->> 'biz_date') !~ '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'
     or (v_input ->> 'anchor_type') is null
     or (v_input ->> 'anchor_type') not in ('wake','workout_end','lights_off')
     or (v_input ->> 'actual_at') is null
     or (v_input ->> 'actual_at') !~ '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$'
     or (v_input ? 'note' and jsonb_typeof(v_input -> 'note') is distinct from 'string')
     or char_length(coalesce(v_input ->> 'note', '')) > 2000 then
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'check_anchor_v1',
      'VALIDATION_FAILED', 'input 字段非法（biz_date/anchor_type/actual_at/note）', false, v_request_id);
  end if;
  v_biz := (v_input ->> 'biz_date')::date;
  v_anchor := v_input ->> 'anchor_type';
  v_actual := (v_input ->> 'actual_at')::timestamptz;

  if not exists (select 1 from public.workspace_settings s where s.user_id = p_uid) then
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'check_anchor_v1',
      'WORKSPACE_NOT_INITIALIZED', '工作区尚未初始化', false, v_request_id);
  end if;
  v_today := (now() at time zone 'Asia/Shanghai')::date;
  if v_biz > v_today then
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'check_anchor_v1',
      'VALIDATION_FAILED', '不可为未来日期打卡', false, v_request_id);
  end if;
  if v_actual > now() + interval '60 seconds' then
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'check_anchor_v1',
      'VALIDATION_FAILED', '实际时间不可为未来', false, v_request_id);
  end if;

  -- 归属校验（C-02/C-03）：wake/workout_end 本地日=biz_date；
  -- lights_off ∈ [当日 12:00, 次日 12:00)，次日凌晨归前日（F08：00:30→前日，偏差+135）
  v_local := v_actual at time zone 'Asia/Shanghai';
  if v_anchor in ('wake','workout_end') and v_local::date is distinct from v_biz then
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'check_anchor_v1',
      'VALIDATION_FAILED', '实际时间不属于该生活日', false, v_request_id);
  end if;
  if v_anchor = 'lights_off'
     and (v_local < (v_biz::text || ' 12:00:00')::timestamp
          or v_local >= ((v_biz + 1)::text || ' 12:00:00')::timestamp) then
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'check_anchor_v1',
      'VALIDATION_FAILED', '关灯时间须在该日 12:00 至次日 12:00 之间', false, v_request_id);
  end if;

  v_day := private.materialize_day(p_uid, v_biz);
  if v_day is null then
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'check_anchor_v1',
      'VALIDATION_FAILED', '该日期早于跟踪起日，无默认计划', false, v_request_id);
  end if;
  select * into v_day from public.life_data d where d.id = v_day.id for update;
  select * into v_row from public.life_data d
   where d.user_id = p_uid and d.module = 'anchor'
     and d.entity_key = v_biz::text || '/' || v_anchor
   for update;
  if not found then
    raise exception 'anchor_materialize_failed' using errcode = 'P0001';
  end if;
  if v_row.deleted_at is not null then
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'check_anchor_v1',
      'RESOURCE_DELETED', '记录已删除', false, v_request_id);
  end if;
  if v_row.payload ->> 'status' = 'not_applicable' then
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'check_anchor_v1',
      'ANCHOR_NOT_APPLICABLE', '当日无此训练计划；如需训练请先将今日设为训练日', false, v_request_id);
  end if;

  -- LWW：Core 导出 status/target/planned/plan_version；actual_at 归一化为工作区墙钟 +08:00
  v_new_payload := jsonb_build_object(
    'payload_v', 1,
    'anchor_type', v_anchor,
    'timezone', 'Asia/Shanghai',
    'target_at', v_row.payload -> 'target_at',
    'actual_at', to_jsonb(to_char(v_actual at time zone 'Asia/Shanghai', 'YYYY-MM-DD"T"HH24:MI:SS') || '+08:00'),
    'status', to_jsonb('recorded'::text),
    'planned', v_row.payload -> 'planned',
    'note', coalesce(v_input -> 'note', v_row.payload -> 'note'),
    'plan_version', v_row.payload -> 'plan_version');

  if v_new_payload = v_row.payload then
    v_no_change := true;
  else
    update public.life_data d set payload = v_new_payload where d.id = v_row.id
    returning * into v_row;
    -- 记录首个 actual_at 后锁定既有计划目标与分母下限（C-02 计划落地 4）
    if not (v_day.payload ->> 'plan_locked')::boolean then
      update public.life_data d
         set payload = d.payload || jsonb_build_object('plan_locked', to_jsonb(true))
       where d.id = v_day.id
      returning * into v_day;
    end if;
  end if;

  v_result := jsonb_build_object(
    'no_change', v_no_change,
    'record', jsonb_build_object(
      'id', v_row.id, 'module', v_row.module, 'entity_key', v_row.entity_key,
      'biz_date', v_row.biz_date, 'payload', v_row.payload,
      'version', v_row.version::text, 'updated_at', v_row.updated_at),
    'day_type', jsonb_build_object(
      'id', v_day.id, 'code', v_day.payload ->> 'code',
      'plan_locked', (v_day.payload ->> 'plan_locked')::boolean,
      'version', v_day.version::text));
  perform private.receipt_complete(p_uid, 'human', p_uid, v_key, v_result);
  return jsonb_build_object(
    'ok', true, 'request_id', v_request_id, 'server_time', now()::text,
    'replayed', false, 'result', v_result);
end;
$$;

create or replace function private.cmd_clear_anchor_v1(p_uid uuid, p_envelope jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_request_id uuid := gen_random_uuid();
  v_key uuid; v_input jsonb; v_rs record;
  v_biz date; v_anchor text; v_today date;
  v_day public.life_data%rowtype;
  v_row public.life_data%rowtype;
  v_no_change boolean := false;
  v_result jsonb;
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
     or not (p_envelope ? 'input')
     or jsonb_typeof(p_envelope -> 'input') <> 'object' then
    perform private.write_event(p_uid, 'human', p_uid, 'command.rejected',
      'command', null, jsonb_build_object('operation', 'clear_anchor_v1', 'code', 'VALIDATION_FAILED'));
    return private.err_envelope('VALIDATION_FAILED',
      'envelope 形状非法（api_version/idempotency_key/input；Human 命令不接受 expected_version）',
      false, v_request_id);
  end if;
  v_key := (p_envelope ->> 'idempotency_key')::uuid;
  v_input := p_envelope -> 'input';

  perform private.cmd_set_actor('human', p_uid);
  perform set_config('morrow.request_id', v_request_id::text, true);
  perform private.lock_workspace_state(p_uid);

  select * into v_rs from private.receipt_begin(p_uid, 'human', p_uid, v_key, 'clear_anchor_v1', v_input);
  if v_rs.status = 'conflict' then
    return private.cmd_finish_err(p_uid, 'human', p_uid, null, 'clear_anchor_v1',
      'IDEMPOTENCY_KEY_REUSED', '同一幂等键绑定了不同请求内容', false, v_request_id);
  elsif v_rs.status = 'expired' then
    return private.cmd_finish_err(p_uid, 'human', p_uid, null, 'clear_anchor_v1',
      'IDEMPOTENCY_RESULT_EXPIRED', '收据响应已过期，请重新读取当前状态', false, v_request_id);
  elsif v_rs.status = 'replay' then
    return private.cmd_wrap_replay(v_rs.stored_state, v_rs.stored_response, v_request_id);
  end if;

  if (select count(*) from jsonb_object_keys(v_input) k where k not in ('biz_date','anchor_type')) > 0
     or (v_input ->> 'biz_date') is null
     or (v_input ->> 'biz_date') !~ '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'
     or (v_input ->> 'anchor_type') is null
     or (v_input ->> 'anchor_type') not in ('wake','workout_end','lights_off') then
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'clear_anchor_v1',
      'VALIDATION_FAILED', 'input 字段非法（biz_date/anchor_type）', false, v_request_id);
  end if;
  v_biz := (v_input ->> 'biz_date')::date;
  v_anchor := v_input ->> 'anchor_type';

  if not exists (select 1 from public.workspace_settings s where s.user_id = p_uid) then
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'clear_anchor_v1',
      'WORKSPACE_NOT_INITIALIZED', '工作区尚未初始化', false, v_request_id);
  end if;
  v_today := (now() at time zone 'Asia/Shanghai')::date;
  if v_biz > v_today then
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'clear_anchor_v1',
      'VALIDATION_FAILED', '不可为未来日期操作', false, v_request_id);
  end if;

  v_day := private.materialize_day(p_uid, v_biz);
  if v_day is null then
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'clear_anchor_v1',
      'VALIDATION_FAILED', '该日期早于跟踪起日，无默认计划', false, v_request_id);
  end if;
  select * into v_row from public.life_data d
   where d.user_id = p_uid and d.module = 'anchor'
     and d.entity_key = v_biz::text || '/' || v_anchor
   for update;
  if not found then
    raise exception 'anchor_materialize_failed' using errcode = 'P0001';
  end if;
  if v_row.deleted_at is not null then
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'clear_anchor_v1',
      'RESOURCE_DELETED', '记录已删除', false, v_request_id);
  end if;

  -- 清事实不清计划：actual_at 置空、status 回落；planned/target/plan_version/note 保留；
  -- 不改变分母、不解锁 plan_locked（C-02 计划落地 4、F11）
  if v_row.payload ->> 'actual_at' is null
     and v_row.payload ->> 'status' in ('pending','not_applicable') then
    v_no_change := true;
  else
    update public.life_data d
       set payload = jsonb_build_object(
             'payload_v', 1,
             'anchor_type', v_anchor,
             'timezone', 'Asia/Shanghai',
             'target_at', d.payload -> 'target_at',
             'actual_at', 'null'::jsonb,
             'status', case when (d.payload ->> 'planned')::boolean
                            then to_jsonb('pending'::text)
                            else to_jsonb('not_applicable'::text) end,
             'planned', d.payload -> 'planned',
             'note', d.payload -> 'note',
             'plan_version', d.payload -> 'plan_version')
     where d.id = v_row.id
    returning * into v_row;
  end if;

  v_result := jsonb_build_object(
    'no_change', v_no_change,
    'record', jsonb_build_object(
      'id', v_row.id, 'module', v_row.module, 'entity_key', v_row.entity_key,
      'biz_date', v_row.biz_date, 'payload', v_row.payload,
      'version', v_row.version::text, 'updated_at', v_row.updated_at));
  perform private.receipt_complete(p_uid, 'human', p_uid, v_key, v_result);
  return jsonb_build_object(
    'ok', true, 'request_id', v_request_id, 'server_time', now()::text,
    'replayed', false, 'result', v_result);
end;
$$;

create or replace function private.cmd_update_anchor_note_v1(p_uid uuid, p_envelope jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_request_id uuid := gen_random_uuid();
  v_key uuid; v_input jsonb; v_rs record;
  v_record_id uuid;
  v_row public.life_data%rowtype;
  v_no_change boolean := false;
  v_result jsonb;
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
     or not (p_envelope ? 'input')
     or jsonb_typeof(p_envelope -> 'input') <> 'object' then
    perform private.write_event(p_uid, 'human', p_uid, 'command.rejected',
      'command', null, jsonb_build_object('operation', 'update_anchor_note_v1', 'code', 'VALIDATION_FAILED'));
    return private.err_envelope('VALIDATION_FAILED',
      'envelope 形状非法（api_version/idempotency_key/input；Human 命令不接受 expected_version）',
      false, v_request_id);
  end if;
  v_key := (p_envelope ->> 'idempotency_key')::uuid;
  v_input := p_envelope -> 'input';

  perform private.cmd_set_actor('human', p_uid);
  perform set_config('morrow.request_id', v_request_id::text, true);
  perform private.lock_workspace_state(p_uid);

  select * into v_rs from private.receipt_begin(p_uid, 'human', p_uid, v_key, 'update_anchor_note_v1', v_input);
  if v_rs.status = 'conflict' then
    return private.cmd_finish_err(p_uid, 'human', p_uid, null, 'update_anchor_note_v1',
      'IDEMPOTENCY_KEY_REUSED', '同一幂等键绑定了不同请求内容', false, v_request_id);
  elsif v_rs.status = 'expired' then
    return private.cmd_finish_err(p_uid, 'human', p_uid, null, 'update_anchor_note_v1',
      'IDEMPOTENCY_RESULT_EXPIRED', '收据响应已过期，请重新读取当前状态', false, v_request_id);
  elsif v_rs.status = 'replay' then
    return private.cmd_wrap_replay(v_rs.stored_state, v_rs.stored_response, v_request_id);
  end if;

  if (select count(*) from jsonb_object_keys(v_input) k where k not in ('record_id','note')) > 0
     or (v_input ->> 'record_id') is null
     or (v_input ->> 'record_id') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     or not (v_input ? 'note')
     or jsonb_typeof(v_input -> 'note') is distinct from 'string'
     or char_length(v_input ->> 'note') > 2000 then
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'update_anchor_note_v1',
      'VALIDATION_FAILED', 'input 字段非法（record_id/note）', false, v_request_id);
  end if;
  v_record_id := (v_input ->> 'record_id')::uuid;

  select * into v_row from public.life_data d
   where d.user_id = p_uid and d.id = v_record_id
   for update;
  if not found then
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'update_anchor_note_v1',
      'RESOURCE_NOT_FOUND', '记录不存在', false, v_request_id);
  end if;
  if v_row.module <> 'anchor' then
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'update_anchor_note_v1',
      'VALIDATION_FAILED', '仅支持锚点记录', false, v_request_id);
  end if;
  if v_row.deleted_at is not null then
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'update_anchor_note_v1',
      'RESOURCE_DELETED', '记录已删除', false, v_request_id);
  end if;

  -- 同一记录 LWW 仅改 note，其余当前字段由 Core 保留（不接受任意 JSON patch）
  if v_row.payload -> 'note' = v_input -> 'note' then
    v_no_change := true;
  else
    update public.life_data d
       set payload = d.payload || jsonb_build_object('note', v_input -> 'note')
     where d.id = v_row.id
    returning * into v_row;
  end if;

  v_result := jsonb_build_object(
    'no_change', v_no_change,
    'record', jsonb_build_object(
      'id', v_row.id, 'module', v_row.module, 'entity_key', v_row.entity_key,
      'biz_date', v_row.biz_date, 'payload', v_row.payload,
      'version', v_row.version::text, 'updated_at', v_row.updated_at));
  perform private.receipt_complete(p_uid, 'human', p_uid, v_key, v_result);
  return jsonb_build_object(
    'ok', true, 'request_id', v_request_id, 'server_time', now()::text,
    'replayed', false, 'result', v_result);
end;
$$;

create or replace function private.cmd_record_open_v1(p_uid uuid, p_envelope jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_request_id uuid := gen_random_uuid();
  v_key uuid; v_input jsonb; v_rs record;
  v_device text; v_biz date;
  v_open_id uuid;
  v_deduped boolean := false;
  v_result jsonb;
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
     or not (p_envelope ? 'input')
     or jsonb_typeof(p_envelope -> 'input') <> 'object' then
    perform private.write_event(p_uid, 'human', p_uid, 'command.rejected',
      'command', null, jsonb_build_object('operation', 'record_open_v1', 'code', 'VALIDATION_FAILED'));
    return private.err_envelope('VALIDATION_FAILED',
      'envelope 形状非法（api_version/idempotency_key/input；Human 命令不接受 expected_version）',
      false, v_request_id);
  end if;
  v_key := (p_envelope ->> 'idempotency_key')::uuid;
  v_input := p_envelope -> 'input';

  perform private.cmd_set_actor('human', p_uid);
  perform set_config('morrow.request_id', v_request_id::text, true);
  perform private.lock_workspace_state(p_uid);

  select * into v_rs from private.receipt_begin(p_uid, 'human', p_uid, v_key, 'record_open_v1', v_input);
  if v_rs.status = 'conflict' then
    return private.cmd_finish_err(p_uid, 'human', p_uid, null, 'record_open_v1',
      'IDEMPOTENCY_KEY_REUSED', '同一幂等键绑定了不同请求内容', false, v_request_id);
  elsif v_rs.status = 'expired' then
    return private.cmd_finish_err(p_uid, 'human', p_uid, null, 'record_open_v1',
      'IDEMPOTENCY_RESULT_EXPIRED', '收据响应已过期，请重新读取当前状态', false, v_request_id);
  elsif v_rs.status = 'replay' then
    return private.cmd_wrap_replay(v_rs.stored_state, v_rs.stored_response, v_request_id);
  end if;

  -- device_id 仅去重标识，不作身份凭据（身份永久来自 JWT owner 复核，见函数入口）
  if (select count(*) from jsonb_object_keys(v_input) k where k not in ('device_id','biz_date')) > 0
     or (v_input ->> 'device_id') is null
     or jsonb_typeof(v_input -> 'device_id') is distinct from 'string'
     or char_length(v_input ->> 'device_id') not between 1 and 200
     or (v_input ->> 'biz_date') is null
     or (v_input ->> 'biz_date') !~ '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$' then
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'record_open_v1',
      'VALIDATION_FAILED', 'input 字段非法（device_id/biz_date）', false, v_request_id);
  end if;
  v_device := v_input ->> 'device_id';
  v_biz := (v_input ->> 'biz_date')::date;

  if not exists (select 1 from public.workspace_settings s where s.user_id = p_uid) then
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'record_open_v1',
      'WORKSPACE_NOT_INITIALIZED', '工作区尚未初始化', false, v_request_id);
  end if;

  -- 同 device 同日即使更换幂等 key 也至多 1 条（部分唯一索引兜底）；重复不刷日志
  begin
    insert into public.activity_log
      (user_id, actor_type, actor_id, agent_id, action, resource, resource_id, request_id, metadata)
    values
      (p_uid, 'human', p_uid, null, 'human.opened', 'workspace', null, v_request_id,
       jsonb_build_object('device_id', v_device, 'biz_date', v_biz::text))
    returning id into v_open_id;
  exception when unique_violation then
    v_open_id := null;
  end;
  v_deduped := v_open_id is null;

  v_result := jsonb_build_object(
    'recorded', not v_deduped,
    'deduped', v_deduped,
    'device_id', v_device,
    'biz_date', v_biz,
    'open_id', v_open_id);
  perform private.receipt_complete(p_uid, 'human', p_uid, v_key, v_result);
  return jsonb_build_object(
    'ok', true, 'request_id', v_request_id, 'server_time', now()::text,
    'replayed', false, 'result', v_result);
end;
$$;

-- ========== 6. 今日上下文（只读；workspace_state FOR SHARE 一致锁，不物化业务数据） ==========
-- 未物化日期返回计划派生占位（version='0', materialized:false），不把占位当实际记录（C-02 计划落地 2）。
create or replace function private.cmd_get_today_context_v1(p_uid uuid, p_envelope jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_request_id uuid := gen_random_uuid();
  v_input jsonb;
  v_biz date; v_today date;
  v_settings public.workspace_settings%rowtype;
  v_rev bigint;
  v_plan jsonb;
  v_day public.life_data%rowtype;
  v_dt jsonb;
  v_anchors jsonb := '[]'::jsonb;
  v_atype text;
  v_row public.life_data%rowtype;
  v_p jsonb; v_mat boolean; v_ver text; v_rid uuid; v_planned boolean;
  v_target timestamptz; v_actual_ts timestamptz;
  v_dev numeric; v_met boolean;
  v_w_act timestamptz; v_l_act timestamptz;
  v_int_min numeric; v_int_met boolean;
  v_na jsonb;
  v_e jsonb;
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
  if (select count(*) from jsonb_object_keys(v_input) k where k not in ('biz_date')) > 0
     or ((v_input ? 'biz_date') and (v_input ->> 'biz_date') !~ '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$') then
    return private.err_envelope('VALIDATION_FAILED', 'input 字段非法（biz_date）', false, v_request_id);
  end if;

  -- 一致锁：先 FOR SHARE workspace_state，与写同一锁边界；并发计划/打卡变更不会混入快照
  perform 1 from public.workspace_state s where s.user_id = p_uid for share;
  if not found then
    raise exception 'workspace_state_missing' using errcode = 'P0001';
  end if;
  select s.data_revision into v_rev from public.workspace_state s where s.user_id = p_uid;

  select * into v_settings from public.workspace_settings s where s.user_id = p_uid;
  if not found then
    return private.err_envelope('WORKSPACE_NOT_INITIALIZED', '工作区尚未初始化', false, v_request_id);
  end if;

  v_today := (now() at time zone 'Asia/Shanghai')::date;  -- F13：工作区时区
  v_biz := coalesce((v_input ->> 'biz_date')::date, v_today);
  v_plan := private.resolve_day_plan(v_settings, v_biz);
  if v_plan is null then
    return private.err_envelope('VALIDATION_FAILED', '该日期早于跟踪起日，无计划上下文', false, v_request_id);
  end if;

  -- 日型投影：物化行优先，否则计划派生占位
  select * into v_day from public.life_data d
   where d.user_id = p_uid and d.module = 'day_type'
     and d.entity_key = v_biz::text and d.deleted_at is null;
  if found then
    v_dt := v_day.payload || jsonb_build_object(
      'record_id', v_day.id, 'version', v_day.version::text, 'materialized', true);
  else
    v_dt := v_plan || jsonb_build_object(
      'record_id', null, 'version', '0', 'materialized', false);
  end if;

  -- 三锚点投影（固定顺序）+ 派生 target_met/deviation_minutes
  foreach v_atype in array array['wake','workout_end','lights_off'] loop
    select * into v_row from public.life_data d
     where d.user_id = p_uid and d.module = 'anchor'
       and d.entity_key = v_biz::text || '/' || v_atype and d.deleted_at is null;
    if found then
      v_p := v_row.payload; v_mat := true; v_ver := v_row.version::text; v_rid := v_row.id;
    else
      v_planned := v_atype <> 'workout_end' or (v_plan ->> 'workout_expected')::boolean;
      v_p := jsonb_build_object(
        'payload_v', 1, 'anchor_type', v_atype, 'timezone', 'Asia/Shanghai',
        'target_at', case
          when v_atype = 'wake' then to_jsonb(v_biz::text || 'T06:50:00+08:00')
          when v_atype = 'workout_end'
            then case when v_planned then to_jsonb(v_biz::text || 'T19:15:00+08:00') else 'null'::jsonb end
          else to_jsonb(v_biz::text || 'T22:15:00+08:00') end,
        'actual_at', 'null'::jsonb,
        'status', case when v_planned then 'pending' else 'not_applicable' end,
        'planned', v_planned, 'note', '',
        'plan_version', v_plan ->> 'template_version');
      v_mat := false; v_ver := '0'; v_rid := null;
    end if;
    v_target := (v_p ->> 'target_at')::timestamptz;
    v_actual_ts := (v_p ->> 'actual_at')::timestamptz;
    v_dev := case when v_actual_ts is not null and v_target is not null
                  then extract(epoch from (v_actual_ts - v_target)) / 60 end;
    v_met := case when v_actual_ts is not null and v_target is not null
                  then v_actual_ts <= v_target end;
    v_anchors := v_anchors || jsonb_build_array(jsonb_build_object(
      'anchor_type', v_atype,
      'planned', (v_p ->> 'planned')::boolean,
      'target_at', v_p -> 'target_at',
      'actual_at', v_p -> 'actual_at',
      'status', v_p ->> 'status',
      'note', v_p ->> 'note',
      'plan_version', v_p ->> 'plan_version',
      'record_id', v_rid,
      'version', v_ver,
      'materialized', v_mat,
      'target_met', v_met,
      'deviation_minutes', v_dev));
  end loop;

  -- 训练→关灯实际间隔（F03–F06）：只在 workout_end 元素上输出 interval 字段
  select (e ->> 'actual_at')::timestamptz into v_w_act
    from jsonb_array_elements(v_anchors) e where e ->> 'anchor_type' = 'workout_end';
  select (e ->> 'actual_at')::timestamptz into v_l_act
    from jsonb_array_elements(v_anchors) e where e ->> 'anchor_type' = 'lights_off';
  v_int_min := case when v_w_act is not null and v_l_act is not null
                    then extract(epoch from (v_l_act - v_w_act)) / 60 end;
  v_int_met := case when v_int_min is null then null
                    when v_int_min >= 180 then true else false end;
  v_anchors := (
    select jsonb_agg(
      case when e ->> 'anchor_type' = 'workout_end'
           then e || jsonb_build_object(
                  'interval_to_lights_off_minutes', v_int_min,
                  'interval_met', v_int_met)
           else e end
      order by array_position(array['wake','workout_end','lights_off'], e ->> 'anchor_type'))
    from jsonb_array_elements(v_anchors) e);

  -- 下一步（C-03）：计划中尚未记录的首个锚点；过时 overdue 标记；全部完成 day_complete
  if v_biz > v_today then
    v_na := jsonb_build_object('kind', 'future');
  else
    v_na := null;
    for v_e in
      select e from jsonb_array_elements(v_anchors) with ordinality as t(e, ord) order by t.ord
    loop
      if (v_e ->> 'planned')::boolean and v_e ->> 'status' <> 'recorded' then
        v_na := jsonb_build_object(
          'kind', 'record_anchor',
          'anchor_type', v_e ->> 'anchor_type',
          'target_at', v_e -> 'target_at',
          'biz_date_relation', case when v_biz < v_today then 'past' else 'today' end,
          'overdue', case
            when v_biz < v_today then true
            when (v_e ->> 'target_at') is not null and now() > (v_e ->> 'target_at')::timestamptz
              then true
            else false end);
        exit;
      end if;
    end loop;
    if v_na is null then
      v_na := jsonb_build_object('kind', 'day_complete');
    end if;
  end if;

  v_stats := private.mvp_stats(p_uid, v_settings, v_settings.tracking_started_on, v_biz);

  return jsonb_build_object(
    'ok', true, 'request_id', v_request_id, 'server_time', now()::text,
    'result', jsonb_build_object(
      'biz_date', v_biz,
      'today', v_today,
      'timezone', v_settings.timezone,
      'tracking_started_on', v_settings.tracking_started_on,
      'data_revision', v_rev::text,
      'day_type', v_dt,
      'anchors', v_anchors,
      'next_action', v_na,
      'stats', v_stats));
end;
$$;

-- ========== 7. public invoker 壳（SECURITY INVOKER → private definer） ==========

create or replace function public.set_day_type_v1(p_envelope jsonb)
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
  return private.cmd_set_day_type_v1(v_uid, p_envelope);
end;
$$;

create or replace function public.check_anchor_v1(p_envelope jsonb)
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
  return private.cmd_check_anchor_v1(v_uid, p_envelope);
end;
$$;

create or replace function public.clear_anchor_v1(p_envelope jsonb)
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
  return private.cmd_clear_anchor_v1(v_uid, p_envelope);
end;
$$;

create or replace function public.update_anchor_note_v1(p_envelope jsonb)
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
  return private.cmd_update_anchor_note_v1(v_uid, p_envelope);
end;
$$;

create or replace function public.record_open_v1(p_envelope jsonb)
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
  return private.cmd_record_open_v1(v_uid, p_envelope);
end;
$$;

create or replace function public.get_today_context_v1(p_envelope jsonb)
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
  return private.cmd_get_today_context_v1(v_uid, p_envelope);
end;
$$;

-- ========== 8. grants 收口 ==========
revoke all on function public.set_day_type_v1(jsonb)        from public, anon, authenticated, service_role;
revoke all on function public.check_anchor_v1(jsonb)        from public, anon, authenticated, service_role;
revoke all on function public.clear_anchor_v1(jsonb)        from public, anon, authenticated, service_role;
revoke all on function public.update_anchor_note_v1(jsonb)  from public, anon, authenticated, service_role;
revoke all on function public.record_open_v1(jsonb)         from public, anon, authenticated, service_role;
revoke all on function public.get_today_context_v1(jsonb)   from public, anon, authenticated, service_role;
grant execute on function public.set_day_type_v1(jsonb)        to authenticated;
grant execute on function public.check_anchor_v1(jsonb)        to authenticated;
grant execute on function public.clear_anchor_v1(jsonb)        to authenticated;
grant execute on function public.update_anchor_note_v1(jsonb)  to authenticated;
grant execute on function public.record_open_v1(jsonb)         to authenticated;
grant execute on function public.get_today_context_v1(jsonb)   to authenticated;

-- private 命令函数：invoker 链需要 authenticated EXECUTE；函数内强制 p_uid=auth.uid()+owner 复核
revoke all on function private.cmd_set_day_type_v1(uuid, jsonb)       from public, anon, authenticated, service_role;
revoke all on function private.cmd_check_anchor_v1(uuid, jsonb)       from public, anon, authenticated, service_role;
revoke all on function private.cmd_clear_anchor_v1(uuid, jsonb)       from public, anon, authenticated, service_role;
revoke all on function private.cmd_update_anchor_note_v1(uuid, jsonb) from public, anon, authenticated, service_role;
revoke all on function private.cmd_record_open_v1(uuid, jsonb)        from public, anon, authenticated, service_role;
revoke all on function private.cmd_get_today_context_v1(uuid, jsonb)  from public, anon, authenticated, service_role;
grant execute on function private.cmd_set_day_type_v1(uuid, jsonb)       to authenticated;
grant execute on function private.cmd_check_anchor_v1(uuid, jsonb)       to authenticated;
grant execute on function private.cmd_clear_anchor_v1(uuid, jsonb)       to authenticated;
grant execute on function private.cmd_update_anchor_note_v1(uuid, jsonb) to authenticated;
grant execute on function private.cmd_record_open_v1(uuid, jsonb)        to authenticated;
grant execute on function private.cmd_get_today_context_v1(uuid, jsonb)  to authenticated;

-- private helper：不授予任何客户端角色（撤销默认 PUBLIC EXECUTE）
revoke all on function private.mvp_day_payload(text, text, boolean)              from public, anon, authenticated, service_role;
revoke all on function private.resolve_day_plan(public.workspace_settings, date) from public, anon, authenticated, service_role;
revoke all on function private.materialize_day(uuid, date)                       from public, anon, authenticated, service_role;
revoke all on function private.mvp_stats(uuid, public.workspace_settings, date, date) from public, anon, authenticated, service_role;

commit;
