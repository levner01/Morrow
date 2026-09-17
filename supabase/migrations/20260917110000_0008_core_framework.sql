-- P0-004 / migration 0008：唯一 Core 的身份、事务、版本、审计与幂等框架
-- 依据：01-architecture.md §3.10/§4/§5/§10.1；02-contracts.md C-04/C-05/C-05.1/C-06/C-10
-- 头部裁决（需求方开工令）：版本触发器本次必须落地（V2.1 BEFORE UPDATE 原子递增），
--   验收含"并发 UPDATE 无重号"实测。
-- 边界：不建业务 HTTP/MCP；private helper 不授予任何客户端角色；不改已应用 migration。
-- 函数 owner = postgres（Supabase 托管 migration 执行角色；架构目标形态的"独立 NOLOGIN
--   Core owner"在托管环境以 postgres 为事实载体，记入收据决策）。

begin;

-- ========== 1. 可信 actor 上下文（transaction-local GUC） ==========
-- morrow.actor = '<type>:<uuid>'；仅 Core definer 函数设置；trigger 缺失即拒。
-- 客户端角色对业务表无 DML grant（P0-003 已实证），本机制为纵深防御，不替代 grant/RLS。

create or replace function private.cmd_set_actor(p_type text, p_id uuid)
returns void
language plpgsql volatile security definer set search_path = '' as $$
begin
  if p_type not in ('human','agent','system','import') or p_id is null then
    raise exception 'actor_context_invalid' using errcode = 'P0001';
  end if;
  perform set_config('morrow.actor', p_type || ':' || p_id::text, true);
end;
$$;

create or replace function private.current_actor(out actor_type text, out actor_id uuid)
language plpgsql stable security definer set search_path = '' as $$
declare
  v text := current_setting('morrow.actor', true);
begin
  if v is null or v = '' then
    raise exception 'actor_context_missing' using errcode = 'P0001';
  end if;
  actor_type := split_part(v, ':', 1);
  actor_id := split_part(v, ':', 2)::uuid;
  if actor_type not in ('human','agent','system','import') then
    raise exception 'actor_context_invalid' using errcode = 'P0001';
  end if;
exception when invalid_text_representation then
  raise exception 'actor_context_invalid' using errcode = 'P0001';
end;
$$;

-- ========== 2. 版本 / 不可变列 BEFORE trigger ==========

create or replace function private.trg_life_data_before_insert()
returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_at text; v_aid uuid;
begin
  select a.actor_type, a.actor_id into v_at, v_aid from private.current_actor() a;
  -- 来源只信事务内可信上下文，不信调用方传值
  NEW.source_type := v_at;
  NEW.source_id := v_aid;
  NEW.version := 1;
  NEW.created_at := now();
  NEW.updated_at := now();
  return NEW;
end;
$$;

create or replace function private.trg_life_data_before_update()
returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_at text; v_aid uuid;
begin
  select a.actor_type, a.actor_id into v_at, v_aid from private.current_actor() a;
  if NEW.id          is distinct from OLD.id
     or NEW.user_id     is distinct from OLD.user_id
     or NEW.module      is distinct from OLD.module
     or NEW.entity_key  is distinct from OLD.entity_key
     or NEW.source_type is distinct from OLD.source_type
     or NEW.source_id   is distinct from OLD.source_id
     or NEW.created_at  is distinct from OLD.created_at then
    raise exception 'immutable_column_violation' using errcode = 'P0001';
  end if;
  NEW.version := OLD.version + 1;
  NEW.updated_at := now();
  return NEW;
end;
$$;

create or replace function private.trg_settings_before_update()
returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_at text; v_aid uuid;
begin
  select a.actor_type, a.actor_id into v_at, v_aid from private.current_actor() a;
  if NEW.user_id is distinct from OLD.user_id
     or NEW.created_at is distinct from OLD.created_at then
    raise exception 'immutable_column_violation' using errcode = 'P0001';
  end if;
  NEW.version := OLD.version + 1;
  NEW.updated_at := now();
  return NEW;
end;
$$;

create or replace function private.trg_clients_before_update()
returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_at text; v_aid uuid;
begin
  select a.actor_type, a.actor_id into v_at, v_aid from private.current_actor() a;
  if NEW.id is distinct from OLD.id
     or NEW.user_id is distinct from OLD.user_id
     or NEW.created_at is distinct from OLD.created_at then
    raise exception 'immutable_column_violation' using errcode = 'P0001';
  end if;
  -- 仅 last_seen_at 变化：不作为 client 配置变更，不增 version、不动 updated_at（§3.10）
  if NEW.name       is not distinct from OLD.name
     and NEW.type       is not distinct from OLD.type
     and NEW.scopes     is not distinct from OLD.scopes
     and NEW.enabled    is not distinct from OLD.enabled
     and NEW.revoked_at is not distinct from OLD.revoked_at
     and NEW.version    is not distinct from OLD.version
     and NEW.updated_at is not distinct from OLD.updated_at
     and NEW.last_seen_at is distinct from OLD.last_seen_at then
    NEW.version := OLD.version;
    NEW.updated_at := OLD.updated_at;
    return NEW;
  end if;
  NEW.version := OLD.version + 1;
  NEW.updated_at := now();
  return NEW;
end;
$$;

-- ========== 3. AFTER 审计 + revision trigger（唯一资源日志来源） ==========

create or replace function private.trg_after_write_audit()
returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_at text; v_aid uuid;
  v_meta jsonb := '{}';
  v_rid uuid;
  v_skip_log boolean := false;
