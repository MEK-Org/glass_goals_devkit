// Generates sync_parity_scenarios.json, the scenarios shared by the Dart and
// TS sync parity suites. Run from this directory:
//   node gen_sync_parity_scenarios.mjs sync_parity_scenarios.json
// then regenerate the Dart-observed output from packages/goals_core:
//   UPDATE_SYNC_PARITY=1 dart test test/sync/sync_parity_fixture_test.dart
import { writeFileSync } from "node:fs";
const h = (t, c = 0) => `${String(t).padStart(15, "0")}:${c.toString(36).padStart(5, "0")}:srv`;
const op = (i, t, d) => ({ h: h(t), i, v: 6, t: "d", d });
const create = (i, t, g, text) => op(i, t, { i: g, t: text });
const text = create;
const addParent = (i, t, g, p) => op(i, t, { i: g, lE: { t: "aP", i: `e-${i}`, cT: t, pI: p } });
const setParent = (i, t, g, p) => op(i, t, { i: g, lE: { t: "sP", i: `e-${i}`, cT: t, pI: p } });
const removeParent = (i, t, g, p) => op(i, t, { i: g, lE: { t: "rP", i: `e-${i}`, cT: t, pI: p } });
const note = (i, t, g, te) => op(i, t, { i: g, lE: { t: "n", i: `e-${i}`, cT: t, te } });
const contents = (i, t, g, te) => op(i, t, { i: g, lE: { t: "d", i: `e-${i}`, cT: t, te } });
const disable = (i, t, target) => ({ h: h(t), i, v: 6, t: "dO", oI: target });
const enable = (i, t, target) => ({ h: h(t), i, v: 6, t: "eO", oI: target });
const snap = (label, extra = {}) => ({ op: "snapshot", label, ...extra });

