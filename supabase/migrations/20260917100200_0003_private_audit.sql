-- M1 首批 migration 3/4：private 凭据/收据、activity_log、封闭 advice/rules
-- 依据：01-architecture.md §3.4/§3.5/§3.6/§3.7/§3.8；02-contracts.md C-05.1/C-06/C-08

begin;

-- 1. private.agent_credentials（§3.4）：opaque token 摘要；不存原始 token；不进导出/Human SELECT
create table if not exists private.agent_credentials (
  id          uuid primary key default gen_random_uuid(),  -- 亦为非秘密 token locator
  user_id     uuid not null,
  agent_id    uuid not null,
  token_hash  bytea not null unique check (octet_length(token_hash) = 32),  -- SHA-256
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  revoked_at  timestamptz,
  constraint agent_credentials_fk foreign key (user_id, agent_id)
    references public.agent_clients (user_id, id) on delete restrict,
  constraint agent_credentials_exp_chk check (expires_at > created_at)
);
create index if not exists agent_credentials_agent_idx on private.agent_credentials (agent_id, revoked_at);
alter table private.agent_credentials enable row level security;
comment on table private.agent_credentials is 'Agent opaque token 摘要（SHA-256，32字节）；locator=id；不存原文，不进导出/SELECT';

-- 2. private.request_receipts（§3.8）：幂等收据；namespace (owner,actor_type,actor_id,key)
create table if not exists private.request_receipts (
  user_id         uuid not null references auth.users (id) on delete restrict,
  actor_type      text not null check (actor_type in ('human','agent','system','import')),
  actor_id        uuid not null,
  idempotency_key uuid not null,
  operation       text not null,
  request_hash    bytea not null check (octet_length(request_hash) = 32),
  state           text not null check (state in ('processing','completed','rejected','expired')),
  response        jsonb,
  created_at      timestamptz not null default now(),
  completed_at    timestamptz,
  response_expires_at timestamptz,
  primary key (user_id, actor_type, actor_id, idempotency_key)
);
create index if not exists request_receipts_exp_idx on private.request_receipts (response_expires_at) where response is not null;
alter table private.request_receipts enable row level security;
comment on table private.request_receipts is '幂等收据；只存 request_hash（SHA-256），不存 token 明文；响应过期留小收据，绝不当新命令重放';

-- 3. public.activity_log（§3.6）：仅 Core 追加；外部 INSERT/UPDATE/DELETE 全拒绝
create table if not exists public.activity_log (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete restrict,
  actor_type  text not null check (actor_type in ('human','agent','system','import')),
  actor_id    uuid not null,
  agent_id    uuid,
  action      text not null,
  resource    text not null,
  resource_id uuid,
  request_id  uuid,
  metadata    jsonb not null default '{}',
  created_at  timestamptz not null default now(),
  -- agent_id 有值时复合 owner FK（§3.6）
  constraint activity_log_agent_fk foreign key (user_id, agent_id)
    references public.agent_clients (user_id, id) on delete restrict
);
create index if not exists activity_log_time_idx on public.activity_log (user_id, created_at desc, id desc);
create index if not exists activity_log_req_idx  on public.activity_log (user_id, request_id);
alter table public.activity_log enable row level security;
comment on table public.activity_log is '审计日志；仅 Core 追加；不默认复制 note/content 全文；无应用修改接口';

create policy activity_log_owner_select on public.activity_log
  for select to authenticated
  using (user_id = auth.uid()
         and exists (select 1 from private.workspace_owner o where o.user_id = auth.uid()));

-- 4. public.agent_advice（§3.5）：M1 空表封闭；Phase2 激活；无 advice 写权限及 UI
create table if not exists public.agent_advice (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null,
  agent_id   uuid not null,
  topic      text not null check (char_length(topic) between 1 and 80),
  title      text not null check (char_length(title) between 1 and 200),
  content    text not null check (char_length(content) between 1 and 8000),
  reason     text not null check (char_length(reason) between 1 and 2000),
  evidence   jsonb not null default '[]',
  priority   text not null check (priority in ('low','normal','high')),
  status     text not null default 'unread' check (status in ('unread','read','accepted','dismissed','expired')),
  payload_v  integer not null default 1 check (payload_v > 0),
  version    bigint not null default 1 check (version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz,
  constraint agent_advice_fk foreign key (user_id, agent_id)
    references public.agent_clients (user_id, id) on delete restrict,
  constraint agent_advice_exp_chk check (expires_at is null or expires_at > created_at),
  constraint agent_advice_evidence_chk check (jsonb_typeof(evidence) = 'array')
);
create index if not exists agent_advice_read_idx on public.agent_advice (user_id, status, created_at desc, id);
alter table public.agent_advice enable row level security;
comment on table public.agent_advice is 'Agent 建议；M1 空表封闭，Phase2 激活；仅 Agent 创建仅 Human 裁决';

-- M1 封闭：无任何 policy → owner 也无 SELECT（Phase2 才按合同开放）
revoke all on public.agent_advice from public, anon, authenticated, service_role;

-- 5. public.automation_rules（§3.7）：M1 空表封闭；Phase3 激活；无写入口
create table if not exists public.automation_rules (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete restrict,
  name        text not null check (char_length(name) between 1 and 120),
  enabled     boolean not null default false,
  definition  jsonb not null check (jsonb_typeof(definition) = 'object'),
  version     bigint not null default 1 check (version > 0),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz
);
create index if not exists automation_rules_enabled_idx on public.automation_rules (user_id, enabled) where deleted_at is null;
alter table public.automation_rules enable row level security;
comment on table public.automation_rules is '自动化规则；M1 空表封闭，Phase3 激活；definition payload_v:1，M1 拒绝实际执行动作';

revoke all on public.automation_rules from public, anon, authenticated, service_role;

-- 6. 私有/审计表 grants 收口（§4 矩阵）
revoke all on private.agent_credentials from public, anon, authenticated, service_role;
revoke all on private.request_receipts from public, anon, authenticated, service_role;
revoke all on public.activity_log from public, anon, authenticated, service_role;
grant select on public.activity_log to authenticated;   -- owner 只读自己日志（RLS 限 owner）
-- activity_log / advice / rules / credentials / receipts：无 INSERT/UPDATE/DELETE 给任何客户端角色

commit;
