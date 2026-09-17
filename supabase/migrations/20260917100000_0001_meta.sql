-- M1 首批 migration 1/4：扩展、private schema、技术元表、默认权限收口
-- 依据：01-architecture.md §3.9/§3.10/§4；02-contracts.md C-01/C-09
-- 纪律：不改已应用 migration；本批为首个基线。所有业务表 RLS 开启，默认权限拒绝。

begin;

-- 1. pg_jsonschema（payload 结构校验，装到 extensions schema）
create extension if not exists pg_jsonschema with schema extensions;

-- 2. private schema：不加入 Data API exposed schemas；托管项目的核心/凭据/收据/schema 快照
create schema if not exists private;
comment on schema private is 'Morrow 内部 schema：凭据/收据/schema 快照/owner 允许表；不向 Data API 暴露，不授予 anon/authenticated/service_role 任何对象';

-- 3. private.workspace_owner：owner 允许表（§4 singleton）
create table if not exists private.workspace_owner (
  user_id   uuid    primary key references auth.users (id) on delete restrict,
  singleton boolean not null default true unique check (singleton),
  created_at timestamptz not null default now()
);
alter table private.workspace_owner enable row level security;
comment on table private.workspace_owner is 'owner 允许表，仅一行（singleton 唯一）。RLS 无 policy=默认拒绝；仅供 Core（SECURITY DEFINER 固定 owner）内部检查';

-- 4. public.workspace_state（§3.9）：导出 revision，预置零值，Human 只读
create table if not exists public.workspace_state (
  user_id       uuid   primary key references auth.users (id) on delete restrict,
  data_revision bigint not null default 0 check (data_revision >= 0),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
alter table public.workspace_state enable row level security;
comment on table public.workspace_state is '导出一致性 revision；任何导出集合有效变化在同事务 +1；不替代单记录 version';

-- 5. private.payload_schemas（§3.9）：migration 固化 contracts 快照 + hash
create table if not exists private.payload_schemas (
  module      text not null,
  payload_v   integer not null check (payload_v > 0),
  schema      jsonb not null,
  schema_hash text not null,
  primary key (module, payload_v)
);
comment on table private.payload_schemas is 'contracts/v1 的 payload schema 快照 + schema_hash；由 migration 装载，CI 校验 hash 匹配';

-- 6. 默认权限收口（§4）：显式撤销 PUBLIC/anon/authenticated/service_role 对上述对象的一切权限；
--    再按矩阵回授最小权限。private schema 下的对象对客户端角色零权限。
revoke all on schema private from public, anon, authenticated, service_role;

revoke all on private.workspace_owner from public, anon, authenticated, service_role;
revoke all on private.payload_schemas from public, anon, authenticated, service_role;

-- workspace_state：Human（authenticated）只读；anon 无；写入只能经 Core（SR 内部，不给 client 直写）
revoke all on public.workspace_state from public, anon, authenticated, service_role;
grant select on public.workspace_state to authenticated;

commit;
