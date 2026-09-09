# ADR 0009: Agent Core language-to-Planner vertical slice

## Status

Accepted for Phase 10's third vertical slice.

## Decision

For a bounded request such as “今天有点累，高数少学一点。”, the iOS app sends
the original text, current tasks, today's schedule, planning preferences, and a
SHA-256 state fingerprint to `POST /v1/replan-language`.

Agent Core gives the language model only a redacted, structured summary of that
submitted state. The model may produce one strict workload decision: the intent,
the submitted task ID, a target number of minutes, local/day scope, temporary
fatigue state, reason codes, and confidence. It may not invent task IDs, call
tools, calculate schedule blocks, or commit domain state. Decisions that are
ungrounded, below confidence threshold, outside task limits, or not a genuine
reduction are rejected before planning.

The validated decision is converted into an immutable state snapshot and passed
to the existing deterministic Replanning Engine. The Planner alone performs time
math and conflict resolution. Only the named task is mutable; fixed events and
unrelated tasks remain occupied and protected. The response contains the model
decision, provider/model metadata, Planner diagnostics, and explicit plan changes
in one trace.

The endpoint is proposal-only. `commitRequired` is always true. The iOS client
validates ownership, bounds, conflicts, replacement IDs, the echoed request ID,
and the echoed fingerprint. It checks the fingerprint again on confirmation,
then replaces only blocks identified by the proposal and adds a one-day temporary
fatigue state. Dismissal leaves the schedule unchanged.

Within a running service instance, requests are keyed by authenticated user and
request ID. Identical retries return the cached result; reusing an ID with a
different payload is rejected. Durable cross-process idempotency remains deferred
until proposals move to production storage.

Development and automated tests use a deterministic local model provider, so the
model/Planner boundary is reproducible and does not consume provider traffic.
Production has no fallback: it requires `DEEPSEEK_API_KEY`. The authenticated
Supabase `replan-language` Edge Function only forwards the versioned contract and
cannot interpret language or mutate a plan.

## Consequences

- The model owns language understanding and target selection; the Planner owns
  schedule math, feasibility, and stability.
- The 60-minute high-math block can become a 30-minute proposal without moving
  English study or a fixed class.
- Users see the interpretation and computed changes before explicitly applying
  them.
- Invalid, stale, or conflicting proposals cannot overwrite newer local state.
- A real DeepSeek call is an opt-in integration test, not part of deterministic
  CI or simulator regression tests.
