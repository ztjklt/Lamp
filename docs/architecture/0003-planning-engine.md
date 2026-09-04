# ADR 0003 — Planning Engine v1

Date: 2026-09-04

## Options considered

1. Weighted heuristic: fast and explainable, but needs an explicit feasibility layer.
2. Constraint/optimization solver: excellent hard-constraint guarantees, but adds integration and explanation complexity for v1.
3. Hybrid: deterministic feasibility and candidate generation followed by an explainable score.

## Decision

Use the **hybrid** approach.

1. Normalize the horizon into candidate slots.
2. Remove fixed events, protected time, buffers and dependency-invalid candidates.
3. Split tasks only within declared min/max session constraints.
4. Rank placements with a deterministic score: deadline pressure, goal importance, energy fit, lateness, continuity and schedule-churn cost.
5. Preserve free capacity and enforce a workload ceiling derived from temporary state.
6. Return structured explanation factors with each placement.

This design is deterministic, incremental and unit-testable. If v1 fixtures reveal cases that heuristic search cannot solve reliably, the feasibility stage can be replaced with a constraint solver without changing the UI or tool layer.

## Required fixture set

The test target covers fixed classes, deadline infeasibility, partial completion, a new conflicting event, fatigue, protected time, early completion, late-night failure preference, dependency ordering and stability ties.