begin
  select a.actor_type, a.actor_id into v_at, v_aid from private.current_actor() a;

  -- agent_clients 仅 last_seen_at 变化：bump revision（属导出变化）但不写配置日志
  if TG_TABLE_NAME = 'agent_clients' and TG_OP = 'UPDATE'
     and NEW.name       is not distinct from OLD.name
     and NEW.type       is not distinct from OLD.type
     and NEW.scopes     is not distinct from OLD.scopes
     and NEW.enabled    is not distinct from OLD.enabled
     and NEW.revoked_at is not distinct from OLD.revoked_at
     and NEW.version    is not distinct from OLD.version then
    v_skip_log := true;
  end if;

  if not v_skip_log then
    if TG_TABLE_NAME = 'life_data' then
      v_rid := NEW.id;
      v_meta := jsonb_build_object(
        'module', NEW.module, 'entity_key', NEW.entity_key,
        'biz_date', NEW.biz_date, 'deleted', NEW.deleted_at is not null);
    elsif TG_TABLE_NAME = 'workspace_settings' then
      v_rid := null;
      v_meta := jsonb_build_object(
        'timezone', NEW.timezone, 'tracking_started_on', NEW.tracking_started_on);
    elsif TG_TABLE_NAME = 'agent_clients' then
      v_rid := NEW.id;
      v_meta := jsonb_build_object(
        'name', NEW.name, 'type', NEW.type,
        'enabled', NEW.enabled, 'revoked', NEW.revoked_at is not null);
    end if;
    insert into public.activity_log
      (user_id, actor_type, actor_id, agent_id, action, resource, resource_id, request_id, metadata)
    values
      (NEW.user_id, v_at, v_aid,
       case when v_at = 'agent' then v_aid end,
       TG_TABLE_NAME || '.' || lower(TG_OP), TG_TABLE_NAME, v_rid,
       nullif(current_setting('morrow.request_id', true), '')::uuid,
       v_meta);
  end if;

  -- 同事务 bump 导出 revision；行必须已预置（部署时零值），不存在即技术故障整体回滚
  update public.workspace_state
     set data_revision = data_revision + 1, updated_at = now()
   where user_id = NEW.user_id;
  if not found then
    raise exception 'workspace_state_missing' using errcode = 'P0001';
  end if;
  return NEW;
end;
$$;

-- activity_log 自身变化只 bump revision（T11），不再生成日志（不递归）
create or replace function private.trg_activity_bump_revision()
returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.workspace_state
     set data_revision = data_revision + 1, updated_at = now()
   where user_id = NEW.user_id;
  if not found then
    raise exception 'workspace_state_missing' using errcode = 'P0001';
  end if;
  return NEW;
end;
$$;

create trigger trg_life_data_bi
  before insert on public.life_data
  for each row execute function private.trg_life_data_before_insert();
create trigger trg_life_data_bu
  before update on public.life_data
  for each row execute function private.trg_life_data_before_update();
create trigger trg_life_data_aw
  after insert or update on public.life_data
  for each row execute function private.trg_after_write_audit();

create trigger trg_settings_bu
  before update on public.workspace_settings
  for each row execute function private.trg_settings_before_update();
create trigger trg_settings_aw
  after insert or update on public.workspace_settings
  for each row execute function private.trg_after_write_audit();

create trigger trg_clients_bu
  before update on public.agent_clients
  for each row execute function private.trg_clients_before_update();
create trigger trg_clients_aw
  after insert or update on public.agent_clients
  for each row execute function private.trg_after_write_audit();

create trigger trg_activity_ai
  after insert on public.activity_log
  for each row execute function private.trg_activity_bump_revision();

-- ========== 4. receipt 幂等框架 ==========
-- namespace (user_id, actor_type, actor_id, idempotency_key)；request_hash = sha256({operation,input})
-- jsonb_build_object 输出键序由 jsonb 规范化保证稳定。

create or replace function private.receipt_begin(
  p_user uuid, p_atype text, p_aid uuid, p_key uuid, p_operation text, p_input jsonb,
  out status text, out stored_response jsonb, out stored_state text)
language plpgsql security definer set search_path = '' as $$
declare
  v_hash bytea;
  r private.request_receipts%rowtype;
  v_waited int := 0;
begin
  v_hash := extensions.digest(
    jsonb_build_object('operation', p_operation, 'input', p_input)::text, 'sha256');
  loop
    insert into private.request_receipts
      (user_id, actor_type, actor_id, idempotency_key, operation, request_hash, state)
    values (p_user, p_atype, p_aid, p_key, p_operation, v_hash, 'processing')
    on conflict on constraint request_receipts_pkey do nothing
    returning * into r;
    if found then
      status := 'fresh'; return;
    end if;
    -- 冲突：ON CONFLICT 已等待 in-flight 事务落定；读已提交结果
    select * into r from private.request_receipts
     where user_id = p_user and actor_type = p_atype and actor_id = p_aid
       and idempotency_key = p_key;
    if not found then
      continue;  -- 前者回滚，重试插入
    end if;
    if r.state = 'processing' then
      -- 正常并发已被等待覆盖；可见 processing 属异常残留，短等后按技术故障回滚
      if v_waited >= 2 then
        raise exception 'receipt_in_progress_stuck' using errcode = 'P0001';
      end if;
      v_waited := v_waited + 1;
      perform pg_sleep(0.2);
      continue;
    end if;
    if r.request_hash is distinct from v_hash then
      status := 'conflict'; stored_state := r.state; return;
    end if;
    if r.state = 'expired' then
      status := 'expired'; stored_state := r.state; return;
    end if;
    status := 'replay'; stored_response := r.response; stored_state := r.state; return;
  end loop;
end;
$$;

create or replace function private.receipt_complete(
  p_user uuid, p_atype text, p_aid uuid, p_key uuid, p_response jsonb)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  update private.request_receipts
     set state = 'completed', response = p_response, completed_at = now()
   where user_id = p_user and actor_type = p_atype and actor_id = p_aid
     and idempotency_key = p_key and state = 'processing';
  if not found then
    raise exception 'receipt_state_invalid' using errcode = 'P0001';
  end if;
