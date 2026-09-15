# Lamp Agent Evals

`baseline-v1.json` is the Phase 8 regression baseline for the 105-case offline
dataset. Run it with:

```bash
npm run eval
```

The dataset contains 15 cases each for intent, constraints, deadlines,
replanning, schedule stability, safety policy, and tool selection. Intent and
tool outputs come from a deterministic mock-provider boundary. Planning,
replanning, schema validation, and policy decisions execute the production
core without network calls or a live DeepSeek key.

Hard constraints, deadlines, tool selection, and safety are graded only by
code. The optional `LLMGrader` interface is reserved for manual or nightly
checks of response naturalness, explanation quality, and preference alignment.
It is not part of the required regression gate.
