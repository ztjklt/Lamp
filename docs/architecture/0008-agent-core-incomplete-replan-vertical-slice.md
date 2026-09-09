# ADR 0008: Agent Core incomplete-task replanning vertical slice

## Status

Accepted for Phase 10's second vertical slice.

## Decision

When a user marks a focus block as unfinished, Lamp first records that fact as
`missed`. It then sends a version 1 `TASK_INCOMPLETE` event, the affected task,
the missed block, a bounded four-day schedule snapshot, preferences, and a
SHA-256 state fingerprint to `POST /v1/replan-incomplete`.

Agent Core validates the request and publishes the event through its Event Bus.
The Replanning Policy starts with a four-hour local scope. Conflict resolution
makes only affected focus blocks mutable; fixed, recurring, completed, and
unrelated blocks remain occupied or protected. The Scheduling Engine generates
candidates, constraints reject unsafe placements, and Plan Stability describes
the selected candidate as explicit `ADD`, `MOVE`, `RESIZE`, `REMOVE`, or
`UNCHANGED` changes with reason codes. A missed block can never be preserved in
its already elapsed position.

The endpoint is proposal-only. `commitRequired` is always true and the server
has no schedule commit operation. The iOS client validates ownership, bounds,
overlaps, replacement IDs, the echoed event ID, and the echoed fingerprint. On
explicit confirmation it checks the fingerprint again, removes only mutable
blocks named by non-unchanged changes, appends the proposed focus blocks, and
retains the original missed occurrence as history. Dismissing the proposal
keeps the missed record but leaves all later schedule blocks unchanged.

The running service keys completed requests by authenticated user and event ID.
An identical retry returns the cached proposal; the same event ID with a
different payload returns HTTP 409. The event ID, proposal revision, change
records, diagnostics, and reason codes form the explainable trace. The
versioned request is sufficient to reproduce the deterministic planning path;
durable cross-process idempotency is deferred until Agent Core revisions move
from the in-memory repository to production storage.

Production traffic passes through the authenticated Supabase
`replan-incomplete` Edge Function, which only verifies the user and forwards the
contract with the user's ID. It does not call an LLM and cannot commit a plan.

## Consequences

- The 19:45 “高数未完成” scenario can move or split only the high-math work;
  the 20:10 English block and fixed events remain unchanged.
- Recording reality is immediate and undoable; changing future time remains a
  separate, explicit confirmation.
- Stale proposals are discarded instead of overwriting newer local state.
- The same event is not executed twice inside a running service instance.
