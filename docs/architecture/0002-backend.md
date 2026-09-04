# ADR 0002 — Backend architecture

Date: 2026-09-04

## Options considered

| Option | Strengths | Weaknesses |
| --- | --- | --- |
| BaaS-led (Firebase/Supabase only) | Fast auth, persistence, storage, sync | Domain and AI policy can leak into database triggers/functions; complex audit workflow becomes scattered |
| Custom service (Swift/Vapor or TypeScript + PostgreSQL) | Maximum control, clean domain boundary | Highest operations burden; auth, storage, jobs and push plumbing slow the first release |
| Hybrid: Supabase platform + controlled application functions | Managed Auth/Postgres/Storage/RLS plus explicit policy and AI orchestration boundary | Some provider coupling; background workloads must respect function limits |

## Decision

Use the **hybrid** design:

- Supabase Auth, PostgreSQL, Storage and row-level security.
- Versioned Edge Functions as the only AI/tool execution boundary.
- PostgreSQL tables for plan nodes, blocks, execution records, memories, replan proposals and append-only audit events.
- Cron/Queues for briefs, reviews and retryable jobs. APNs provider credentials remain server-side.
- iOS maintains an offline cache and an outbox of idempotent low-risk actions.

DeepSeek never receives database credentials and never writes storage. Model tool requests are decoded into versioned commands, validated, risk-classified and executed by domain services inside a transaction.

## Exit path

Keep the domain/tool schemas provider-neutral. If Edge Function runtime limits become constraining, move orchestration and jobs to a custom service while retaining Supabase Postgres/Auth/Storage.

## Sources

- https://supabase.com/docs/guides/auth/architecture
- https://supabase.com/docs/guides/database/overview
- https://supabase.com/docs/guides/functions/auth
- https://supabase.com/docs/guides/cron

