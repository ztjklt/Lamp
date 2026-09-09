import { LampError } from "../../errors/LampError.js";
import type { PlanRevisionRepository } from "../../domain/repositories/PlanRevisionRepository.js";
import { PlanRevisionSchema, type PlanRevision } from "../../planning/ReplanningTypes.js";

export class InMemoryPlanRevisionRepository implements PlanRevisionRepository {
  private readonly revisions = new Map<string, PlanRevision[]>();

  async append(rawRevision: Readonly<PlanRevision>): Promise<void> {
    const revision = PlanRevisionSchema.parse(rawRevision);
    const existing = this.revisions.get(revision.planId) ?? [];
    if (existing.some((item) => item.userId !== revision.userId)) {
      throw new LampError({
        code: "AUTH_ERROR",
        message: "Plan revision user does not match existing plan ownership",
        safeMessage: "计划数据隔离校验失败。",
        statusCode: 403,
      });
    }
    const expected = existing.length + 1;
    if (revision.revision !== expected || existing.some((item) => item.revisionId === revision.revisionId)) {
      throw new LampError({
        code: "CONFLICT_ERROR",
        message: `Plan revision must append at version ${expected}`,
        safeMessage: "计划版本已发生变化，请重新规划。",
        statusCode: 409,
      });
    }
    if ((existing.at(-1)?.revisionId ?? null) !== revision.previousRevisionId) {
      throw new LampError({
        code: "STALE_STATE",
        message: "Plan revision predecessor does not match latest revision",
        safeMessage: "计划版本已过期，请重新规划。",
        statusCode: 409,
      });
    }
    this.revisions.set(revision.planId, [...existing, structuredClone(revision)]);
  }

  async getLatest(planId: string): Promise<Readonly<PlanRevision> | null> {
    const latest = this.revisions.get(planId)?.at(-1);
    return latest === undefined ? null : structuredClone(latest);
  }

  async list(planId: string): Promise<ReadonlyArray<Readonly<PlanRevision>>> {
    return structuredClone(this.revisions.get(planId) ?? []);
  }
}
