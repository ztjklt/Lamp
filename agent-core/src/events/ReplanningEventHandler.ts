import type { StateEngine } from "../agent/state/StateEngine.js";
import type { ReplanningEngine } from "../planning/ReplanningEngine.js";
import type { ReplanningResult } from "../planning/ReplanningTypes.js";
import type { DomainEvent } from "./DomainEvent.js";

export type ReplanningResultSink = (event: Readonly<DomainEvent>, result: ReplanningResult) => Promise<void>;

export class ReplanningEventHandler {
  constructor(
    private readonly stateEngine: StateEngine,
    private readonly replanning: ReplanningEngine,
    private readonly sink: ReplanningResultSink,
    private readonly horizonDays = 14,
  ) {}

  async handle(event: Readonly<DomainEvent>): Promise<void> {
    const state = await this.stateEngine.buildSnapshot({ userId: event.userId, horizonDays: this.horizonDays });
    const result = await this.replanning.replan({ event, state });
    await this.sink(event, result);
  }
}
