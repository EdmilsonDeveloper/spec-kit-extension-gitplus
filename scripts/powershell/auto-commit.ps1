#!/usr/bin/env pwsh
# Git extension: auto-commit.ps1
# Automatically commit changes after a Spec Kit command completes.
# Checks per-command config keys in gitplus-config.yml before committing.
#
# Usage: auto-commit.ps1 <event_name> [generated_message]
#        auto-commit.ps1 <event_name> -MessageFile <path>
#        auto-commit.ps1 <event_name> -PlanDir <dir>   (multi-commit, commit_style: skill)
#   e.g.: auto-commit.ps1 after_specify
#   e.g.: auto-commit.ps1 after_specify -MessageFile C:\temp\commit-msg.txt  (commit_style: conventional)
#
# -MessageFile is the preferred way to supply an agent-generated commit
# message: it reads the message from a file instead of a shell argument,
# so message content (which may contain quotes, $(...), backticks, etc.)
# is never interpolated into a shell command line.
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$EventName,

    # Optional agent-generated commit message (used when commit_style: conventional is configured).
    # Prefer -MessageFile over passing the message directly as a shell argument.
    [Parameter(Position = 1, Mandatory = $false)]
    [string]$GeneratedMessage = "",

    [Parameter(Mandatory = $false)]
    [string]$MessageFile = "",

    # A directory holding a multi-commit plan (see Invoke-CommitPlan): a "plan"
    # manifest plus one message file per commit. Used by commit_style: skill when
    # the skill splits the changes into several logical commits.
    [Parameter(Mandatory = $false)]
    [string]$PlanDir = ""
)
$ErrorActionPreference = 'Stop'

if ($MessageFile) {
    if (-not (Test-Path $MessageFile -PathType Leaf)) {
        Write-Warning "[specify] Error: message file '$MessageFile' not found"
        exit 1
    }
    $GeneratedMessage = (Get-Content -Path $MessageFile -Raw)
    if ($null -ne $GeneratedMessage) {
        $GeneratedMessage = $GeneratedMessage.TrimEnd("`r", "`n")
    }
    # The message file is a transport-only artifact: its content is now
    # captured above, so remove it immediately. Otherwise, if it was written
    # inside the worktree, it would be picked up as an untracked change by
    # both the "any changes?" check below and by `git add .`, polluting the
    # commit or defeating the no-changes short-circuit even when nothing
    # else changed.
    Remove-Item -Path $MessageFile -Force -ErrorAction SilentlyContinue
}

if ($PlanDir) {
    if (-not (Test-Path -LiteralPath $PlanDir -PathType Container)) {
        Write-Warning "[specify] Error: plan directory '$PlanDir' not found"
        exit 1
    }
}

# Run a multi-commit plan: a directory holding a "plan" manifest plus one message
# file per commit. Each manifest line is TAB-separated:
#     <message-file>`t<pathspec>[`t<pathspec>...]
# Lines run in order; only the listed files are staged and a separate commit is
# made from the message file verbatim (no attribution). Mirrors the bash twin.
function Invoke-CommitPlan {
    param(
        [string]$PlanDir,
        [string]$EventName
    )
    $manifest = Join-Path $PlanDir 'plan'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        Write-Warning "[specify] Error: plan manifest '$manifest' not found in plan directory"
        exit 1
    }
    $made = 0
    $savedEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($line in Get-Content -LiteralPath $manifest) {
            if (-not $line -or $line.StartsWith('#')) { continue }
            $fields = $line -split "`t"
            $msgRel = $fields[0]
            if ($fields.Count -gt 1) {
                $paths = @($fields[1..($fields.Count - 1)] | Where-Object { $_ -ne '' })
            } else {
                $paths = @()
            }
            $msgFile = Join-Path $PlanDir $msgRel
            if (-not (Test-Path -LiteralPath $msgFile -PathType Leaf)) {
                Write-Warning "[specify] Error: plan references message file '$msgRel' which was not found"
                exit 1
            }
            if ($paths.Count -eq 0) {
                Write-Warning "[specify] Warning: plan entry '$msgRel' lists no files; skipping"
                continue
            }
            git reset -q 2>$null | Out-Null
            $out = git add -A -- $paths 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "[specify] Error: git add failed for plan entry '$msgRel': $out"
                exit 1
            }
            git diff --cached --quiet 2>$null; $staged = $LASTEXITCODE
            if ($staged -eq 0) {
                Write-Warning "[specify] Warning: plan entry '$msgRel' staged no changes; skipping"
                continue
            }
            $out = git commit -q -F $msgFile 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "[specify] Error: git commit failed for plan entry '$msgRel': $out"
                exit 1
            }
            $made++
        }

        if ($made -eq 0) {
            Write-Warning "[specify] Error: commit plan produced no commits"
            exit 1
        }

        git diff --quiet HEAD 2>$null; $d = $LASTEXITCODE
        $untracked = git ls-files --others --exclude-standard 2>$null
        if ($d -ne 0 -or $untracked) {
            Write-Warning "[specify] Warning: some changes were not covered by the commit plan and remain uncommitted"
        }
    } finally {
        $ErrorActionPreference = $savedEAP
    }

    Remove-Item -LiteralPath $PlanDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "[OK] Committed $made grouped commit(s) for $EventName"
}

