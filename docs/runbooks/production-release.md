# Production release runbook

1. Confirm all CI jobs pass and the release commit has no secrets or private content.
2. Apply additive Supabase migrations to staging; run RLS, RPC, idempotency, concurrency, and replay tests.
3. Build the Agent Core image and deploy a new Cloud Run revision in the Supabase region (default `asia-southeast1`).
4. Deploy the `proposals` and `account` Edge Functions with rotated secrets.
5. Run all three vertical slices through CLI and public Debug API; retain Trace/Replay hashes and the sign-off report.
6. Promote only a cryptographically signed `prod-v*` tag that passed every gate.
7. Roll out TestFlight flags in order: read-only sync, bidirectional sync, proposal/reject, explicit confirm, wider internal cohort.

Rollback uses the previous Cloud Run revision, previous Edge Function bundle, and feature flags. Database migrations remain forward-compatible and are never destructively rolled back.

Stop rollout immediately on silent data loss, cross-user access, safety-eval failure, elevated 5xx/model errors, p95 regression, or cost anomaly.
