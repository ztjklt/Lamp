import type { AgentContext } from "../orchestrator/AgentContext.js";
import type { StateSnapshot } from "../state/StateSnapshot.js";
import type { LLMMessage } from "../../llm/LLMRequest.js";
import { ContextBudget } from "./ContextBudget.js";
import { ContextSelector } from "./ContextSelector.js";
import { LampError } from "../../errors/LampError.js";
import type { PreferenceMemory, WorkingMemoryEntry } from "../memory/MemoryModels.js";

const SYSTEM_PROMPT = `You are Lamp's planning controller. Return only a JSON object matching one allowed AgentAction.
Never invent task IDs or tool names. Use tools only to inspect the immutable snapshot. For schedule requests,
return generate_plan and let the deterministic planner do all time mathematics. Never claim a mutation was committed.
All planning instants must be UTC Z values inside the supplied snapshot horizon. Allowed action types are respond,
ask_user, and generate_plan. Include a validated intent and a concise structured decision.`;

export class ContextBuilder {
  constructor(
    private readonly budget = new ContextBudget(),
    private readonly selector = new ContextSelector(),
  ) {}

  build(
    userInput: string,
    agent: AgentContext,
    state: Readonly<StateSnapshot>,
    relevantMemories: readonly PreferenceMemory[] = [],
    workingMemory: readonly WorkingMemoryEntry[] = [],
  ): LLMMessage[] {
    const selected = this.selector.select(state);
    const stateSummary = JSON.stringify({
      snapshotId: state.snapshotId,
      sourceRevision: state.sourceRevision,
      now: state.now,
      timezone: state.timezone,
      planningHorizon: state.planningHorizon,
      preferences: state.preferences,
      energy: state.energy,
      tasks: selected.tasks,
      schedule: selected.schedule,
      events: selected.events,
      lockedConstraints: state.lockedConstraints,
    });
    const policySummary = JSON.stringify({
      authenticatedUserId: agent.userId,
      automationLevel: agent.automationLevel,
      rules: [
        "all tool calls pass registry, schema, permission, risk, and audit checks",
        "planning produces proposals only",
        "locked and fixed events are immutable",
        "ask the user when required information is ambiguous",
        "memory candidates are not permanent preferences until separately approved",
      ],
    });
    const memorySummary = JSON.stringify({
      relevantPreferences: relevantMemories.map((memory) => ({
        preference: memory.preference,
        version: memory.version,
        confidence: memory.confidence,
        explicitOrInferred: memory.explicitOrInferred,
        updatedAt: memory.updatedAt,
      })),
      workingMemory: workingMemory.map((entry) => ({
        key: entry.key,
        value: entry.value,
        expiresAt: entry.expiresAt,
      })),
    });
    const fixedUsage = SYSTEM_PROMPT.length + policySummary.length + userInput.length + 64;
    const contextAllowance = Math.max(
      1_000,
      Math.min(Math.floor(this.budget.maximumCharacters * 0.6), this.budget.maximumCharacters - fixedUsage),
    );
    const currentContext = `STATE\n${stateSummary}\nMEMORY\n${memorySummary}`;
    return [
      { role: "system", content: SYSTEM_PROMPT },
      { role: "system", content: `POLICY_SUMMARY\n${policySummary}` },
      { role: "system", content: `CURRENT_CONTEXT\n${this.budget.clip(currentContext, contextAllowance)}` },
      { role: "user", content: userInput },
    ];
  }

  clipObservation(value: unknown): string {
    return this.budget.clip(JSON.stringify(value), Math.min(1_500, Math.floor(this.budget.maximumCharacters / 16)));
  }

  compactMessages(messages: readonly LLMMessage[]): LLMMessage[] {
    if (messageSize(messages) <= this.budget.maximumCharacters) return structuredClone([...messages]);
    const base = structuredClone(messages.slice(0, 4));
    const groups: LLMMessage[][] = [];
    for (const message of messages.slice(4)) {
      if (message.role === "assistant" || groups.length === 0) groups.push([structuredClone(message)]);
      else groups.at(-1)?.push(structuredClone(message));
    }
    let used = messageSize(base);
    const retained: LLMMessage[][] = [];
    for (let index = groups.length - 1; index >= 0; index -= 1) {
      const group = groups[index];
      if (group === undefined) continue;
      const size = messageSize(group);
      if (used + size <= this.budget.maximumCharacters) {
        retained.unshift(group);
        used += size;
      } else if (retained.length === 0) {
        const shrunk = shrinkGroup(group, Math.max(0, this.budget.maximumCharacters - used));
        if (used + messageSize(shrunk) > this.budget.maximumCharacters) {
          throw new LampError({
            code: "VALIDATION_ERROR",
            message: "Newest tool exchange exceeds the context budget even after content truncation",
            safeMessage: "工具上下文超过本次运行的安全预算。",
          });
        }
        retained.unshift(shrunk);
        used += messageSize(shrunk);
      }
    }
    if (retained.length < groups.length) {
      const marker: LLMMessage = { role: "system", content: "EARLIER_WORKING_CONTEXT_OMITTED_BY_BUDGET" };
      if (used + messageSize([marker]) <= this.budget.maximumCharacters) retained.unshift([marker]);
    }
    return [...base, ...retained.flat()];
  }
}

function messageSize(messages: readonly LLMMessage[]): number {
  return 2 + Math.max(0, messages.length - 1) +
    messages.reduce((sum, message) => sum + JSON.stringify(message).length, 0);
}

function shrinkGroup(group: readonly LLMMessage[], maximumCharacters: number): LLMMessage[] {
  const cloned = structuredClone([...group]);
  const stringMessages = cloned.filter((message) => typeof message.content === "string");
  const overhead = messageSize(cloned.map((message) => ({ ...message, content: message.content === null ? null : "" })));
  const suffix = "\n[TRUNCATED_BY_BUDGET]";
  const allocation = Math.max(0, Math.floor((maximumCharacters - overhead) / Math.max(1, stringMessages.length)));
  for (const message of stringMessages) {
    message.content = allocation <= suffix.length
      ? ""
      : `${message.content?.slice(0, allocation - suffix.length) ?? ""}${suffix}`;
  }
  return cloned;
}