const scenarios = [
  {
    name: "parent_first_cold_load",
    seed: [create("p1", 1000, "p", "Parent"), create("c1", 1100, "c", "Child"), addParent("c2", 1200, "c", "p")],
    steps: [
      { op: "start" }, snap("first session", { cursor: true }),
      { op: "restart" }, snap("restart: roots only"),
      { op: "load", id: "p" }, snap("after load p"),
      { op: "load", id: "c" }, snap("after load c"),
    ],
  },
  {
    name: "child_first_cold_load",
    seed: [
      create("g1", 1000, "gp", "Grand"), create("p1", 1100, "p", "Parent"), create("c1", 1200, "c", "Child"),
      addParent("p2", 1300, "p", "gp"), addParent("c2", 1400, "c", "p"),
    ],
    steps: [
      { op: "start" }, { op: "restart" }, snap("restart: roots only"),
      { op: "load", id: "c" }, snap("after load c"),
      { op: "load", id: "p" }, snap("after load p"),
    ],
  },
  {
    name: "late_older_hlc_batch",
    seed: [create("o1", 1000, "g", "old"), text("o2", 3000, "g", "new"), create("q1", 1000, "q", "Q")],
    steps: [
      { op: "start" }, snap("before late batch", { cursor: true }),
      { op: "remote", ops: [text("o3", 2000, "g", "late"), addParent("o4", 2500, "q", "g")] },
      snap("in-session after late batch", { cursor: true }),
      { op: "restart" }, { op: "load", id: "g" }, { op: "load", id: "q" }, snap("after restart", { cursor: true }),
    ],
  },
  {
    name: "exact_op_redelivery",
    seed: [create("a1", 1000, "a", "A"), note("a2", 1100, "a", "first note"), create("b1", 1200, "b", "B"), addParent("b2", 1300, "b", "a")],
    steps: [
      { op: "start" },
      { op: "remote", ops: [note("a2", 1100, "a", "first note"), addParent("b2", 1300, "b", "a")] }, snap("after redelivery"),
      { op: "remote", ops: [note("a2", 1100, "a", "first note"), note("a3", 1400, "a", "second note")] }, snap("after redelivery plus new op"),
      { op: "restart" }, { op: "load", id: "a" }, { op: "load", id: "b" }, snap("after restart"),
    ],
  },
  {
    name: "disable_enable_across_cursor",
    seed: [create("o1", 1000, "g", "a"), text("o2", 2000, "g", "b")],
    steps: [
      { op: "start" },
      { op: "remote", ops: [disable("x1", 4000, "o2")] }, snap("disable pre-cursor target, in session"),
      { op: "remote", ops: [text("o3", 5000, "g", "c")] }, snap("working text op"),
      { op: "remote", ops: [disable("x2", 6000, "o3")] }, snap("disable working target"),
      { op: "remote", ops: [enable("x3", 7000, "o3")] }, snap("enable working target"),
      { op: "restart" }, { op: "load", id: "g" }, snap("after restart"),
      { op: "remote", ops: [enable("x4", 8000, "o2")] }, snap("enable pre-cursor target after restart"),
      { op: "restart" }, { op: "load", id: "g" }, snap("after second restart"),
    ],
  },
  {
    name: "mutate_echo_undo_redo_restart",
    seed: [create("p1", 1000, "p", "Parent")],
    steps: [
      { op: "start" },
      { op: "modify", deltas: [{ i: "c", t: "Child" }, { i: "c", lE: { t: "aP", i: "m-ap", cT: 2000, pI: "p" } }] },
      snap("after modify and echo"),
      { op: "modify", deltas: [{ i: "c", t: "Renamed" }] }, snap("after rename"),
      { op: "undo" }, snap("after undo rename"),
      { op: "redo" }, snap("after redo rename"),
      { op: "undo" }, { op: "undo" }, snap("after undoing both actions"),
      { op: "redo" }, snap("after redo create"),
      { op: "restart" }, { op: "load", id: "p" }, { op: "load", id: "c" }, snap("after restart"),
    ],
  },
  {
    name: "root_index",
    seed: [create("a1", 1000, "a", "A"), create("b1", 1100, "b", "B"), addParent("b2", 1200, "b", "a")],
    steps: [
      { op: "start" }, snap("initial roots"),
      { op: "remote", ops: [setParent("b3", 3000, "b", null)] }, snap("after detach"),
      { op: "restart" }, snap("restart roots"),
      { op: "remote", ops: [setParent("b4", 4000, "b", "a")] }, snap("after reattach"),
      { op: "restart" }, snap("restart roots again"),
    ],
  },
  {
    name: "lru_touch_eviction",
    seed: [
      create("r1", 1000, "r", "Root"),
      ...["a", "b", "c", "d"].flatMap((g, k) => [create(`${g}1`, 1100 + k * 10, g, g.toUpperCase()), addParent(`${g}2`, 1500 + k * 10, g, "r")]),
    ],
    steps: [
      { op: "start" }, { op: "restart", cap: 3 }, snap("restart cap 3"),
      { op: "load", id: "a" }, { op: "load", id: "b" }, snap("a b loaded"),
      { op: "load", id: "c" }, snap("c loaded, root evicted"),
      { op: "load", id: "a" }, snap("touch a"),
      { op: "load", id: "d" }, snap("d loaded, b evicted"),
      { op: "load", id: "a" }, { op: "load", id: "b" }, snap("a hit, b reloaded"),
    ],
  },
  {
    name: "pin_release_watch",
    seed: [
      create("r1", 1000, "r", "Root"),
      ...["a", "b", "c", "d"].flatMap((g, k) => [create(`${g}1`, 1100 + k * 10, g, g.toUpperCase()), addParent(`${g}2`, 1500 + k * 10, g, "r")]),
    ],
    steps: [
      { op: "start" }, { op: "restart", cap: 1 },
      { op: "ref", id: "a", as: "ra" }, snap("ref a"),
      { op: "load", id: "b" }, { op: "load", id: "c" }, snap("a pinned through loads"),
      { op: "release", as: "ra" }, { op: "release", as: "ra" }, { op: "load", id: "d" }, snap("a released and evicted"),
      { op: "load", id: "a" }, snap("a reloaded"),
      { op: "watch", ids: ["b"], as: "wb" }, snap("watch b"),
      { op: "remote", ops: [create("x1", 9000, "x", "X"), addParent("x2", 9100, "x", "b")] }, snap("child adopted by watch"),
      { op: "watchRemove", as: "wb", id: "x" }, snap("x removed from watch"),
      { op: "unwatch", as: "wb" }, snap("watch disposed"),
    ],
  },
  {
    name: "reload_content_conservation",
    seed: [create("g1", 1000, "g", "Doc"), note("g2", 1100, "g", "a note"), contents("g3", 1200, "g", "# body"), create("h1", 1300, "h", "Other"), addParent("h2", 1400, "h", "g")],
    steps: [
      { op: "start" }, snap("first session", { strings: ["e-g2", "e-g3"] }),
      { op: "restart", cap: 1 }, { op: "load", id: "g" }, snap("cold load", { strings: ["e-g2", "e-g3"] }),
      { op: "load", id: "h" }, { op: "load", id: "g" }, snap("evicted and reloaded", { strings: ["e-g2", "e-g3"] }),
    ],
  },
  {
    name: "cycle_guard",
    seed: [create("a1", 1000, "a", "A"), create("b1", 1100, "b", "B"), create("c1", 1150, "c", "C"), addParent("b2", 1200, "b", "a"), addParent("c2", 1250, "c", "b"), addParent("a2", 1300, "a", "c"), setParent("b3", 1400, "b", "c")],
    steps: [
      { op: "start" }, snap("first session"),
      { op: "restart" }, { op: "load", id: "a" }, { op: "load", id: "b" }, { op: "load", id: "c" }, snap("after restart"),
    ],
  },
  {
    name: "remote_edges_in_session",
    seed: [create("c1", 1000, "c", "Child"), create("x1", 1010, "x", "X"), create("y1", 1020, "y", "Y")],
    steps: [
      { op: "start" },
      { op: "remote", ops: [setParent("sp", 1100, "c", "p")] }, snap("edge before its parent exists"),
      { op: "remote", ops: [create("p1", 1200, "p", "Parent")] }, snap("parent created later"),
      { op: "remote", ops: [setParent("sp", 1100, "c", "p")] }, snap("edge redelivered"),
      { op: "remote", ops: [addParent("xy", 1300, "x", "y")] },
      { op: "remote", ops: [addParent("yx", 1400, "y", "x")] },
      { op: "remote", ops: [addParent("xx", 1500, "x", "x")] }, snap("cycle-closing edges"),
      { op: "restart" }, { op: "load", id: "c" }, { op: "load", id: "p" }, { op: "load", id: "x" }, { op: "load", id: "y" },
      snap("after restart"),
    ],
  },
];
writeFileSync(process.argv[2], JSON.stringify({ scenarios }, null, 2) + "\n");
