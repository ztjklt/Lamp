# Lamp — Master Project Plan for Codex

**Document type:** PRD + System Architecture Brief + Implementation Roadmap  
**Project:** Lamp  
**Primary platform:** iPhone / iOS  
**Status:** Product definition v1.0  
**Primary AI model family:** DeepSeek (exact model selected through configuration / research gate)  
**Core philosophy:** *Lamp should reduce the cost of knowing what to do next.*

---

## 0. Instructions to Codex

This document is the product source of truth for the first major implementation of Lamp. Do **not** begin by writing the entire app in one pass.

Before implementation, complete the following research gates and produce short written decisions inside the repository:

1. **iOS deployment target research** — choose the minimum iOS version after verifying which required capabilities are available: SwiftUI, ActivityKit / Live Activities, WidgetKit, App Intents, notifications, speech capture/transcription, calendar integration, photo import, HealthKit, and any system-level entry points.
2. **Backend architecture research** — compare at least: a BaaS-led option, a custom backend option, and a hybrid option. Evaluate authentication, PostgreSQL/relational data needs, object storage, background jobs, notifications, AI orchestration, audit logs, and future cross-device support. Choose one and document why.
3. **Planning Engine research** — compare at least: heuristic/scoring scheduling, constraint/optimization scheduling, and a hybrid approach. Select the first production-worthy design based on explainability, determinism, replanning speed, testability, and ability to respect hard constraints.
4. **DeepSeek integration research** — verify the current official API, supported tool/function calling behavior, structured outputs, model options, latency/cost tradeoffs, error modes, retries, timeouts, and schema constraints. The model name must be configurable, never hard-coded throughout the app.
5. **Locked-screen partial-completion voice flow research** — verify on a physical iPhone what can be triggered directly from Live Activities, including authentication requirements and whether an `AudioRecordingIntent` path can provide the desired low-friction voice feedback. If system restrictions prevent the ideal flow, implement the closest native fallback: one tap from the Live Activity into a minimal recording sheet/screen.

Only after these gates should Codex freeze the initial architecture and start feature implementation.

**Engineering rule:** DeepSeek must never have direct database access. The LLM can only request actions through typed Lamp tools. Every write passes through validation/policy logic, risk classification, and an auditable execution layer.

---

# 1. Product Definition

## 1.1 One-sentence definition

**Lamp is a personal planning agent that understands a user's goals, constraints, habits, state, and real-world schedule; continuously decides what the user should do next; converts that reasoning into an executable schedule; and presents the result through the lowest-friction iPhone surfaces possible.**

Lamp is **not** primarily a chat app, a to-do list, or a calendar. Conversation is one input channel. Calendar/task interfaces are one output channel. The product itself is the continuously updated planning system between them.

## 1.2 Core product promise

A user should be able to say something naturally such as:

> “I want to learn AI, finance, stock investing, and calculus, but I don’t know how to fit everything in.”

Lamp should progressively transform that into:

- understood goals and constraints,
- a realistic roadmap,
- dynamically prioritized projects/tasks,
- a weekly plan,
- a concrete Today timeline,
- a single clear “Now” action,
- reminders and Live Activity guidance,
- execution feedback,
- automatic replanning proposals when reality changes.

The user should spend as little time as possible *managing the planner itself*.

## 1.3 Product principles

1. **Complexity belongs to Lamp, not the user.** Users should not need to understand project-management taxonomy.
2. **The default output is action, not prose.** When the user says something actionable, the result should appear in the app's plan, not remain as a chat response.
3. **Minimize information-transfer cost.** Voice, screenshots, text, photos, manual editing, and system data should all be accepted when useful.
4. **Minimize information-retrieval cost.** The user should often know what to do without opening the app, using notifications, Live Activities, Dynamic Island, widgets/shortcuts where feasible.
5. **Suggest, do not silently control.** Lamp may make strong recommendations, but important tradeoffs and broad replans require user awareness/confirmation.
6. **Be proactive but not annoying.** Lamp acts like a competent personal assistant, not an electronic disciplinarian.
7. **Plans are dynamic.** Priorities, schedules, roadmaps, workload, and even user models can change as new evidence arrives.
8. **The schedule must be explainable.** Important changes must include a concise reason. Ordinary decisions can expose a “Why?” view on demand.
9. **User memory is inspectable and correctable.** Lamp may learn, but the user owns the model of themselves.
10. **Deterministic scheduling should not be delegated entirely to an LLM.** LLM reasoning and scheduling logic are separate systems.

---

# 2. Target Experience

## 2.1 First launch / onboarding

Lamp cannot plan from nothing. The first-run experience should establish a minimum viable life framework without turning onboarding into a questionnaire marathon.

