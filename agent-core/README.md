# Lamp Agent Core

Independent TypeScript implementation of the Lamp Agent Harness.

The current foundation includes validated schemas, configuration, structured
errors and logging, agent-run records, the LLM gateway/provider boundary, a
Temporal-based clock/timezone boundary, repository contracts, and immutable
state snapshots. The tool layer provides a strict registry, input/output
validation, permission and risk policies, hashed audit records, and read-only
tools. The deterministic scheduling layer generates multiple candidates,
enforces hard constraints (including daily workload), and scores only valid
plans with centralized weights. It does not call an LLM, connect to the iOS app,
or mutate Lamp domain data. The Phase 5 orchestrator now connects structured
intent/decision output, immutable state, model routing, validated tool calls,
planning policy, candidate generation, and persisted run checkpoints through a
finite loop. Model/tool/planning/repair counts and overall duration are bounded;
limit violations safe-abort with structured errors.

Phase 6 adds immutable domain events, idempotent in-process delivery, event
trigger policy, affected-scope and dependency resolution, deterministic scope
expansion, schedule-change cost, and append-only proposed plan revisions. Both
event-triggered and natural-language replanning use the same stability engine;
unaffected blocks remain occupied and protected, and no revision is committed
to the user's live schedule.

Phase 7 adds run/session-scoped Working Memory with expiration, structured
Preference Memory with immutable versions and provenance, and policy-gated
Memory Candidates. Model-facing tools can search approved preferences or
submit candidates, but cannot silently create permanent memory. Explicit
preferences are eligible for a separate approval step; inferred and behavioral
preferences require user confirmation and can be superseded by newer evidence.
Retrieval uses a small structured/keyword/time interface without vector storage
or a RAG dependency.

Phase 8 adds a 105-case offline evaluation dataset covering intent,
constraints, deadlines, replanning, stability, safety, and tool selection.
Deterministic graders enforce hard rules, while production planning,
replanning, schemas, and policies run behind deterministic mock model outputs.
The checked-in baseline and regression thresholds are enforced by `npm run
eval`; subjective LLM grading remains an optional manual/nightly boundary.

Phase 9 completes the initial core with an offline debug harness. `npm run
agent -- "安排复习高数"` runs the real orchestrator, policies, tools, and planner
against a deterministic local fixture and prints Intent, state summary, model
metadata, tools, candidate scores, policy decisions, final output, a redacted
trace, and a replay bundle. `npm run replay -- /absolute/path/bundle.json`
replays captured normalized model outputs and fails when the final result hash
drifts. The protocol-independent Debug API exposes run/trace lookup and
planning simulate/validate methods with ownership checks. Debug endpoints are
off by default and cannot be enabled in production; traces never contain raw
prompts, tool arguments/results, or model chain-of-thought.

Phase 10 starts with one deliberately narrow iOS vertical slice: a versioned
`POST /v1/plan-day` API accepts current tasks, occupied calendar blocks, and
planning preferences, then returns a deterministic plan proposal. It never
commits or mutates Lamp data. The client validates task ownership, time bounds,
overlaps, and an echoed state fingerprint before it exposes a separate confirm
action. A Supabase Edge Function can authenticate the app and forward the same
contract to a deployed Agent Core service.

The second Phase 10 vertical slice adds `POST /v1/replan-incomplete`. The app
records the missed occurrence, sends a versioned `TASK_INCOMPLETE` event and an
immutable schedule snapshot, and receives a local-scope proposal from the same
Event Bus → Replanning Policy → Scheduling Engine → Stability path used by the
core. Fixed and unrelated blocks stay outside the mutable scope. Reusing the
same event and payload returns the same response; reusing its ID with different
state is rejected. Every response still requires explicit client confirmation.

The third Phase 10 vertical slice adds `POST /v1/replan-language`. A normalized
LLM call maps a bounded natural-language request and an immutable state summary
to a validated workload decision such as “reduce this submitted task to 30
minutes.” The model cannot calculate or commit schedule blocks. The existing
deterministic replanning engine performs time math, protects fixed and unrelated
blocks, and returns a versioned proposal with both the model decision and Planner
changes in its trace. Development and automated tests use the deterministic
local provider; production requires `DEEPSEEK_API_KEY`.

```bash
npm install
npm run typecheck
npm test
npm run build
npm run eval
npm run agent -- "安排复习高数"
npm run replay -- /absolute/path/to/replay-bundle.json
npm run api
```

For Simulator development, set the app process environment variable
`LAMP_AGENT_CORE_URL=http://127.0.0.1:8790/v1/plan-day` and run `npm run api`.
Set `LAMP_AGENT_CORE_REPLAN_URL=http://127.0.0.1:8790/v1/replan-incomplete` for
the incomplete-task flow, and set
`LAMP_AGENT_CORE_LANGUAGE_URL=http://127.0.0.1:8790/v1/replan-language` for the
language-to-Planner flow.
Without the override, the app calls the authenticated Supabase `plan-day`
function; configure that function with `AGENT_CORE_URL` and
`AGENT_CORE_SERVICE_TOKEN`, and configure the service with the matching
`LAMP_AGENT_API_TOKEN`.

Copy `.env.example` to `.env` only for local service work. Never commit provider
keys.
