---
description: "Create a typed feature branch <author>/<type>/<number>-<slug> (type inferred from the request)"
---

# Create Typed Feature Branch

Create and switch to a new git feature branch for the given specification. GIT+
adds a **change type** as a native template segment, so the branch shape is
**`<author>/<type>/<number>-<slug>`** (e.g. `edmilson/fix/003-corrige-carga-xp`).
This command handles **branch creation only** — the spec directory and files are
created by the core `__SPECKIT_COMMAND_SPECIFY__` workflow, and it derives its
number from this branch's final `<number>-<slug>` segment, so branch and spec
always share the same number.

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Environment Variable Override

If the user explicitly provided `GIT_BRANCH_NAME` (via environment variable,
argument, or in their request), pass it through to the script by setting the
`GIT_BRANCH_NAME` environment variable before invoking the script. When
`GIT_BRANCH_NAME` is set:
- The script uses the exact value as the branch name, bypassing all
  prefix/type/suffix generation (`--type`, `--short-name`, `--number`, and
  `--timestamp` are ignored).
- `FEATURE_NUM` is extracted when the final path segment starts with a numeric or
  timestamp feature marker (for example `042-name`, `fix/042-name`, or
  `jdoe/app/042-name`), otherwise set to the full branch name.

## Prerequisites

- Verify Git is available by running `git rev-parse --is-inside-work-tree 2>/dev/null`
- If Git is not available, warn the user and skip branch creation

## Step 1 — Determine the change type

Infer the change type from the feature description. Pick ONE, defaulting to
`feature`:

- `feature` (default), `fix`, `refactor`, `chore`, `docs`, `test`, `perf`,
  `build`, `ci`, `style` — as in Conventional Commits.
- If the user explicitly names a type ("faz um fix", "isso é refactor"), honor it.
  If it is outside the set but a valid lowercase slug, use it anyway.
- Do **not** put the type inside the short name — the script places it in the
  `{type}` template segment.

## Step 2 — Branch numbering mode

Determine the branch numbering strategy by checking configuration in this order:

1. `.specify/extensions/gitplus/gitplus-config.yml` → `branch_numbering`
2. `.specify/init-options.json` → `feature_numbering` (inherit from core)
3. `.specify/init-options.json` → `branch_numbering` (deprecated, backward compat)
4. Default to `sequential`

## Step 3 — Branch name template

Check `.specify/extensions/gitplus/gitplus-config.yml` for `branch_template`. GIT+
ships a typed default: `{author}/{type}/{number}-{slug}`. The script expands:

- `{author}`: sanitized Git author (`user.name`, falling back to the email local part)
- `{type}`: the change type from Step 1 (omitted, with its adjacent slash, when empty)
- `{app}`: sanitized Spec Kit init directory name
- `{number}`: sequential number or timestamp
- `{slug}`: generated short branch slug

`{slug}` must not appear before `{number}`, and the final path segment must start
with `{number}-`. Do not manually expand the template; the script reads the config
and applies it consistently.

## Step 4 — Generate the short name (slug)

2–4 words, action-noun form (e.g. "add-user-auth", "fix-payment-bug"). Preserve
technical terms and acronyms (OAuth2, API, JWT). Do not include the type.

## Step 5 — Run the script (once)

Run the variant matching this project's platform:

- **Bash**: `.specify/extensions/gitplus/scripts/bash/create-new-feature-branch.sh --type <type> --json --short-name "<short-name>" "<feature description>"`
- **Bash (timestamp)**: `.specify/extensions/gitplus/scripts/bash/create-new-feature-branch.sh --type <type> --json --timestamp --short-name "<short-name>" "<feature description>"`
- **PowerShell**: `.specify/extensions/gitplus/scripts/powershell/create-new-feature-branch.ps1 -Type <type> -Json -ShortName "<short-name>" "<feature description>"`
- **PowerShell (timestamp)**: `.specify/extensions/gitplus/scripts/powershell/create-new-feature-branch.ps1 -Type <type> -Json -Timestamp -ShortName "<short-name>" "<feature description>"`

**IMPORTANT**:
- Do NOT pass `--number` — the script determines the next number automatically.
- Always include the JSON flag so the output can be parsed reliably.
- Run this script only once per feature.
- The JSON output contains `BRANCH_NAME` and `FEATURE_NUM`.

## Graceful Degradation

If Git is not installed or the current directory is not a Git repository:
- Branch creation is skipped with a warning:
  `[specify] Warning: Git repository not detected; skipped branch creation`
- The script still outputs `BRANCH_NAME` and `FEATURE_NUM` for reference.

## Output

The script outputs JSON with:
- `BRANCH_NAME`: the typed branch (e.g. `edmilson/fix/003-corrige-carga-xp`)
- `FEATURE_NUM`: the numeric or timestamp prefix used (equals the spec directory's number)
