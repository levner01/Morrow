-- M1 首批 migration 2/4：life_data / workspace_settings / agent_clients + RLS
-- 依据：01-architecture.md §3.1/§3.2/§3.3/§4；02-contracts.md C-01/C-02

begin;

-- 1. life_data（§3.1）：业务记录主表，记录级 tombstone + 唯一业务键
create table if not exists public.life_data (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete restrict,
  module      text not null check (module in (
                'anchor','day_type','day_type_definition',
                'habit_definition','habit_log','workout','inbox','shopping','goal'
              )),
  entity_key  text not null check (char_length(entity_key) between 1 and 200),
  biz_date    date,
  payload     jsonb not null check (jsonb_typeof(payload) = 'object'),
  version     bigint not null default 1 check (version > 0),
  source_type text not null check (source_type in ('human','agent','system','import')),
  source_id   uuid not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz,
  -- payload_v 顶层正整数（严格 JSON Schema 在 Core/pg_jsonschema 侧强制）
  constraint life_data_payload_v_chk check (
    (payload ? 'payload_v') and (jsonb_typeof(payload -> 'payload_v') = 'number')
  ),
  constraint life_data_biz_date_chk check (
    -- anchor/day_type 必填 biz_date；其余按模块合同（Phase1 后按需收紧）
    (module in ('anchor','day_type')) = (biz_date is not null)
  ),
  unique (user_id, id)             -- 供跨表复合 FK
);
-- 唯一业务键永久有效（含 soft delete 仍占键）
create unique index if not exists life_data_biz_key_uq
  on public.life_data (user_id, module, entity_key);
create index if not exists life_data_read_idx
  on public.life_data (user_id, module, biz_date, id) where deleted_at is null;

alter table public.life_data enable row level security;
comment on table public.life_data is '业务记录主表；记录级 tombstone + LWW/OCC；不可变列/版本/审计由 Core 事务强制';

-- RLS：仅 owner（经 private.workspace_owner）可见自己行；写入只经 RPC，直接 DML 全拒绝
create policy life_data_owner_select on public.life_data
  for select to authenticated
  using (user_id = auth.uid()
         and exists (select 1 from private.workspace_owner o where o.user_id = auth.uid()));
-- 无 insert/update/delete policy → 默认拒绝（写仅经 SECURITY DEFINER Core RPC）

-- 2. workspace_settings（§3.2）：时区/跟踪起日/周计划历史
create table if not exists public.workspace_settings (
  user_id             uuid primary key references auth.users (id) on delete restrict,
  timezone            text not null,
  tracking_started_on date not null,
  schedule_history    jsonb not null check (jsonb_typeof(schedule_history) = 'array'),
  version             bigint not null default 1 check (version > 0),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
alter table public.workspace_settings enable row level security;
comment on table public.workspace_settings is '工作区设置；schedule_history 按 effective_from 严格递增、保历史；payload_v:1';

create policy workspace_settings_owner_select on public.workspace_settings
  for select to authenticated
  using (user_id = auth.uid()
         and exists (select 1 from private.workspace_owner o where o.user_id = auth.uid()));
-- 写仅经 initialize/set RPC（SECURITY DEFINER）；直接 DML 全拒绝

-- scopes 无重复用 IMMUTABLE 函数校验（PG 不允许 CHECK 子查询）
create or replace function public._scopes_no_dup(s text[]) returns boolean
  language sql immutable parallel safe as
$$ select coalesce(cardinality(s), 0) = coalesce((select count(distinct x) from unnest(s) as x), 0) $$;

-- 3. agent_clients（§3.3）：M1 建表，仅 health 客户端；停用/撤销而非 DELETE
create table if not exists public.agent_clients (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users (id) on delete restrict,
  name         text not null check (char_length(name) between 1 and 80),
  type         text not null check (type in ('local','remote','scheduled')),
  scopes       text[] not null default '{}',
  enabled      boolean not null default false,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  last_seen_at timestamptz,
  revoked_at   timestamptz,
  version      bigint not null default 1 check (version > 0),
  unique (user_id, id),
  -- scopes 无重复；M1 唯一可发 system:health（C-05.1）
  constraint agent_clients_scopes_chk check (public._scopes_no_dup(scopes)),
  constraint agent_clients_scopes_m1_chk check (
    scopes <@ array['system:health']::text[]
  )
);
create index if not exists agent_clients_enabled_idx on public.agent_clients (user_id, enabled);
alter table public.agent_clients enable row level security;
comment on table public.agent_clients is 'Agent 客户端配置；M1 仅 system:health；凭据不在此表；停用/撤销不删除';

create policy agent_clients_owner_select on public.agent_clients
  for select to authenticated
  using (user_id = auth.uid()
         and exists (select 1 from private.workspace_owner o where o.user_id = auth.uid()));
-- 无直接 DML；管理经 manage_health_client_v1 RPC（P0-004）

-- 4. grants（§4）：authenticated 只读 owner 行；anon 无；service_role 不直读业务表
revoke all on public.life_data         from public, anon, authenticated, service_role;
revoke all on public.workspace_settings from public, anon, authenticated, service_role;
revoke all on public.agent_clients     from public, anon, authenticated, service_role;
grant select on public.life_data          to authenticated;
grant select on public.workspace_settings to authenticated;
grant select on public.agent_clients      to authenticated;

-- CHECK 校验函数不对外开放 EXECUTE（§4：默认撤销 PUBLIC function EXECUTE）
revoke all on function public._scopes_no_dup(text[]) from public, anon, authenticated, service_role;

commit;
