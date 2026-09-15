import type {
  StateReadRepository,
  StateReadRequest,
  StateSnapshotRepository,
  StateSourceData,
  UserRepository,
} from "../../domain/repositories/StateRepositories.js";
import type { UserState } from "../../agent/state/StateModels.js";
import type { StateSnapshot } from "../../agent/state/StateSnapshot.js";
import { LampError } from "../../errors/LampError.js";

export interface InMemoryStateFixture {
  user: UserState;
  state: StateSourceData;
}

export class InMemoryStateRepository implements UserRepository, StateReadRepository {
  private readonly fixtures = new Map<string, InMemoryStateFixture>();

  constructor(fixtures: InMemoryStateFixture[] = []) {
    for (const fixture of fixtures) this.set(fixture);
  }

  set(fixture: InMemoryStateFixture): void {
    this.fixtures.set(fixture.user.id, structuredClone(fixture));
  }

  async getById(userId: string): Promise<UserState | null> {
    const fixture = this.fixtures.get(userId);
    return fixture ? structuredClone(fixture.user) : null;
  }

  async readForSnapshot(request: StateReadRequest): Promise<StateSourceData> {
    const fixture = this.fixtures.get(request.userId);
    if (!fixture) {
      throw new LampError({
        code: "DATABASE_ERROR",
        message: "In-memory state fixture was not found",
        safeMessage: "当前状态暂时无法读取。",
        retryable: false,
      });
    }
    const horizonStart = Date.parse(request.horizon.start);
    const horizonEnd = Date.parse(request.horizon.end);
    const intersects = (start: string, end: string) =>
      Date.parse(start) < horizonEnd && Date.parse(end) > horizonStart;
    const state = structuredClone(fixture.state);
    state.schedule = state.schedule.filter((block) => intersects(block.startsAt, block.endsAt));
    state.upcomingEvents = state.upcomingEvents.filter((event) => intersects(event.startsAt, event.endsAt));
    return state;
  }
}

export class InMemoryStateSnapshotRepository implements StateSnapshotRepository {
  private readonly snapshots = new Map<string, StateSnapshot>();

  async save(snapshot: Readonly<StateSnapshot>): Promise<void> {
    this.snapshots.set(snapshot.snapshotId, structuredClone(snapshot));
  }

  async getById(snapshotId: string): Promise<Readonly<StateSnapshot> | null> {
    const snapshot = this.snapshots.get(snapshotId);
    return snapshot ? structuredClone(snapshot) : null;
  }
}
