-- Lamp Harness production persistence and offline-sync foundation.
-- Additive only: existing v1 tables and clients remain valid during the v2 rollout.

alter table public.profiles
  add column if not exists state_version bigint not null default 0,
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists deleted_at timestamptz;

alter table public.plan_nodes
  add column if not exists client_mutation_id uuid,
  add column if not exists deleted_at timestamptz;

create unique index if not exists plan_nodes_user_mutation
  on public.plan_nodes(user_id, client_mutation_id) where client_mutation_id is not null;

alter table public.schedule_blocks
  add column if not exists version bigint not null default 1,
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists deleted_at timestamptz,
  add column if not exists client_mutation_id uuid,
  add column if not exists is_locked boolean not null default false;

create unique index if not exists schedule_blocks_user_mutation
  on public.schedule_blocks(user_id, client_mutation_id) where client_mutation_id is not null;

alter table public.memories
  add column if not exists memory_key text,
  add column if not exists version bigint not null default 1,
  add column if not exists supersedes_id uuid references public.memories(id),
  add column if not exists expires_at timestamptz,
  add column if not exists deleted_at timestamptz,
  add column if not exists client_mutation_id uuid;

create unique index if not exists memories_user_key_version
  on public.memories(user_id, memory_key, version) where memory_key is not null;
create unique index if not exists memories_user_mutation
  on public.memories(user_id, client_mutation_id) where client_mutation_id is not null;

alter table public.replan_proposals
  add column if not exists request_id text,
  add column if not exists request_hash text,
  add column if not exists kind text,
  add column if not exists source_fingerprint text,
  add column if not exists expected_state_version bigint not null default 0,
  add column if not exists confirmation_token_hash text,
  add column if not exists scope text not null default 'local',
  add column if not exists trace jsonb not null default '{}'::jsonb,
  add column if not exists response jsonb not null default '{}'::jsonb,
  add column if not exists confirmed_at timestamptz,
  add column if not exists rejected_at timestamptz;

create unique index if not exists replan_proposals_user_request
  on public.replan_proposals(user_id, request_id) where request_id is not null;

alter table public.agent_actions
  add column if not exists run_id uuid,
  add column if not exists trace_id uuid,
  add column if not exists input_hash text,
  add column if not exists output_hash text,
  add column if not exists policy_result jsonb,
  add column if not exists duration_ms integer check (duration_ms is null or duration_ms >= 0),
  add column if not exists expires_at timestamptz default (now() + interval '180 days');

update public.agent_actions set expires_at = created_at + interval '180 days' where expires_at is null;

create table if not exists public.agent_runs (
  run_id uuid primary key,
  trace_id uuid not null unique,
  user_id uuid not null references auth.users(id) on delete cascade,
  session_id text not null,
  request_id text not null,
  status text not null check (status in ('running', 'succeeded', 'confirmation_required', 'safe_aborted', 'failed')),
  record jsonb not null,
  input_hash text not null check (input_hash ~ '^[a-f0-9]{64}$'),
  started_at timestamptz not null,
  ended_at timestamptz,
  expires_at timestamptz not null default (now() + interval '30 days'),
  created_at timestamptz not null default now(),
  unique (user_id, request_id)
);

create table if not exists public.state_snapshots (
  snapshot_id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  source_revision bigint not null,
  content_hash text not null check (content_hash ~ '^[a-f0-9]{64}$'),
  snapshot jsonb not null,
  captured_at timestamptz not null,
  expires_at timestamptz not null default (now() + interval '30 days'),
  created_at timestamptz not null default now()
);

create table if not exists public.plan_revisions (
  revision_id uuid primary key,
  plan_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  revision bigint not null check (revision > 0),
  previous_revision_id uuid references public.plan_revisions(revision_id) on delete set null,
  source_event_id uuid not null,
  base_state_revision bigint not null,
  status text not null default 'proposed' check (status in ('proposed', 'applied', 'rejected', 'expired')),
  revision_record jsonb not null,
  created_at timestamptz not null,
  expires_at timestamptz not null default (now() + interval '30 days'),
  unique (plan_id, revision)
);

create table if not exists public.idempotency_records (
  user_id uuid not null references auth.users(id) on delete cascade,
  operation text not null,
  idempotency_key text not null,
  request_hash text not null check (request_hash ~ '^[a-f0-9]{64}$'),
  response_status integer not null,
  response_body jsonb not null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  primary key (user_id, operation, idempotency_key)
);

create table if not exists public.working_memory (
  user_id uuid not null references auth.users(id) on delete cascade,
  session_id text not null,
  run_id uuid not null,
  memory_key text not null,
  entry jsonb not null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  primary key (user_id, session_id, run_id, memory_key)
);

create table if not exists public.memory_candidates (
  candidate_id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  status text not null check (status in ('pending', 'approved', 'rejected', 'expired')),
  candidate jsonb not null,
  created_at timestamptz not null,
  updated_at timestamptz not null default now(),
  expires_at timestamptz
);