Suggested sequence:

1. Create/sign into a Lamp account.
2. Ask the user what broad context they are in (student / working / other). This should affect onboarding examples, not constrain product capability.
3. Obtain hard schedule information with the lowest-cost input:
   - student: upload a screenshot/photo of the timetable or manually add/import it;
   - worker: provide work hours or calendar access;
   - anyone: optionally connect system calendar.
4. Ask only a few high-value questions required for initial planning, e.g. typical wake/sleep ranges, major near-term deadlines, and current priorities.
5. Generate the first usable Today/Week plan quickly.
6. Explain that Lamp learns through future interaction and that all learned information is reviewable under “What Lamp knows about me.”

Do not require users to fully configure habits, goals, productivity style, energy profile, etc. up front. Learn progressively.

## 2.2 Main home experience: NOW + TODAY

The primary screen should be structurally simple.

### NOW
The top region answers exactly one question:

**“What should I do right now?”**

Example:

- Calculus review
- 14:00–15:30
- 42 minutes remaining
- short context: “Exam in 8 days” (only if useful)

Primary state actions should be easy to reach.

### TODAY
Below Now is the day timeline. It should display fixed events, Lamp-planned tasks, breaks/free time, and upcoming obligations without making the user manage calendar mechanics.

The Today timeline should support direct drag/editing. Manual edits are behavioral signals that Lamp can learn from.

## 2.3 Time horizons

Lamp should expose three natural planning horizons:

- **Today** — what happens today.
- **Week** — how the current week fits together.
- **Roadmap** — where longer goals are headed.

Avoid over-emphasizing a traditional month calendar unless later user research shows a strong need.

## 2.4 Global “Tell Lamp” entry point

The app should not force users into a conventional chat tab. The dominant cross-app action is **Tell Lamp**.

Preferred modes:

- tap-to-type,
- tap/hold-to-speak,
- image/screenshot import,
- system-level shortcuts/App Intents where supported,
- Action Button / Shortcut exposure when feasible.

Long-form chat history may exist, but it is secondary to the action-centric experience.

---

# 3. Input System

Lamp should accept multiple information channels and normalize all of them into the same agent understanding pipeline.

## 3.1 Voice

Voice is a first-class input method for day-to-day interactions because it minimizes friction.

Requirements:

- fast start,
- reliable Mandarin support, while architecture remains multilingual,
- streaming or near-streaming transcription if feasible,
- editable transcript before high-risk operations,
- robust interpretation of colloquial time expressions,
- separate ASR/transcription layer from DeepSeek reasoning layer,
- voice model/provider must be replaceable through an abstraction rather than embedded directly into business logic.

Examples:

- “Tomorrow at three I’m meeting Wang to discuss Lamp for about two hours.”
- “I’m exhausted today. Don’t make tonight too heavy.”
- “I finished the first half of Tool Calling but didn’t do the exercise.”

## 3.2 Screenshot / image ingestion

Users should be able to submit a screenshot or photo such as a school timetable.

Pipeline:

`Image → OCR/vision parsing → candidate structured events → confidence evaluation → validation → write/import`

Interaction policy:

- High confidence: import automatically and show a lightweight undo banner.
- Ambiguous: ask only the missing/uncertain detail.
- Large imports such as a semester timetable should offer an overview before destructive replacement of existing data.

## 3.3 Text

Free-form text uses the same intent pipeline as voice.

## 3.4 Manual UI entry/edit

Users can still add/edit/move schedule blocks manually. Lamp must treat edits as meaningful behavioral data rather than out-of-band changes.

Example learning signal:

If a user repeatedly drags calculus from late evening into the afternoon, Lamp may later suggest:

> “You often move calculus to the afternoon. Should I prefer afternoons for high-effort math?”

Only after confirmation should this become a durable planning rule/memory.

## 3.5 System sources

Where permission is granted, Lamp may use:

- Apple Calendar / EventKit,
- HealthKit data (long-term core capability; MVP subset is acceptable),
- notifications/status from Lamp itself,
- future supported system surfaces via App Intents.

External data should always have clear permission and provenance.

---

# 4. Agent Behavior Model

## 4.1 Autonomy level

Lamp is **suggestion-autonomous**, not fully autonomous.

It may:

- infer low-risk intent,
- create ordinary tasks when confidence is high,
- re-evaluate priorities,
- detect schedule failures,
- generate revised plans,
- make proactive suggestions,
- learn patterns and propose new planning rules.

It should not silently perform high-impact changes such as deleting goals, broadly changing planning rules, or rewriting a large future schedule without explicit user awareness/confirmation.

## 4.2 Clarification policy

Use **intelligent clarification**:

