# Initial domain model

The native prototype and cloud schema share these concepts:

- `PlanItem`: flexible hierarchy node (goal/project/milestone/task/step), deadline, effort, importance, dependencies and scheduling constraints.
- `ScheduleBlock`: fixed/flexible time placement, provenance, state and explanation factors.
- `ExecutionRecord`: completion outcome, actual effort and feedback.
- `Memory`: inferred/proposed/confirmed user knowledge with source and confidence.
- `PlanningRule`: hard/soft user constraint.
- `TemporaryState`: expiring context such as fatigue or travel.
- `ReplanProposal`: immutable before/after diff awaiting approval.
- `AgentAction`: requested tool, validation/risk result, execution result and undo metadata.

IDs are UUIDs. Dates are instants; local day/time rules carry an IANA timezone. Writes are idempotent and schedule changes are versioned transactions.
