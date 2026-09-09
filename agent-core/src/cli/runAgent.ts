import { createInterface } from "node:readline/promises";
import { stdin, stdout } from "node:process";
import { DebugApi } from "../debug/DebugApi.js";
import { LocalDebugHarness } from "../debug/LocalDebugHarness.js";

const input = await readInput(process.argv.slice(2));
const harness = new LocalDebugHarness();
const api = new DebugApi(
  { enabled: true, environment: "development" },
  harness,
  harness.runs,
  harness.snapshots,
  harness.audits,
);
const artifact = await api.runAgent("eval-user", {
  context: {
    userId: "eval-user",
    sessionId: "local-debug-session",
    requestId: `cli-${Date.now()}`,
    timezone: "Asia/Singapore",
    locale: "zh-CN",
    automationLevel: 0,
    authentication: {
      subject: "eval-user",
      scopes: ["state:read", "activity:read", "agent_runs:read"],
    },
  },
  input,
  horizonDays: 1,
});

const run = await api.getRun("eval-user", artifact.response.runId);
const proposal = artifact.response.proposal;
const candidates = proposal && Array.isArray(proposal["candidates"]) ? proposal["candidates"]
  : proposal?.["candidate"] === undefined ? [] : [proposal["candidate"]];
writeSection("Intent", run.intent ?? "unknown");
writeSection("State Snapshot", artifact.trace.state ?? {});
writeSection("Model", artifact.trace.events.filter((event) => event.type === "LLMCall"));
writeSection("Tools", artifact.trace.events.filter((event) => event.type === "ToolSelected" || event.type === "ToolExecuted"));
writeSection("Candidate Plans", candidates);
writeSection("Selected Plan", candidates[0] ?? null);
writeSection("Policy Decision", artifact.trace.events.filter((event) => event.type === "PolicyChecked"));
writeSection("Final Result", artifact.response);
writeSection("Trace", artifact.trace);
writeSection("Replay Bundle", artifact.replayBundle);

async function readInput(argumentsList: string[]): Promise<string> {
  const argumentInput = argumentsList.join(" ").trim();
  if (argumentInput.length > 0) return argumentInput;
  const terminal = createInterface({ input: stdin, output: stdout });
  try {
    return (await terminal.question("> ")).trim();
  } finally {
    terminal.close();
  }
}

function writeSection(name: string, value: unknown): void {
  stdout.write(`\n${name}\n${typeof value === "string" ? value : JSON.stringify(value, null, 2)}\n`);
}