- if the current context is sufficient, act;
- if uncertainty materially changes the plan, ask;
- never ask merely because a field is technically missing when it can be safely inferred;
- expose undo for confident low-risk operations.

## 4.3 Proactivity

Lamp should behave like a private assistant.

Good proactive interventions:

- a high-priority goal is falling materially behind;
- a user unexpectedly gains a useful free block;
- the week's load is becoming unrealistic;
- the user repeatedly fails a certain type/time of task;
- a deadline makes the current plan infeasible;
- a temporary state such as fatigue requires a lighter plan.

Bad proactive behavior:

- repeated nagging,
- guilt language,
- excessive notifications,
- turning every free moment into work.

## 4.4 Temporary states

Lamp should understand temporary states that alter planning strategy, such as:

- fatigue,
- illness,
- travel,
- exam week,
- project crunch,
- unusually busy day.

If a user says “I’m exhausted today,” Lamp may propose a lighter schedule and explain what changes. It should not silently rewrite the week.

## 4.5 User-facing explanations

- Ordinary schedule decisions: minimal by default; “Why?” available.
- Material changes: concise proactive explanation.
- Never expose raw hidden chain-of-thought. Explanations should use explicit product-level factors: deadline, fixed schedule, user preference, available time, completion history, energy match, etc.

---

# 5. Personal Memory and User Model

## 5.1 “What Lamp knows about me”

This is a first-class user-facing area.

Lamp may maintain durable knowledge such as:

- fixed schedule patterns,
- goals and current commitments,
- preferred work times,
- disliked time windows,
- typical task duration bias,
- sleep/wake tendencies if shared,
- recurring obligations,
- planning rules,
- communication preference/personality preference,
- user-provided medication reminder instructions (not medical decision-making),
- learned rhythm patterns.

Every durable memory must be:

- viewable,
- editable,
- deletable,
- attributable to a source where practical (user said / inferred / confirmed pattern),
- confidence-scored or status-tagged internally.

## 5.2 Learning from behavior

Lamp should learn from:

- completion / partial / failure,
- start delay,
- early completion,
- manual schedule moves,
- repeated duration overruns,
- repeated avoidance of certain time windows,
- accepted/rejected planning suggestions.

Learning must not instantly convert every observation into a permanent rule. Patterns should accumulate evidence and then become a suggestion for user confirmation when the change is consequential.

## 5.3 Personal Rhythm Model

The scheduling system should maintain a profile of when different kinds of work are likely to succeed.

Example dimensions:

- cognitive intensity,
- preferred time-of-day,
- typical session length,
- fatigue sensitivity,
- task/category completion probability,
- user-stated preferences.

This model is an input to Planning Engine, not a medical or psychological diagnosis.

---

# 6. Planning Model

## 6.1 Dynamic structure

Lamp must not force every user concept into a fixed hierarchy.

The agent may represent simple things as a single Task, while complex goals may become a deeper structure such as:

`Goal → Project → Milestone → Task → Step`

The hierarchy exists internally. The user interface should only expose complexity when useful.

## 6.2 Dynamic roadmap

Long-term plans are not frozen documents.

Lamp may update a roadmap when:

- the user advances faster/slower than expected,
- prerequisite gaps appear,
- the user changes the desired outcome,
- a new deadline appears,
- a part is already mastered,
- real execution data invalidates prior estimates.

Major roadmap changes require explanation and confirmation where appropriate.

## 6.3 Task classification

The Agent should infer the nature of each item, while allowing correction.

Internal categories may include:

- hard obligation,
- fixed event,
- deadline task,
- flexible task,
- long-term goal work,
- habit/routine,
- interest/backlog,
- rest/free time,
- reminder-only obligation.

Do not reduce everything to a single priority number.

## 6.4 Planning constraints

At minimum, the scheduling system should be able to reason over:

- fixed events/hard constraints,
- deadlines,
- estimated duration,
- minimum/maximum session duration,
- task splittability,
- dependency/prerequisite relationships,
- user importance/preference,
- goal-level importance,
- lateness/backlog pressure,
- personal rhythm/energy fit,
- allowed working windows,
- non-negotiable rest / protected time,
- transition/buffer time,
- completion history,
- task category,
- temporary user state,
- schedule stability (avoid unnecessary churn).

## 6.5 Dynamic priority

Priority should evolve over time rather than remain a static high/medium/low label.

The engine should be able to justify priority using factors such as urgency, importance, remaining effort, schedule feasibility, lateness, dependencies, and user context.

The exact mathematical design is a Codex research decision, but the resulting behavior must be deterministic enough to test and explain.

## 6.6 Free time / leave blank space

Lamp should **not optimize for 100% utilization**.

