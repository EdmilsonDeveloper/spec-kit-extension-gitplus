#!/usr/bin/env python3
"""git-typed-branch — create a feature branch as <author>/<type>/<number>-<slug>
by wrapping the spec-kit "git" extension's own branch script.

WHAT "DRY RUN" MEANS HERE
The git extension already renders "<author>/<number>-<slug>" and picks the number
(sequential or timestamp). We first call it with --dry-run, which COMPUTES and
PRINTS that name without creating anything. We read it, splice the change type in
as a path segment after the author, then call the extension again FOR REAL through
GIT_BRANCH_NAME (which makes it use our exact name verbatim).

Usage: typed_branch.py --type <type> [--json] [--timestamp] [--dry-run]
                       [--short-name <slug>] "<feature description>"
If GIT_BRANCH_NAME is set in the environment, it is honored verbatim.
"""
import argparse
import json
import os
import subprocess
import sys


def repo_root() -> str:
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        )
        return out.stdout.strip()
    except Exception:
        return os.getcwd()


def numbering_is_timestamp(cfg_path: str) -> bool:
    if not os.path.isfile(cfg_path):
        return False
    with open(cfg_path, encoding="utf-8") as fh:
        for line in fh:
            s = line.strip()
            if s.startswith("branch_numbering:"):
                val = s.split(":", 1)[1].split("#", 1)[0].strip().strip("\"'")
                return val == "timestamp"
    return False


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--type", default="feature")
    ap.add_argument("--short-name", dest="short_name", default="")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--timestamp", action="store_true")
    ap.add_argument("--dry-run", dest="dry_run", action="store_true")
    ap.add_argument("description", nargs=argparse.REMAINDER)
    args = ap.parse_args()
    desc = " ".join(args.description).strip()

    root = repo_root()
    ext = os.path.join(root, ".specify", "extensions", "git",
                       "scripts", "python", "create_new_feature_branch.py")
    if not os.path.isfile(ext):
        print(f"Error: git extension script not found at {ext} "
              f"(is the 'git' extension installed?)", file=sys.stderr)
        return 1

    timestamp = args.timestamp or numbering_is_timestamp(
        os.path.join(root, ".specify", "extensions", "git", "git-config.yml"))

    def ext_cmd(extra):
        cmd = [sys.executable, ext]
        if timestamp:
            cmd.append("--timestamp")
        if args.short_name:
            cmd += ["--short-name", args.short_name]
        cmd += extra
        if desc:
            cmd.append(desc)
        return cmd

    # Escape hatch: explicit exact name bypasses type splicing.
    if os.environ.get("GIT_BRANCH_NAME"):
        extra = ["--json"] if args.json else []
        if args.dry_run:
            extra = ["--dry-run"] + extra
        return subprocess.run(ext_cmd(extra)).returncode

    # Step 1 — native name (no side effects).
    native = subprocess.run(ext_cmd(["--dry-run", "--json"]),
                            capture_output=True, text=True)
    if native.returncode != 0:
        sys.stderr.write(native.stderr)
        return native.returncode
    try:
        native_branch = json.loads(native.stdout)["BRANCH_NAME"]
    except Exception:
        print(f"Error: could not parse BRANCH_NAME from extension dry-run: "
              f"{native.stdout}", file=sys.stderr)
        return 1

    # Step 2 — splice <type> after the author segment.
    if "/" in native_branch:
        author_seg, feature_seg = native_branch.split("/", 1)
        typed_branch = f"{author_seg}/{args.type}/{feature_seg}"
    else:
        typed_branch = f"{args.type}/{native_branch}"

    # Step 3 — create for real (or preview) with our exact name.
    env = dict(os.environ, GIT_BRANCH_NAME=typed_branch)
    extra = ["--json"] if args.json else []
    if args.dry_run:
        extra = ["--dry-run"] + extra
    return subprocess.run(ext_cmd(extra), env=env).returncode


if __name__ == "__main__":
    raise SystemExit(main())
