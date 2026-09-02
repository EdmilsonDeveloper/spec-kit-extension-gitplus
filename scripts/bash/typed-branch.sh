#!/usr/bin/env bash
# git-typed-branch — create a feature branch as <author>/<type>/<number>-<slug>
# by wrapping the spec-kit "git" extension's own branch script.
#
# WHAT "DRY RUN" MEANS HERE
# The git extension already knows how to render "<author>/<number>-<slug>" and how
# to pick the number (sequential or timestamp, scanning specs/ and branches). We
# first call it with --dry-run, which makes it COMPUTE and PRINT that name WITHOUT
# creating any branch or file. We read the computed name, splice the change type
# in as a path segment after the author, then call the extension again FOR REAL
# through GIT_BRANCH_NAME (which tells it to use our exact name verbatim).
#
# Usage: typed-branch.sh --type <type> [--json] [--timestamp] [--dry-run]
#                        [--short-name <slug>] "<feature description>"
# If GIT_BRANCH_NAME is set in the environment, it is honored verbatim (the type
# is not spliced) — same escape hatch the extension offers.
set -e

TYPE="feature"
SHORT_NAME=""
JSON=false
TIMESTAMP=false
DRY_RUN=false
DESC_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --type)       TYPE="$2"; shift 2 ;;
    --short-name) SHORT_NAME="$2"; shift 2 ;;
    --json)       JSON=true; shift ;;
    --timestamp)  TIMESTAMP=true; shift ;;
    --dry-run)    DRY_RUN=true; shift ;;
    *)            DESC_ARGS+=("$1"); shift ;;
  esac
done
DESC="${DESC_ARGS[*]}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
EXT="$REPO_ROOT/.specify/extensions/git/scripts/bash/create-new-feature-branch.sh"
if [ ! -f "$EXT" ]; then
  echo "Error: git extension script not found at $EXT (is the 'git' extension installed?)" >&2
  exit 1
fi

# Inherit the numbering mode from the extension config unless --timestamp forces it.
CFG="$REPO_ROOT/.specify/extensions/git/git-config.yml"
if [ "$TIMESTAMP" != true ] && [ -f "$CFG" ]; then
  numbering="$(grep -E '^[[:space:]]*branch_numbering:' "$CFG" | head -1 \
    | sed -E 's/.*:[[:space:]]*//; s/[[:space:]]*#.*$//; s/["'"'"' ]//g')"
  [ "$numbering" = "timestamp" ] && TIMESTAMP=true
fi

TS_FLAG=();   [ "$TIMESTAMP" = true ] && TS_FLAG=(--timestamp)
SN_FLAG=();   [ -n "$SHORT_NAME" ]    && SN_FLAG=(--short-name "$SHORT_NAME")
OUT_JSON=();  [ "$JSON" = true ]      && OUT_JSON=(--json)
DRY_FLAG=();  [ "$DRY_RUN" = true ]   && DRY_FLAG=(--dry-run)

# Escape hatch: an explicit exact name bypasses type splicing entirely.
if [ -n "${GIT_BRANCH_NAME:-}" ]; then
  exec env GIT_BRANCH_NAME="$GIT_BRANCH_NAME" "$EXT" "${DRY_FLAG[@]}" "${OUT_JSON[@]}" "${TS_FLAG[@]}" "${SN_FLAG[@]}" "$DESC"
fi

# Step 1 — compute the extension's native "<author>/<number>-<slug>" (no side effects).
native_json="$("$EXT" --dry-run --json "${TS_FLAG[@]}" "${SN_FLAG[@]}" "$DESC")"
native_branch="$(printf '%s' "$native_json" | sed -E 's/.*"BRANCH_NAME":"([^"]*)".*/\1/')"
if [ -z "$native_branch" ]; then
  echo "Error: could not parse BRANCH_NAME from extension dry-run: $native_json" >&2
  exit 1
fi

# Step 2 — splice <type> in after the author segment.
if printf '%s' "$native_branch" | grep -q '/'; then
  author_seg="${native_branch%%/*}"
  feature_seg="${native_branch#*/}"
  typed_branch="${author_seg}/${TYPE}/${feature_seg}"
else
  typed_branch="${TYPE}/${native_branch}"
fi

# Step 3 — create for real (or preview) with our exact name.
exec env GIT_BRANCH_NAME="$typed_branch" "$EXT" "${DRY_FLAG[@]}" "${OUT_JSON[@]}" "${TS_FLAG[@]}" "${SN_FLAG[@]}" "$DESC"
