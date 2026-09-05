grant usage on schema public to authenticated, service_role;
grant select on table public.agent_actions to authenticated;
grant select, insert, update on table public.agent_actions to service_role;
