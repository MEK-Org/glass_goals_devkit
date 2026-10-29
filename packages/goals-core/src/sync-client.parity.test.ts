import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  AnyOp,
  DeltaOp,
  GoalDelta,
  GoalLogEntry,
  WireOp,
  compressLogEntry,
  expandOp,
} from "@thkp-eng/goals-types";
import { Goal } from "./model";
import { MemoryLocalStore } from "./local-store";
import { MemoryPersistenceService } from "./persistence";
import { GoalRef, SyncClient, WatchedGoalSet } from "./sync-client";

// Shared with the Dart suite: goals_core/test/sync/sync_parity_fixture_test.dart
// runs the same scenarios against the Dart SyncClient and records what it
// observed in sync_parity_expected.json. This suite asserts the TypeScript
// port produces exactly that output.
const fixtureDir = join(__dirname, "../../goals_core/test/sync/fixtures");
const scenarios: Scenario[] = JSON.parse(
  readFileSync(join(fixtureDir, "sync_parity_scenarios.json"), "utf8"),
).scenarios;
const expected: Record<string, unknown[]> = JSON.parse(
  readFileSync(join(fixtureDir, "sync_parity_expected.json"), "utf8"),
);

interface Scenario {
  name: string;
  seed: WireOp[];
  steps: Array<Record<string, any>>;
}

/** Counts per-goal op loads and full-history reads. */
export class CountingLocalStore extends MemoryLocalStore {
  loads = new Map<string, number>();
  getAllOpsCalls = 0;

  override async loadOpsForGoal(goalId: string): Promise<AnyOp[]> {
    this.loads.set(goalId, (this.loads.get(goalId) ?? 0) + 1);
    return super.loadOpsForGoal(goalId);
  }

  override async getAllOps(): Promise<AnyOp[]> {
    this.getAllOpsCalls++;
    return super.getAllOps();
  }
}

const sorted = (ids: Iterable<string>) => [...ids].sort();

function describeEntry(entry: GoalLogEntry): string {
  const wire = compressLogEntry(entry as any) as any;
  return wire.te == null
    ? `${wire.t}:${entry.id}`
    : `${wire.t}:${entry.id}:${wire.te}`;
}

function describeGoal(goal: Goal) {
  return {
    text: goal.text,
    parents: sorted(goal.superGoalIds),
    children: sorted(goal.subGoalIds),
    log: goal.log.map(describeEntry),
  };
}

const pause = (ms: number) => new Promise((r) => setTimeout(r, ms));

class Runner {
  persistence = new MemoryPersistenceService();
  store = new CountingLocalStore();
  client: SyncClient | null = null;
  refs = new Map<string, GoalRef>();
  watches = new Map<string, WatchedGoalSet>();

  async pump() {
    for (let i = 0; i < 4; i++) {
      await this.persistence.settled();
      await pause(5);
    }
  }

  async start(cap: number) {
    this.client = new SyncClient(this.persistence, this.store, {
      residentSoftCap: cap,
    });
    await this.client.init();
  }

  stop() {
    this.client?.dispose();
    this.client = null;
    this.refs.clear();
    this.watches.clear();
  }

  async snapshot(step: Record<string, any>) {
    const c = this.client!;
    const state = c.stateSubject.value;
    const result: Record<string, unknown> = {
      label: step.label,
      state: Object.fromEntries(
        sorted(state.keys()).map((id) => [id, describeGoal(state.get(id)!)]),
      ),
      resident: c.numResidentGoals,
      pinned: c.numPinnedGoals,
      roots: sorted(c.getRootGoalIds()),
      unsynced: c.numUnsyncedOps,
      loads: Object.fromEntries(
        sorted(this.store.loads.keys()).map((id) => [id, this.store.loads.get(id)]),
      ),
      getAllOps: this.store.getAllOpsCalls,
      refs: Object.fromEntries(
        sorted(this.refs.keys()).map((alias) => [
          alias,
          this.refs.get(alias)!.goal?.text ?? null,
        ]),
      ),
      watches: Object.fromEntries(
        sorted(this.watches.keys()).map((alias) => {
          const watch = this.watches.get(alias)!;
          return [
            alias,
            {
              watched: sorted(watch.watchedIds),
              current: sorted(watch.currentValue.keys()),
            },
          ];
        }),
      ),
    };
    if (step.cursor === true) {
      result.cursor = c.cursor;
    }
    if (step.strings) {
      const strings: Record<string, string | null> = {};
      for (const key of step.strings as string[]) {
        strings[key] = await c.loadString(key);
      }
      result.strings = strings;
    }
    return result;
  }

  async run(scenario: Scenario) {
    const snapshots: unknown[] = [];
    await this.persistence.save(scenario.seed.map(expandOp));
    await this.pump();

    for (const step of scenario.steps) {
      switch (step.op) {
        case "start":
          await this.start(step.cap ?? 2000);
          break;
        case "restart":
          this.stop();
          await this.start(step.cap ?? 2000);
          break;
        case "load":
          await this.client!.loadGoal(step.id);
          break;
        case "remote":
          await this.persistence.save((step.ops as WireOp[]).map(expandOp));
          break;
        case "modify":
          await this.client!.modifyGoals(
            (step.deltas as any[]).map(
              (d) =>
                (
                  expandOp({
                    h: "000000000000000:00000:fixture",
                    i: "fixture",
                    v: 6,
                    t: "d",
                    d,
                  } as WireOp) as DeltaOp
                ).delta as GoalDelta,
            ),
          );
          break;
        case "undo":
          await this.client!.undo();
          break;
        case "redo":
          await this.client!.redo();
          break;
        case "ref":
          this.refs.set(step.as, await this.client!.loadGoalRef(step.id));
          break;
        case "release":
          await this.refs.get(step.as)!.dispose();
          break;
        case "watch":
          this.watches.set(step.as, this.client!.watchGoals(step.ids));
          break;
        case "watchRemove":
          this.watches.get(step.as)!.remove(step.id);
          break;
        case "unwatch":
          await this.watches.get(step.as)!.dispose();
          break;
        case "snapshot":
          await this.pump();
          snapshots.push(await this.snapshot(step));
          break;
        default:
          throw new Error(`Unknown step ${step.op}`);
      }
      await this.pump();
    }
    this.stop();
    return snapshots;
  }
}

describe("SyncClient parity with the Dart SyncClient", () => {
  it("covers every scenario in the shared fixture", () => {
    expect(Object.keys(expected).sort()).toEqual(
      scenarios.map((s) => s.name).sort(),
    );
  });

  for (const scenario of scenarios) {
    it(scenario.name, async () => {
      const snapshots = await new Runner().run(scenario);
      expect(JSON.parse(JSON.stringify(snapshots))).toEqual(
        expected[scenario.name],
      );
    });
  }
});
