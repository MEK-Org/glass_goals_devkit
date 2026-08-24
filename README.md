# glass_goals_devkit

Shared library packages extracted from Glass Goals, published as a devkit for
consumers (e.g. the rusa dashboard) that build against the Glass Goals data
model without needing the private application repository.

The Glass Goals application itself remains private; this repository holds only
the reusable Dart and TypeScript packages.

## Layout

All packages live under [`packages/`](packages/):

### Dart

| Package | Description |
| --- | --- |
| [`goals_types`](packages/goals_types) | Core operation/log types and schema. |
| [`goals_core`](packages/goals_core) | Sync client, model, and query engine. |
| [`goals_ui_core`](packages/goals_ui_core) | Shared UI services, providers, and theming. |
| [`goals_widgets`](packages/goals_widgets) | Reusable goal widgets. |

The Dart packages depend on each other via intra-repo `path:` dependencies, so
they resolve directly within this repository (and within any consumer that adds
this repository as a git dependency or submodule).

### TypeScript

| Package | npm | Description |
| --- | --- | --- |
| [`goals-types`](packages/goals-types) | `@thkp-eng/goals-types` | Operation/log types. |
| [`goals-core`](packages/goals-core) | `@thkp-eng/goals-core` | Sync client and model. |

The TypeScript packages use a pnpm workspace (`workspace:*`) for their
inter-package dependency; see [`pnpm-workspace.yaml`](pnpm-workspace.yaml).

## License

BSD 3-Clause — see [`LICENSE`](LICENSE). Copyright 2025 Matthew Keller.
