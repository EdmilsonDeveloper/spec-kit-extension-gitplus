#!/usr/bin/env bash
# Git extension: auto-commit.sh
# Automatically commit changes after a Spec Kit command completes.
# Checks per-command config keys in gitplus-config.yml before committing.
#
# Usage: auto-commit.sh <event_name> [generated_message]
#        auto-commit.sh <event_name> --message-file <path>
#   e.g.: auto-commit.sh after_specify
#   e.g.: auto-commit.sh after_specify --message-file /tmp/commit-msg.txt  (commit_style: conventional)
#
# --message-file is the preferred way to supply an agent-generated commit
# message: it reads the message from a file instead of a shell argument,
# so message content (which may contain quotes, `$(...)`, backticks, etc.)
# is never interpolated into a shell command line.

set -e

EVENT_NAME="${1:-}"
if [ -z "$EVENT_NAME" ]; then
    echo "Usage: $0 <event_name> [generated_message | --message-file <path> | --plan-dir <dir>]" >&2
    exit 1
fi
shift || true

# Optional second argument: an agent-generated commit message (used when
# commit_style: conventional is configured). Prefer --message-file over
# passing the message directly as a shell argument.
GENERATED_MESSAGE=""
# --plan-dir points at a directory holding a multi-commit plan (see run_commit_plan):
# a "plan" manifest plus one message file per commit. Used by commit_style: skill
# when the skill splits the changes into several logical commits.
PLAN_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --plan-dir)
            PLAN_DIR="${2:-}"
            if [ -z "$PLAN_DIR" ]; then
                echo "[specify] Error: --plan-dir requires a path argument" >&2
                exit 1
            fi
            if [ ! -d "$PLAN_DIR" ]; then
                echo "[specify] Error: plan directory '$PLAN_DIR' not found" >&2
                exit 1
            fi
            shift 2
            ;;
        --message-file)
            _message_file="${2:-}"
            if [ -z "$_message_file" ]; then
                echo "[specify] Error: --message-file requires a path argument" >&2
                exit 1
            fi
            if [ ! -f "$_message_file" ]; then
                echo "[specify] Error: message file '$_message_file' not found" >&2
                exit 1
            fi
            GENERATED_MESSAGE="$(cat "$_message_file")"
            # The message file is a transport-only artifact: its content is
            # now captured above, so remove it immediately. Otherwise, if it
            # was written inside the worktree, it would be picked up as an
            # untracked change by both the "any changes?" check below and by
            # `git add .`, polluting the commit or defeating the no-changes
            # short-circuit even when nothing else changed.
            rm -f "$_message_file"
            shift 2
            ;;
        *)
            GENERATED_MESSAGE="$1"
            shift
            ;;
    esac