end;
$$;

create or replace function private.receipt_reject(
  p_user uuid, p_atype text, p_aid uuid, p_key uuid, p_error jsonb)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  update private.request_receipts
     set state = 'rejected', response = p_error, completed_at = now()
   where user_id = p_user and actor_type = p_atype and actor_id = p_aid
     and idempotency_key = p_key and state = 'processing';
  if not found then
    raise exception 'receipt_state_invalid' using errcode = 'P0001';
  end if;
end;
$$;

-- ========== 5. 通用 helper（均不授予客户端角色） ==========

create or replace function private.lock_workspace_state(p_user uuid)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform 1 from public.workspace_state where user_id = p_user for update;
  if not found then
    raise exception 'workspace_state_missing' using errcode = 'P0001';
  end if;
end;
$$;

create or replace function private.write_event(
  p_user uuid, p_atype text, p_aid uuid, p_action text,
  p_resource text, p_resource_id uuid, p_metadata jsonb default '{}')
returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.activity_log
    (user_id, actor_type, actor_id, agent_id, action, resource, resource_id, request_id, metadata)
  values
    (p_user, p_atype, p_aid,
     case when p_atype = 'agent' then p_aid end,
     p_action, p_resource, p_resource_id,
     nullif(current_setting('morrow.request_id', true), '')::uuid,
     coalesce(p_metadata, '{}'));
end;
$$;

create or replace function private.err_envelope(
  p_code text, p_msg text, p_retryable boolean, p_request_id uuid, p_details jsonb default null)
returns jsonb
language sql immutable security definer set search_path = '' as $$
  select jsonb_build_object(
    'ok', false,
    'error', jsonb_build_object(
      'code', p_code, 'message', p_msg, 'retryable', p_retryable,
      'request_id', p_request_id,
      'details', p_details));
$$;