function Find-ProjectRoot {
    param([string]$StartDir)
    $current = Resolve-Path $StartDir
    while ($true) {
        foreach ($marker in @('.specify', '.git')) {
            if (Test-Path (Join-Path $current $marker)) {
                return $current
            }
        }
        $parent = Split-Path $current -Parent
        if ($parent -eq $current) { return $null }
        $current = $parent
    }
}

$repoRoot = Find-ProjectRoot -StartDir $PSScriptRoot
if (-not $repoRoot) { $repoRoot = Get-Location }
Set-Location $repoRoot

# Check if git is available
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Warning "[specify] Warning: Git not found; skipped auto-commit"
    exit 0
}

# Temporarily relax ErrorActionPreference so git stderr warnings
# (e.g. CRLF notices on Windows) do not become terminating errors.
$savedEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    git rev-parse --is-inside-work-tree 2>$null | Out-Null
    $isRepo = $LASTEXITCODE -eq 0
} finally {
    $ErrorActionPreference = $savedEAP
}
if (-not $isRepo) {
    Write-Warning "[specify] Warning: Not a Git repository; skipped auto-commit"
    exit 0
}

# Read per-command config from gitplus-config.yml
$configFile = Join-Path $repoRoot ".specify/extensions/gitplus/gitplus-config.yml"
$enabled = $false
$commitMsg = ""
$commitStyle = "fixed"

if (Test-Path $configFile) {
    # Top-level scalar key: commit_style (fixed | conventional | skill)
    foreach ($line in Get-Content $configFile) {
        if ($line -match '^commit_style:\s*(.+)$') {
            $styleVal = (($matches[1] -replace '\s+#.*$', '').Trim()) -replace '^["'']' -replace '["'']$'
            if ($styleVal) {
                $styleVal = $styleVal.ToLower()
                if ($styleVal -eq 'fixed' -or $styleVal -eq 'conventional' -or $styleVal -eq 'skill') {
                    $commitStyle = $styleVal
                } else {
                    Write-Warning "[specify] Warning: unknown commit_style '$styleVal' in gitplus-config.yml (expected 'fixed', 'conventional', or 'skill'); defaulting to 'fixed'"
                }
            }
            break
        }
    }

    # Parse YAML to find auto_commit section
    $inAutoCommit = $false
    $inEvent = $false
    $defaultEnabled = $false

    foreach ($line in Get-Content $configFile) {
        # Detect auto_commit: section
        if ($line -match '^auto_commit:') {
            $inAutoCommit = $true
            $inEvent = $false
            continue
        }

        # Exit auto_commit section on next top-level key
        if ($inAutoCommit -and $line -match '^[a-z]') {
            break
        }

        if ($inAutoCommit) {
            # Check default key
            if ($line -match '^\s+default:\s*(.+)$') {
                $val = $matches[1].Trim().ToLower()
                if ($val -eq 'true') { $defaultEnabled = $true }
            }

            # Detect our event subsection
            if ($line -match "^\s+${EventName}:") {
                $inEvent = $true
                continue
            }

            # Inside our event subsection
            if ($inEvent) {
                # Exit on next sibling key (2-space indent, not 4+)
                if ($line -match '^\s{2}[a-z]' -and $line -notmatch '^\s{4}') {
                    $inEvent = $false
                    continue
                }
                if ($line -match '\s+enabled:\s*(.+)$') {
                    $val = $matches[1].Trim().ToLower()
                    if ($val -eq 'true') { $enabled = $true }
                    if ($val -eq 'false') { $enabled = $false }
                }
                if ($line -match '\s+message:\s*(.+)$') {
                    $commitMsg = $matches[1].Trim() -replace '^["'']' -replace '["'']$'
                }
            }
        }
    }

    # If event-specific key not found, use default
    if (-not $enabled -and $defaultEnabled) {
        $hasEventKey = Select-String -Path $configFile -Pattern "^\s*${EventName}:" -Quiet
        if (-not $hasEventKey) {
            $enabled = $true
        }
    }
} else {
    # No config file -- auto-commit disabled by default
    exit 0
}

