---
description: "Commit changes; optionally via a named skill in an isolated subagent, committed deterministically without AI attribution"
---

# GIT+ Commit

Stage and commit changes. GIT+ can generate the commit message(s) with a **named
skill running in an isolated subagent** (so the skill's verbose context never leaks
into the main chat), then run the actual commit(s) **deterministically from files** —
so each message is exactly what the skill produced, with **no `Co-Authored-By` or
other AI attribution** ever appended. The skill may also **split the changes into
several logical commits**, each with its own message and file set.

## When this runs

- **As a lifecycle hook** (e.g. `after_specify`, `before_plan`): the event name is
  the hook that triggered it. Whether it commits depends on the `auto_commit`
  config for that event.
- **On demand** (`/speckit.gitplus.commit [--skill <name>]`): use the synthetic
  event name **`manual`**, which always commits (subject to there being changes).
  An explicit `--skill <name>` overrides the configured `commit_skill` for this run.

## Step 1 — Determine the event name

From the hook context, or `manual` for an on-demand invocation.

## Step 2 — Read the commit configuration

From `.specify/extensions/gitplus/gitplus-config.yml`:
- `commit_style`: `fixed` | `conventional` | `skill`
- `commit_skill`: the skill name used when `commit_style: skill` (an explicit
  `--skill <name>` argument overrides it)

## Step 3 — Produce the commit message

### `fixed` (or config absent)
Do not generate a message. Run the script with just the event name; it uses the
configured/static message.

### `conventional`
Inspect the changes (`git diff` / `git status` since the last commit) and generate
a single-line [Conventional Commit](https://www.conventionalcommits.org/) message
(`type(scope): subject`, e.g. `feat: add OAuth specification`). Then go to Step 4.

### `skill`
Resolve the skill name (`--skill` argument > `commit_skill` config). Delegating to
the skill can yield **either one commit message or a multi-commit plan** — the
skill may split the changes into several logical commits, each with its own message
and set of files (e.g. a commit-message skill that emits a message plus a `git add`
per commit). Support both outcomes, degrading gracefully to what the agent supports:

1. **Isolated subagent (preferred).** If you can spawn an isolated subagent (e.g.
   a Task/Agent tool), spawn one and instruct it to:
   - invoke the skill named `<commit_skill>`,
   - give it the staged/working changes as context (the diff and `git status`),
   - **return ONLY the result** — either the final commit message text, or, when
     it splits the work, an ordered list of commits, each as `{ message, files }`.
     No preamble, no explanation, and **no attribution lines** (`Co-Authored-By`,
     "Generated with …", etc.).
   Use only what it returns. This keeps the skill's context out of the main chat.
2. **Skill without a subagent.** If you support skills but cannot spawn a
   subagent, invoke the skill named `<commit_skill>` inline, still using only its
   returned message/plan (no attribution).
3. **No skill mechanism.** If you cannot invoke the named skill at all, fall back
   to the `conventional` behavior above (a single Conventional Commit from the
   diff). Note in your response that the skill was unavailable.

Then go to Step 4 — the single-commit path for one message, or the multi-commit
path for a plan.

## Step 4 — Write the message/plan to disk (injection-safe)

**Never interpolate a generated message into a shell command string** — it may
contain quotes, `$(...)`, or backticks. Always write messages to files with your
file-editing tool (**not** a shell `echo`/`printf`), with **no attribution lines**.

**Single commit** — write the message to one temporary file. The script deletes it
after reading.

**Multiple commits (plan)** — create a temporary directory **outside the working
tree** (so its own files are never staged) containing:
- one message file per commit, e.g. `1.msg`, `2.msg`, … (full message, no attribution);
- a `plan` manifest, one line per commit **in order**, TAB-separated:
  `<message-file><TAB><pathspec>[<TAB><pathspec>…]` — the pathspecs are the files
  that commit should stage (git pathspecs, relative to the repo root).

Example `plan`:
```
1.msg	src/auth.py	src/auth_test.py
2.msg	docs/auth.md
```
The script processes each line in order: stages only that line's files, commits from
its message file, and moves on. It warns about any changes left uncovered and
deletes the plan directory afterward.

## Step 5 — Run the commit script

- **Bash**: `.specify/extensions/gitplus/scripts/bash/auto-commit.sh <event_name> [--message-file <path> | --plan-dir <dir>]`
- **PowerShell**: `.specify/extensions/gitplus/scripts/powershell/auto-commit.ps1 <event_name> [-MessageFile <path> | -PlanDir <dir>]`

- `fixed`: pass only the event name.
- `conventional`, or `skill` with one message: pass `--message-file <path>`.
- `skill` with a plan: pass `--plan-dir <dir>`.

The script performs the staging and the `git commit`(s) itself, so each recorded
message is exactly its file's contents — nothing is added by you.

## No-attribution guarantee

Each commit is executed by the script from its message file verbatim. As long as
the skill/subagent output and the files contain no attribution lines, the commits
carry none. **Never** re-run a commit yourself with your own git-commit path, which
may append attribution.

## Graceful Degradation

- Git unavailable or not a repository: skips with a warning.
- No config file: skips (disabled by default).
- No changes to commit: skips with a message.
- `commit_style: conventional` or `skill` but no message and no `--plan-dir`
  supplied: the script fails with a clear error instead of using the fixed format.
- A plan whose pathspecs miss some changes: those changes are left uncommitted with
  a warning (nothing is silently dropped).
