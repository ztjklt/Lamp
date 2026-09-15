import { CandidateGenerator } from "./CandidateGenerator.js";
import { PlanValidator } from "./PlanValidator.js";
import { PlanningRequestSchema, PlanningResultSchema, type PlanningRequest, type PlanningResult } from "./PlanningTypes.js";

export class SchedulingEngine {
  constructor(
    private readonly generator = new CandidateGenerator(),
    private readonly validator = new PlanValidator(),
  ) {}

  plan(input: unknown): PlanningResult {
    const request: PlanningRequest = PlanningRequestSchema.parse(input);
    const generated = this.generator.generate(request);
    const candidates = [];
    const diagnostics: Array<{ code: string; message: string; candidateId?: string; taskId?: string }> = [];
    for (const raw of generated) {
      const result = this.validator.validate(raw, request);
      if (result.valid && result.candidate !== undefined) candidates.push(result.candidate);
      else for (const item of result.violations) diagnostics.push({
        code: item.code,
        message: item.message,
        candidateId: raw.id,
        ...(item.taskId === undefined ? {} : { taskId: item.taskId }),
      });
    }
    candidates.sort((left, right) => right.score - left.score || left.id.localeCompare(right.id));
    if (candidates.length === 0) {
      if (diagnostics.length === 0) diagnostics.push({
        code: "NO_FEASIBLE_PLAN",
        message: generated.length === 0 ? "No candidate could place all requested work within the hard constraints." : "All candidates failed validation.",
      });
      return PlanningResultSchema.parse({ status: "no_feasible_plan", candidates: [], diagnostics });
    }
    return PlanningResultSchema.parse({ status: "success", candidates: candidates.slice(0, request.candidateLimit), diagnostics });
  }
}
