-- P0-004 / migration 0009：修复 0008 实测暴露的两处缺陷（追加式，不改已应用 migration）
-- 证据: docs/planning/evidence/P0-004/core-tests.output.txt 首轮 FAIL D2/L1/E1/H1
-- 缺陷1（42703）: trg_after_write_audit 的 IF 条件 `TG_TABLE_NAME='agent_clients' and NEW.name ...`
--   —— PL/pgSQL IF 条件交 SQL 求值器，AND 不保证短路；挂到 life_data/settings 行时 NEW 无 name 列即报错。
--   修复: 外层 IF 只判 TG_TABLE_NAME/TG_OP（安全标识符），字段比较放内层。
-- 缺陷2（42883）: pg_jsonschema 0.3.3 的 jsonb_matches_schema 签名为 (schema json, instance jsonb)，
--   第一参数是 json 非 jsonb。修复: v_schema::json。
begin;

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
  -- 外层仅判安全标识符；NEW 字段比较必须在内层（AND 不短路，42703 实证）
  if TG_TABLE_NAME = 'agent_clients' and TG_OP = 'UPDATE' then
    if NEW.name       is not distinct from OLD.name
       and NEW.type       is not distinct from OLD.type
       and NEW.scopes     is not distinct from OLD.scopes
       and NEW.enabled    is not distinct from OLD.enabled
       and NEW.revoked_at is not distinct from OLD.revoked_at
       and NEW.version    is not distinct from OLD.version then
      v_skip_log := true;
    end if;
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

  update public.workspace_state
     set data_revision = data_revision + 1, updated_at = now()
   where user_id = NEW.user_id;
  if not found then
    raise exception 'workspace_state_missing' using errcode = 'P0001';
  end if;
  return NEW;
end;
$$;

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
  if p_actor_type = 'human' and v_expected is not null then
    return private.cmd_finish_err(v_owner, p_actor_type, p_actor_id, p_key, p_operation,
      'VALIDATION_FAILED', 'Human 命令不接受 expected_version', false, v_request_id);
  end if;
  if p_actor_type <> 'human'
     and (v_expected is null or v_expected !~ '^(0|[1-9][0-9]*)$') then
    return private.cmd_finish_err(v_owner, p_actor_type, p_actor_id, p_key, p_operation,
      'VALIDATION_FAILED', 'Agent 命令必须携带十进制字符串 expected_version', false, v_request_id);
  end if;

  select s.schema into v_schema from private.payload_schemas s
   where s.module = v_module and s.payload_v = ((p_input -> 'payload' ->> 'payload_v')::int);
  if not found then
    return private.cmd_finish_err(v_owner, p_actor_type, p_actor_id, p_key, p_operation,
      'PAYLOAD_UNSUPPORTED', '未知 module/payload_v', false, v_request_id);
  end if;
  -- pg_jsonschema 0.3.3: jsonb_matches_schema(schema json, instance jsonb)
  if not extensions.jsonb_matches_schema(v_schema::json, p_input -> 'payload') then
    return private.cmd_finish_err(v_owner, p_actor_type, p_actor_id, p_key, p_operation,
      'VALIDATION_FAILED', 'payload 不匹配版本化 schema', false, v_request_id);
  end if;

  select * into v_row from public.life_data d
   where d.user_id = v_owner and d.module = v_module
     and d.entity_key = (p_input ->> 'entity_key')
   for update;

  if p_actor_type <> 'human' and v_expected = '0' then
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

commit;
