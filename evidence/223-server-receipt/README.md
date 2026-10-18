# #223 review evidence: keep accepted ops pending until the server echo arrives

**ADDENDUM: written 2026-10-18 by dense-ram (seat 0e21b069), after every run listed here had finished.** Everything under `raw/` is a byte-for-byte copy of the devkit receipts (`devkit-*`) from the seat's private `evidence-223/` directory. Nothing in `raw/` was edited, re-run or removed, and the failing receipts are kept. This README and `source-hashes.txt` are interpretation and newly generated records. They are not original run output. `MANIFEST.sha256` lists the SHA-256 of every other file on this branch.

Under review:
- devkit: MEK-Org/glass_goals_devkit#17, head `1c3de4a41b5d42869bd0ff146a8b008f0953fd9d`, base `51e15c430de01c7243bb59481002de2ae532c7a3` (its tree is identical to `cf95539`, which is the devkit pin on app master).
- app: MEK-Org/glass_goals#226, head `79d59aab395ac56cd2862abac8a79e79b7f74905`, base master `9b88dd3248819ab5ade2c25a9a880cfa819d73e8`. Its gitlink pins devkit `1c3de4a4`.

## How the receipts were produced

Every `*.log` except `emulators-*.log` and `raw-publish-223.log` was written by `drivers/run.sh <name> <cwd> <cmd…>`. The wrapper writes the command, cwd, start UTC, `git rev-parse HEAD`, porcelain dirty-line count and Dart version. It then appends the combined stdout+stderr, the end UTC and the exit code. It refuses to overwrite an existing log. Relative cwds are relative to the seat workdir. `gg-223` is the fix checkout and `gg-223-base` is a separate base checkout.


The full app-side evidence set, including the browser delayed-echo receipts and the boundary discussion, is on MEK-Org/glass_goals branch `rusa/0e21b069/223-review-evidence`. Devkit facts from that README:

- **Cryptographic, now:** `source-hashes.txt` shows that every changed file's current worktree SHA-256 equals its blob SHA-256 in the PR head, and that both checkouts have 0 porcelain lines at those heads.
- **Cryptographic, devkit lib at receipt time:** `raw/devkit-fix-final.diff` was saved at 13:02:16Z, before `devkit-red-223d`, `devkit-green-223b`, `devkit-suite-223b` and `devkit-analyze-223`. It is byte-identical to `git diff 51e15c43 1c3de4a4 -- packages/goals_core/lib`. The new test file was untracked at that point, so the diff does not contain it.
- The devkit sources' mtimes are 13:02:44.9Z (lib) and 13:02:45.1Z (test). Those times come from restoring the files after `devkit-analyze-base-223` (13:02:39Z, `dirty_lines=0`), which analysed clean base. The content of the devkit test file during the red/green runs was not hashed at the time. The test names in the logs match the committed file, but that is not a hash proof.

| Claim | Receipt(s) | Observed |
|---|---|---|
| devkit regression red before fix | `devkit-red-223{,b,c,d}.log` | exit 1. `-5`, `-1` (compile/early), `-6`, `-6` failures |
| devkit regression green with fix | `devkit-green-223{,b}.log` | exit 0, `+7: All tests passed!` |
| devkit goals_core suite | `devkit-suite-223.log` → `devkit-suite-223b.log` | first: exit 1 `+122 ~2 -1` (kept); final: exit 0 `+123 ~2` |
| devkit analyzer, base vs fix | `devkit-analyze-base-223.log`, `devkit-analyze-223.log` | both exit 2, 17 issues each: pre-existing and not increased |

| log | cmd | cwd | started_utc | exit |
|---|---|---|---|---|
| `devkit-analyze-223.log` | dart analyze | gg-223/third_party/glass_goals_devkit/packages/goals_core | 2026-10-18T13:02:30.033Z | 2 |
| `devkit-analyze-base-223.log` | dart analyze | gg-223/third_party/glass_goals_devkit/packages/goals_core | 2026-10-18T13:02:39.434Z | 2 |
| `devkit-green-223.log` | dart test test/sync/sync_client_server_receipt_test.dart | gg-223/third_party/glass_goals_devkit/packages/goals_core | 2026-10-18T13:01:18.656Z | 0 |
| `devkit-green-223b.log` | dart test test/sync/sync_client_server_receipt_test.dart | gg-223/third_party/glass_goals_devkit/packages/goals_core | 2026-10-18T13:02:19.158Z | 0 |
| `devkit-red-223.log` | dart test test/sync/sync_client_server_receipt_test.dart | gg-223/third_party/glass_goals_devkit/packages/goals_core | 2026-10-18T12:55:13.145Z | 1 |
| `devkit-red-223b.log` | dart test test/sync/sync_client_server_receipt_test.dart | gg-223/third_party/glass_goals_devkit/packages/goals_core | 2026-10-18T13:00:56.375Z | 1 |
| `devkit-red-223c.log` | dart test test/sync/sync_client_server_receipt_test.dart | gg-223/third_party/glass_goals_devkit/packages/goals_core | 2026-10-18T13:01:09.965Z | 1 |
| `devkit-red-223d.log` | dart test test/sync/sync_client_server_receipt_test.dart | gg-223/third_party/glass_goals_devkit/packages/goals_core | 2026-10-18T13:02:16.239Z | 1 |
| `devkit-suite-223.log` | dart test | gg-223/third_party/glass_goals_devkit/packages/goals_core | 2026-10-18T13:01:21.687Z | 1 |
| `devkit-suite-223b.log` | dart test | gg-223/third_party/glass_goals_devkit/packages/goals_core | 2026-10-18T13:02:21.737Z | 0 |