-- 业务拒绝：写 rejected receipt + 审计，正常返回 error envelope（事务提交，证据留存）
create or replace function private.cmd_finish_err(
  p_user uuid, p_atype text, p_aid uuid, p_key uuid, p_operation text,
  p_code text, p_msg text, p_retryable boolean, p_request_id uuid, p_details jsonb default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_err jsonb;
begin
  v_err := jsonb_build_object(
    'code', p_code, 'message', p_msg, 'retryable', p_retryable,
    'details', p_details);
  if p_key is not null then
    perform private.receipt_reject(p_user, p_atype, p_aid, p_key, v_err);
  end if;
  perform private.write_event(p_user, p_atype, p_aid, 'command.rejected',
    'command', null,
    jsonb_build_object('operation', p_operation, 'code', p_code));
  return private.err_envelope(p_code, p_msg, p_retryable, p_request_id, p_details);
end;
$$;

-- 重放包装：换发新 request_id + replayed:true；rejected 收据同样原样重放
create or replace function private.cmd_wrap_replay(
  p_state text, p_stored jsonb, p_request_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
begin
  if p_state = 'completed' then
    return jsonb_build_object(
      'ok', true, 'request_id', p_request_id, 'server_time', now()::text,
      'replayed', true, 'result', p_stored);
  end if;
  return jsonb_build_object(
    'ok', false, 'request_id', p_request_id, 'server_time', now()::text,
    'replayed', true,
    'error', jsonb_build_object(
      'code', p_stored ->> 'code',
      'message', p_stored ->> 'message',
      'retryable', coalesce((p_stored ->> 'retryable')::boolean, false),
      'request_id', p_request_id,
      'details', p_stored -> 'details'));
end;
$$;

-- ========== 6. 命令实现（private definer；p_uid 必须等于 auth.uid() 且为 owner） ==========

create or replace function private.cmd_initialize_workspace_v1(p_uid uuid, p_envelope jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_request_id uuid := gen_random_uuid();
  v_key uuid;
  v_input jsonb;
  v_rs record;
  v_date date;
  v_row public.workspace_settings%rowtype;
  v_result jsonb;
begin
  -- 身份：definer 内强制复核，不信 public 壳与参数
  if p_uid is null or p_uid is distinct from auth.uid()
     or not exists (select 1 from private.workspace_owner o where o.user_id = p_uid) then
    return private.err_envelope('OWNER_DENIED', '仅工作区 owner 可执行', false, v_request_id);
  end if;
  -- envelope
  if p_envelope is null or jsonb_typeof(p_envelope) <> 'object'
     or (p_envelope ->> 'api_version') is distinct from '1'
     or not (p_envelope ? 'idempotency_key')
     or (p_envelope ->> 'idempotency_key') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     or p_envelope ? 'expected_version'
     or not (p_envelope ? 'input')
     or jsonb_typeof(p_envelope -> 'input') <> 'object' then
    perform private.write_event(p_uid, 'human', p_uid, 'command.rejected',
      'command', null, jsonb_build_object('operation', 'initialize_workspace_v1', 'code', 'VALIDATION_FAILED'));
    return private.err_envelope('VALIDATION_FAILED',
      'envelope 形状非法（api_version/idempotency_key/input；Human 命令不接受 expected_version）',
      false, v_request_id);
  end if;
  v_key := (p_envelope ->> 'idempotency_key')::uuid;
  v_input := p_envelope -> 'input';

  perform private.cmd_set_actor('human', p_uid);
  perform set_config('morrow.request_id', v_request_id::text, true);
  perform private.lock_workspace_state(p_uid);

  select * into v_rs from private.receipt_begin(
    p_uid, 'human', p_uid, v_key, 'initialize_workspace_v1', v_input);
  if v_rs.status = 'conflict' then
    return private.cmd_finish_err(p_uid, 'human', p_uid, null, 'initialize_workspace_v1',
      'IDEMPOTENCY_KEY_REUSED', '同一幂等键绑定了不同请求内容', false, v_request_id);
  elsif v_rs.status = 'expired' then
    return private.cmd_finish_err(p_uid, 'human', p_uid, null, 'initialize_workspace_v1',
      'IDEMPOTENCY_RESULT_EXPIRED', '收据响应已过期，请重新读取当前状态', false, v_request_id);
  elsif v_rs.status = 'replay' then
    return private.cmd_wrap_replay(v_rs.stored_state, v_rs.stored_response, v_request_id);
  end if;

  -- 业务校验（命令 schema 语义由 Core 强制）
  if (select count(*) from jsonb_object_keys(v_input) k
      where k not in ('timezone', 'tracking_started_on', 'weekday_codes')) > 0
     or (v_input ->> 'timezone') is distinct from 'Asia/Shanghai'
     or (v_input ->> 'tracking_started_on') is null
     or (v_input ->> 'tracking_started_on') !~ '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'
     or jsonb_typeof(v_input -> 'weekday_codes') is distinct from 'object'
     or (select count(*) from jsonb_object_keys(v_input -> 'weekday_codes')) <> 7
     or (select count(*) from jsonb_object_keys(v_input -> 'weekday_codes') k
         where k not in ('mon','tue','wed','thu','fri','sat','sun')) > 0
     or (select count(*) from jsonb_each_text(v_input -> 'weekday_codes') e
         where e.value not in ('ordinary_workday','workout_workday','weekend','weekend_workout')) > 0 then
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'initialize_workspace_v1',
      'VALIDATION_FAILED', 'input 字段非法（timezone/tracking_started_on/weekday_codes）', false, v_request_id);
  end if;
  v_date := (v_input ->> 'tracking_started_on')::date;

  if exists (select 1 from public.workspace_settings s where s.user_id = p_uid) then
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'initialize_workspace_v1',
      'ALREADY_EXISTS', '工作区已初始化，不允许重复初始化或重置', false, v_request_id);
  end if;

  insert into public.workspace_settings (user_id, timezone, tracking_started_on, schedule_history)
  values (p_uid, 'Asia/Shanghai', v_date,
    jsonb_build_array(jsonb_build_object(
      'payload_v', 1, 'effective_from', v_date,
      'weekday_codes', v_input -> 'weekday_codes')))
  returning * into v_row;

  v_result := jsonb_build_object(
    'record', jsonb_build_object(
      'timezone', v_row.timezone,
      'tracking_started_on', v_row.tracking_started_on,
      'schedule_history', v_row.schedule_history,
      'version', v_row.version::text,
      'created_at', v_row.created_at,
      'updated_at', v_row.updated_at));
  perform private.receipt_complete(p_uid, 'human', p_uid, v_key, v_result);
  return jsonb_build_object(
    'ok', true, 'request_id', v_request_id, 'server_time', now()::text,
    'replayed', false, 'result', v_result);
end;
$$;

create or replace function private.cmd_manage_health_client_v1(p_uid uuid, p_envelope jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_request_id uuid := gen_random_uuid();
  v_key uuid;
  v_input jsonb;
  v_action text;
  v_rs record;
  v_client public.agent_clients%rowtype;
  v_client_id uuid;
  v_cred_id uuid;
  v_hash_hex text;
  v_expires timestamptz;
  v_no_change boolean := false;
  v_revoked_count int;
  v_result jsonb;
  v_allowed text[];
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
      'command', null, jsonb_build_object('operation', 'manage_health_client_v1', 'code', 'VALIDATION_FAILED'));
    return private.err_envelope('VALIDATION_FAILED',
      'envelope 形状非法（api_version/idempotency_key/input；Human 命令不接受 expected_version）',
      false, v_request_id);
  end if;
  v_key := (p_envelope ->> 'idempotency_key')::uuid;
  v_input := p_envelope -> 'input';
  v_action := v_input ->> 'action';

  perform private.cmd_set_actor('human', p_uid);
  perform set_config('morrow.request_id', v_request_id::text, true);

  -- 形状预检（unknown key 拦截自报 user_id/actor/scopes/token 明文等伪造字段）
  if v_action = 'create' then
    v_allowed := array['action','name','type','credential_id','token_hash','expires_at'];
  elsif v_action = 'rotate' then
    v_allowed := array['action','client_id','credential_id','token_hash','expires_at'];
  elsif v_action = 'revoke' and (v_input ->> 'target') = 'client' then
    v_allowed := array['action','client_id','target'];
  elsif v_action = 'revoke' and (v_input ->> 'target') = 'credential' then
    v_allowed := array['action','client_id','target','credential_id'];
  else
    perform private.lock_workspace_state(p_uid);
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'manage_health_client_v1',
      'VALIDATION_FAILED', 'action/target 非法', false, v_request_id);
  end if;
  if (select count(*) from jsonb_object_keys(v_input) k where k <> all (v_allowed)) > 0 then
    perform private.lock_workspace_state(p_uid);
    return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'manage_health_client_v1',
      'VALIDATION_FAILED', 'input 含未声明字段（拒绝自报 user_id/actor/scopes/token 明文）', false, v_request_id);
  end if;

  -- ===== 锁序 =====
  -- create：无既有 client 可锁，固定 state → receipt → 校验 → insert（C-05.1）
  -- rotate/revoke：client → credentials(按 id 升序) → state → receipt
  if v_action = 'create' then
    perform private.lock_workspace_state(p_uid);
  else
    if (v_input ->> 'client_id') is null
       or (v_input ->> 'client_id') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      perform private.lock_workspace_state(p_uid);
      return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'manage_health_client_v1',
        'VALIDATION_FAILED', 'client_id 非法', false, v_request_id);
    end if;
    v_client_id := (v_input ->> 'client_id')::uuid;
    select * into v_client from public.agent_clients c
     where c.user_id = p_uid and c.id = v_client_id
     for update;
    if not found then
      perform private.lock_workspace_state(p_uid);
      return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'manage_health_client_v1',
        'RESOURCE_NOT_FOUND', 'client 不存在', false, v_request_id);
    end if;
    -- 锁定该 client 全部凭据（按 id 升序）
    perform 1 from private.agent_credentials cr
     where cr.user_id = p_uid and cr.agent_id = v_client_id
     order by cr.id
     for update;
    perform private.lock_workspace_state(p_uid);
  end if;

  -- ===== receipt =====
  select * into v_rs from private.receipt_begin(
    p_uid, 'human', p_uid, v_key, 'manage_health_client_v1', v_input);
  if v_rs.status = 'conflict' then
    return private.cmd_finish_err(p_uid, 'human', p_uid, null, 'manage_health_client_v1',
      'IDEMPOTENCY_KEY_REUSED', '同一幂等键绑定了不同请求内容', false, v_request_id);
  elsif v_rs.status = 'expired' then
    return private.cmd_finish_err(p_uid, 'human', p_uid, null, 'manage_health_client_v1',
      'IDEMPOTENCY_RESULT_EXPIRED', '收据响应已过期，请重新读取当前状态', false, v_request_id);
  elsif v_rs.status = 'replay' then
    return private.cmd_wrap_replay(v_rs.stored_state, v_rs.stored_response, v_request_id);
  end if;

  -- ===== 分支 =====
  if v_action = 'create' then
    if coalesce(char_length(v_input ->> 'name'), 0) not between 1 and 80
       or (v_input ->> 'type') not in ('local','remote','scheduled')
       or (v_input ->> 'credential_id') is null
       or (v_input ->> 'credential_id') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or (v_input ->> 'token_hash') is null
       or (v_input ->> 'token_hash') !~ '^[0-9a-f]{64}$'
       or (v_input ->> 'expires_at') is null then
      return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'manage_health_client_v1',
        'VALIDATION_FAILED', 'create 输入非法（name/type/credential_id/token_hash/expires_at）', false, v_request_id);
    end if;
    begin
      v_expires := (v_input ->> 'expires_at')::timestamptz;
    exception when others then
      return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'manage_health_client_v1',
        'VALIDATION_FAILED', 'expires_at 不是合法时间戳', false, v_request_id);
    end;
    if v_expires <= now() or v_expires > now() + interval '90 days' then
      return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'manage_health_client_v1',
        'VALIDATION_FAILED', 'expires_at 必须在 server_now 之后且不超过 90 天', false, v_request_id);
    end if;
    v_cred_id := (v_input ->> 'credential_id')::uuid;
    v_hash_hex := v_input ->> 'token_hash';
    if exists (select 1 from private.agent_credentials c where c.id = v_cred_id)
       or exists (select 1 from private.agent_credentials c
                  where c.token_hash = decode(v_hash_hex, 'hex')) then
      return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'manage_health_client_v1',
        'ALREADY_EXISTS', 'credential locator 或 token 摘要已被占用', false, v_request_id);
    end if;
    insert into public.agent_clients (user_id, name, type, scopes, enabled, revoked_at)
    values (p_uid, v_input ->> 'name', v_input ->> 'type',
            array['system:health']::text[], true, null)
    returning id into v_client_id;
    insert into private.agent_credentials (id, user_id, agent_id, token_hash, expires_at)
    values (v_cred_id, p_uid, v_client_id, decode(v_hash_hex, 'hex'), v_expires);
    perform private.write_event(p_uid, 'human', p_uid, 'agent_credential.create',
      'agent_credentials', v_cred_id, jsonb_build_object('client_id', v_client_id));
    v_result := jsonb_build_object(
      'client_id', v_client_id, 'credential_id', v_cred_id,
      'enabled', true, 'scopes', jsonb_build_array('system:health'),
      'expires_at', v_expires, 'version', '1');

  elsif v_action = 'rotate' then
    if v_client.revoked_at is not null then
      return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'manage_health_client_v1',
        'RESOURCE_DELETED', 'client 已撤销，不能轮换', false, v_request_id);
    end if;
    if not v_client.enabled then
      return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'manage_health_client_v1',
        'VALIDATION_FAILED', 'client 已停用，不能轮换', false, v_request_id);
    end if;
    if (v_input ->> 'credential_id') is null
       or (v_input ->> 'credential_id') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or (v_input ->> 'token_hash') is null
       or (v_input ->> 'token_hash') !~ '^[0-9a-f]{64}$'
       or (v_input ->> 'expires_at') is null then
      return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'manage_health_client_v1',
        'VALIDATION_FAILED', 'rotate 输入非法（credential_id/token_hash/expires_at）', false, v_request_id);
    end if;
    begin
      v_expires := (v_input ->> 'expires_at')::timestamptz;
    exception when others then
      return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'manage_health_client_v1',
        'VALIDATION_FAILED', 'expires_at 不是合法时间戳', false, v_request_id);
    end;
    if v_expires <= now() or v_expires > now() + interval '90 days' then
      return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'manage_health_client_v1',
        'VALIDATION_FAILED', 'expires_at 必须在 server_now 之后且不超过 90 天', false, v_request_id);
    end if;
    v_cred_id := (v_input ->> 'credential_id')::uuid;
    v_hash_hex := v_input ->> 'token_hash';
    if exists (select 1 from private.agent_credentials c where c.id = v_cred_id)
       or exists (select 1 from private.agent_credentials c
                  where c.token_hash = decode(v_hash_hex, 'hex')) then
      return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'manage_health_client_v1',
        'ALREADY_EXISTS', 'credential locator 或 token 摘要已被占用', false, v_request_id);
    end if;
    -- 旧凭据收紧为 min(原到期, now+24h)，保留供宿主切换；不复活已撤凭据
    update private.agent_credentials
       set expires_at = least(expires_at, now() + interval '24 hours')
     where user_id = p_uid and agent_id = v_client_id and revoked_at is null;
    insert into private.agent_credentials (id, user_id, agent_id, token_hash, expires_at)
    values (v_cred_id, p_uid, v_client_id, decode(v_hash_hex, 'hex'), v_expires);
    perform private.write_event(p_uid, 'human', p_uid, 'agent_credential.rotate',
      'agent_credentials', v_cred_id, jsonb_build_object('client_id', v_client_id));
    v_result := jsonb_build_object(
      'client_id', v_client_id, 'credential_id', v_cred_id,
      'expires_at', v_expires, 'version', v_client.version::text);

  else  -- revoke
    if (v_input ->> 'target') = 'client' then
      if v_client.revoked_at is not null then
        v_no_change := true;
      else
        update public.agent_clients
           set enabled = false, revoked_at = now()
         where user_id = p_uid and id = v_client_id
        returning * into v_client;
        update private.agent_credentials set revoked_at = now()
         where user_id = p_uid and agent_id = v_client_id and revoked_at is null;
        get diagnostics v_revoked_count = row_count;
        perform private.write_event(p_uid, 'human', p_uid, 'agent_credential.revoke',
          'agent_credentials', null,
          jsonb_build_object('client_id', v_client_id, 'revoked_count', v_revoked_count));
      end if;
      v_result := jsonb_build_object(
        'client_id', v_client_id, 'target', 'client',
        'revoked_at', v_client.revoked_at, 'no_change', v_no_change,
        'version', v_client.version::text);
    else  -- target = credential
      if (v_input ->> 'credential_id') is null
         or (v_input ->> 'credential_id') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'manage_health_client_v1',
          'VALIDATION_FAILED', 'credential_id 非法', false, v_request_id);
      end if;
      v_cred_id := (v_input ->> 'credential_id')::uuid;
      if not exists (select 1 from private.agent_credentials c
                     where c.user_id = p_uid and c.agent_id = v_client_id and c.id = v_cred_id) then
        return private.cmd_finish_err(p_uid, 'human', p_uid, v_key, 'manage_health_client_v1',
          'RESOURCE_NOT_FOUND', 'credential 不存在或不属于该 client', false, v_request_id);
      end if;
      if exists (select 1 from private.agent_credentials c
                 where c.id = v_cred_id and c.revoked_at is not null) then
        v_no_change := true;
      else
        update private.agent_credentials set revoked_at = now()
         where user_id = p_uid and agent_id = v_client_id and id = v_cred_id;
        perform private.write_event(p_uid, 'human', p_uid, 'agent_credential.revoke',
          'agent_credentials', v_cred_id, jsonb_build_object('client_id', v_client_id));
      end if;
      v_result := jsonb_build_object(
        'client_id', v_client_id, 'target', 'credential', 'credential_id', v_cred_id,
        'no_change', v_no_change, 'version', v_client.version::text);
    end if;
  end if;

  perform private.receipt_complete(p_uid, 'human', p_uid, v_key, v_result);
  return jsonb_build_object(
    'ok', true, 'request_id', v_request_id, 'server_time', now()::text,
    'replayed', false, 'result', v_result);