create table if not exists public.recurring_schedule_rules (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  payload jsonb not null,
  version bigint not null default 1,
  client_mutation_id uuid,
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (user_id, client_mutation_id)
);

create table if not exists public.schedule_occurrence_overrides (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  recurring_rule_id uuid not null references public.recurring_schedule_rules(id) on delete cascade,
  occurrence_date date not null,
  payload jsonb not null,
  version bigint not null default 1,
  client_mutation_id uuid,
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (user_id, recurring_rule_id, occurrence_date),
  unique (user_id, client_mutation_id)
);

create table if not exists public.planning_rules (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  payload jsonb not null,
  version bigint not null default 1,
  client_mutation_id uuid,
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (user_id, client_mutation_id)
);

create table if not exists public.temporary_states (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  payload jsonb not null,
  expires_at timestamptz not null,
  version bigint not null default 1,
  client_mutation_id uuid,
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (user_id, client_mutation_id)
);

create table if not exists public.sync_devices (
  device_id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  last_cursor bigint not null default 0,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (user_id, device_id)
);

create table if not exists public.sync_changes (
  cursor bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  entity_type text not null,
  entity_id uuid not null,
  entity_version bigint not null,
  operation text not null check (operation in ('upsert', 'delete')),
  payload jsonb,
  content_hash text not null check (content_hash ~ '^[a-f0-9]{64}$'),
  client_mutation_id uuid not null,
  occurred_at timestamptz not null default now(),
  unique (user_id, client_mutation_id)
);

create table if not exists public.account_migration_audit (
  id uuid primary key default gen_random_uuid(),
  source_user_hash text not null check (source_user_hash ~ '^[a-f0-9]{64}$'),
  target_user_hash text not null check (target_user_hash ~ '^[a-f0-9]{64}$'),
  status text not null check (status in ('completed', 'failed')),
  occurred_at timestamptz not null default now()
);

create table if not exists public.account_deletion_receipts (
  id uuid primary key default gen_random_uuid(),
  user_hash text not null check (user_hash ~ '^[a-f0-9]{64}$'),
  status text not null default 'completed' check (status = 'completed'),
  occurred_at timestamptz not null default now()
);

create index if not exists agent_runs_user_started on public.agent_runs(user_id, started_at desc);
create index if not exists snapshots_user_captured on public.state_snapshots(user_id, captured_at desc);
create index if not exists revisions_user_plan on public.plan_revisions(user_id, plan_id, revision desc);
create index if not exists idempotency_expiry on public.idempotency_records(expires_at);
create index if not exists working_memory_expiry on public.working_memory(expires_at);
create index if not exists sync_changes_user_cursor on public.sync_changes(user_id, cursor);

