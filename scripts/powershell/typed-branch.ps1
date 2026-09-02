#!/usr/bin/env pwsh
# git-typed-branch — create a feature branch as <author>/<type>/<number>-<slug>
# by wrapping the spec-kit "git" extension's own branch script.
#
# WHAT "DRY RUN" MEANS HERE
# The git extension already renders "<author>/<number>-<slug>" and picks the number
# (sequential or timestamp). We first call it with -DryRun, which COMPUTES and
# PRINTS that name without creating anything. We read it, splice the change type in
# as a path segment after the author, then call the extension again FOR REAL through
# GIT_BRANCH_NAME (which makes it use our exact name verbatim).
#
# Usage: typed-branch.ps1 -Type <type> [-Json] [-Timestamp] [-DryRun]
#                         [-ShortName <slug>] "<feature description>"
# If $env:GIT_BRANCH_NAME is set, it is honored verbatim.
param(
    [string]$Type = "feature",
    [string]$ShortName = "",
    [switch]$Json,
    [switch]$Timestamp,
    [switch]$DryRun,
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Description
)
$ErrorActionPreference = "Stop"
$desc = ($Description -join " ").Trim()

$root = (git rev-parse --show-toplevel 2>$null)
if (-not $root) { $root = (Get-Location).Path }
$ext = Join-Path $root ".specify/extensions/git/scripts/powershell/create-new-feature-branch.ps1"
if (-not (Test-Path $ext)) {
    Write-Error "git extension script not found at $ext (is the 'git' extension installed?)"
    exit 1
}

# Inherit numbering mode from the extension config unless -Timestamp forces it.
$ts = [bool]$Timestamp
if (-not $ts) {
    $cfg = Join-Path $root ".specify/extensions/git/git-config.yml"
    if (Test-Path $cfg) {
        $line = Select-String -Path $cfg -Pattern '^\s*branch_numbering:' | Select-Object -First 1
        if ($line -and ($line.Line -replace '.*:\s*', '' -replace '\s*#.*$', '' -replace '["'' ]', '') -eq 'timestamp') {
            $ts = $true
        }
    }
}

function Invoke-Ext([string[]]$extra) {
    $a = @()
    if ($ts) { $a += "-Timestamp" }
    if ($ShortName) { $a += @("-ShortName", $ShortName) }
    $a += $extra
    if ($desc) { $a += $desc }
    & $ext @a
}

# Escape hatch: explicit exact name bypasses type splicing.
if ($env:GIT_BRANCH_NAME) {
    $extra = @(); if ($Json) { $extra += "-Json" }; if ($DryRun) { $extra = @("-DryRun") + $extra }
    Invoke-Ext $extra
    exit $LASTEXITCODE
}

# Step 1 — native "<author>/<number>-<slug>" (no side effects).
$nativeJson = Invoke-Ext @("-DryRun", "-Json") | Out-String
try { $nativeBranch = ($nativeJson | ConvertFrom-Json).BRANCH_NAME }
catch { Write-Error "could not parse BRANCH_NAME from extension dry-run: $nativeJson"; exit 1 }

# Step 2 — splice <type> after the author segment.
if ($nativeBranch -like "*/*") {
    $author, $rest = $nativeBranch -split "/", 2
    $typedBranch = "$author/$Type/$rest"
} else {
    $typedBranch = "$Type/$nativeBranch"
}

# Step 3 — create for real (or preview) with our exact name.
$env:GIT_BRANCH_NAME = $typedBranch
$extra = @(); if ($Json) { $extra += "-Json" }; if ($DryRun) { $extra = @("-DryRun") + $extra }
Invoke-Ext $extra
exit $LASTEXITCODE
