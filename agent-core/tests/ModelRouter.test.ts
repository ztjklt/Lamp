import { describe, expect, it } from "vitest";
import { ModelRouter } from "../src/llm/ModelRouter.js";
import { makeStateSnapshot } from "./fixtures/StateFixture.js";

describe("ModelRouter", () => {
  it("keeps model choice server-side and escalates repeated failures", () => {
    const router = new ModelRouter("flash", "pro");
    const state = makeStateSnapshot();
    expect(router.route({ userInput: "安排今天", state, toolFailureCount: 0, repairAttempts: 0 }))
      .toMatchObject({ model: "flash", complexity: "NORMAL", thinking: { enabled: false } });
    expect(router.route({ userInput: "安排今天", state, toolFailureCount: 2, repairAttempts: 0 }))
      .toMatchObject({ model: "pro", complexity: "CRITICAL", thinking: { enabled: true, reasoningEffort: "max" } });
  });
});
