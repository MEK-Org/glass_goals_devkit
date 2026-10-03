# Upward cycle guard evidence

Refs MEK-Org/glass_goals#66. Approved in [Matt's comment](https://github.com/MEK-Org/glass_goals/issues/66#issuecomment-5563418336).

The baseline was freshly cloned devkit `a63fd38f2015c7ca88b483f46fe69e25ce54735b`. The app was freshly cloned at `b747c95d054af1eb7fc603496d55562421ff31d8`, pinning devkit `9d4b97d192590657c97e1172592d34170b444232`. Flutter 3.41.5 / Dart 3.11.3 were used from the actor's writable SDK. Commands below ran in the indicated package; `../../../.flutter_mnt/bin/` identifies that SDK. Logs in this directory omit only `[SYNC-DIAG]` chatter. Complete raw logs remain in the actor's `evidence/` directory.

## Red receipts, before source edits

- Core: `timeout 90 ../../../.flutter_mnt/bin/dart test test/sync/sync_client_cycles_test.dart --reporter expanded` exited **1**, with **2 passing / 8 failing**. [red-core.log](red-core.log) records both actual SyncClient sequences: `a up=[b] down=[]; b up=[a] down=[a]`. The graph assertions expose upward residue while downward edges remain acyclic. Separate traversal tests run those op sequences inside worker isolates: the test isolate's **2-second watchdog** expires and kills the worker with `Isolate.immediate`, so its timer cannot be blocked by the synchronous reader. Both AddParent and SetParent reader tests fail with a real `TimeoutException`.
- Breadcrumb: `timeout --kill-after=3s 60s ../../../.flutter_mnt/bin/flutter test test/goal_breadcrumb_cycles_test.dart --reporter expanded` exited **124**. [red-breadcrumb.log](red-breadcrumb.log) shows the test body started, with no completion before the OS process watchdog stopped it. The graph is made through SyncClient using a slice closing edge; this remains permitted after the ordinary guard fix, so the widget regression exercises the independent reader protection.
- Notification sweep: a guard-only implementation left an old-parent watch stale despite detachment in global state. Adding current prior-parent IDs fixed normal SetParent invalidation; the extended undo control then failed because its restored parent was absent from the current graph. [watch-undo.log](watch-undo.log) records **9 passing / 1 failing**, expecting `old.subGoalIds == ['b']` after undo but seeing `[]`. Referenced SetParent enable/disable ops now include historical parent IDs as well.

## Green receipts

[green.log](green.log) contains observed after-fix output. Every check below exited **0**:

| Working directory | Command (with outer timeout) | Observed result |
| --- | --- | --- |
| `packages/goals_core` | `timeout 240 ../../../.flutter_mnt/bin/dart test --reporter expanded` | **115 passed, 2 existing skips** |
| `packages/goals_widgets` | `timeout 240 ../../../.flutter_mnt/bin/flutter test --reporter expanded` | **26 passed**, including actual breadcrumb render-order/removal test |
| `packages/goals_core` | `timeout 120 ../../../.flutter_mnt/bin/dart analyze lib/src/queries.dart lib/src/sync/sync_client.dart test/sync/sync_client_cycles_test.dart` | No errors/warnings; 3 existing naming infos |
| `packages/goals_widgets` | `timeout 120 ../../../.flutter_mnt/bin/flutter analyze --no-pub --no-fatal-infos lib/src/goal_breadcrumb.dart test/goal_breadcrumb_cycles_test.dart` | No errors/warnings; 11 existing `this.` style infos |
| `packages/goals_core` | `timeout 120 ../../../.flutter_mnt/bin/dart compile kernel test/sync/sync_client_cycles_test.dart -o ../../../evidence/core-cycles.dill` | Kernel artifact generated |
| repo root | `timeout 120 pnpm --filter @thkp-eng/goals-types build` | `tsc` passed |
| repo root | `timeout 120 pnpm --filter @thkp-eng/goals-core build` | `tsc` passed |
| repo root | `timeout 120 pnpm --filter @thkp-eng/goals-core exec vitest run` | **36 passed / 6 files** |
| sibling `widget_smoke` app | `timeout 240 ../.flutter_mnt/bin/flutter build web --release` | **Built build/web**, 105.2 seconds |

The smoke app was generated with `flutter create --platforms=web --no-pub widget_smoke` next to the devkit clone. Copy [widget-smoke-pubspec.yaml](widget-smoke-pubspec.yaml) to its `pubspec.yaml` and [widget-smoke-main.dart](widget-smoke-main.dart) to `lib/main.dart`, run `flutter pub get`, then the web build. It builds the actual changed ParentBreadcrumb/core/UI packages through local path dependencies; it is not the deferred Glass Goals integration build. The successful JavaScript web build emitted existing dependency WASM-compatibility and Cupertino font warnings. Earlier native bundle attempts encountered missing Android SDK and Linux linker components; no native build is claimed.

