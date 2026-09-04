create extension if not exists pgcrypto;

create type public.plan_node_kind as enum ('goal', 'project', 'milestone', 'task', 'step', 'event', 'rest');
create type public.action_risk as enum ('low', 'medium', 'high');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  timezone text not null default 'Asia/Singapore',
  locale text not null default 'zh-CN',
  created_at timestamptz not null default now()
);

create table public.plan_nodes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  parent_id uuid references public.plan_nodes(id) on delete cascade,
  kind public.plan_node_kind not null,
  title text not null check (char_length(title) between 1 and 240),
  detail text not null default '',
  importance smallint not null default 3 check (importance between 1 and 5),
  deadline timestamptz,
  estimated_minutes integer not null default 60 check (estimated_minutes >= 0),
  remaining_minutes integer not null default 60 check (remaining_minutes >= 0),
  progress numeric(5,4) not null default 0 check (progress between 0 and 1),
  is_paused boolean not null default false,
  version bigint not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.schedule_blocks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  plan_node_id uuid references public.plan_nodes(id) on delete set null,
  starts_at timestamptz not null,
  ends_at timestamptz not null check (ends_at > starts_at),
  is_fixed boolean not null default false,
  provenance text not null default 'lamp',
  state text not null default 'planned',
  reason_factors jsonb not null default '[]'::jsonb,
  schedule_version bigint not null,
  created_at timestamptz not null default now()
);

create table public.memories (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  category text not null,
  content jsonb not null,
  source text not null,
  confidence numeric(5,4) not null check (confidence between 0 and 1),
  status text not null check (status in ('inferred', 'proposed', 'confirmed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.replan_proposals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  reason text not null,
  preview_hash text not null,
  diff jsonb not null,
  status text not null default 'pending' check (status in ('pending', 'applied', 'rejected', 'expired')),
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create table public.agent_actions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  idempotency_key text not null,
  tool_name text not null,
  tool_version integer not null,
  model text,
  risk public.action_risk not null,
  validation_result jsonb not null,
  execution_result jsonb,
  created_at timestamptz not null default now(),
  unique (user_id, idempotency_key)
);

alter table public.profiles enable row level security;
alter table public.plan_nodes enable row level security;
alter table public.schedule_blocks enable row level security;
alter table public.memories enable row level security;
alter table public.replan_proposals enable row level security;
alter table public.agent_actions enable row level security;

create policy "own profiles" on public.profiles for all using (id = auth.uid()) with check (id = auth.uid());
create policy "own plan nodes" on public.plan_nodes for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own schedule blocks" on public.schedule_blocks for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own memories" on public.memories for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own replans" on public.replan_proposals for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "read own audit" on public.agent_actions for select using (user_id = auth.uid());

create index plan_nodes_user_parent on public.plan_nodes(user_id, parent_id);
create index schedule_blocks_user_time on public.schedule_blocks(user_id, starts_at, ends_at);
create index memories_user_status on public.memories(user_id, status);

