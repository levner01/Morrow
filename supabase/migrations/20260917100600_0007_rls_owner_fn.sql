-- P0-003 / migration 0007: 修复 RLS 策略表达式引用 private.workspace_owner 导致的 authenticated 42501
-- 证据: docs/planning/evidence/P0-003/rls-tests.output.txt 首轮 A1/C1/D1/D2
--   策略子查询以求值者权限执行，authenticated 对 private 表无 grant → 策略本身报错而非过滤。
-- 方案: owner 判定封装进 private.is_workspace_owner()（SECURITY DEFINER + search_path=''，无参数无注入面），
--   策略改调该函数；authenticated 仅获 private schema USAGE 与该函数 EXECUTE，private 各表对象级 grant 仍全撤。
-- 同时补 workspace_state 缺失的 owner SELECT 策略（§3.9 Human 只读；首轮 C2 暴露其零策略默认全拒）。
begin;

create or replace function private.is_workspace_owner()
returns boolean
language sql
security definer
stable
parallel safe
set search_path = ''
as $$
  select exists (
    select 1 from private.workspace_owner o
    where o.user_id = (select auth.uid())
  );
$$;

revoke all on function private.is_workspace_owner() from public, anon, authenticated, service_role;
grant usage on schema private to authenticated;
grant execute on function private.is_workspace_owner() to authenticated;

alter policy life_data_owner_select on public.life_data
  using (user_id = auth.uid() and private.is_workspace_owner());

alter policy workspace_settings_owner_select on public.workspace_settings
  using (user_id = auth.uid() and private.is_workspace_owner());

alter policy agent_clients_owner_select on public.agent_clients
  using (user_id = auth.uid() and private.is_workspace_owner());

alter policy activity_log_owner_select on public.activity_log
  using (user_id = auth.uid() and private.is_workspace_owner());

create policy workspace_state_owner_select on public.workspace_state
  for select to authenticated
  using (user_id = auth.uid() and private.is_workspace_owner());

commit;
