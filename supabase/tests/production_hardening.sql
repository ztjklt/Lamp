begin;
select plan(25);

insert into auth.users (instance_id, id, aud, role, email, encrypted_password, created_at, updated_at)
values
  ('00000000-0000-0000-0000-000000000000', '10000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'rls-a@example.invalid', '', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '10000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'rls-b@example.invalid', '', now(), now());
insert into public.profiles(id) values
  ('10000000-0000-4000-8000-000000000001'),
  ('10000000-0000-4000-8000-000000000002');
insert into public.plan_nodes(id, user_id, kind, title, estimated_minutes, remaining_minutes)
values
  ('20000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001', 'task', 'A task', 30, 30),
  ('20000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000002', 'task', 'B task', 30, 30);

select has_table('public', 'agent_runs', 'agent_runs exists');
select has_table('public', 'state_snapshots', 'state_snapshots exists');
select has_table('public', 'plan_revisions', 'plan_revisions exists');
select has_table('public', 'working_memory', 'working_memory exists');
select has_function('public', 'confirm_agent_proposal', array['uuid','uuid','text','text','bigint','text'], 'atomic confirm RPC exists');
select has_function('public', 'push_sync_batch', array['uuid','jsonb'], 'sync push RPC exists');
select has_function('public', 'pull_sync_changes', array['bigint','integer'], 'sync pull RPC exists');

set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
select results_eq(
  $$ select count(*)::bigint from public.plan_nodes $$,
  $$ values (1::bigint) $$,
  'user A reads only user A rows'
);
select throws_ok(
  $$ insert into public.plan_nodes(user_id, kind, title, estimated_minutes, remaining_minutes) values ('10000000-0000-4000-8000-000000000002', 'task', 'cross-user write', 10, 10) $$,
  '42501', null, 'user A cannot insert rows for user B'
);
select is_empty(
  $$ update public.plan_nodes set title = 'cross-user update' where id = '20000000-0000-4000-8000-000000000002' returning id $$,
  'user A cannot update user B rows'
);

select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
select results_eq(
  $$ select count(*)::bigint from public.plan_nodes $$,
  $$ values (1::bigint) $$,
  'user B reads only user B rows'
);

set local role service_role;
select set_config('request.jwt.claim.sub', '', true);

insert into public.replan_proposals(
  id, user_id, reason, kind, request_id, request_hash, preview_hash,
  source_fingerprint, expected_state_version, confirmation_token_hash, diff, expires_at
) values (
  '30000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001',
  'plan_day', 'plan_day', 'request-a', repeat('a', 64), repeat('b', 64), repeat('c', 64),
  0, repeat('d', 64), '{"operations":[]}'::jsonb, now() + interval '15 minutes'
);

