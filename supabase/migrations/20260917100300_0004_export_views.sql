-- M1 首批 migration 4/4：导出 security_invoker 视图（BIGINT 服务端 cast text，固定列白名单）
-- 依据：01-architecture.md §4（RLS/视图/BIGINT）；02-contracts.md C-08（Export 字段白名单）
-- 说明：security_invoker=true 使视图继承底表 RLS（owner 只见自己行）；BIGINT 一律 ::text；
--      固定列白名单，禁止 select(*)，未来新增字段不自动流入导出。

begin;

-- 1. life_data 导出视图
create or replace view public.export_life_data_v1
  with (security_invoker = true)
as
select id,
       user_id,
       module,
       entity_key,
       biz_date,
       payload,
       version::text        as version,      -- BIGINT → text（服务端）
       source_type,
       source_id,
       created_at,
       updated_at,
       deleted_at
from public.life_data;
comment on view public.export_life_data_v1 is '导出视图：security_invoker 继承 RLS；version 服务端转 text';

-- 2. workspace_settings 导出视图（必含以重建计划分母，C-08）
create or replace view public.export_workspace_settings_v1
  with (security_invoker = true)
as
select user_id,
       timezone,
       tracking_started_on,
       schedule_history,
       version::text        as version,
       created_at,
       updated_at
from public.workspace_settings;

-- 3. agent_clients 导出视图（仅白名单非敏感字段，C-08：不含 credentials/hash/locator）
create or replace view public.export_agent_clients_v1
  with (security_invoker = true)
as
select id,
       user_id,
       name,
       type,
       scopes,
       enabled,
       created_at,
       updated_at,
       last_seen_at,
       revoked_at,
       version::text        as version
from public.agent_clients;

-- 4. activity_log 导出视图
create or replace view public.export_activity_log_v1
  with (security_invoker = true)
as
select id,
       user_id,
       actor_type,
       actor_id,
       agent_id,
       action,
       resource,
       resource_id,
       request_id,
       metadata,
       created_at
from public.activity_log;

-- 5. agent_advice 导出视图（C-08 容器含此表；M1 封闭——底表无 SELECT policy，视图继承得零行）
create or replace view public.export_agent_advice_v1
  with (security_invoker = true)
as
select id,
       user_id,
       agent_id,
       topic,
       title,
       content,
       reason,
       evidence,
       priority,
       status,
       payload_v,
       version::text        as version,
       created_at,
       updated_at,
       expires_at
from public.agent_advice;

-- 6. automation_rules 导出视图（同上：底表封闭，继承得零行）
create or replace view public.export_automation_rules_v1
  with (security_invoker = true)
as
select id,
       user_id,
       name,
       enabled,
       definition,
       version::text        as version,
       created_at,
       updated_at,
       deleted_at
from public.automation_rules;

-- 7. workspace_state 导出视图（C-08 workspace.data_revision 来源；BIGINT 转 text）
create or replace view public.export_workspace_state_v1
  with (security_invoker = true)
as
select user_id,
       data_revision::text as data_revision,
       created_at,
       updated_at
from public.workspace_state;

-- grants：导出视图对 authenticated 只读（RLS 在视图层继承生效）；anon/service_role 无
revoke all on public.export_life_data_v1           from public, anon, authenticated, service_role;
revoke all on public.export_workspace_settings_v1  from public, anon, authenticated, service_role;
revoke all on public.export_agent_clients_v1       from public, anon, authenticated, service_role;
revoke all on public.export_activity_log_v1        from public, anon, authenticated, service_role;
revoke all on public.export_agent_advice_v1        from public, anon, authenticated, service_role;
revoke all on public.export_automation_rules_v1    from public, anon, authenticated, service_role;
revoke all on public.export_workspace_state_v1     from public, anon, authenticated, service_role;

grant select on public.export_life_data_v1           to authenticated;
grant select on public.export_workspace_settings_v1  to authenticated;
grant select on public.export_agent_clients_v1       to authenticated;
grant select on public.export_activity_log_v1        to authenticated;
grant select on public.export_workspace_state_v1     to authenticated;
-- export_agent_advice_v1 / export_automation_rules_v1：底表 M1 封闭，暂不授予（Phase 激活时再授）

commit;
