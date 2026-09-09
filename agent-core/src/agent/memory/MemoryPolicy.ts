import type { PolicyDecision } from "../tools/ToolResult.js";
import type { MemoryCandidateInput, PreferenceMemory } from "./MemoryModels.js";

export class MemoryPolicy {
  evaluate(input: MemoryCandidateInput, current: PreferenceMemory | null): PolicyDecision {
    if (current && JSON.stringify(current.preference) === JSON.stringify(input.preference)) {
      return { decision: "deny", policyId: "memory_policy", reasonCode: "DUPLICATE_PREFERENCE" };
    }
    if (input.source === "user_explicit" && input.confidence >= 0.7) {
      return { decision: "allow", policyId: "memory_policy", reasonCode: "EXPLICIT_PREFERENCE_ELIGIBLE" };
    }
    const distinctEvidence = new Set(input.evidence.map((item) => `${item.sourceType}:${item.referenceId}`)).size;
    if (input.source === "user_inferred" && input.confidence >= 0.85 && distinctEvidence >= 2) {
      return { decision: "ask_user", policyId: "memory_policy", reasonCode: "INFERRED_PREFERENCE_REQUIRES_CONFIRMATION" };
    }
    if (input.source === "behavioral" && input.confidence >= 0.9 && distinctEvidence >= 3) {
      return { decision: "ask_user", policyId: "memory_policy", reasonCode: "BEHAVIORAL_PREFERENCE_REQUIRES_CONFIRMATION" };
    }
    return { decision: "deny", policyId: "memory_policy", reasonCode: "INSUFFICIENT_MEMORY_EVIDENCE" };
  }
}
