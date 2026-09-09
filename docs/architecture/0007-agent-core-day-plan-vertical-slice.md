# ADR 0007: Agent Core day-plan vertical slice

## Status

Accepted for Phase 10's first vertical slice.

## Decision

Lamp's first iOS-to-Agent-Core workflow is limited to generating a plan for the
remainder of one local day from existing actionable tasks, occupied calendar
blocks, and planning preferences.

The iOS client sends the version 1 `plan-day` contract. Agent Core validates the
boundary, converts it to an immutable `StateSnapshot`, invokes the deterministic
`SchedulingEngine`, and returns one proposal. The response always says
`commitRequired: true`; the service has no commit endpoint and does not write to
Lamp storage.

The app keeps the proposal separate from its live timeline. Before explicit
confirmation it checks that every block belongs to a submitted task, remains
inside the requested day, and does not overlap current schedule data. On
confirmation it checks the source-state SHA-256 fingerprint again. A stale or
conflicting proposal is discarded and must be regenerated. A valid proposal is
merged by appending only its new focus blocks, preserving all existing and
recurring schedule records.

Production-shaped traffic uses an authenticated Supabase Edge Function as a
thin forwarding boundary. The Edge Function neither invokes a model nor edits
domain data. Simulator development may target the local Agent Core HTTP server
directly through `LAMP_AGENT_CORE_URL`.

## Consequences

- Fixed events remain protected by both Agent Core validation and client-side
  conflict checks.
- The planning result is deterministic and replayable from its versioned
  request; IDs derive from the request and candidate inputs.
- The old natural-language item-creation route remains isolated and unchanged.
- Dynamic replanning after incomplete work is intentionally deferred to the
  second vertical slice.
