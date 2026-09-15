import { z } from "zod";
import { defineTool, type RegisteredAgentTool } from "../../agent/tools/AgentTool.js";
import { UTCInstantSchema } from "../../agent/state/StateModels.js";
import {
  MemoryCandidateInputSchema,
  MemoryCandidateSchema,
  PREFERENCE_KEYS,
  PreferenceMemorySchema,
} from "../../agent/memory/MemoryModels.js";
import type { MemoryEngine } from "../../agent/memory/MemoryEngine.js";

export function createMemoryTools(memory: MemoryEngine): RegisteredAgentTool[] {
  return [
    defineTool({
      name: "search_memory",
      version: 1,
      description: "Search approved current preference memories using structured keys, keywords, and UTC time filters.",
      inputSchema: z.object({
        keys: z.array(z.enum(PREFERENCE_KEYS)).max(20).optional(),
        keywords: z.array(z.string().trim().min(1).max(100)).max(20).optional(),
        createdAfter: UTCInstantSchema.optional(),
        createdBefore: UTCInstantSchema.optional(),
        limit: z.number().int().min(1).max(100).default(20),
      }).strict(),
      outputSchema: z.object({ memories: z.array(PreferenceMemorySchema) }).strict(),
      riskLevel: "READ_ONLY",
      requiredScopes: ["memory:read"],
      execute: async (input, context) => ({
        memories: await memory.retrieve({ userId: context.agent.userId, ...input }),
      }),
    }),
    defineTool({
      name: "write_memory_candidate",
      version: 1,
      description: "Submit a structured preference-memory candidate for policy review; never writes permanent memory.",
      inputSchema: MemoryCandidateInputSchema,
      outputSchema: z.object({
        candidate: MemoryCandidateSchema,
        policyDecision: z.object({
          decision: z.enum(["allow", "ask_user", "deny"]),
          policyId: z.string().min(1),
          reasonCode: z.string().min(1),
        }).strict(),
      }).strict(),
      riskLevel: "LOW_MUTATION",
      requiredScopes: ["memory:propose"],
      execute: async (input, context) => memory.propose(context.agent.userId, input),
    }),
    defineTool({
      name: "update_preference",
      version: 1,
      description: "Promote an eligible preference candidate after external confirmation and version checks.",
      inputSchema: z.object({
        candidateId: z.uuid(),
        expectedVersion: z.number().int().min(0).optional(),
      }).strict(),
      outputSchema: z.object({ memory: PreferenceMemorySchema }).strict(),
      riskLevel: "MEDIUM_MUTATION",
      requiredScopes: ["memory:write"],
      execute: async (input, context) => ({
        memory: await memory.approve({
          userId: context.agent.userId,
          candidateId: input.candidateId,
          approvedBy: "policy",
          ...(input.expectedVersion === undefined ? {} : { expectedVersion: input.expectedVersion }),
        }),
      }),
    }),
  ];
}
