import { describe, expect, it } from "vitest";
import { AnyOp, DeltaOp } from "@thkp-eng/goals-types";
import { HLC } from "./hlc";
import { LoadOpsResp, PersistenceService } from "./persistence";
import { compareHlc } from "./op-utils";
import { SyncClient } from "./sync-client";

/**
 * Mirrors the Dart re-enable tests in
 * `goals_core/test/sync/sync_client_server_receipt_test.dart`: a server whose
 * saves succeed at once and whose listener echoes wait until released.
 */
class DelayedEchoServer implements PersistenceService {
  committed: AnyOp[] = [];
  private pending: AnyOp[] = [];
  private listener: ((ops: AnyOp[], cursor: string) => void) | null = null;
  /** The next save delivers its first op's echo before it returns. */
  echoFirstDuringNextSave = false;

  async save(ops: Iterable<AnyOp>): Promise<void> {
    await tick();
    const saved = [...ops];
    this.committed.push(...saved);
    this.pending.push(...saved);
    if (this.echoFirstDuringNextSave && saved.length > 0) {
      this.echoFirstDuringNextSave = false;
      const first = saved[0];
      this.pending = this.pending.filter((op) => op !== first);
      this.listener?.([first], first.hlcTimestamp);
      await drain();
      await drain();
    }
  }

  async releaseEchoes(): Promise<void> {
    const echoes = this.pending;
    this.pending = [];
    for (const op of echoes) {
      this.listener?.([op], op.hlcTimestamp);
      await drain();
    }
  }

  /** Delivers [ops] committed by another client through the listener. */
  async deliver(ops: AnyOp[]): Promise<void> {
    this.committed.push(...ops);
    this.listener?.(ops, ops[ops.length - 1].hlcTimestamp);
    await drain();
    await drain();
  }

  async load({
    cursor = null,
    limit,
  }: {
    cursor?: string | null;
    limit?: number;
  }): Promise<LoadOpsResp> {
    const ops = this.committed
      .filter((op) => cursor == null || compareHlc(op.hlcTimestamp, cursor) > 0)
      .sort((a, b) => compareHlc(a.hlcTimestamp, b.hlcTimestamp))
      .slice(0, limit ?? Number.MAX_SAFE_INTEGER);
    return {
      ops,
      cursor: ops.length > 0 ? ops[ops.length - 1].hlcTimestamp : cursor,
    };
  }

  async loadString(): Promise<string | null> {
    return null;
  }

  async count(): Promise<number> {
    return this.committed.length;
  }

  subscribeJSON(
    _cursor: string | null,
    callback: (ops: AnyOp[], cursor: string) => void,
  ): () => void {
    this.listener = callback;
    return () => {
      this.listener = null;
    };
  }
}

function tick(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

async function drain(): Promise<void> {
  for (let i = 0; i < 5; i++) await tick();
}

async function connectedClient() {
  const server = new DelayedEchoServer();
  const client = new SyncClient(server);
  await client.init();
  return { server, client };
}

describe("re-enabled ops", () => {
  it("redo of a multi-op action keeps every re-enabled op when the first echo arrives before the push returns", async () => {
    const { server, client } = await connectedClient();
    const text = (id: string) => client.stateSubject.value.get(id)?.text;

    await client.modifyGoals([
      { id: "a", text: "First draft" },
      { id: "b", text: "B one" },
      { id: "c", text: "C one" },
    ]);
    await drain();
    await server.releaseEchoes();
    await drain();

    // One action that changes several goals, like a merge.
    await client.modifyGoals([
      { id: "a", text: "Final draft" },
      { id: "b", text: "B two" },
      { id: "c", text: "C two" },
    ]);
    await drain();
    await server.releaseEchoes();
    await drain();

    const watch = client.watchGoals(["a", "b", "c"]);
    await drain();

    await client.undo();
    await drain();
    await server.releaseEchoes();
    await drain();
    expect([text("a"), text("b"), text("c")]).toEqual([
      "First draft",
      "B one",
      "C one",
    ]);

    const expectRedone = () => {
      expect([text("a"), text("b"), text("c")]).toEqual([
        "Final draft",
        "B two",
        "C two",
      ]);
      for (const id of ["a", "b", "c"]) {
        expect(text(id)).toEqual(watch.currentValue.get(id)?.text);
      }
    };

    // The first re-enable's echo lands before the push replaces the unsynced
    // originals with their pushed copies.
    server.echoFirstDuringNextSave = true;
    await client.redo();
    await drain();
    expectRedone();

    await server.releaseEchoes();
    await drain();
    expect(client.numUnsyncedOps).toBe(0);
    expectRedone();
    await watch.dispose();
    client.dispose();
  });

  it("enable ops that share an HLC each re-enable their own target", async () => {
    const { server, client } = await connectedClient();
    const text = (id: string) => client.stateSubject.value.get(id)?.text;
    let seq = 0;
    const nextHlc = () =>
      new HLC(1_700_000_000_000 + ++seq, 0, "remote").pack();
    const textOp = (id: string, goalId: string, value: string): DeltaOp =>
      ({
        id,
        hlcTimestamp: nextHlc(),
        version: 6,
        type: "delta",
        delta: { id: goalId, text: value },
      }) as DeltaOp;

    const x2 = textOp("x2", "x", "x two");
    const y2 = textOp("y2", "y", "y two");
    await server.deliver([
      textOp("x1", "x", "x one"),
      textOp("y1", "y", "y one"),
      x2,
      y2,
      { id: "dx", hlcTimestamp: nextHlc(), version: 6, type: "disable", opId: x2.id } as AnyOp,
      { id: "dy", hlcTimestamp: nextHlc(), version: 6, type: "disable", opId: y2.id } as AnyOp,
    ]);
    expect([text("x"), text("y")]).toEqual(["x one", "y one"]);

    const shared = nextHlc();
    await server.deliver([
      { id: "ex", hlcTimestamp: shared, version: 6, type: "enable", opId: x2.id } as AnyOp,
      { id: "ey", hlcTimestamp: shared, version: 6, type: "enable", opId: y2.id } as AnyOp,
    ]);
    expect([text("x"), text("y")]).toEqual(["x two", "y two"]);
    client.dispose();
  });

  it("undo after redo disables the re-enabled op again", async () => {
    const { server, client } = await connectedClient();
    const text = () => client.stateSubject.value.get("g")?.text;
    const settle = async () => {
      await drain();
      await server.releaseEchoes();
      await drain();
    };

    await client.modifyGoal({ id: "g", text: "one" });
    await client.modifyGoal({ id: "g", text: "two" });
    await settle();

    await client.undo();
    await settle();
    expect(text()).toBe("one");

    await client.redo();
    await settle();
    expect(text()).toBe("two");

    await client.undo();
    await settle();
    expect(text()).toBe("one");
    expect(client.numUnsyncedOps).toBe(0);
    client.dispose();
  });
});
