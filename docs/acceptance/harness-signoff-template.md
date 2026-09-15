# Harness production sign-off

- Release/tag:
- Staging environment:
- Database migration version:
- Cloud Run revision:
- Edge Function versions:

## Automated evidence

- Agent Core unit/integration:
- Offline eval (hard constraints and safety must be 100%):
- Supabase migration/RLS/RPC/concurrency:
- Swift core and simulator build:
- UI regression and sync scenarios:
- Replay result hashes:
- Secret/private-content scan:

## Manual vertical slices

Record intent, immutable state fingerprint, model metadata, policy result, candidate scores, Reason Codes, trace, replay hash, and failure recovery for:

1. Plan day.
2. Replan incomplete work.
3. Replan from natural language.

Also verify fixed-event protection, minimum-scope changes, prompt injection, authorization failure, unavailable model/database, retries, offline recovery, Apple upgrade, and cross-device conflicts.

## Required approvals

- Product:
- Security:
- Data migration:

All three approvals are required before internal TestFlight.
