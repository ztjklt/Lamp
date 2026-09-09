import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { stdout } from "node:process";
import { LocalDebugHarness } from "../debug/LocalDebugHarness.js";
import { ReplayBundleSchema } from "../debug/Replay.js";

const path = process.argv[2];
if (!path) throw new Error("Usage: npm run replay -- /absolute/path/to/replay-bundle.json");
const bundle = ReplayBundleSchema.parse(JSON.parse(await readFile(resolve(path), "utf8")));
const result = await new LocalDebugHarness().replay(bundle);
stdout.write(`${JSON.stringify(result, null, 2)}\n`);
if (!result.matched) process.exitCode = 1;