## Resulting contract

Both ordinary parent branches check for cycles before adding either side of a new relationship. SetParent still detaches prior parents first, including when the replacement is cyclic, and retains modified IDs for those detachments. Rejected ops remain in the goal log. Clearing to root, valid reparenting, removal, unloaded-parent/missing-ancestor fail-open behavior, and slice entry identity are retained.

The map-returning transitive reader skips already returned IDs in both directions. It keeps the root even when the predicate would exclude it, retains depth-first encounter order, and visits a diamond's accepted shared ancestor once. Path-based traversal still retains both paths through that diamond. Legacy and permitted slice cycles terminate. ParentBreadcrumb renders each loaded ID once, in ancestor-to-leaf order, then still responds to removal.

Per-goal notifications include SetParent's old parents. Undo/redo of SetParent also includes parents named in the child's history, because undo can restore an edge absent from its current parent set. Tests check synchronous watch values after the mutation resolves, detach/reparent/clear behavior, undo/redo, and immutability of the prior published snapshot.

## Dependent sweep

The sweep searched `superGoalIds`, `getTransitiveSuperGoals`, and `traverseUp` throughout devkit Dart and `glass_goals/goals_web/lib` at the heads above, then read the surrounding implementations.

| Reader/dependent | Finding and evidence |
| --- | --- |
| Core `_getTransitiveGoals` | Demonstrated nontermination through both actual op sequences; fixed and bounded by separate-isolate regression tests. Both up/down and legacy/slice graphs are covered. |
| Widgets `ParentBreadcrumb.build` | Demonstrated process timeout. Added visited IDs. Real widget test covers cyclic render order and rebuild after removal; its existing `_computeChainIds` already stops on repeats. |
| Core `_traverse`, async traversal variants | Existing per-path cycle checks; preserve multi-parent path semantics. Diamond control proves 5 visits including both root paths; existing query suite covers synchronous/async traversal. |
| Core `_findAncestors` / `findLatestCommonAncestor` | Existing seen-ID map prevents revisiting ancestors. No reliance on residue found. |
| Core `computeDropOnGoalEffects`, `computeDropOnSeparatorEffects` | Use `getTransitiveSuperGoals` to reject dropping ancestors into descendants; benefit from the bounded reader. Existing drop tests and widget Alt-drag suite exercise valid move/add, cycles, reorder, and root behavior. |
| App `goal_search_modal.dart` | Upward map keys exclude ancestors from add-child candidates; direct-parent loops are finite. It benefits from the query fix after gitlink consumption. |
| App `goal_viewer.dart` | Drop guard reads upward map keys; other parent reads are direct enumeration. Integration deferred until merged core consumption. |
| App `inverted_goal_instance.dart` | Uses the existing cycle-aware `traverseUp`. |
| App `pdf_drop_zone.dart` | `_hasCompletedAncestorExtraction` already has a visited set. Other parent reads are bounded direct accesses/enumeration. |
| App `scheduled_goals_v2.dart`, `hover_actions.dart` | Direct parent loops or fixed-depth first-parent lookups; no unbounded upward walker found. |
| Sync watches and indexing | Rejected SetParent detachments exposed missing old-parent invalidation; fixed as above. Full reactive, eviction, phase-B and existing reparent/undo core suites remain green. |

No consumer requiring ordinary upward cycle residue was found in this source sweep. This is a source-and-test result, not a claim about production data. Legacy/slice cycles remain readable; there is no migration.

## TypeScript parity seam

The current TS port **has** `checkCycles`; the old issue's description of its missing guards is stale at this baseline. `packages/goals-core/src/sync-client.ts` inserts the upward edge before checking in both `evaluateSuperGoals` branches, explicitly documenting that residue. `sync-client.cycles.test.ts` asserts “skips only the down edge” for AddParent and SetParent, including longer cycles, self-parenting, and log-order resolution. After this Dart change, those ordinary-cycle expectations are the precise parity mismatch. The TS detach-first SetParent, unloaded-parent tolerance, diamond, and slice identity contracts continue to match the retained Dart behavior. The TS package exports sync/model utilities and has no corresponding Dart transitive query or breadcrumb implementation.

TS source and publication are unchanged in this PR. Its existing 36 tests and both package TypeScript builds pass, which verifies the existing port but does not establish parity with the new Dart rejection behavior. Reconciling those TS expectations and any release requires separate scope.

## Integration gate

The app gitlink is unchanged. After actual devkit merge and a separate steward commission, pin a separate Glass Goals PR to the accepted merged devkit commit. Build the app, then reproduce the original ordering: create both goals; AddParent A→B; AddParent or SetParent B→A; inspect both graph sides; call getTransitiveSuperGoals; render ParentBreadcrumb. Keep legacy/slice reader controls in that integration verification. Matt owns merge; issue #66 stays open until consumption is verified. No packages are published here.