Free time and recovery are valid planned outcomes. The amount of scheduled work should adapt to:

- deadline pressure,
- recent workload,
- completion rate,
- temporary state,
- explicit rules,
- time of day,
- user preference.

## 6.7 Deadline failure / sprint mode

When the current plan becomes infeasible, Lamp should not merely warn.

It should generate a revised “sprint” plan by lowering or postponing less important work, then show the user the proposal and consequences for confirmation.

Example:

> “At the current pace, calculus cannot be covered before the exam. I propose pausing stock-study blocks this week and moving 3.5 hours to calculus. This keeps the Lamp milestone unchanged but delays AI reading by 4 days.”

## 6.8 Replanning protocol

Events that can trigger replanning include:

- user reports new conflict,
- partial completion,
- missed task,
- early completion,
- fixed event added,
- deadline change,
- temporary state,
- task duration estimate updated,
- major priority change.

For meaningful plan changes:

1. compute candidate revised schedule,
2. summarize material changes,
3. explain key reasons,
4. request confirmation,
5. apply atomically,
6. keep an audit/undo path.

## 6.9 Early completion

If a task finishes earlier than scheduled, Lamp should evaluate what to do with the newly available block based on context. It may recommend:

- rest,
- advancing another task,
- pulling forward an upcoming deadline,
- leaving time blank.

Do not automatically fill every gap.

---

# 7. Planning Engine Architecture

The Planning Engine is a first-class subsystem separate from the LLM.

## 7.1 Responsibilities

Planning Engine owns:

- hard constraint enforcement,
- candidate time-slot generation,
- dynamic scheduling,
- conflict detection,
- workload balancing,
- session splitting/merging where allowed,
- schedule stability/churn cost,
- feasibility checking,
- replanning calculations,
- structured explanation factors.

DeepSeek can propose semantic priorities and task structure, but should not be the final authority over exact time placement.

## 7.2 Research requirement

Codex must compare:

- heuristic/weighted scoring,
- constraint programming / optimization,
- hybrid model.

Evaluation criteria:

- deterministic behavior,
- performance for 1 day / 1 week / 1 month horizons,
- explainability,
- incremental replanning speed,
- support for soft constraints,
- handling of task splitting,
- schedule stability,
- ease of unit testing,
- implementation complexity.

## 7.3 Required test scenarios

The engine must have deterministic fixtures covering at least:

1. hard classes + two flexible study goals;
2. deadline approaching and insufficient remaining capacity;
3. partial completion and remaining-duration update;
4. new fixed event invalidates afternoon plan;
5. user fatigue lowers workload;
6. protected time cannot be violated;
7. early completion produces free capacity;
8. repeated late-night failures lower late-night placement score;
9. task dependency prevents child work before prerequisite;
10. equal-priority tasks where schedule stability should prevent unnecessary reshuffling.

---

# 8. DeepSeek Agent Architecture

## 8.1 Role of DeepSeek

DeepSeek is responsible for language/semantic intelligence, including:

- intent understanding,
- extracting dates/times/constraints from natural language,
- deciding whether clarification is required,
- goal decomposition,
- roadmap generation/revision,
- semantic task classification,
- suggesting priority/importance inputs,
- interpreting partial-completion feedback,
- writing concise user-facing explanations,
- proposing memories/rules to store,
- selecting and invoking typed Lamp tools.

## 8.2 DeepSeek must not

- directly write to the database,
- silently bypass scheduling constraints,
- independently invent a medical regimen,
- expose raw chain-of-thought,
- delete or broadly alter high-impact information without passing validation/confirmation policy.

## 8.3 Tool Calling

Create a typed Lamp Tool layer. Candidate tools include:

- `get_user_context`
- `get_today_schedule`
- `get_week_schedule`
- `get_roadmap`
- `create_item`
- `update_item`
- `pause_item`
- `delete_item`
- `import_fixed_events`
- `request_replan`
- `preview_replan`
- `apply_replan`
- `record_completion`
- `record_partial_completion`
- `record_noncompletion`
- `create_memory_candidate`
- `confirm_memory`
- `update_planning_rule`
- `get_planning_explanation`
- `create_reminder_instruction`

Tool schemas must be strict, versioned, validated, and unit-tested.

## 8.4 Agent execution pipeline

Recommended logical flow:

`User Input`
→ `Transcription/OCR if needed`
→ `Context Retrieval`
→ `DeepSeek Intent + Tool Selection`
→ `Schema Validation`
→ `Policy/Risk Validation`
→ `Planning Engine / Domain Service`
→ `Execution`
→ `Result / Undo Token`
→ `UI Update`
→ `Concise Agent Response`

## 8.5 Risk classes

Define at least three action levels:

