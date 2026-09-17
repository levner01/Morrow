-- P0-004 / migration 0010：修复 manage_health_client 预检/未找到分支的 receipt_state_invalid（追加式）
-- 证据: docs/planning/evidence/P0-004/core-tests.output.txt 第二轮 K6e
--   revoke 未知 client 时，not-found 分支在 receipt_begin 之前以非空 key 调 cmd_finish_err，
--   receipt_reject 找不到 processing 行 → P0001 技术错误（应为 RESOURCE_NOT_FOUND 业务封套）。
--   同类隐患：action/target 非法、input 含未声明字段、client_id 非法三处预检分支。
-- 方案: 新增 private.cmd_pre_reject（调用方须已持 workspace_state 锁 → receipt_begin →
--   状态分发 → 拒绝落据），四处分支改走它。锁序不变：state 仍在 receipt 前。
begin;

-- 预检拒绝（receipt 未建立时）：先补 receipt_begin 再按状态分发。
-- 前置条件：调用方已持 workspace_state FOR UPDATE（锁序 state→receipt 不变）。
create or replace function private.cmd_pre_reject(
  p_user uuid, p_atype text, p_aid uuid, p_key uuid, p_operation text, p_input jsonb,
  p_code text, p_msg text, p_request_id uuid)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_rs record;
begin
  select * into v_rs from private.receipt_begin(p_user, p_atype, p_aid, p_key, p_operation, p_input);
  if v_rs.status = 'conflict' then
    return private.cmd_finish_err(p_user, p_atype, p_aid, null, p_operation,
      'IDEMPOTENCY_KEY_REUSED', '同一幂等键绑定了不同请求内容', false, p_request_id);
  elsif v_rs.status = 'expired' then
    return private.cmd_finish_err(p_user, p_atype, p_aid, null, p_operation,
      'IDEMPOTENCY_RESULT_EXPIRED', '收据响应已过期，请重新读取当前状态', false, p_request_id);
  elsif v_rs.status = 'replay' then
    return private.cmd_wrap_replay(v_rs.stored_state, v_rs.stored_response, p_request_id);
  end if;
  return private.cmd_finish_err(p_user, p_atype, p_aid, p_key, p_operation,
    p_code, p_msg, false, p_request_id);
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
    return private.cmd_pre_reject(p_uid, 'human', p_uid, v_key, 'manage_health_client_v1', v_input,
      'VALIDATION_FAILED', 'action/target 非法', v_request_id);
  end if;
  if (select count(*) from jsonb_object_keys(v_input) k where k <> all (v_allowed)) > 0 then
    perform private.lock_workspace_state(p_uid);
    return private.cmd_pre_reject(p_uid, 'human', p_uid, v_key, 'manage_health_client_v1', v_input,
      'VALIDATION_FAILED', 'input 含未声明字段（拒绝自报 user_id/actor/scopes/token 明文）', v_request_id);
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
      return private.cmd_pre_reject(p_uid, 'human', p_uid, v_key, 'manage_health_client_v1', v_input,
        'VALIDATION_FAILED', 'client_id 非法', v_request_id);
    end if;
    v_client_id := (v_input ->> 'client_id')::uuid;
    select * into v_client from public.agent_clients c
     where c.user_id = p_uid and c.id = v_client_id
     for update;
    if not found then
      perform private.lock_workspace_state(p_uid);
      return private.cmd_pre_reject(p_uid, 'human', p_uid, v_key, 'manage_health_client_v1', v_input,
        'RESOURCE_NOT_FOUND', 'client 不存在', v_request_id);
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

-- grants：cmd_pre_reject 为新 helper，撤销默认 PUBLIC EXECUTE，不授任何客户端角色
revoke all on function private.cmd_pre_reject(uuid, text, uuid, uuid, text, jsonb, text, text, uuid) from public, anon, authenticated, service_role;
-- cmd_manage_health_client_v1 为 OR REPLACE 同签名，保留 0008 已设 grant（authenticated EXECUTE）

commit;
