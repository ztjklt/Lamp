import type { PlanRevision } from "../../planning/ReplanningTypes.js";

export interface PlanRevisionRepository {
  append(revision: Readonly<PlanRevision>): Promise<void>;
  getLatest(planId: string): Promise<Readonly<PlanRevision> | null>;
  list(planId: string): Promise<ReadonlyArray<Readonly<PlanRevision>>>;
}