### Low risk
Examples: create an ordinary flexible task, mark a task done, read schedule.

May execute automatically if confidence is high. Show undo where useful.

### Medium risk
Examples: move several tasks, modify a remembered preference, pause a goal.

Usually show preview/confirmation when the effect is meaningful.

### High risk
Examples: delete a goal/large data set, overwrite imported schedule, broad multi-week replan, change durable protected-time rule, destructive account/data actions.

Must require explicit confirmation.

## 8.6 Validation layer

Before execution, validate semantic/action consistency.

Example:

User: “Don’t schedule stock study this week.”

Invalid tool request: `delete_goal(stock_study)`

Expected resolution: block the destructive call and translate into a temporary pause or clarification.

---

# 9. Execution Feedback Loop

## 9.1 Live Activity task controls

For an active/planned task, target a compact interaction model:

- **✓** = fully completed
- **×** = not completed
- **○** = partially completed / needs explanation

The exact visual symbols can change after usability testing, but the semantic model should remain.

## 9.2 Partial completion flow

Ideal flow:

1. user taps ○ in Live Activity / task surface,
2. low-friction voice input starts or opens immediately,
3. user says what happened,
4. transcription is interpreted by DeepSeek,
5. Lamp updates progress/remaining effort,
6. Planning Engine generates a revised schedule if needed,
7. meaningful changes are shown for confirmation.

The locked-screen recording implementation must be validated against current iOS restrictions on physical hardware. If direct recording cannot reliably start from the locked surface, fallback to a one-tap minimal Lamp recording UI.

## 9.3 Start/missed behavior

Default reminder behavior:

- 5 minutes before task: pre-reminder,
- at task time: primary notification / active state,
- if the user does not start/respond: one appropriate follow-up after a reasonable interval,
- do not repeatedly nag.

The exact follow-up interval can vary by task type/importance.

## 9.4 Completion outcomes

Support at least:

- completed,
- partial,
- not completed,
- skipped/cancelled if explicitly requested.

Partial completion must update remaining estimated work rather than simply count as failure.

---

# 10. Notification and Presence System

## 10.1 Default reminder strategy

Normal tasks:

- default pre-alert: **5 minutes**,
- at-time alert,
- one adaptive follow-up if no response.

## 10.2 Smart reminder intensity

Reminder behavior can vary according to:

- task criticality,
- deadline pressure,
- obligation vs flexible goal,
- user preference,
- whether the user is in a temporary state,
- past response behavior.

A medication reminder explicitly created from user-provided instructions should be treated as a time-sensitive obligation, but Lamp must not infer/change medication dosage, frequency, contraindications, or medical decisions.

## 10.3 Morning Brief

Every morning provide a concise optional brief, ideally through an appropriate surface:

- fixed events count/context,
- 1–3 important focus items,
- expected self-directed workload,
- major warning if the day is unrealistic.

Do not force the user to press “start day.”

## 10.4 Evening Review

Provide a concise review:

- what was completed,
- what was partial/missed,
- important schedule consequences,
- whether tomorrow has been adjusted/proposed.

## 10.5 Weekly Review

Weekly Review should combine analytics and learning:

- completion trends,
- estimate accuracy,
- successful/unsuccessful time windows,
- workload balance,
- goal progress,
- proposed new user-model rules.

Example:

> “Your high-effort tasks complete more reliably in the afternoon. Prefer afternoons for calculus/programming?”

User confirmation turns the suggestion into durable knowledge.

---

# 11. iOS System Integration

## 11.1 Live Activities / Dynamic Island

Use ActivityKit + WidgetKit to provide glanceable active-task guidance and interactive controls where supported.

Must support appropriate layouts for:

- Lock Screen,
- Dynamic Island compact/minimal/expanded states,
- device configurations without Dynamic Island through Lock Screen Live Activity.

Keep the experience glanceable; do not overload it with entire schedules.

## 11.2 App Intents / Shortcuts

Expose useful Lamp actions to the system, potentially including:

- Tell Lamp,
- What should I do now?,
- Mark current task complete,
- Partial completion,
- Add a quick obligation,
- Open Today,
- Start/continue current task.

Use App Intents so supported actions can integrate with Shortcuts, Siri/system surfaces, widgets, and Action Button where available.

## 11.3 Notifications

Implement robust local/remote notification scheduling as needed by the chosen architecture. Replanning must update stale reminders atomically.

## 11.4 Calendar

Support user-authorized calendar reading/import. Define provenance so Lamp knows which events originated externally and should not be silently modified.

## 11.5 HealthKit

Health data is a **long-term core capability**, but first implementation may be narrow.

Potential inputs include sleep and activity. Health data may influence planning effort/state but must not be used to make medical diagnoses.

