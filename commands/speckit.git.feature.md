---
description: "Create an <author>/<type>/<number>-<slug> feature branch (type inferred from the request)"
---

# Create Feature Branch (typed: <author>/<type>/<number>-<slug>)

Create and switch to a new git feature branch. The branch shape is
**`<author>/<type>/<number>-<slug>`** (e.g.
`edmilson/fix/20260902-143022-corrige-carga-xp`); the spec directory — created
later by the core `__SPECKIT_COMMAND_SPECIFY__` workflow — mirrors the final
segment **`<number>-<slug>`**, so branch and spec share the same number.

All the mechanics live in the reusable `typed-branch` script; this command only
picks the change type and calls it.

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Explicit branch override (highest priority)

If the user explicitly provided `GIT_BRANCH_NAME`, pass it through unchanged and
skip type inference — the script honors it verbatim.

## Step 1 — Determine the change type

Infer the change type from the feature description. Pick ONE, defaulting to
`feature`:

- `feature` (default), `fix`, `refactor`, `chore`, `docs`, `test`, `perf`,
  `build`, `ci`, `style` — as in Conventional Commits.
- If the user explicitly names a type ("faz um fix", "isso é refactor"), honor it.
  If it is outside the set but a valid lowercase slug, use it anyway.
- Do **not** put the type inside the short name — the script adds it as a segment.

## Step 2 — Generate the short name (slug)

2–4 words, action-noun form, preserve acronyms (OAuth2, API, JWT). Do not include
the type.

## Step 3 — Run the typed-branch script (once)

Run the variant matching this project's script type / platform. It reads
`branch_numbering` from `git-config.yml` itself (sequential vs timestamp) and
prints JSON with `BRANCH_NAME` and `FEATURE_NUM`:

- **Bash**: `.specify/presets/git-typed-branch/scripts/bash/typed-branch.sh --type <type> --json --short-name "<slug>" "<feature description>"`
- **PowerShell**: `.specify/presets/git-typed-branch/scripts/powershell/typed-branch.ps1 -Type <type> -Json -ShortName "<slug>" "<feature description>"`
- **Python**: `python3 .specify/presets/git-typed-branch/scripts/python/typed_branch.py --type <type> --json --short-name "<slug>" "<feature description>"`

Run it **once**. Do not pass `--number`.

## Graceful degradation

If Git is not a repository, the underlying extension skips branch creation with a
warning and still prints `BRANCH_NAME`/`FEATURE_NUM` for reference.

## Output

Report the script's JSON:
- `BRANCH_NAME`: `<author>/<type>/<number>-<slug>`
- `FEATURE_NUM`: the number/timestamp used (equals the spec directory's number)
