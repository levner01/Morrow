-- P0-005 移交 / migration 0011：core_test_write_v1 receipt 分发补 expired 分支（追加式，不改已应用 migration）
-- 证据: docs/planning/evidence/P0-005/expired-defect.output.txt（稳定复现 3 次）
-- 缺陷: receipt_begin 返回 status='expired'（identical-input 且收据已过期）时无匹配分支，
--   函数穿透到业务写逻辑完整执行一遍，随后 receipt_complete 找不到 processing 行
--   抛 P0001 receipt_state_invalid 整体回滚。违反 C-04：超期请求须返回
--   IDEMPOTENCY_RESULT_EXPIRED 并要求重新读取，绝不能重跑。
-- 修复: receipt 分发补三分支（conflict/expired/replay），与 initialize/manage 及
--   0010 cmd_pre_reject 同构；key 传 null 与 conflict 分支同构。
--   函数体其余部分与 0009 完全一致，不改 grants、不改其它函数。
begin;

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
  elsif v_rs.status = 'expired' then
    return private.cmd_finish_err(v_owner, p_actor_type, p_actor_id, null, p_operation,
      'IDEMPOTENCY_RESULT_EXPIRED', '收据响应已过期，请重新读取当前状态', false, v_request_id);
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
