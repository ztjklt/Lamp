# Lamp Harness production hardening status

## Status

- Phase 0–9 core: complete and baselined.
- Vertical slices: day planning, incomplete-task replanning, and language replanning complete.
- Production hardening: implemented locally on `codex/harness-production-hardening`;
  environment-backed verification is pending.
- Public production launch: not complete.

Supabase/Postgres is authoritative. SwiftData is the offline cache and outbox.
Agent Core runs on Cloud Run behind JWT-validating Supabase Edge Functions. Models
may produce validated proposals only; they never receive SQL, repository, service
role, or commit capabilities. Every task or schedule mutation requires explicit
user confirmation, and automatic commit is forbidden in staging and production.

The local implementation now includes durable proposal confirmation, repository
adapters, SwiftData/outbox migration, persistent item-by-item conflict resolution,
native Apple identity linking with transactional migration fallback, Edge-to-Core
authentication, Cloud Run packaging, OpenTelemetry/MetricKit instrumentation,
monitoring resources, OIDC deployment workflows, and release/sign-off runbooks.

External completion gates remain environment-owned: staging/production credentials,
signed deployment tags, Apple Developer/TestFlight access, physical-device checks,
and product/security/data-migration sign-off.

## Local verification snapshot

- Agent Core: 156 tests passed; the live DeepSeek integration test is opt-in and skipped by default.
- Deterministic Eval: 105/105 passed, including every hard-constraint and safety gate.
- Swift package: 30/30 passed.
- iOS UI regression: 23/23 passed on iPhone 17 Pro Simulator; the app build also passed.
- Supabase: 25 pgTAP assertions are checked in for schema, RLS, confirmation, rollback,
  expiration, idempotency, and protected-block behavior. Runtime execution remains an
  environment gate when a local Docker/Postgres service or staging project is available.