end;
$$;

create or replace function private.cmd_get_command_result_v1(p_uid uuid, p_envelope jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_request_id uuid := gen_random_uuid();
  v_input jsonb;
  v_target uuid;
  r private.request_receipts%rowtype;
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
     or jsonb_typeof(p_envelope -> 'input') <> 'object'
     or (p_envelope -> 'input' ->> 'idempotency_key') is null
     or (p_envelope -> 'input' ->> 'idempotency_key') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     or (select count(*) from jsonb_object_keys(p_envelope -> 'input') k
         where k <> 'idempotency_key') > 0 then
    return private.err_envelope('VALIDATION_FAILED', 'envelope/input 形状非法', false, v_request_id);
  end if;
  v_target := (p_envelope -> 'input' ->> 'idempotency_key')::uuid;

  -- 只读自己（human 命名空间）收据；绝不执行未见请求
  select * into r from private.request_receipts t
   where t.user_id = p_uid and t.actor_type = 'human' and t.actor_id = p_uid
     and t.idempotency_key = v_target;
  if not found then
    return private.err_envelope('RESOURCE_NOT_FOUND',
      '收据未找到；未找到不代表原请求已取消', false, v_request_id);
  end if;
  return jsonb_build_object(
    'ok', true, 'request_id', v_request_id, 'server_time', now()::text,
    'result', jsonb_build_object(
      'idempotency_key', r.idempotency_key,
      'operation', r.operation,
      'state', r.state,
      'created_at', r.created_at,
      'completed_at', r.completed_at,
      'response', r.response));
end;
$$;

create or replace function private.cmd_get_workspace_revision_v1(p_uid uuid, p_envelope jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_request_id uuid := gen_random_uuid();
  v_rev bigint;
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
  select s.data_revision into v_rev from public.workspace_state s where s.user_id = p_uid;
  if not found then
    raise exception 'workspace_state_missing' using errcode = 'P0001';
  end if;
  return jsonb_build_object(
    'ok', true, 'request_id', v_request_id, 'server_time', now()::text,
    'data_revision', v_rev::text);
end;
$$;

-- ========== 7. 测试专用入口（不授予任何客户端角色；仅经 Management API postgres 驱动） ==========
-- 完整走 actor/锁序/receipt/LWW-OCC/schema/审计/版本框架写 life_data，供 P0 事务测试。
-- fault='after_business_write' 在业务写后注入技术故障验证整体回滚。

create or replace function private.core_test_write_v1(
  p_actor_type text, p_actor_id uuid, p_key uuid, p_operation text, p_input jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_request_id uuid := gen_random_uuid();
  v_owner uuid;
  v_rs record;
  v_module text;
  v_expected text;
  v_row public.life_data%rowtype;
  v_payload jsonb;
  v_schema jsonb;
  v_no_change boolean := false;
  v_result jsonb;
begin
  if p_actor_type not in ('human','agent','system','import') or p_actor_id is null then
    raise exception 'actor_context_invalid' using errcode = 'P0001';
  end if;
  select o.user_id into v_owner from private.workspace_owner o;
  if not found then
    raise exception 'workspace_owner_missing' using errcode = 'P0001';
  end if;
  if p_actor_type = 'human' and p_actor_id <> v_owner then
    raise exception 'actor_context_invalid' using errcode = 'P0001';
  end if;

  perform private.cmd_set_actor(p_actor_type, p_actor_id);
  perform set_config('morrow.request_id', v_request_id::text, true);
  perform private.lock_workspace_state(v_owner);

  select * into v_rs from private.receipt_begin(
    v_owner, p_actor_type, p_actor_id, p_key, p_operation, p_input);
  if v_rs.status = 'conflict' then
    return private.cmd_finish_err(v_owner, p_actor_type, p_actor_id, null, p_operation,
      'IDEMPOTENCY_KEY_REUSED', '同一幂等键绑定了不同请求内容', false, v_request_id);
  elsif v_rs.status = 'replay' then
    return private.cmd_wrap_replay(v_rs.stored_state, v_rs.stored_response, v_request_id);
  end if;

  v_module := p_input ->> 'module';
  v_expected := p_input ->> 'expected_version';
  if v_module not in ('anchor','day_type')
     or (p_input ->> 'entity_key') is null
     or jsonb_typeof(p_input -> 'payload') is distinct from 'object' then
    return private.cmd_finish_err(v_owner, p_actor_type, p_actor_id, p_key, p_operation,
      'PAYLOAD_UNSUPPORTED', 'module/entity_key/payload 非法或 M1 未开放', false, v_request_id);
  end if;
  -- LWW/OCC 分支约束：Human 禁带 expected_version；Agent/system 必带
  if p_actor_type = 'human' and v_expected is not null then
    return private.cmd_finish_err(v_owner, p_actor_type, p_actor_id, p_key, p_operation,
      'VALIDATION_FAILED', 'Human 命令不接受 expected_version', false, v_request_id);
  end if;
  if p_actor_type <> 'human'
     and (v_expected is null or v_expected !~ '^(0|[1-9][0-9]*)$') then
    return private.cmd_finish_err(v_owner, p_actor_type, p_actor_id, p_key, p_operation,
      'VALIDATION_FAILED', 'Agent 命令必须携带十进制字符串 expected_version', false, v_request_id);
  end if;

  -- payload 结构校验（DB 固化 schema 快照）
  select s.schema into v_schema from private.payload_schemas s
   where s.module = v_module and s.payload_v = ((p_input -> 'payload' ->> 'payload_v')::int);
  if not found then
    return private.cmd_finish_err(v_owner, p_actor_type, p_actor_id, p_key, p_operation,
      'PAYLOAD_UNSUPPORTED', '未知 module/payload_v', false, v_request_id);
  end if;
  if not extensions.jsonb_matches_schema(v_schema, p_input -> 'payload') then
    return private.cmd_finish_err(v_owner, p_actor_type, p_actor_id, p_key, p_operation,
      'VALIDATION_FAILED', 'payload 不匹配版本化 schema', false, v_request_id);
  end if;

  -- 锁定目标行业务键（含 tombstone）
  select * into v_row from public.life_data d
   where d.user_id = v_owner and d.module = v_module
     and d.entity_key = (p_input ->> 'entity_key')
   for update;

  if p_actor_type <> 'human' and v_expected = '0' then
    -- create 语义：已存在或 tombstone 均不能变成 update
    if found then
      if v_row.deleted_at is not null then
        return private.cmd_finish_err(v_owner, p_actor_type, p_actor_id, p_key, p_operation,
          'RESOURCE_DELETED', '业务键已删除（tombstone），不能 create 覆盖', false, v_request_id,
          jsonb_build_object('resource_id', v_row.id));
      end if;
      return private.cmd_finish_err(v_owner, p_actor_type, p_actor_id, p_key, p_operation,
        'ALREADY_EXISTS', '业务键已存在，create（expected_version=0）不能覆盖', false, v_request_id,
        jsonb_build_object('resource_id', v_row.id, 'current_version', v_row.version::text));
    end if;
    insert into public.life_data (user_id, module, entity_key, biz_date, payload)
    values (v_owner, v_module, p_input ->> 'entity_key',
            nullif(p_input ->> 'biz_date', '')::date, p_input -> 'payload')
    returning * into v_row;
    v_result := jsonb_build_object(
      'result', 'created', 'id', v_row.id, 'version', v_row.version::text);
  else
    if not found then
      return private.cmd_finish_err(v_owner, p_actor_type, p_actor_id, p_key, p_operation,
        'RESOURCE_NOT_FOUND', '记录不存在', false, v_request_id);
    end if;
    if v_row.deleted_at is not null then
      return private.cmd_finish_err(v_owner, p_actor_type, p_actor_id, p_key, p_operation,
        'RESOURCE_DELETED', '记录已删除', false, v_request_id,
        jsonb_build_object('resource_id', v_row.id));
    end if;
    if p_actor_type <> 'human' and v_row.version <> v_expected::bigint then
      return private.cmd_finish_err(v_owner, p_actor_type, p_actor_id, p_key, p_operation,
        'VERSION_CONFLICT', '记录已更新，请重新读取', false, v_request_id,
        jsonb_build_object('resource_id', v_row.id, 'current_version', v_row.version::text));
    end if;
    -- no-op：相同值重复提交返回 no_change，不凭空递增 version
    if v_row.payload = (p_input -> 'payload') then
      v_no_change := true;
      perform private.write_event(v_owner, p_actor_type, p_actor_id, 'core_test.no_change',
        'life_data', v_row.id, jsonb_build_object('operation', p_operation));
    else
      update public.life_data set payload = p_input -> 'payload'
       where user_id = v_owner and id = v_row.id
      returning * into v_row;
    end if;
    v_result := jsonb_build_object(
      'result', case when v_no_change then 'no_change' else 'changed' end,
      'id', v_row.id, 'version', v_row.version::text);
  end if;

  if (p_input ->> 'fault') = 'after_business_write' then
    raise exception 'injected_fault_after_business_write' using errcode = 'P0001';
  end if;

  perform private.receipt_complete(v_owner, p_actor_type, p_actor_id, p_key, v_result);
  return jsonb_build_object(
    'ok', true, 'request_id', v_request_id, 'server_time', now()::text,
    'replayed', false, 'result', v_result);
end;
$$;

-- ========== 8. public invoker 壳（SECURITY INVOKER → private definer） ==========

create or replace function public.initialize_workspace_v1(p_envelope jsonb)
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
  return private.cmd_initialize_workspace_v1(v_uid, p_envelope);
end;
$$;

create or replace function public.manage_health_client_v1(p_envelope jsonb)
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
  return private.cmd_manage_health_client_v1(v_uid, p_envelope);
end;
$$;

create or replace function public.get_command_result_v1(p_envelope jsonb)
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
  return private.cmd_get_command_result_v1(v_uid, p_envelope);
end;
$$;

create or replace function public.get_workspace_revision_v1(p_envelope jsonb)
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
  return private.cmd_get_workspace_revision_v1(v_uid, p_envelope);
end;
$$;

-- ========== 9. grants 收口 ==========
-- public 入口：仅 authenticated；anon/service_role/PUBLIC 全撤
revoke all on function public.initialize_workspace_v1(jsonb)    from public, anon, authenticated, service_role;
revoke all on function public.manage_health_client_v1(jsonb)    from public, anon, authenticated, service_role;
revoke all on function public.get_command_result_v1(jsonb)      from public, anon, authenticated, service_role;
revoke all on function public.get_workspace_revision_v1(jsonb)  from public, anon, authenticated, service_role;
grant execute on function public.initialize_workspace_v1(jsonb)   to authenticated;
grant execute on function public.manage_health_client_v1(jsonb)   to authenticated;
grant execute on function public.get_command_result_v1(jsonb)     to authenticated;
grant execute on function public.get_workspace_revision_v1(jsonb) to authenticated;

-- private 命令函数：invoker 链需要 authenticated EXECUTE；函数内强制 p_uid=auth.uid()+owner 复核
revoke all on function private.cmd_initialize_workspace_v1(uuid, jsonb)   from public, anon, authenticated, service_role;
revoke all on function private.cmd_manage_health_client_v1(uuid, jsonb)   from public, anon, authenticated, service_role;
revoke all on function private.cmd_get_command_result_v1(uuid, jsonb)     from public, anon, authenticated, service_role;
revoke all on function private.cmd_get_workspace_revision_v1(uuid, jsonb) from public, anon, authenticated, service_role;
grant execute on function private.cmd_initialize_workspace_v1(uuid, jsonb)   to authenticated;
grant execute on function private.cmd_manage_health_client_v1(uuid, jsonb)   to authenticated;
grant execute on function private.cmd_get_command_result_v1(uuid, jsonb)     to authenticated;
grant execute on function private.cmd_get_workspace_revision_v1(uuid, jsonb) to authenticated;

-- private helper / trigger / 测试入口：不授予任何客户端角色（撤销默认 PUBLIC EXECUTE）
revoke all on function private.cmd_set_actor(text, uuid)          from public, anon, authenticated, service_role;
revoke all on function private.current_actor()                    from public, anon, authenticated, service_role;
revoke all on function private.receipt_begin(uuid, text, uuid, uuid, text, jsonb) from public, anon, authenticated, service_role;
revoke all on function private.receipt_complete(uuid, text, uuid, uuid, jsonb)    from public, anon, authenticated, service_role;
revoke all on function private.receipt_reject(uuid, text, uuid, uuid, jsonb)      from public, anon, authenticated, service_role;
revoke all on function private.lock_workspace_state(uuid)         from public, anon, authenticated, service_role;
revoke all on function private.write_event(uuid, text, uuid, text, text, uuid, jsonb) from public, anon, authenticated, service_role;
revoke all on function private.err_envelope(text, text, boolean, uuid, jsonb)     from public, anon, authenticated, service_role;
revoke all on function private.cmd_finish_err(uuid, text, uuid, uuid, text, text, text, boolean, uuid, jsonb) from public, anon, authenticated, service_role;
revoke all on function private.cmd_wrap_replay(text, jsonb, uuid) from public, anon, authenticated, service_role;
revoke all on function private.core_test_write_v1(text, uuid, uuid, text, jsonb)  from public, anon, authenticated, service_role;
revoke all on function private.trg_life_data_before_insert()      from public, anon, authenticated, service_role;
revoke all on function private.trg_life_data_before_update()      from public, anon, authenticated, service_role;
revoke all on function private.trg_settings_before_update()       from public, anon, authenticated, service_role;
revoke all on function private.trg_clients_before_update()        from public, anon, authenticated, service_role;
revoke all on function private.trg_after_write_audit()            from public, anon, authenticated, service_role;
revoke all on function private.trg_activity_bump_revision()       from public, anon, authenticated, service_role;

commit;
