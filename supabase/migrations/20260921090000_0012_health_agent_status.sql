-- P0-007 / migration 0012：health-only Agent 的运行时状态通道（追加式，不改已应用 migration）
-- 依据：02-contracts.md C-05.1/C-06；01-architecture.md AD03/AD04/§4；03-execution.md §8
-- 边界（任务卡）：
--   * 唯一 scope = system:health；响应仅 status/db/server_time/request_id，绝无生活数据字段
--   * health 是外部 GET，但内部走 POST + VOLATILE RPC（行锁 + 真实 activity_log 写入），禁静态 ping
--   * 每 client ≤5 次/分钟（数据库窗口计数实现，C-06 固定上限）
--   * public.agent_health_check_v1 仅授予 service_role（Edge 函数自持调用）；anon/authenticated 全拒
--   * private.get_system_status 不授予任何客户端角色（仅 Core 内部调用）

begin;

-- ========== 1. private.get_system_status：行锁 + 真实审计写 ==========
-- 持 workspace_state 行锁（与全部业务命令同一锁序锚点），写一条 health.keepalive
-- activity_log（trg_activity_ai 同事务 bump data_revision），并刷新 client last_seen_at
-- （0008 审计 trigger 对该字段有 skip-log 分支：bump revision 但不伪造配置日志）。
create or replace function private.get_system_status(
  p_user uuid, p_agent_id uuid, p_request_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
begin
  perform private.lock_workspace_state(p_user);
  perform private.cmd_set_actor('agent', p_agent_id);
  perform set_config('morrow.request_id', p_request_id::text, true);
  perform private.write_event(p_user, 'agent', p_agent_id,
    'health.keepalive', 'system', null, '{}'::jsonb);
  update public.agent_clients set last_seen_at = now()
   where user_id = p_user and id = p_agent_id;
  return jsonb_build_object(
    'status', 'ok', 'db', 'ok',
    'server_time', now()::text, 'request_id', p_request_id);
end;
$$;

-- ========== 2. public.agent_health_check_v1：Edge 唯一入口（仅 service_role） ==========
-- 认证：opaque token 的 SHA-256 hex 摘要匹配 private.agent_credentials（不落明文）。
-- 缺失/错配/过期/已撤销凭据/停用 client 一律 UNAUTHENTICATED（不区分原因，防探针探测）。
-- scope 检查：client.scopes 必须恰为 ['system:health']，否则 SCOPE_DENIED（不带对象细节）。
-- 限流：同一 client 60s 窗口内 health.keepalive 审计行 ≥5 → RATE_LIMITED。
create or replace function public.agent_health_check_v1(p_token_hash text)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_request_id uuid := gen_random_uuid();
  v_cred private.agent_credentials%rowtype;
  v_client public.agent_clients%rowtype;
  v_recent int;
begin
  if p_token_hash is null or p_token_hash !~ '^[0-9a-f]{64}$' then
    return private.err_envelope('UNAUTHENTICATED', '无效凭据', false, v_request_id);
  end if;

  select * into v_cred from private.agent_credentials c
   where c.token_hash = decode(p_token_hash, 'hex');
  if not found or v_cred.revoked_at is not null or v_cred.expires_at <= now() then
    return private.err_envelope('UNAUTHENTICATED', '无效凭据', false, v_request_id);
  end if;

  select * into v_client from public.agent_clients cl
   where cl.user_id = v_cred.user_id and cl.id = v_cred.agent_id;
  if not found or not v_client.enabled or v_client.revoked_at is not null then
    return private.err_envelope('UNAUTHENTICATED', '无效凭据', false, v_request_id);
  end if;

  if v_client.scopes <> array['system:health']::text[] then
    return private.err_envelope('SCOPE_DENIED', 'scope 不足', false, v_request_id);
  end if;

  select count(*) into v_recent from public.activity_log a
   where a.user_id = v_cred.user_id and a.actor_type = 'agent'
     and a.actor_id = v_client.id and a.action = 'health.keepalive'
     and a.created_at > now() - interval '1 minute';
  if v_recent >= 5 then
    return private.err_envelope('RATE_LIMITED', '超出每 client 每分钟 5 次上限', true, v_request_id);
  end if;

  return jsonb_build_object('ok', true)
    || private.get_system_status(v_cred.user_id, v_client.id, v_request_id);
end;
$$;

-- ========== 3. grants 收口 ==========
revoke all on function private.get_system_status(uuid, uuid, uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.agent_health_check_v1(text)
  from public, anon, authenticated, service_role;
grant execute on function public.agent_health_check_v1(text) to service_role;

commit;
