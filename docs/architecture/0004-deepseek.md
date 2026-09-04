# ADR 0004 — DeepSeek provider and tool boundary

Date: 2026-09-04

## Decision

- API base URL and model are server configuration, never app constants. The initial production candidates are `deepseek-v4-flash` for ordinary intent work and `deepseek-v4-pro` for complex roadmap work.
- Use the official API. Resolve available models at deployment/startup and fail closed on an unknown configured model.
- Use versioned, strict JSON tool schemas where supported, while still validating every response locally.
- Prefer non-thinking mode for low-latency common actions. If thinking mode is used with tools, preserve `reasoning_content` across tool turns as required by the official API. Never expose it to the client or audit UI.
- Retry transient 429/5xx/network failures with bounded exponential backoff and jitter; never blindly retry a non-idempotent write. Use idempotency keys at the execution layer.
- Time-box an interaction and degrade to queued/local actions when the provider is unavailable.

As of this decision, the official API lists V4 Flash/Pro with 1M context and tool/JSON support; older `deepseek-chat` and `deepseek-reasoner` aliases retired in July 2026. Model naming is therefore especially important to keep configurable.

## Security boundary

`DeepSeek → proposed LampToolCall → schema validation → semantic/policy validation → risk gate → transactional domain service → audit event`.

No database handle, service-role key or raw persistence API is available to the model.

## Sources

- https://api-docs.deepseek.com/quick_start/pricing
- https://api-docs.deepseek.com/guides/tool_calls/
- https://api-docs.deepseek.com/guides/thinking_mode/
- https://api-docs.deepseek.com/api/create-chat-completion/

