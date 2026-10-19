# Addendum: Rename `awaitingReceiptOpIds` -> `ackedOpIds`

**Written 2026-10-19 by dense-ram (seat 0e21b069)**

## Context and Scope
In review 5570388239 (inline comment 4312890733 on `packages/goals_core/lib/src/sync/local_store.dart`), Matt requested:
> "let's call these ackedOpIds."

This amendment is a pure identifier rename with identical runtime behavior:
- `awaitingReceiptOpIds` -> `ackedOpIds` across `local_store.dart`, `sync_repository.dart`, `sync_client.dart`, and `sync_client_server_receipt_test.dart`.

## Amended Commits Under Review
- **devkit**: `MEK-Org/glass_goals_devkit#17` amended from `1c3de4a41b5d42869bd0ff146a8b008f0953fd9d` to `1877e9b5d8b8cb773b15f0fbe83d41a8746d060f`.
- **app**: `MEK-Org/glass_goals#226` amended from `79d59aab395ac56cd2862abac8a79e79b7f74905` to `0cb5f66d17db1c0a7cf02d4c141076ea39b5f237` (gitlink updated to pin devkit `1877e9b5d8b8cb773b15f0fbe83d41a8746d060f`).

## Verification at Clean Committed Heads (`dirty_lines=0`)
Unlike the initial evidence runs recorded prior to commit in `README.md`, all amendment verification runs were executed against clean committed checkouts with zero porcelain lines (`dirty_lines=0`):
- Devkit runs recorded `git_head: 1877e9b5d8b8cb773b15f0fbe83d41a8746d060f` and `dirty_lines=0`.
- App runs recorded `git_head: 0cb5f66d17db1c0a7cf02d4c141076ea39b5f237` and `dirty_lines=0`.
- Current worktree blobs match committed blobs exactly as recorded in `source-hashes-amend.txt`.

Because this amendment is a pure identifier rename with identical behavior, the browser delayed-echo proof from pre-rename head `79d59aab` (commit `f271ed5333ba38fa24075196cf02fe9485b0d061`) remains the behavioral proof for live end-to-end delayed echo and reload persistence.

The complete app-side evidence set (including app unit tests, full web_tests suite, analyzer checks, and release build) is published on `MEK-Org/glass_goals` branch `rusa/0e21b069/223-review-evidence`.

## Index of Devkit Amendment Logs
All files in `raw/*-amend.log` were executed via `drivers/run.sh` without modification:

| log | sha256 | cmd | cwd | started_utc | git_head | dirty_lines | exit |
|---|---|---|---|---|---|---|---|
| `devkit-green-amend.log` | `99689f11be9ea69479014d9e1ec93862beaa42b8710047e7957e373b57682353` | dart test test/sync/sync_client_server_receipt_test.dart | gg-223/third_party/glass_goals_devkit/packages/goals_core | 2026-10-19T10:59:28.615Z | 1877e9b5… | 0 | 0 (+7: All tests passed!) |
| `devkit-suite-amend.log` | `64dd02b71ece9e82db7a665d0ecca56d2a876103f9f39539502c5d0de9bc9d04` | dart test | gg-223/third_party/glass_goals_devkit/packages/goals_core | 2026-10-19T10:59:38.116Z | 1877e9b5… | 0 | 0 (+123 ~2: All tests passed!) |
| `devkit-analyze-amend.log` | `a94329075284d0f216a33e845f5997320435e5a9be447ea353a223b685028556` | dart analyze | gg-223/third_party/glass_goals_devkit/packages/goals_core | 2026-10-19T10:59:50.149Z | 1877e9b5… | 0 | 2 (17 pre-existing issues, zero regressions) |
