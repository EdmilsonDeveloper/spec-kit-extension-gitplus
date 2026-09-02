# Git Typed Branch — a spec-kit preset

Adds a change **type** to spec-kit feature branches, on top of the official `git`
extension:

- **Branch**: `<author>/<type>/<number>-<slug>` — e.g. `edmilson/fix/20260902-143022-corrige-carga-xp`
- **Spec dir**: `<number>-<slug>` (mirrors the branch's final segment, so both share the same number)

| Part | Source |
|---|---|
| `<author>` | git extension, from `git config user.name` (via `branch_prefix: "{author}"`) |
| `<type>` | inferred from the request by this preset (`feature`, `fix`, `refactor`, …) |
| `<number>` | git extension, per `branch_numbering` (`sequential` or `timestamp`) |
| `<slug>` | git extension short-name generation |

## How it works (and what "dry run" means)

The `git` extension already renders `<author>/<number>-<slug>` and picks the
number. Its `branch_template` has **no `{type}` token**, so the type is spliced in
by a small script (`scripts/{bash,powershell,python}/typed-branch`):

1. **Dry run** — call the extension with `--dry-run`: it *computes and prints* the
   native `<author>/<number>-<slug>` **without creating** any branch or file.
2. **Splice** — insert `/<type>/` after the author segment.
3. **Real run** — call the extension again with `GIT_BRANCH_NAME=<the typed name>`,
   which makes it use that exact name.

The command override is therefore thin (pick the type, call the script); the
mechanics live in the reusable script. A wrap of `speckit.specify` pins the spec
directory to the branch's final `<number>-<slug>` so the numbers always match
(needed under `timestamp`, where an independently recomputed number would differ).

## Why a preset (survives updates)

Direct edits to the extension or core files are wiped on `spec-kit`/extension
update. A preset lives in the resolution layer (`overrides → presets → extension →
core`) and **survives updates**.

## Requirements

- The `git` extension installed (`specify extension add git`).
- In `.specify/extensions/git/git-config.yml`: `branch_prefix: "{author}"` (or a
  `branch_template` ending in `{number}-{slug}`), and `branch_numbering` set to
  `sequential` or `timestamp`.

## Install (per project)

```bash
# From a local directory (development):
specify preset add --dev /path/to/git-typed-branch --priority 5

# Or from a packaged release (no local copy needed):
specify preset add --from https://github.com/EdmilsonDeveloper/spec-kit-preset-git-typed-branch/archive/refs/tags/1.0.0.zip --priority 5
```

`--priority 5` keeps it above the `git` extension (priority 10). Verify with
`specify preset list` and `specify preset resolve speckit.git.feature`. After a
spec-kit update, re-run the install.

## Publishing

1. Push this directory to its own GitHub repo; tag a release (e.g. `1.0.0`).
2. Others install via `specify preset add --from <repo>/archive/refs/tags/<tag>.zip`.
3. To appear in spec-kit's **community** catalog (discovery via
   `specify preset search`), open a PR to `github/spec-kit` adding an entry to
   `presets/catalog.community.json` (fields: `id`, `name`, `version`,
   `description`, `author`, `repository`, `download_url`, `license`, `requires`,
   `provides`, `tags`, timestamps).

## License

MIT — see `LICENSE`.
