#!/usr/bin/env python3
"""Git extension: auto_commit.py

Automatically commit changes after a Spec Kit command completes.
Python port of ``auto-commit.sh`` / ``auto-commit.ps1``.
Checks per-command config keys in gitplus-config.yml before committing.

Usage: auto_commit.py <event_name> [generated_message]
       auto_commit.py <event_name> --message-file <path>
  e.g.: auto_commit.py after_specify
  e.g.: auto_commit.py after_specify --message-file /tmp/commit-msg.txt  (commit_style: conventional | skill)

--message-file is the preferred way to supply an agent-generated commit
message: it reads the message from a file instead of a shell argument, so
message content (which may contain quotes, ``$(...)``, backticks, etc.) is
never interpolated into a shell command line.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
from pathlib import Path


def _find_project_root(start: Path) -> Path | None:
    current = start
    while True:
        if (current / ".specify").is_dir() or (current / ".git").exists():
            return current
        if current.parent == current:
            return None
        current = current.parent


def _value_after_colon(line: str) -> str:
    return re.sub(r"^[^:]*:\s*", "", line)


def _strip_quotes(value: str) -> str:
    """Strip surrounding whitespace, then one leading quote and all trailing quotes.

    Trimming first matters when the YAML value has trailing whitespace after a
    closing quote (``message: "Done"  ``): stripping quotes anchored to the end
    of string would leave the closing quote dangling (``Done"  ``) because the
    quote is no longer at the end. The PowerShell twin ``.Trim()``s before
    stripping, so trim here too to keep all three script variants in parity.
    """
    value = value.strip()
    value = re.sub(r"^[\"']", "", value)
    return re.sub(r"[\"']*$", "", value)


def _parse_auto_commit_config(
    config_file: Path, event_name: str
) -> tuple[bool, str]:
    """Parse the auto_commit section for this event, mirroring the bash line parser.

    Returns (enabled, commit_msg). Looks for auto_commit.<event_name>.enabled
    and .message, with auto_commit.default as fallback.
    """
    enabled = False
    commit_msg = ""
    default_enabled = False
    in_auto_commit = False
    in_event = False

    try:
        content = config_file.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        # Unreadable or non-UTF-8 config is treated like a missing one:
        # auto-commit stays disabled instead of crashing with a traceback.
        return False, ""
    for record in content.splitlines(keepends=True):
        if not record.endswith("\n"):
            break
        line = record[:-1]
        if line.startswith("auto_commit:"):
            in_auto_commit = True
            in_event = False
            continue

        # Exit auto_commit section on next top-level key
        if in_auto_commit and re.match(r"^[a-z]", line):
            break

        if not in_auto_commit:
            continue

        if re.match(r"^\s+default:\s", line):
            value = re.sub(r"\s", "", _value_after_colon(line)).lower()
            if value == "true":
                default_enabled = True

        if re.match(rf"^\s+{re.escape(event_name)}:", line):
            in_event = True
            continue

        if in_event:
            # Exit on next sibling key (same indent level as event name)
            if re.match(r"^\s{2}[a-z]", line) and not re.match(r"^\s{4}", line):
                in_event = False
                continue
            if re.search(r"\s+enabled:", line):
                value = re.sub(r"\s", "", _value_after_colon(line)).lower()
                if value == "true":
                    enabled = True
                elif value == "false":
                    enabled = False
            if re.search(r"\s+message:", line):
                commit_msg = _strip_quotes(_value_after_colon(line))

    # If event-specific key not found, use default — but only if the event
    # section didn't exist at all (an explicit false must win).
    if not enabled and default_enabled:
        if not re.search(rf"^\s*{re.escape(event_name)}:", content, re.MULTILINE):
            enabled = True

    return enabled, commit_msg


def _read_commit_style(config_file: Path) -> str:
    """Read the top-level commit_style scalar (fixed | conventional | skill).

    Mirrors the bash twin: the first ``commit_style:`` line wins, an unknown
    value warns and falls back to 'fixed', and an absent/empty value defaults
    to 'fixed'.
    """
    try:
        content = config_file.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return "fixed"
    for line in content.splitlines():
        if line.startswith("commit_style:"):
            raw = re.sub(r"\s+#.*$", "", _value_after_colon(line))
            value = _strip_quotes(raw).lower()
            if not value:
                return "fixed"
            if value in ("fixed", "conventional", "skill"):
                return value
            print(
                f"[specify] Warning: unknown commit_style '{value}' in gitplus-config.yml "
                "(expected 'fixed', 'conventional', or 'skill'); defaulting to 'fixed'",
                file=sys.stderr,
            )
            return "fixed"
    return "fixed"


def _read_generated_message(rest: list[str]) -> tuple[str, str, int]:
    """Parse the optional agent-generated message from the args after the event.

    Accepts ``--message-file <path>`` (single commit, preferred), ``--plan-dir
    <dir>`` (a multi-commit plan), or a raw message as a positional argument,
    mirroring the bash/PowerShell twins. Returns (generated_message, plan_dir,
    exit_code); exit_code is non-zero on a usage error and the caller should
    return it immediately. The message file is transport-only, so it is deleted
    immediately after being read.
    """
    generated_message = ""
    plan_dir = ""
    i = 0
    while i < len(rest):
        if rest[i] == "--plan-dir":
            plan_dir = rest[i + 1] if i + 1 < len(rest) else ""
            if not plan_dir:
                print(
                    "[specify] Error: --plan-dir requires a path argument",
                    file=sys.stderr,
                )
                return "", "", 1
            if not Path(plan_dir).is_dir():
                print(
                    f"[specify] Error: plan directory '{plan_dir}' not found",
                    file=sys.stderr,
                )
                return "", "", 1
            i += 2
        elif rest[i] == "--message-file":
            message_file = rest[i + 1] if i + 1 < len(rest) else ""
            if not message_file:
                print(
                    "[specify] Error: --message-file requires a path argument",
                    file=sys.stderr,
                )
                return "", "", 1
            path = Path(message_file)
            if not path.is_file():
                print(
                    f"[specify] Error: message file '{message_file}' not found",
                    file=sys.stderr,
                )
                return "", "", 1
            try:
                generated_message = path.read_text(encoding="utf-8").rstrip("\r\n")
            except (OSError, UnicodeDecodeError):
                print(
                    f"[specify] Error: could not read message file '{message_file}'",
                    file=sys.stderr,
                )
                return "", 1
            # Transport-only artifact: its content is captured, so remove it
            # immediately. Otherwise, if it was written inside the worktree, it
            # would be picked up as an untracked change by both the "any
            # changes?" check and by `git add .`, polluting the commit or
            # defeating the no-changes short-circuit even when nothing else
            # changed.
            try:
                path.unlink()
            except OSError:
                pass
            i += 2
        else:
            generated_message = rest[i]
            i += 1
    return generated_message, plan_dir, 0


def _run_commit_plan(repo_root: Path, plan_dir: Path, event_name: str) -> int:
    """Run a multi-commit plan: a directory holding a "plan" manifest plus one
    message file per commit. Each manifest line is TAB-separated:
        <message-file>\t<pathspec>[\t<pathspec>...]
    Lines run in order; only the listed files are staged and a separate commit is
    made from the message file verbatim (no attribution). Mirrors the bash twin.
    """
    manifest = plan_dir / "plan"
    if not manifest.is_file():
        print(
            f"[specify] Error: plan manifest '{manifest}' not found in plan directory",
            file=sys.stderr,
        )
        return 1

    def _run(*args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *args], cwd=repo_root, capture_output=True, text=True
        )

    def _quiet(*args: str) -> bool:
        return _run(*args).returncode == 0

    try:
        manifest_lines = manifest.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        print(f"[specify] Error: could not read plan manifest '{manifest}'", file=sys.stderr)
        return 1

    made = 0
    for line in manifest_lines:
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        msg_rel = fields[0]
        paths = [p for p in fields[1:] if p != ""]
        msg_file = plan_dir / msg_rel
        if not msg_file.is_file():
            print(
                f"[specify] Error: plan references message file '{msg_rel}' which was not found",
                file=sys.stderr,
            )
            return 1
        if not paths:
            print(
                f"[specify] Warning: plan entry '{msg_rel}' lists no files; skipping",
                file=sys.stderr,
            )
            continue
        _run("reset", "-q")
        add = _run("add", "-A", "--", *paths)
        if add.returncode != 0:
            output = (add.stdout + add.stderr).strip()
            print(
                f"[specify] Error: git add failed for plan entry '{msg_rel}': {output}",
                file=sys.stderr,
            )
            return 1
        if _quiet("diff", "--cached", "--quiet"):
            print(
                f"[specify] Warning: plan entry '{msg_rel}' staged no changes; skipping",
                file=sys.stderr,
            )
            continue
        commit = _run("commit", "-q", "-F", str(msg_file))
        if commit.returncode != 0:
            output = (commit.stdout + commit.stderr).strip()
            print(
                f"[specify] Error: git commit failed for plan entry '{msg_rel}': {output}",
                file=sys.stderr,
            )
            return 1
        made += 1

    if made == 0:
        print("[specify] Error: commit plan produced no commits", file=sys.stderr)
        return 1

    untracked = _run("ls-files", "--others", "--exclude-standard").stdout.strip()
    if not _quiet("diff", "--quiet", "HEAD") or untracked:
        print(
            "[specify] Warning: some changes were not covered by the commit plan "
            "and remain uncommitted",
            file=sys.stderr,
        )

    shutil.rmtree(plan_dir, ignore_errors=True)
    print(f"[OK] Committed {made} grouped commit(s) for {event_name}", file=sys.stderr)
    return 0


def main(argv: list[str]) -> int:
    event_name = argv[0] if argv else ""
    if not event_name:
        print(
            f"Usage: {Path(sys.argv[0]).name} <event_name> "
            "[generated_message | --message-file <path> | --plan-dir <dir>]",
            file=sys.stderr,
        )
        return 1

    # Optional second argument: an agent-generated commit message (used when
    # commit_style is 'conventional' or 'skill'). Prefer --message-file over
    # passing the message directly as a shell argument.
    generated_message, plan_dir, arg_error = _read_generated_message(argv[1:])
    if arg_error:
        return arg_error

    script_dir = Path(__file__).resolve().parent
    repo_root = _find_project_root(script_dir) or Path.cwd()

    if shutil.which("git") is None:
        print("[specify] Warning: Git not found; skipped auto-commit", file=sys.stderr)
        return 0

    probe = subprocess.run(
        ["git", "rev-parse", "--is-inside-work-tree"],
        cwd=repo_root,
        capture_output=True,
        text=True,
    )
    if probe.returncode != 0:
        print(
            "[specify] Warning: Not a Git repository; skipped auto-commit",
            file=sys.stderr,
        )
        return 0

    config_file = repo_root / ".specify" / "extensions" / "gitplus" / "gitplus-config.yml"
    if not config_file.is_file():
        # No config file — auto-commit disabled by default
        return 0

    commit_style = _read_commit_style(config_file)
    enabled, commit_msg = _parse_auto_commit_config(config_file, event_name)

    # The synthetic "manual" event is a user-initiated /speckit.gitplus.commit
    # run, so it always commits regardless of the auto_commit gating above.
    if event_name == "manual":
        enabled = True

    if not enabled:
        return 0

    # Check if there are changes to commit
    def _quiet(*args: str) -> bool:
        return (
            subprocess.run(
                ["git", *args], cwd=repo_root, capture_output=True, text=True
            ).returncode
            == 0
        )

    untracked = subprocess.run(
        ["git", "ls-files", "--others", "--exclude-standard"],
        cwd=repo_root,
        capture_output=True,
        text=True,
    ).stdout.strip()
    if _quiet("diff", "--quiet", "HEAD") and _quiet("diff", "--cached", "--quiet") and not untracked:
        print(f"[specify] No changes to commit after {event_name}", file=sys.stderr)
        return 0

    # A multi-commit plan takes precedence over any single message: the skill
    # split the changes into several logical commits. _run_commit_plan makes each
    # one deterministically from its own message file (no attribution).
    if plan_dir:
        return _run_commit_plan(repo_root, Path(plan_dir), event_name)

    # In conventional and skill modes, the commit message must be supplied by the
    # agent (via --message-file, or --plan-dir for multiple commits); never fall
    # back to the fixed message. In skill mode the message was produced by a named
    # skill in an isolated subagent; the commit below runs it verbatim, so no AI
    # attribution is ever appended here.
    if commit_style in ("conventional", "skill"):
        if generated_message:
            commit_msg = generated_message
        else:
            print(
                f"[specify] Error: commit_style is '{commit_style}' but no generated "
                "commit message or --plan-dir was supplied; aborting commit (pass "
                "--message-file <path> or --plan-dir <dir>, or set commit_style: fixed)",
                file=sys.stderr,
            )
            return 1

    # Derive a human-readable command name from the event
    # e.g., after_specify -> specify, before_plan -> plan
    command_name = re.sub(r"^(after_|before_)", "", event_name)
    phase = "before" if event_name.startswith("before_") else "after"

    if not commit_msg:
        commit_msg = f"[Spec Kit] Auto-commit {phase} {command_name}"

    steps = [
        (["git", "add", "."], "git add"),
        (["git", "commit", "-q", "-m", commit_msg], "git commit"),
    ]
    for cmd, label in steps:
        result = subprocess.run(cmd, cwd=repo_root, capture_output=True, text=True)
        if result.returncode != 0:
            output = (result.stdout + result.stderr).strip()
            print(f"[specify] Error: {label} failed: {output}", file=sys.stderr)
            return 1

    print(f"[OK] Changes committed {phase} {command_name}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
