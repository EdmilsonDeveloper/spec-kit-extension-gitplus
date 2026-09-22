# GIT+ — a spec-kit extension

GIT+ is a drop-in **fork of spec-kit's official `git` extension** with two additions:

1. **Typed branches (native).** A change **type** is a first-class branch segment:
   `<author>/<type>/<number>-<slug>` — e.g. `edmilson/fix/003-corrige-carga-xp`.
   The `{type}` token lives in `branch_template`, so there is no dry-run/splice hack.
2. **Skill-driven, attribution-free commits.** A new `commit_style: skill` lets you
   name a skill that writes your commit messages. The skill runs in an **isolated
   subagent** (its context never pollutes the main chat), and the commit is executed
   **deterministically by a script** from a message file — so the message is exactly
   what the skill produced, with **no `Co-Authored-By` / AI attribution**.

Everything else from the official git extension is preserved: sequential/timestamp
numbering, templates, branch validation, remote detection, repo initialization, and
the full set of before/after auto-commit lifecycle hooks.

## The two increments

### 1. Typed branch

| Part | Source |
|---|---|
| `<author>` | `{author}` token — `git config user.name` (falls back to email local part) |
| `<type>` | `{type}` token — inferred from the request by `speckit.gitplus.feature` |
| `<number>` | `{number}` token — `branch_numbering` (`sequential` or `timestamp`) |
| `<slug>` | `{slug}` token — generated short name |

The default `branch_template` is `{author}/{type}/{number}-{slug}`. Drop `{type}` for
`{author}/{number}-{slug}`, or set the template to `""` for the plain `{number}-{slug}`.
When the type is empty, the `{type}` token and one adjacent slash are removed, so no
invalid double-slash is produced.

The spec directory (created later by core `/specify`) mirrors the branch's final
`<number>-<slug>` segment, so branch and spec always share the same number — natively,
because GIT+ creates the branch in the `before_specify` hook and core derives the spec
directory from it. (No `/specify` wrap is needed, unlike the earlier preset version.)

### 2. Commit by skill

```yaml
# .specify/extensions/gitplus/gitplus-config.yml
commit_style: skill          # fixed | conventional | skill
commit_skill: "my-committer" # the skill that writes the message
```

Flow of `/speckit.gitplus.commit` (or any enabled auto-commit hook) when
`commit_style: skill`:

1. Collect the diff / `git status`.
2. Resolve the skill (`--skill <name>` argument overrides `commit_skill`).
3. Generate the result, degrading gracefully:
   - **isolated subagent** invoking the skill (preferred) →
   - **skill inline** (no subagent support) →
   - **conventional** message from the diff (no skill support at all).
   The skill returns **one message** or a **multi-commit plan** — N logical commits,
   each with its own message and file set.
4. Write it to disk (never `echo`/`printf` — injection-safe): one temp message file,
   or a temp **plan directory** (a `plan` manifest + one `*.msg` per commit) outside
   the worktree.
5. Run the script, which does the staging and `git commit`(s) itself:
   - one message → `auto-commit.sh <event> --message-file <path>` (`git add .` + one commit);
   - a plan → `auto-commit.sh <event> --plan-dir <dir>` — for each manifest line, in
     order: stage only that line's pathspecs and commit from its message file.
   The transport file/directory is deleted after reading.

**Multi-commit plan.** Each manifest line is `<msg-file><TAB><pathspec>…`. The script
stages exactly those files per commit, so unrelated changes don't get mixed. Anything
the plan doesn't cover is **left uncommitted with a warning** (never silently dropped).
Splitting is per file/pathspec, not per hunk.

**No-attribution guarantee:** the script commits each file's contents verbatim and adds
nothing; the skill/subagent is instructed to emit no attribution lines. Run it via the
command — never re-commit yourself, or your agent's own git path may add attribution.

On-demand commits use the synthetic event `manual`, which always commits (if there are
changes). `conventional`/`skill` with neither a message nor a plan fail loudly rather
than silently using the fixed message.

## Requirements

- spec-kit `>= 0.2.0` with the extension system (`specify extension ...`).
- Git (optional at runtime — GIT+ degrades gracefully when Git is absent).
- Because GIT+ registers the same lifecycle hooks (`before_specify`, etc.) as the
  official `git` extension, **disable the official one** so hooks don't run twice:
  `specify extension disable git`.

## Install (per project)

```bash
# From a local directory (development):
specify extension add --dev /path/to/gitplus
specify extension disable git   # avoid duplicate branch/commit hooks

# Or from a packaged release:
specify extension add gitplus --from https://github.com/EdmilsonDeveloper/spec-kit-extension-gitplus/archive/refs/tags/1.0.0.zip
specify extension disable git
```

Verify with `specify extension info gitplus` and `specify extension list`.

## Configuration

`.specify/extensions/gitplus/gitplus-config.yml` (installed from `config-template.yml`):

- `branch_numbering`: `sequential` | `timestamp`
- `branch_template`: default `{author}/{type}/{number}-{slug}`; tokens `{author}`,
  `{type}`, `{app}`, `{number}`, `{slug}`
- `branch_prefix`: shorthand namespace (expands to `<prefix>/{number}-{slug}`)
- `init_commit_message`: message for `speckit.gitplus.initialize`
- `commit_style`: `fixed` | `conventional` | `skill`
- `commit_skill`: skill name used when `commit_style: skill`
- `auto_commit`: per-event `{enabled, message}` map + `default` toggle

Overrides layer as: extension defaults → `gitplus-config.yml` →
`gitplus-config.local.yml` (gitignored) → `SPECKIT_GITPLUS_*` env vars.

## Commands

| Command | Purpose |
|---|---|
| `speckit.gitplus.feature` | Create `<author>/<type>/<number>-<slug>` branch (type inferred) |
| `speckit.gitplus.commit` | Commit; optionally message-by-skill in a subagent, no attribution |
| `speckit.gitplus.validate` | Validate the current branch's feature naming (typed prefixes OK) |
| `speckit.gitplus.remote` | Detect the GitHub remote URL |
| `speckit.gitplus.initialize` | `git init` + initial commit |

## Publishing

1. Push this directory to its GitHub repo; tag a release (e.g. `1.0.0`).
2. Others install via `specify extension add gitplus --from <repo>/archive/refs/tags/<tag>.zip`.
3. To appear in spec-kit's community catalog, open a PR to `github/spec-kit`
   adding an entry to the extension catalog.

## License

MIT — see `LICENSE`.