## 11.6 Apple Watch

**Out of scope for first version.** Do not spend first-version engineering effort on a Watch app.

---

# 12. Product UI / Visual Language

## 12.1 Style

Visual direction:

**Apple-native minimalism + warm companionship.**

Avoid stereotypical AI aesthetics such as neon gradients, glowing sci-fi dashboards, or excessive “AI thinking” animation.

The app should feel calm, native, refined, and useful.

## 12.2 Lamp identity

Lamp is represented by an **abstract light**, not a mascot.

This “light” can subtly indicate states such as:

- listening,
- understanding,
- planning,
- ready,
- gentle attention.

It should remain understated.

## 12.3 Personality

Default language style:

- concise,
- calm,
- human,
- slightly warm,
- non-judgmental,
- not overly encouraging or verbose.

Lamp should adapt its communication style over time based on user preferences and observed interaction, while remaining safe and clear.

## 12.4 Navigation

Avoid a conventional five-tab productivity-app feel.

Primary experience should revolve around:

- Now/Today home,
- Week,
- Roadmap,
- Tell Lamp,
- lightweight access to user model/settings.

Exact navigation is a design implementation decision, but “Tell Lamp” should be globally accessible and traditional tabs should be visually de-emphasized.

---

# 13. Data Model — Conceptual

Codex should refine this after architecture selection. Initial domain entities likely include:

## Account/User
- user id
- profile metadata
- locale/timezone
- communication preferences

## Memory
- memory id
- type/category
- content / structured value
- source
- confidence
- status: inferred / proposed / confirmed
- created/updated timestamps

## PlanningRule
- rule id
- rule type
- scope
- hard/soft constraint
- source
- active status

## Goal/PlanNode
Use a flexible hierarchical model rather than separate rigid tables if that simplifies dynamic depth.

Fields may include:
- node id
- parent id
- node type (goal/project/milestone/task/step/etc.)
- title/description
- status
- importance
- deadline
- estimated effort
- remaining effort
- splittability
- dependencies
- constraints

## ScheduleBlock
- block id
- linked plan node/event
- start/end
- fixed vs flexible
- source/provenance
- status
- version/replan id

## ExecutionRecord
- planned block
- actual start/end if known
- outcome: complete/partial/not complete/etc.
- user feedback
- estimated vs actual duration

## TemporaryState
- state type
- start/end/expiry
- impact hints
- source/confidence

## ReplanProposal
- proposal id
- reason
- before/after summary
- affected blocks/nodes
- status: pending/applied/rejected/expired
- explanation factors

## AgentAction/AuditLog
- triggering input
- model/tool/version
- requested tool call
- validation result
- execution result
- undo metadata

## ReminderInstruction
- schedule/trigger semantics
- linked obligation
- notification policy
- user-supplied instruction provenance

---

# 14. Account, Sync, and Backend Requirements

Lamp should use its **own account system** rather than being permanently local-only.

Requirements:

- secure authentication,
- cloud persistence,
- future cross-device readiness,
- server-side secret handling for DeepSeek and other providers,
- user data export/delete pathway,
- auditability for Agent writes,
- background job capability for reviews/replanning/reminder updates,
- push notification support if required,
- provider abstraction for AI/transcription.

Backend technology is not preselected. Codex must research and document the choice.

---

# 15. Privacy, Safety, and Trust

## 15.1 Secrets

Never ship DeepSeek API keys or private service credentials in the iOS binary. AI requests requiring private credentials should go through a secure backend or equivalent secret-holding architecture.

## 15.2 User control

Users must be able to:

- see/edit/delete learned memories,
- undo recent automatic low-risk actions,
- approve important replans,
- revoke data-source permissions,
- delete account/data.

## 15.3 Medication/health boundary

Lamp may store and remind the user of **instructions the user explicitly provides**, for example “take this after dinner every day.”

Lamp must not independently:

- prescribe medication,
- change dose/frequency,
- advise stopping medication,
- infer drug interactions as a scheduling decision,
- replace professional medical advice.

## 15.4 Data minimization

Collect only what improves the planning experience. Health, calendar, microphone, photos, and notification permissions should be contextual and optional rather than demanded on first launch.

---

# 16. Core User Journeys

## Journey A — “I want to learn AI”

1. User tells Lamp by voice.
2. Lamp checks existing context.
3. If goal is underspecified enough to materially alter the plan, Lamp asks one targeted question; otherwise it generates an initial interpretation.
4. DeepSeek creates/revises roadmap nodes.
5. Planning Engine calculates feasible weekly allocation.
6. Lamp presents a concise proposal.
7. User approves.
8. Today/Week/Roadmap update.
9. Execution feedback gradually updates roadmap and personal rhythm model.

