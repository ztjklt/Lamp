import { z } from "zod";

export const AgentContextSchema = z.object({
  userId: z.string().min(1),
  sessionId: z.string().min(1),
  requestId: z.string().min(1),
  timezone: z.string().min(1).max(80),
  locale: z.string().min(1).max(40),
  automationLevel: z.union([z.literal(0), z.literal(1), z.literal(2)]),
  authentication: z.object({
    subject: z.string().min(1),
    scopes: z.array(z.string().min(1)).max(100),
  }).strict(),
}).strict().refine(
  (context) => context.userId === context.authentication.subject,
  { path: ["authentication", "subject"], message: "authenticated subject must match userId" },
);

export type AgentContext = z.infer<typeof AgentContextSchema>;