create or replace function public.migrate_anonymous_account(p_source_user uuid, p_target_user uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_table text;
begin
  if p_source_user = p_target_user then return jsonb_build_object('status', 'linked', 'userId', p_target_user); end if;
  if not exists (select 1 from auth.users where id = p_source_user and is_anonymous) then
    raise exception using errcode = '42501', message = 'source_is_not_anonymous';
  end if;
  if not exists (select 1 from auth.users where id = p_target_user) then
    raise exception using errcode = 'P0002', message = 'target_user_not_found';
  end if;
  if exists (select 1 from public.plan_nodes where user_id = p_target_user) or
     exists (select 1 from public.schedule_blocks where user_id = p_target_user) or
     exists (select 1 from public.memories where user_id = p_target_user) then
    raise exception using errcode = '23505', message = 'target_account_not_empty';
  end if;

  delete from public.profiles where id = p_target_user;
  update public.profiles set id = p_target_user where id = p_source_user;
  foreach v_table in array array[
    'plan_nodes', 'schedule_blocks', 'memories', 'replan_proposals', 'agent_actions',
    'agent_runs', 'state_snapshots', 'plan_revisions', 'idempotency_records', 'working_memory',
    'memory_candidates', 'recurring_schedule_rules', 'schedule_occurrence_overrides',
    'planning_rules', 'temporary_states', 'sync_devices', 'sync_changes'
  ] loop
    execute format('update public.%I set user_id = $1 where user_id = $2', v_table)
      using p_target_user, p_source_user;
  end loop;
  insert into public.account_migration_audit(source_user_hash, target_user_hash, status)
  values (
    encode(digest(p_source_user::text, 'sha256'), 'hex'),
    encode(digest(p_target_user::text, 'sha256'), 'hex'), 'completed'
  );
  return jsonb_build_object('status', 'migrated', 'userId', p_target_user);
end;
$$;

create or replace function public.record_account_deletion(p_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_receipt uuid;
begin
  insert into public.account_deletion_receipts(user_hash)
  values (encode(digest(p_user_id::text, 'sha256'), 'hex')) returning id into v_receipt;
  return v_receipt;
end;
$$;

create or replace function public.cleanup_expired_agent_data(p_now timestamptz default now())
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_working integer;
  v_idempotency integer;
  v_candidates integer;
  v_runs integer;
  v_snapshots integer;
  v_revisions integer;
  v_audits integer;
  v_proposals integer;
begin
  delete from public.working_memory where expires_at <= p_now;
  get diagnostics v_working = row_count;
  delete from public.idempotency_records where expires_at <= p_now;
  get diagnostics v_idempotency = row_count;
  update public.memory_candidates set status = 'expired', updated_at = p_now
    where status = 'pending' and expires_at is not null and expires_at <= p_now;
  get diagnostics v_candidates = row_count;
  update public.replan_proposals set status = 'expired'
    where status = 'pending' and expires_at <= p_now;
  get diagnostics v_proposals = row_count;
  delete from public.agent_runs where expires_at <= p_now;
  get diagnostics v_runs = row_count;
  delete from public.state_snapshots where expires_at <= p_now;
  get diagnostics v_snapshots = row_count;
  delete from public.plan_revisions where expires_at <= p_now;
  get diagnostics v_revisions = row_count;
  delete from public.agent_actions where expires_at <= p_now;
  get diagnostics v_audits = row_count;
  return jsonb_build_object(
    'workingMemory', v_working, 'idempotency', v_idempotency, 'memoryCandidates', v_candidates,
    'proposals', v_proposals, 'runs', v_runs, 'snapshots', v_snapshots,
    'revisions', v_revisions, 'audits', v_audits
  );
end;
$$;

alter table public.agent_runs enable row level security;
alter table public.state_snapshots enable row level security;
alter table public.plan_revisions enable row level security;
alter table public.idempotency_records enable row level security;
alter table public.working_memory enable row level security;
alter table public.memory_candidates enable row level security;
alter table public.recurring_schedule_rules enable row level security;
alter table public.schedule_occurrence_overrides enable row level security;
alter table public.planning_rules enable row level security;
alter table public.temporary_states enable row level security;
alter table public.sync_devices enable row level security;
alter table public.sync_changes enable row level security;
alter table public.account_migration_audit enable row level security;
alter table public.account_deletion_receipts enable row level security;

create policy "read own agent runs" on public.agent_runs for select using (user_id = auth.uid());
create policy "read own snapshots" on public.state_snapshots for select using (user_id = auth.uid());
create policy "read own revisions" on public.plan_revisions for select using (user_id = auth.uid());
create policy "read own idempotency" on public.idempotency_records for select using (user_id = auth.uid());
create policy "own working memory" on public.working_memory for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own memory candidates" on public.memory_candidates for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own recurring rules" on public.recurring_schedule_rules for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own occurrence overrides" on public.schedule_occurrence_overrides for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own planning rules" on public.planning_rules for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own temporary states" on public.temporary_states for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own sync devices" on public.sync_devices for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "read own sync changes" on public.sync_changes for select using (user_id = auth.uid());

grant select on public.agent_runs, public.state_snapshots, public.plan_revisions,
  public.idempotency_records, public.sync_changes to authenticated;
grant select, insert, update, delete on public.working_memory, public.memory_candidates,
  public.recurring_schedule_rules, public.schedule_occurrence_overrides,
  public.planning_rules, public.temporary_states, public.sync_devices to authenticated;
grant all on public.agent_runs, public.state_snapshots, public.plan_revisions,
  public.idempotency_records, public.working_memory, public.memory_candidates,
  public.recurring_schedule_rules, public.schedule_occurrence_overrides,
  public.planning_rules, public.temporary_states, public.sync_devices,
  public.sync_changes to service_role;
grant all on public.account_migration_audit, public.account_deletion_receipts to service_role;
grant usage, select on sequence public.sync_changes_cursor_seq to service_role;
revoke insert, update, delete on public.replan_proposals, public.agent_actions from anon, authenticated;
grant select on public.replan_proposals, public.agent_actions to authenticated;
revoke all on function public.cleanup_expired_agent_data(timestamptz) from public;
grant execute on function public.cleanup_expired_agent_data(timestamptz) to service_role;
revoke all on function public.migrate_anonymous_account(uuid, uuid) from public;
revoke all on function public.record_account_deletion(uuid) from public;
grant execute on function public.migrate_anonymous_account(uuid, uuid) to service_role;
grant execute on function public.record_account_deletion(uuid) to service_role;

create or replace function public.confirm_agent_proposal(
  p_user_id uuid,
  p_proposal_id uuid,
  p_preview_hash text,
  p_confirmation_token_hash text,
  p_expected_state_version bigint,
  p_idempotency_key text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := p_user_id;
  v_proposal public.replan_proposals%rowtype;
  v_existing public.agent_actions%rowtype;
  v_new_version bigint;
  v_operation jsonb;
  v_replaced public.schedule_blocks%rowtype;
  v_request_hash text;
  v_mutation_id uuid;
  v_block_version bigint;
begin
  if v_user_id is null then raise exception using errcode = '28000', message = 'authentication_required'; end if;
  if auth.uid() is not null and auth.uid() <> v_user_id then
    raise exception using errcode = '42501', message = 'user_identity_mismatch';
  end if;

  v_request_hash := encode(digest(
    p_proposal_id::text || ':' || p_preview_hash || ':' || p_confirmation_token_hash || ':' || p_expected_state_version::text,
    'sha256'
  ), 'hex');

  select * into v_existing from public.agent_actions
    where user_id = v_user_id and idempotency_key = p_idempotency_key;
  if found then
    if v_existing.input_hash is distinct from v_request_hash then
      raise exception using errcode = '23505', message = 'idempotency_content_mismatch';
    end if;
    return coalesce(v_existing.execution_result, '{}'::jsonb);
  end if;

  select * into v_proposal from public.replan_proposals
    where id = p_proposal_id and user_id = v_user_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'proposal_not_found'; end if;
  if v_proposal.status <> 'pending' then raise exception using errcode = 'P0001', message = 'proposal_not_pending'; end if;
  if v_proposal.expires_at <= now() then
    update public.replan_proposals set status = 'expired' where id = p_proposal_id;
    raise exception using errcode = 'P0001', message = 'proposal_expired';
  end if;
  if v_proposal.preview_hash <> p_preview_hash or
     v_proposal.confirmation_token_hash <> p_confirmation_token_hash then
    raise exception using errcode = '28000', message = 'proposal_confirmation_invalid';
  end if;
  if v_proposal.expected_state_version <> p_expected_state_version then
    raise exception using errcode = '40001', message = 'proposal_version_mismatch';
  end if;

  update public.profiles set state_version = state_version + 1, updated_at = now()
    where id = v_user_id and state_version = p_expected_state_version
    returning state_version into v_new_version;
  if not found then raise exception using errcode = '40001', message = 'stale_state'; end if;

  for v_operation in select value from jsonb_array_elements(coalesce(v_proposal.diff->'operations', '[]'::jsonb))
  loop
    if v_operation->>'type' = 'upsert_schedule_block' then
      if v_operation->>'replacesBlockId' is not null then
        select * into v_replaced from public.schedule_blocks
          where id = (v_operation->>'replacesBlockId')::uuid and user_id = v_user_id for update;
        if not found or v_replaced.is_fixed or v_replaced.is_locked or lower(v_replaced.provenance) <> 'lamp' then
          raise exception using errcode = '42501', message = 'protected_schedule_block';
        end if;
        update public.schedule_blocks set deleted_at = now(), updated_at = now(), version = version + 1
          where id = v_replaced.id and user_id = v_user_id
          returning version into v_block_version;
        v_mutation_id := gen_random_uuid();
        insert into public.sync_changes(
          user_id, entity_type, entity_id, entity_version, operation, payload, content_hash, client_mutation_id
        ) values (
          v_user_id, 'schedule_block', v_replaced.id, v_block_version, 'delete', null,
          encode(digest('deleted:' || v_replaced.id::text || ':' || v_block_version::text, 'sha256'), 'hex'), v_mutation_id
        );
      end if;
      v_mutation_id := gen_random_uuid();
      insert into public.schedule_blocks(
        id, user_id, plan_node_id, starts_at, ends_at, is_fixed, provenance, state,
        reason_factors, schedule_version, version, client_mutation_id
      ) values (
        (v_operation->>'id')::uuid, v_user_id, nullif(v_operation->>'planNodeId', '')::uuid,
        (v_operation->>'startsAt')::timestamptz, (v_operation->>'endsAt')::timestamptz,
        false, 'lamp', 'planned', coalesce(v_operation->'reasonCodes', '[]'::jsonb),
        v_new_version, 1, v_mutation_id
      ) on conflict (id) do update set
        starts_at = excluded.starts_at, ends_at = excluded.ends_at,
        reason_factors = excluded.reason_factors, schedule_version = excluded.schedule_version,
        version = public.schedule_blocks.version + 1, updated_at = now(), deleted_at = null,
        client_mutation_id = excluded.client_mutation_id
      where public.schedule_blocks.user_id = v_user_id and not public.schedule_blocks.is_fixed
        and not public.schedule_blocks.is_locked and lower(public.schedule_blocks.provenance) = 'lamp'
      returning version into v_block_version;
      if not found then raise exception using errcode = '42501', message = 'protected_schedule_block'; end if;
      insert into public.sync_changes(
        user_id, entity_type, entity_id, entity_version, operation, payload, content_hash, client_mutation_id
      ) values (
        v_user_id, 'schedule_block', (v_operation->>'id')::uuid, v_block_version, 'upsert',
        jsonb_build_object(
          'id', v_operation->>'id', 'planItemID', v_operation->>'planNodeId',
          'title', v_operation->>'title', 'start', v_operation->>'startsAt', 'end', v_operation->>'endsAt',
          'kind', 'focus', 'state', 'planned', 'reason', array_to_string(array(select jsonb_array_elements_text(coalesce(v_operation->'reasonCodes', '[]'::jsonb))), ', '),
          'provenance', 'Lamp Agent Core · 用户确认', 'recurringRuleID', null, 'occurrenceDate', null
        ),
        encode(digest(v_operation::text, 'sha256'), 'hex'), v_mutation_id
      );
    elsif v_operation->>'type' = 'remove_schedule_block' then
      v_mutation_id := gen_random_uuid();
      update public.schedule_blocks set deleted_at = now(), updated_at = now(), version = version + 1,
        schedule_version = v_new_version, client_mutation_id = v_mutation_id
      where id = (v_operation->>'id')::uuid and user_id = v_user_id
        and not is_fixed and not is_locked and lower(provenance) = 'lamp'
      returning version into v_block_version;
      if not found then raise exception using errcode = '42501', message = 'protected_schedule_block'; end if;
      insert into public.sync_changes(
        user_id, entity_type, entity_id, entity_version, operation, payload, content_hash, client_mutation_id
      ) values (
        v_user_id, 'schedule_block', (v_operation->>'id')::uuid, v_block_version, 'delete', null,
        encode(digest('deleted:' || (v_operation->>'id') || ':' || v_block_version::text, 'sha256'), 'hex'), v_mutation_id
      );
    elsif v_operation->>'type' = 'set_temporary_state' then
      if length(coalesce(v_operation->>'title', '')) not between 1 and 120 or
         (v_operation->>'workloadMultiplier')::numeric <= 0 or
         (v_operation->>'workloadMultiplier')::numeric > 2 or
         (v_operation->>'expiresAt')::timestamptz <= now() or
         (v_operation->>'expiresAt')::timestamptz > now() + interval '25 hours' then
        raise exception using errcode = '22023', message = 'invalid_temporary_state';
      end if;
      v_mutation_id := gen_random_uuid();
      insert into public.temporary_states(id, user_id, payload, expires_at, version, client_mutation_id)
      values (
        (v_operation->>'id')::uuid, v_user_id,
        jsonb_build_object(
          'id', v_operation->>'id', 'title', v_operation->>'title',
          'expiresAt', v_operation->>'expiresAt',
          'workloadMultiplier', (v_operation->>'workloadMultiplier')::numeric
        ),
        (v_operation->>'expiresAt')::timestamptz, 1, v_mutation_id
      ) on conflict (id) do update set
        payload = excluded.payload, expires_at = excluded.expires_at,
        version = public.temporary_states.version + 1, updated_at = now(), deleted_at = null,
        client_mutation_id = excluded.client_mutation_id
      where public.temporary_states.user_id = v_user_id
      returning version into v_block_version;
      if not found then raise exception using errcode = '42501', message = 'temporary_state_owner_mismatch'; end if;
      insert into public.sync_changes(
        user_id, entity_type, entity_id, entity_version, operation, payload, content_hash, client_mutation_id
      ) values (
        v_user_id, 'temporary_state', (v_operation->>'id')::uuid, v_block_version, 'upsert',
        jsonb_build_object(
          'id', v_operation->>'id', 'title', v_operation->>'title',
          'expiresAt', v_operation->>'expiresAt',
          'workloadMultiplier', (v_operation->>'workloadMultiplier')::numeric
        ),
        encode(digest(v_operation::text, 'sha256'), 'hex'), v_mutation_id
      );
    else
      raise exception using errcode = '22023', message = 'unsupported_proposal_operation';
    end if;
  end loop;

  update public.replan_proposals set status = 'applied', confirmed_at = now()
    where id = p_proposal_id;

  insert into public.agent_actions(
    user_id, idempotency_key, tool_name, tool_version, risk,
    validation_result, execution_result, input_hash, output_hash
  ) values (
    v_user_id, p_idempotency_key, 'confirm_agent_proposal', 2, 'medium',
    jsonb_build_object('previewHash', true, 'stateVersion', true),
    jsonb_build_object('proposalId', p_proposal_id, 'stateVersion', v_new_version),
    v_request_hash,
    encode(digest(p_proposal_id::text || ':' || v_new_version::text, 'sha256'), 'hex')
  );

  return jsonb_build_object('proposalId', p_proposal_id, 'stateVersion', v_new_version, 'status', 'applied');
end;
$$;

create or replace function public.pull_sync_changes(p_after_cursor bigint, p_limit integer default 500)
returns table(
  cursor bigint, entity_type text, entity_id uuid, entity_version bigint,
  operation text, payload jsonb, client_mutation_id uuid, occurred_at timestamptz
)
language sql
security invoker
set search_path = public
as $$
  select c.cursor, c.entity_type, c.entity_id, c.entity_version,
         c.operation, c.payload, c.client_mutation_id, c.occurred_at
  from public.sync_changes c
  where c.user_id = auth.uid() and c.cursor > greatest(p_after_cursor, 0)
  order by c.cursor
  limit least(greatest(p_limit, 1), 500);
$$;

create or replace function public.push_sync_batch(p_device_id uuid, p_changes jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_change jsonb;
  v_accepted integer := 0;
  v_max_cursor bigint := 0;
begin
  if v_user_id is null then raise exception using errcode = '28000', message = 'authentication_required'; end if;
  if jsonb_typeof(p_changes) <> 'array' or jsonb_array_length(p_changes) > 100 then
    raise exception using errcode = '22023', message = 'invalid_sync_batch';
  end if;

  insert into public.sync_devices(device_id, user_id, last_seen_at)
    values (p_device_id, v_user_id, now())
    on conflict (device_id) do update set last_seen_at = now()
    where public.sync_devices.user_id = excluded.user_id;
  if not found then
    raise exception using errcode = '42501', message = 'sync_device_owner_mismatch';
  end if;

  for v_change in select value from jsonb_array_elements(p_changes)
  loop
    if (v_change->>'entityType') not in ('plan_node', 'schedule_block', 'memory', 'planning_rule', 'temporary_state', 'recurring_rule', 'occurrence_override') or
       (v_change->>'operation') not in ('upsert', 'delete') then
      raise exception using errcode = '22023', message = 'invalid_sync_change';
    end if;
    if (v_change->>'entityVersion')::bigint < 1 or coalesce(v_change->>'contentHash', '') !~ '^[a-f0-9]{64}$' then
      raise exception using errcode = '22023', message = 'invalid_sync_version_or_hash';
    end if;
    if exists (
      select 1 from public.sync_changes
      where user_id = v_user_id and client_mutation_id = (v_change->>'clientMutationId')::uuid
    ) then
      continue;
    end if;

    if v_change->>'operation' = 'upsert' and jsonb_typeof(v_change->'payload') <> 'object' then
      raise exception using errcode = '22023', message = 'invalid_sync_payload';
    end if;

    if v_change->>'entityType' = 'plan_node' then
      if v_change->>'operation' = 'delete' then
        update public.plan_nodes set deleted_at = now(), updated_at = now(), version = (v_change->>'entityVersion')::bigint
        where id = (v_change->>'entityId')::uuid and user_id = v_user_id and deleted_at is null
          and version = (v_change->>'entityVersion')::bigint - 1;
      elsif (v_change->>'entityVersion')::bigint = 1 then
        insert into public.plan_nodes(
          id, user_id, parent_id, kind, title, detail, importance, deadline, estimated_minutes,
          remaining_minutes, progress, is_paused, version, client_mutation_id
        ) values (
          (v_change->>'entityId')::uuid, v_user_id, nullif(v_change->'payload'->>'parentID', '')::uuid,
          (v_change->'payload'->>'kind')::public.plan_node_kind, v_change->'payload'->>'title',
          coalesce(v_change->'payload'->>'detail', ''), coalesce((v_change->'payload'->>'importance')::smallint, 3),
          nullif(v_change->'payload'->>'deadline', '')::timestamptz,
          coalesce((v_change->'payload'->>'estimatedMinutes')::integer, 0),
          coalesce((v_change->'payload'->>'remainingMinutes')::integer, 0),
          coalesce((v_change->'payload'->>'progress')::numeric, 0),
          coalesce((v_change->'payload'->>'isPaused')::boolean, false), 1,
          (v_change->>'clientMutationId')::uuid
        ) on conflict (id) do nothing;
      else
        update public.plan_nodes set
          parent_id = nullif(v_change->'payload'->>'parentID', '')::uuid,
          kind = (v_change->'payload'->>'kind')::public.plan_node_kind,
          title = v_change->'payload'->>'title', detail = coalesce(v_change->'payload'->>'detail', ''),
          importance = coalesce((v_change->'payload'->>'importance')::smallint, 3),
          deadline = nullif(v_change->'payload'->>'deadline', '')::timestamptz,
          estimated_minutes = coalesce((v_change->'payload'->>'estimatedMinutes')::integer, 0),
          remaining_minutes = coalesce((v_change->'payload'->>'remainingMinutes')::integer, 0),
          progress = coalesce((v_change->'payload'->>'progress')::numeric, 0),
          is_paused = coalesce((v_change->'payload'->>'isPaused')::boolean, false),
          version = (v_change->>'entityVersion')::bigint, updated_at = now(), deleted_at = null,
          client_mutation_id = (v_change->>'clientMutationId')::uuid
        where id = (v_change->>'entityId')::uuid and user_id = v_user_id
          and version = (v_change->>'entityVersion')::bigint - 1;
      end if;
    elsif v_change->>'entityType' = 'schedule_block' then
      if v_change->>'operation' = 'delete' then
        update public.schedule_blocks set deleted_at = now(), updated_at = now(), version = (v_change->>'entityVersion')::bigint
        where id = (v_change->>'entityId')::uuid and user_id = v_user_id and deleted_at is null
          and version = (v_change->>'entityVersion')::bigint - 1
          and not is_fixed and not is_locked and lower(provenance) = 'lamp';
      elsif (v_change->>'entityVersion')::bigint = 1 then
        insert into public.schedule_blocks(
          id, user_id, plan_node_id, starts_at, ends_at, is_fixed, provenance, state,
          reason_factors, schedule_version, version, client_mutation_id, is_locked
        ) values (
          (v_change->>'entityId')::uuid, v_user_id, nullif(v_change->'payload'->>'planItemID', '')::uuid,
          (v_change->'payload'->>'start')::timestamptz, (v_change->'payload'->>'end')::timestamptz,
          v_change->'payload'->>'kind' = 'fixed', coalesce(v_change->'payload'->>'provenance', 'Lamp'),
          coalesce(v_change->'payload'->>'state', 'planned'),
          jsonb_build_array(coalesce(v_change->'payload'->>'reason', '')), 1, 1,
          (v_change->>'clientMutationId')::uuid,
          v_change->'payload'->>'kind' = 'fixed' or (v_change->'payload'->>'recurringRuleID') is not null
        ) on conflict (id) do nothing;
      else
        update public.schedule_blocks set
          plan_node_id = nullif(v_change->'payload'->>'planItemID', '')::uuid,
          starts_at = (v_change->'payload'->>'start')::timestamptz,
          ends_at = (v_change->'payload'->>'end')::timestamptz,
          state = coalesce(v_change->'payload'->>'state', 'planned'),
          reason_factors = jsonb_build_array(coalesce(v_change->'payload'->>'reason', '')),
          version = (v_change->>'entityVersion')::bigint, updated_at = now(), deleted_at = null,
          client_mutation_id = (v_change->>'clientMutationId')::uuid
        where id = (v_change->>'entityId')::uuid and user_id = v_user_id
          and version = (v_change->>'entityVersion')::bigint - 1
          and not is_fixed and not is_locked and lower(provenance) = 'lamp';
      end if;
    elsif v_change->>'entityType' = 'memory' then
      if v_change->>'operation' = 'delete' then
        update public.memories set deleted_at = now(), updated_at = now(), version = (v_change->>'entityVersion')::bigint
        where id = (v_change->>'entityId')::uuid and user_id = v_user_id and deleted_at is null
          and version = (v_change->>'entityVersion')::bigint - 1;
      elsif (v_change->>'entityVersion')::bigint = 1 then
        insert into public.memories(id, user_id, category, content, source, confidence, status, version, client_mutation_id)
        values (
          (v_change->>'entityId')::uuid, v_user_id, 'preference', v_change->'payload',
          coalesce(v_change->'payload'->>'source', 'user'),
          coalesce((v_change->'payload'->>'confidence')::numeric, 1),
          coalesce(v_change->'payload'->>'status', 'confirmed'), 1, (v_change->>'clientMutationId')::uuid
        ) on conflict (id) do nothing;
      else
        update public.memories set content = v_change->'payload', source = coalesce(v_change->'payload'->>'source', source),
          confidence = coalesce((v_change->'payload'->>'confidence')::numeric, confidence),
          status = coalesce(v_change->'payload'->>'status', status),
          version = (v_change->>'entityVersion')::bigint, updated_at = now(), deleted_at = null,
          client_mutation_id = (v_change->>'clientMutationId')::uuid
        where id = (v_change->>'entityId')::uuid and user_id = v_user_id
          and version = (v_change->>'entityVersion')::bigint - 1;
      end if;
    elsif v_change->>'entityType' = 'planning_rule' then
      if v_change->>'operation' = 'delete' then
        update public.planning_rules set deleted_at = now(), updated_at = now(), version = (v_change->>'entityVersion')::bigint
        where id = (v_change->>'entityId')::uuid and user_id = v_user_id and deleted_at is null
          and version = (v_change->>'entityVersion')::bigint - 1;
      elsif (v_change->>'entityVersion')::bigint = 1 then
        insert into public.planning_rules(id, user_id, payload, version, client_mutation_id)
        values ((v_change->>'entityId')::uuid, v_user_id, v_change->'payload', 1, (v_change->>'clientMutationId')::uuid)
        on conflict (id) do nothing;
      else
        update public.planning_rules set payload = v_change->'payload', version = (v_change->>'entityVersion')::bigint,
          client_mutation_id = (v_change->>'clientMutationId')::uuid, updated_at = now(), deleted_at = null
        where id = (v_change->>'entityId')::uuid and user_id = v_user_id
          and version = (v_change->>'entityVersion')::bigint - 1;
      end if;
    elsif v_change->>'entityType' = 'temporary_state' then
      if v_change->>'operation' = 'delete' then
        update public.temporary_states set deleted_at = now(), updated_at = now(), version = (v_change->>'entityVersion')::bigint
        where id = (v_change->>'entityId')::uuid and user_id = v_user_id and deleted_at is null
          and version = (v_change->>'entityVersion')::bigint - 1;
      elsif (v_change->>'entityVersion')::bigint = 1 then
        insert into public.temporary_states(id, user_id, payload, expires_at, version, client_mutation_id)
        values (
          (v_change->>'entityId')::uuid, v_user_id, v_change->'payload',
          (v_change->'payload'->>'expiresAt')::timestamptz, 1, (v_change->>'clientMutationId')::uuid
        ) on conflict (id) do nothing;
      else
        update public.temporary_states set payload = v_change->'payload',
          expires_at = (v_change->'payload'->>'expiresAt')::timestamptz,
          version = (v_change->>'entityVersion')::bigint, client_mutation_id = (v_change->>'clientMutationId')::uuid,
          updated_at = now(), deleted_at = null
        where id = (v_change->>'entityId')::uuid and user_id = v_user_id
          and version = (v_change->>'entityVersion')::bigint - 1;
      end if;
    elsif v_change->>'entityType' = 'recurring_rule' then
      if v_change->>'operation' = 'delete' then
        update public.recurring_schedule_rules set deleted_at = now(), updated_at = now(), version = (v_change->>'entityVersion')::bigint
        where id = (v_change->>'entityId')::uuid and user_id = v_user_id and deleted_at is null
          and version = (v_change->>'entityVersion')::bigint - 1;
      elsif (v_change->>'entityVersion')::bigint = 1 then
        insert into public.recurring_schedule_rules(id, user_id, payload, version, client_mutation_id)
        values ((v_change->>'entityId')::uuid, v_user_id, v_change->'payload', 1, (v_change->>'clientMutationId')::uuid)
        on conflict (id) do nothing;
      else
        update public.recurring_schedule_rules set payload = v_change->'payload', version = (v_change->>'entityVersion')::bigint,
          client_mutation_id = (v_change->>'clientMutationId')::uuid, updated_at = now(), deleted_at = null
        where id = (v_change->>'entityId')::uuid and user_id = v_user_id
          and version = (v_change->>'entityVersion')::bigint - 1;
      end if;
    elsif v_change->>'entityType' = 'occurrence_override' then
      if v_change->>'operation' = 'delete' then
        update public.schedule_occurrence_overrides set deleted_at = now(), updated_at = now(), version = (v_change->>'entityVersion')::bigint
        where id = (v_change->>'entityId')::uuid and user_id = v_user_id and deleted_at is null
          and version = (v_change->>'entityVersion')::bigint - 1;
      elsif (v_change->>'entityVersion')::bigint = 1 then
        insert into public.schedule_occurrence_overrides(
          id, user_id, recurring_rule_id, occurrence_date, payload, version, client_mutation_id
        ) values (
          (v_change->>'entityId')::uuid, v_user_id, (v_change->'payload'->>'recurringRuleID')::uuid,
          (v_change->'payload'->>'occurrenceDate')::timestamptz::date, v_change->'payload', 1,
          (v_change->>'clientMutationId')::uuid
        ) on conflict (id) do nothing;
      else
        update public.schedule_occurrence_overrides set payload = v_change->'payload',
          occurrence_date = (v_change->'payload'->>'occurrenceDate')::timestamptz::date,
          version = (v_change->>'entityVersion')::bigint, client_mutation_id = (v_change->>'clientMutationId')::uuid,
          updated_at = now(), deleted_at = null
        where id = (v_change->>'entityId')::uuid and user_id = v_user_id
          and version = (v_change->>'entityVersion')::bigint - 1;
      end if;
    end if;

    if not found then raise exception using errcode = '40001', message = 'stale_state'; end if;

    insert into public.sync_changes(
      user_id, entity_type, entity_id, entity_version, operation, payload, content_hash, client_mutation_id
    ) values (
      v_user_id, v_change->>'entityType', (v_change->>'entityId')::uuid,
      (v_change->>'entityVersion')::bigint, v_change->>'operation', v_change->'payload', v_change->>'contentHash',
      (v_change->>'clientMutationId')::uuid
    ) on conflict (user_id, client_mutation_id) do nothing
    returning cursor into v_max_cursor;
    if found then v_accepted := v_accepted + 1; end if;
  end loop;

  select coalesce(max(cursor), 0) into v_max_cursor from public.sync_changes where user_id = v_user_id;
  if v_accepted > 0 then
    update public.profiles
      set state_version = state_version + 1, updated_at = now()
      where id = v_user_id;
  end if;
  update public.sync_devices set last_cursor = v_max_cursor, last_seen_at = now()
    where device_id = p_device_id and user_id = v_user_id;
  return jsonb_build_object('accepted', v_accepted, 'cursor', v_max_cursor);
end;
$$;

revoke all on function public.confirm_agent_proposal(uuid, uuid, text, text, bigint, text) from public;
revoke all on function public.push_sync_batch(uuid, jsonb) from public;
grant execute on function public.confirm_agent_proposal(uuid, uuid, text, text, bigint, text) to service_role;
grant execute on function public.push_sync_batch(uuid, jsonb) to authenticated;
grant execute on function public.pull_sync_changes(bigint, integer) to authenticated;