## Journey B — Timetable screenshot

1. User imports timetable screenshot.
2. OCR/vision extracts class names/times/days.
3. Confidence system detects ambiguous cells.
4. High-confidence schedule is imported; uncertain cells are requested specifically.
5. Fixed classes become hard constraints.
6. Planning Engine recalculates flexible work.
7. User gets a concise “imported + changed” summary and undo.

## Journey C — “I’m exhausted today”

1. User says they are tired.
2. Lamp interprets a temporary state, not a permanent trait.
3. Agent asks clarification only if necessary.
4. Planning Engine creates lighter candidate schedule.
5. Lamp summarizes which items move and why.
6. User applies/modifies/keeps original.

## Journey D — Partial completion from task

1. Task Live Activity is active.
2. User taps ○.
3. User provides short voice feedback.
4. DeepSeek extracts completed portion + remaining work.
5. ExecutionRecord and task remaining effort update.
6. Planning Engine determines schedule consequences.
7. Meaningful replan is proposed for approval.

## Journey E — Deadline is becoming impossible

1. Lamp detects remaining effort > feasible capacity before deadline.
2. Agent/Planning Engine generates a sprint replan.
3. Lower-value goals are reduced/postponed.
4. Lamp explains the tradeoff.
5. User confirms.
6. Schedule and reminders update atomically.

## Journey F — Lamp learns a pattern

1. User repeatedly moves difficult study away from late evening.
2. Analytics detect meaningful pattern.
3. Weekly Review proposes a preference rule.
4. User accepts.
5. “What Lamp knows about me” updates.
6. Future schedules prefer the new pattern.

---

# 17. Technical Quality Requirements

## 17.1 Testing

At minimum:

- unit tests for Planning Engine,
- schema/tool validation tests,
- risk-policy tests,
- date/time/timezone tests,
- schedule atomicity tests,
- notification rescheduling tests,
- intent parsing fixtures,
- UI tests for core Now/Today interactions,
- Live Activity interaction tests where possible,
- physical-device validation checklist for Lock Screen and microphone behavior.

## 17.2 Observability

Track technical events needed to debug planning, without exposing private content unnecessarily:

- planning job id/version,
- input context references,
- tool calls,
- validation failures,
- schedule diff summary,
- model/provider latency/error,
- notification scheduling failures.

## 17.3 Offline/degraded behavior

The app should not become useless when AI/backend is temporarily unavailable.

At minimum, users should still be able to:

- see existing Today/Week schedule,
- mark tasks complete/partial/noncomplete locally if architecture permits,
- receive already scheduled local notifications,
- queue interactions for retry where safe.

## 17.4 Time and timezone correctness

Time is the product. Treat timezone, daylight-saving changes, travel, calendar locale, recurring events, and date parsing as critical correctness areas.

---

# 18. Implementation Roadmap

The first version aims to be a **complete usable product**, not a throwaway demo. However, implementation must still be phased so the architecture is testable.

## Phase 0 — Research and architecture freeze

Deliverables:

- deployment-target decision,
- backend selection ADR,
- Planning Engine ADR/prototype benchmark,
- DeepSeek/provider integration ADR,
- locked-screen partial-voice feasibility note,
- repository structure,
- threat/secrets note,
- initial domain model.

**Do not proceed to broad feature build until these are written.**

## Phase 1 — Domain core and scheduling foundation

Build:

- domain entities,
- persistence/backend skeleton,
- account/authentication skeleton,
- Planning Engine v1,
- fixed/flexible schedule model,
- Today/Week schedule APIs,
- replan proposal/diff model,
- deterministic test fixtures.

Acceptance test: given a synthetic user week, the system can produce, explain, modify, and replan a valid schedule without any LLM.

## Phase 2 — DeepSeek Agent + Tool Layer

Build:

- provider abstraction,
- DeepSeek adapter,
- context retrieval,
- typed tool schemas,
- validation/risk layer,
- audit logs,
- natural-language task/event creation,
- roadmap generation,
- clarification policy,
- replan request/preview/apply workflow.

Acceptance test: natural language can safely become structured product actions without direct model-to-database writes.

## Phase 3 — iOS core experience

Build native SwiftUI app:

- authentication,
- onboarding,
- Now + Today,
- Week,
- Roadmap,
- global Tell Lamp entry,
- text interaction,
- direct timeline edits,
- “What Lamp knows about me,”
- planning-rule management,
- replan confirmation UI.

Acceptance test: app is usable end-to-end without Live Activity polish.

## Phase 4 — Voice + image ingestion

Build:

- microphone capture/transcription abstraction,
- transcript review when needed,
- voice-to-agent flow,
- photo/screenshot import,
- timetable parsing,
- confidence/undo workflow.