done

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_find_project_root() {
    local dir="$1"
    while [ "$dir" != "/" ]; do
        if [ -d "$dir/.specify" ] || [ -d "$dir/.git" ]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

REPO_ROOT=$(_find_project_root "$SCRIPT_DIR") || REPO_ROOT="$(pwd)"
cd "$REPO_ROOT"

# Check if git is available
if ! command -v git >/dev/null 2>&1; then
    echo "[specify] Warning: Git not found; skipped auto-commit" >&2
    exit 0
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "[specify] Warning: Not a Git repository; skipped auto-commit" >&2
    exit 0
fi

# Read per-command config from gitplus-config.yml
_config_file="$REPO_ROOT/.specify/extensions/gitplus/gitplus-config.yml"
_enabled=false
_commit_msg=""
_commit_style="fixed"

if [ -f "$_config_file" ]; then
    # Top-level scalar key: commit_style (fixed | conventional)
    _style_val=$(grep -m1 '^commit_style:' "$_config_file" 2>/dev/null | sed 's/^commit_style:[[:space:]]*//' | sed 's/[[:space:]]\{1,\}#.*$//' | sed 's/[[:space:]]*$//' | sed 's/^["'\'']//' | sed 's/["'\'']*$//' | tr '[:upper:]' '[:lower:]')
    if [ -n "$_style_val" ]; then
        case "$_style_val" in
            fixed|conventional|skill)
                _commit_style="$_style_val"
                ;;
            *)
                echo "[specify] Warning: unknown commit_style '$_style_val' in gitplus-config.yml (expected 'fixed', 'conventional', or 'skill'); defaulting to 'fixed'" >&2
                ;;
        esac
    fi

    # Parse the auto_commit section for this event.
    # Look for auto_commit.<event_name>.enabled and .message
    # Also check auto_commit.default as fallback.
    _in_auto_commit=false
    _in_event=false
    _default_enabled=false

    while IFS= read -r _line; do
        # Detect auto_commit: section
        if echo "$_line" | grep -q '^auto_commit:'; then
            _in_auto_commit=true
            _in_event=false
            continue
        fi

        # Exit auto_commit section on next top-level key
        if $_in_auto_commit && echo "$_line" | grep -Eq '^[a-z]'; then
            break
        fi

        if $_in_auto_commit; then
            # Check default key
            if echo "$_line" | grep -Eq "^[[:space:]]+default:[[:space:]]"; then
                _val=$(echo "$_line" | sed 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
                [ "$_val" = "true" ] && _default_enabled=true
            fi

            # Detect our event subsection
            if echo "$_line" | grep -Eq "^[[:space:]]+${EVENT_NAME}:"; then
                _in_event=true
                continue
            fi

            # Inside our event subsection
            if $_in_event; then
                # Exit on next sibling key (same indent level as event name)
                if echo "$_line" | grep -Eq '^[[:space:]]{2}[a-z]' && ! echo "$_line" | grep -Eq '^[[:space:]]{4}'; then
                    _in_event=false
                    continue
                fi
                if echo "$_line" | grep -Eq '[[:space:]]+enabled:'; then
                    _val=$(echo "$_line" | sed 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
                    [ "$_val" = "true" ] && _enabled=true
                    [ "$_val" = "false" ] && _enabled=false
                fi
                if echo "$_line" | grep -Eq '[[:space:]]+message:'; then
                    # Trim trailing whitespace before stripping the closing quote:
                    # a value like `message: "Done"  ` (trailing spaces after the
                    # quote) would otherwise leave the quote dangling (`Done"  `),
                    # since the closing-quote strip is anchored to end-of-string.
                    # The PowerShell twin .Trim()s first; match it for parity.
                    _commit_msg=$(echo "$_line" | sed 's/^[^:]*:[[:space:]]*//' | sed 's/[[:space:]]*$//' | sed 's/^["'\'']//' | sed 's/["'\'']*$//')
                fi
            fi
        fi
    done < "$_config_file"

    # If event-specific key not found, use default
    if [ "$_enabled" = "false" ] && [ "$_default_enabled" = "true" ]; then
        # Only use default if the event wasn't explicitly set to false
        # Check if event section existed at all
        if ! grep -q "^[[:space:]]*${EVENT_NAME}:" "$_config_file" 2>/dev/null; then
            _enabled=true
        fi
    fi
else
    # No config file — auto-commit disabled by default
    exit 0
fi

# Run a multi-commit plan: a directory holding a "plan" manifest plus one message
# file per commit. Each manifest line is TAB-separated:
#     <message-file>\t<pathspec>[\t<pathspec>...]
# Lines are processed in order; for each, only the listed files are staged and a
# separate commit is made from the message file verbatim (no attribution). Keeping
# multi-line messages in their own files avoids any shell interpolation.
run_commit_plan() {
    local plan_dir="$1"
    local manifest="$plan_dir/plan"
    if [ ! -f "$manifest" ]; then
        echo "[specify] Error: plan manifest '$manifest' not found in plan directory" >&2
        exit 1
    fi
    local made=0
    local line msg_rel msg_file _git_out
    local -a fields paths
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        IFS=$'\t' read -r -a fields <<< "$line"
        msg_rel="${fields[0]}"
        paths=("${fields[@]:1}")
        msg_file="$plan_dir/$msg_rel"
        if [ ! -f "$msg_file" ]; then
            echo "[specify] Error: plan references message file '$msg_rel' which was not found" >&2
            exit 1
        fi
        if [ "${#paths[@]}" -eq 0 ]; then
            echo "[specify] Warning: plan entry '$msg_rel' lists no files; skipping" >&2
            continue
        fi
        git reset -q >/dev/null 2>&1 || true
        if ! _git_out=$(git add -A -- "${paths[@]}" 2>&1); then
            echo "[specify] Error: git add failed for plan entry '$msg_rel': $_git_out" >&2
            exit 1
        fi
        if git diff --cached --quiet 2>/dev/null; then
            echo "[specify] Warning: plan entry '$msg_rel' staged no changes; skipping" >&2
            continue
        fi
        if ! _git_out=$(git commit -q -F "$msg_file" 2>&1); then
            echo "[specify] Error: git commit failed for plan entry '$msg_rel': $_git_out" >&2
            exit 1
        fi
        made=$((made + 1))
    done < "$manifest"

    if [ "$made" -eq 0 ]; then
        echo "[specify] Error: commit plan produced no commits" >&2
        exit 1
    fi

    # Warn about anything the plan did not cover; left uncommitted (non-destructive).
    if ! git diff --quiet HEAD 2>/dev/null || [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
        echo "[specify] Warning: some changes were not covered by the commit plan and remain uncommitted" >&2
    fi

    rm -rf "$plan_dir"
    echo "[OK] Committed $made grouped commit(s) for $EVENT_NAME" >&2
}

# The synthetic "manual" event is a user-initiated /speckit.gitplus.commit run,
# so it always commits regardless of the auto_commit gating above.
if [ "$EVENT_NAME" = "manual" ]; then
    _enabled=true
fi

if [ "$_enabled" != "true" ]; then
    exit 0
fi

# Check if there are changes to commit
if git diff --quiet HEAD 2>/dev/null && git diff --cached --quiet 2>/dev/null && [ -z "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
    echo "[specify] No changes to commit after $EVENT_NAME" >&2
    exit 0
fi

# A multi-commit plan takes precedence over any single message: the skill split
# the changes into several logical commits. run_commit_plan makes each one
# deterministically from its own message file (no attribution) and exits.
if [ -n "$PLAN_DIR" ]; then
    run_commit_plan "$PLAN_DIR"
    exit 0
fi

# In conventional and skill modes, the commit message must be supplied by the
# agent (via --message-file, or --plan-dir for multiple commits); never fall back
# to the fixed message. In skill mode the message was produced by a named skill in
# an isolated subagent; the commit below runs it verbatim, so no AI attribution is
# ever appended here.
if [ "$_commit_style" = "conventional" ] || [ "$_commit_style" = "skill" ]; then
    if [ -n "$GENERATED_MESSAGE" ]; then
        _commit_msg="$GENERATED_MESSAGE"
    else
        echo "[specify] Error: commit_style is '$_commit_style' but no generated commit message or --plan-dir was supplied; aborting commit (pass --message-file <path> or --plan-dir <dir>, or set commit_style: fixed)" >&2
        exit 1
    fi
fi

# Derive a human-readable command name from the event
# e.g., after_specify -> specify, before_plan -> plan
_command_name=$(echo "$EVENT_NAME" | sed 's/^after_//' | sed 's/^before_//')
_phase=$(echo "$EVENT_NAME" | grep -q '^before_' && echo 'before' || echo 'after')

# Use custom message if configured, otherwise default
if [ -z "$_commit_msg" ]; then
    _commit_msg="[Spec Kit] Auto-commit ${_phase} ${_command_name}"
fi

# Stage and commit
_git_out=$(git add . 2>&1) || { echo "[specify] Error: git add failed: $_git_out" >&2; exit 1; }
_git_out=$(git commit -q -m "$_commit_msg" 2>&1) || { echo "[specify] Error: git commit failed: $_git_out" >&2; exit 1; }

echo "[OK] Changes committed ${_phase} ${_command_name}" >&2