select results_eq(
  $$ select count(*)::bigint from public.agent_actions where user_id = '10000000-0000-4000-8000-000000000001' $$,
  $$ values (0::bigint) $$,
  'proposal creation never writes mutation audit before confirmation'
);
select throws_ok(
  $$ select public.confirm_agent_proposal(
    '10000000-0000-4000-8000-000000000002', '30000000-0000-4000-8000-000000000001',
    repeat('b', 64), repeat('d', 64), 0, 'cross-user-confirm'
  ) $$,
  'P0002', null, 'another user cannot confirm the proposal'
);
select throws_ok(
  $$ select public.confirm_agent_proposal(
    '10000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000001',
    repeat('e', 64), repeat('d', 64), 0, 'tampered-preview'
  ) $$,
  '28000', null, 'tampered preview hash is rejected'
);
select throws_ok(
  $$ select public.confirm_agent_proposal(
    '10000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000001',
    repeat('b', 64), repeat('d', 64), 1, 'stale-version'
  ) $$,
  '40001', null, 'stale expected version is rejected'
);
select results_eq(
  $$ select public.confirm_agent_proposal(
    '10000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000001',
    repeat('b', 64), repeat('d', 64), 0, 'confirm-once'
  ) $$,
  $$ values (jsonb_build_object(
    'proposalId', '30000000-0000-4000-8000-000000000001'::uuid,
    'stateVersion', 1::bigint, 'status', 'applied'
  )) $$,
  'valid confirmation applies atomically'
);
select results_eq(
  $$ select state_version from public.profiles where id = '10000000-0000-4000-8000-000000000001' $$,
  $$ values (1::bigint) $$,
  'confirmation increments the authoritative state version once'
);
select results_eq(
  $$ select status from public.replan_proposals where id = '30000000-0000-4000-8000-000000000001' $$,
  $$ values ('applied'::text) $$,
  'proposal is marked applied only after the transaction succeeds'
);
select results_eq(
  $$ select public.confirm_agent_proposal(
    '10000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000001',
    repeat('b', 64), repeat('d', 64), 0, 'confirm-once'
  ) $$,
  $$ values (jsonb_build_object(
    'proposalId', '30000000-0000-4000-8000-000000000001'::uuid,
    'stateVersion', 1::bigint
  )) $$,
  'an idempotent confirmation retry returns the original result'
);
select throws_ok(
  $$ select public.confirm_agent_proposal(
    '10000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000001',
    repeat('e', 64), repeat('d', 64), 0, 'confirm-once'
  ) $$,
  '23505', null, 'an idempotency key cannot be reused with different content'
);

insert into public.replan_proposals(
  id, user_id, reason, kind, request_id, request_hash, preview_hash,
  source_fingerprint, expected_state_version, confirmation_token_hash, diff, expires_at
) values (
  '30000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000001',
  'plan_day', 'plan_day', 'request-expired', repeat('1', 64), repeat('2', 64), repeat('3', 64),
  1, repeat('4', 64), '{"operations":[]}'::jsonb, now() - interval '1 minute'
);
select throws_ok(
  $$ select public.confirm_agent_proposal(
    '10000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000002',
    repeat('2', 64), repeat('4', 64), 1, 'expired-confirm'
  ) $$,
  'P0001', null, 'expired confirmation is rejected'
);
select results_eq(
  $$ select state_version from public.profiles where id = '10000000-0000-4000-8000-000000000001' $$,
  $$ values (1::bigint) $$,
  'expired confirmation does not change state'
);

insert into public.schedule_blocks(
  id, user_id, plan_node_id, starts_at, ends_at, is_fixed, is_locked, provenance, schedule_version
) values (
  '40000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001',
  '20000000-0000-4000-8000-000000000001', now() + interval '1 hour', now() + interval '2 hours',
  true, true, 'external-calendar', 1
);
insert into public.replan_proposals(
  id, user_id, reason, kind, request_id, request_hash, preview_hash,
  source_fingerprint, expected_state_version, confirmation_token_hash, diff, expires_at
) values (
  '30000000-0000-4000-8000-000000000003', '10000000-0000-4000-8000-000000000001',
  'plan_day', 'plan_day', 'request-fixed', repeat('5', 64), repeat('6', 64), repeat('7', 64),
  1, repeat('8', 64),
  '{"operations":[{"type":"remove_schedule_block","id":"40000000-0000-4000-8000-000000000001"}]}'::jsonb,
  now() + interval '15 minutes'
);
select throws_ok(
  $$ select public.confirm_agent_proposal(
    '10000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000003',
    repeat('6', 64), repeat('8', 64), 1, 'fixed-confirm'
  ) $$,
  '42501', null, 'fixed external schedule blocks are protected'
);
select results_eq(
  $$ select count(*)::bigint from public.schedule_blocks
     where id = '40000000-0000-4000-8000-000000000001' and deleted_at is null $$,
  $$ values (1::bigint) $$,
  'failed fixed-block mutation leaves the block intact'
);
select results_eq(
  $$ select state_version from public.profiles where id = '10000000-0000-4000-8000-000000000001' $$,
  $$ values (1::bigint) $$,
  'failed fixed-block mutation rolls back the version increment'
);

select * from finish();
rollback;