Acceptance test: a student can set up a weekly class schedule largely from a screenshot and then add a new event by voice.

## Phase 5 — Notification + Live Activity system

Build:

- 5-minute default reminder,
- at-time reminder,
- adaptive second reminder,
- active-task Live Activity,
- ✓ / ○ / × controls,
- partial completion path,
- App Intents/Shortcuts integration,
- physical-device validation.

Acceptance test: user can follow a planned task from lock screen, report outcome, and trigger a replan proposal.

## Phase 6 — Learning and reviews

Build:

- execution analytics,
- personal rhythm signals,
- inferred-memory candidates,
- Morning Brief,
- Evening Review,
- Weekly Review,
- rule-learning suggestions,
- communication-style preference adaptation.

Acceptance test: after a simulated multi-week dataset, Lamp produces sensible, user-confirmable planning insights.

## Phase 7 — Health and polish

Build a carefully scoped HealthKit input path if supported by the architecture decision, then focus on:

- animations and abstract Lamp light identity,
- accessibility,
- offline/degraded handling,
- privacy controls,
- error recovery,
- app performance,
- beta telemetry and debug tooling.

Apple Watch remains out of scope.

---

# 19. Definition of Done for First Major Version

The first major version is not considered complete merely because it can chat and create tasks.

It should demonstrate all of the following:

1. A new user can establish a real weekly schedule with low friction.
2. User can tell Lamp a vague goal and receive an actionable, editable roadmap/schedule.
3. DeepSeek uses controlled tools rather than direct persistence writes.
4. Planning Engine respects hard constraints and dynamically reprioritizes flexible work.
5. Today home clearly communicates Now + Today.
6. Week and Roadmap provide broader context.
7. User can provide voice and image information.
8. High-confidence low-risk changes execute with undo; ambiguity prompts only when necessary.
9. Significant replans are previewed/explained and require confirmation.
10. Live Activity provides active-task guidance and completion controls, with the closest reliable native partial-voice flow available on the target iOS version.
11. Default task reminders begin 5 minutes before the task and adapt intelligently without nagging.
12. Completed/partial/missed tasks affect future planning.
13. Morning Brief, Evening Review, and Weekly Review exist.
14. Lamp can learn patterns and propose changes to the user model.
15. User can see/edit/delete durable memories and planning rules.
16. Account/cloud persistence works and private API secrets are not embedded in the app.
17. The app remains calm, native, and understandable rather than feeling like a generic AI chatbot.

---

# 20. Non-goals / Out of Scope for First Version

- Apple Watch app.
- Multi-user/social planning or agent-to-agent scheduling.
- Enterprise/team project management.
- Full medical assistant functionality.
- Fully autonomous high-impact decision making.
- A traditional feature-heavy calendar clone.
- Gamification as a core mechanic.
- Exposing model chain-of-thought.

---

# 21. Current Official-Platform Notes for Codex Research

These notes reflect capabilities verified against official documentation at the time this plan was written; Codex should re-check them before implementation because platform APIs evolve.

- Apple ActivityKit/Live Activities are designed to expose ongoing, glanceable activity state on iPhone surfaces including Lock Screen and Dynamic Island. Interactive Live Activities can use App Intents / `LiveActivityIntent`-style actions.
- Apple provides `AudioRecordingIntent` for intents that start/stop/modify audio recording state, with platform-specific Live Activity requirements. The exact locked-device UX must be validated on the chosen deployment target and physical hardware.
- Apple's Speech framework supports recognition of live or prerecorded audio and currently exposes newer transcription/analyzer APIs in addition to legacy speech recognition interfaces.
- App Intents can expose app actions/data to system experiences such as Shortcuts, Siri/system surfaces, widgets, controls, and supported hardware shortcuts.
- DeepSeek's official API documentation currently describes tool/function calling and a strict schema mode in supported configurations. Exact model/tool behavior should be verified and isolated behind an adapter.

Reference URLs for research:

- https://developer.apple.com/documentation/activitykit
- https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities
- https://developer.apple.com/documentation/appintents
- https://developer.apple.com/documentation/appintents/audiorecordingintent
- https://developer.apple.com/documentation/speech
- https://api-docs.deepseek.com/guides/tool_calls/

---

# 22. Final Product North Star

When Lamp is working correctly, the user should feel:

> “I don't need to hold my whole life plan in my head. I tell Lamp what is happening and what I want. Lamp keeps the structure, tells me what matters now, and adjusts the plan when real life changes.”

The product wins when the user spends **less time organizing tasks, less time deciding what to do next, and less time opening the app just to retrieve information** — while still retaining control over important decisions.
