import { describe, expect, it } from "vitest";
import { MemoryEngine } from "../src/agent/memory/MemoryEngine.js";
import { MemoryPolicy } from "../src/agent/memory/MemoryPolicy.js";
import { FixedClock } from "../src/infrastructure/clock/FixedClock.js";
import {
  InMemoryMemoryCandidateRepository,
  InMemoryPreferenceMemoryRepository,
} from "../src/infrastructure/repositories/InMemoryMemoryRepositories.js";

const ids = [
  "00000000-0000-4000-8000-000000000201",
  "00000000-0000-4000-8000-000000000202",
  "00000000-0000-4000-8000-000000000203",
  "00000000-0000-4000-8000-000000000204",
  "00000000-0000-4000-8000-000000000205",
  "00000000-0000-4000-8000-000000000206",
];

function harness() {
  let index = 0;
  const candidates = new InMemoryMemoryCandidateRepository();
  const preferences = new InMemoryPreferenceMemoryRepository();
  const engine = new MemoryEngine(
    candidates,
    preferences,
    new MemoryPolicy(),
    new FixedClock("2026-09-08T08:00:00Z"),
    { next: () => ids[index++]! },
  );
  return { engine, candidates, preferences };
}

function evidence(referenceId = "message-1") {
  return [{
    sourceType: "user_message" as const,
    referenceId,
    observedAt: "2026-09-08T08:00:00Z",
    summary: "用户明确表示晚上学习效率更高",
  }];
}

function explicitPreference(value: "morning" | "afternoon" | "evening" = "evening") {
  return {
    preference: { key: "preferred_study_period" as const, value },
    confidence: 0.95,
    source: "user_explicit" as const,
    evidence: evidence(),
    reasonCodes: ["USER_STATED_PREFERENCE"],
  };
}

describe("MemoryEngine", () => {
  it("stores an explicit candidate without silently creating permanent memory", async () => {
    const { engine, preferences } = harness();
    const proposal = await engine.propose("user-1", explicitPreference());
    expect(proposal).toMatchObject({
      candidate: { status: "eligible", policyReasonCode: "EXPLICIT_PREFERENCE_ELIGIBLE" },
      policyDecision: { decision: "allow" },
    });
    await expect(preferences.listCurrent("user-1")).resolves.toEqual([]);
  });

  it("promotes an approved candidate with provenance and an immutable first version", async () => {
    const { engine } = harness();
    const { candidate } = await engine.propose("user-1", explicitPreference());
    const memory = await engine.approve({ userId: "user-1", candidateId: candidate.candidateId, approvedBy: "policy" });
    expect(memory).toMatchObject({
      version: 1,
      supersedesMemoryId: null,
      source: "user_explicit",
      explicitOrInferred: "explicit",
      sourceCandidateId: candidate.candidateId,
    });
    expect(memory.evidence).toHaveLength(1);
  });

  it("supersedes a preference while retaining append-only history", async () => {
    const { engine, preferences } = harness();
    const first = await engine.propose("user-1", explicitPreference("evening"));
    const firstMemory = await engine.approve({ userId: "user-1", candidateId: first.candidate.candidateId, approvedBy: "policy" });
    const second = await engine.propose("user-1", {
      ...explicitPreference("morning"),
      evidence: evidence("message-2"),
    });
    const secondMemory = await engine.approve({
      userId: "user-1",
      candidateId: second.candidate.candidateId,
      approvedBy: "policy",
      expectedVersion: 1,
    });
    expect(secondMemory).toMatchObject({ version: 2, supersedesMemoryId: firstMemory.memoryId });
    await expect(preferences.getCurrent("user-1", "preferred_study_period"))
      .resolves.toMatchObject({ memoryId: secondMemory.memoryId, preference: { value: "morning" } });
    await expect(preferences.listHistory("user-1", "preferred_study_period")).resolves.toHaveLength(2);
  });

  it("requires user confirmation for an inferred preference backed by distinct evidence", async () => {
    const { engine } = harness();
    const proposal = await engine.propose("user-1", {
      preference: { key: "preferred_focus_duration", value: 45 },
      confidence: 0.9,
      source: "user_inferred",
      evidence: [evidence("run-1")[0]!, evidence("run-2")[0]!],
      reasonCodes: ["REPEATED_FOCUS_PATTERN"],
    });
    expect(proposal.candidate.status).toBe("pending_confirmation");
    await expect(engine.approve({ userId: "user-1", candidateId: proposal.candidate.candidateId, approvedBy: "policy" }))
      .rejects.toMatchObject({ code: "POLICY_DENIED" });
    await expect(engine.approve({ userId: "user-1", candidateId: proposal.candidate.candidateId, approvedBy: "user" }))
      .resolves.toMatchObject({ explicitOrInferred: "inferred" });
  });

  it("rejects weak inferred evidence", async () => {
    const { engine } = harness();
    const proposal = await engine.propose("user-1", {
      preference: { key: "morning_study_preference", value: 0.8 },
      confidence: 0.6,
      source: "user_inferred",
      evidence: evidence(),
      reasonCodes: ["SINGLE_OBSERVATION"],
    });
    expect(proposal.candidate.status).toBe("rejected");
    await expect(engine.approve({ userId: "user-1", candidateId: proposal.candidate.candidateId, approvedBy: "user" }))
      .rejects.toMatchObject({ code: "POLICY_DENIED" });
  });

  it("does not expose candidates across user boundaries", async () => {
    const { engine } = harness();
    const { candidate } = await engine.propose("user-1", explicitPreference());
    await expect(engine.approve({ userId: "user-2", candidateId: candidate.candidateId, approvedBy: "user" }))
      .rejects.toMatchObject({ code: "AUTH_ERROR" });
  });

  it("returns the same promoted memory when approval is retried", async () => {
    const { engine } = harness();
    const { candidate } = await engine.propose("user-1", explicitPreference());
    const first = await engine.approve({ userId: "user-1", candidateId: candidate.candidateId, approvedBy: "policy" });
    const second = await engine.approve({ userId: "user-1", candidateId: candidate.candidateId, approvedBy: "policy" });
    expect(second.memoryId).toBe(first.memoryId);
  });
});