# The synthetic "manual" event is a user-initiated /speckit.gitplus.commit run,
# so it always commits regardless of the auto_commit gating above.
if ($EventName -eq 'manual') {
    $enabled = $true
}

if (-not $enabled) {
    exit 0
}

# Check if there are changes to commit
# Relax ErrorActionPreference so CRLF warnings on stderr do not terminate.
$savedEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    git diff --quiet HEAD 2>$null; $d1 = $LASTEXITCODE
    git diff --cached --quiet 2>$null; $d2 = $LASTEXITCODE
    $untracked = git ls-files --others --exclude-standard 2>$null
} finally {
    $ErrorActionPreference = $savedEAP
}

if ($d1 -eq 0 -and $d2 -eq 0 -and -not $untracked) {
    Write-Host "[specify] No changes to commit after $EventName" -ForegroundColor DarkGray
    exit 0
}

# A multi-commit plan takes precedence over any single message: the skill split
# the changes into several logical commits. Invoke-CommitPlan makes each one
# deterministically from its own message file (no attribution) and exits.
if ($PlanDir) {
    Invoke-CommitPlan -PlanDir $PlanDir -EventName $EventName
    exit 0
}

# In conventional and skill modes, the commit message must be supplied by the
# agent (via the GeneratedMessage argument / -MessageFile, or -PlanDir for
# multiple commits); never fall back to the fixed message. In skill mode the
# message was produced by a named skill in an isolated subagent; the commit below
# runs it verbatim, so no AI attribution is ever appended here.
if ($commitStyle -eq 'conventional' -or $commitStyle -eq 'skill') {
    if ($GeneratedMessage) {
        $commitMsg = $GeneratedMessage
    } else {
        Write-Warning "[specify] Error: commit_style is '$commitStyle' but no generated commit message or -PlanDir was supplied; aborting auto-commit (pass -MessageFile <path> or -PlanDir <dir>, or set commit_style: fixed)"
        exit 1
    }
}

# Derive a human-readable command name from the event
$commandName = $EventName -replace '^after_', '' -replace '^before_', ''
$phase = if ($EventName -match '^before_') { 'before' } else { 'after' }

# Use custom message if configured, otherwise default
if (-not $commitMsg) {
    $commitMsg = "[Spec Kit] Auto-commit $phase $commandName"
}

# Stage and commit
# Relax ErrorActionPreference so CRLF warnings on stderr do not terminate,
# while still allowing redirected error output to be captured for diagnostics.
$savedEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $out = git add . 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "git add failed: $out" }
    $out = git commit -q -m $commitMsg 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "git commit failed: $out" }
} catch {
    Write-Warning "[specify] Error: $_"
    exit 1
} finally {
    $ErrorActionPreference = $savedEAP
}

Write-Host "[OK] Changes committed $phase $commandName"
