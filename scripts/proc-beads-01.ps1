<#
.SYNOPSIS
    Export open/in-progress Beads tasks to ai-prompts\bead-tasks.md.

.DESCRIPTION
    Reads .beads\issues.jsonl, filters by active status, sorts by priority then
    blocked-state, and writes one formatted line per task.

    When -Label is supplied, only tasks whose title contains "[Label]" are written.
    When -Label is omitted, all open/in-progress tasks are written regardless of label.

.PARAMETER Label
    Optional label prefix to filter on (matched as "[Label]" in the issue title).
    Example: "voice2text", "cache", "app-013"
    Omit to export every open/in-progress task.

.EXAMPLE
    pwsh -File .\scripts\proc-beads-01.ps1 -Label "voice2text"

.EXAMPLE
    pwsh -File .\scripts\proc-beads-01.ps1 -Label "cache"

.EXAMPLE
    pwsh -File .\scripts\proc-beads-01.ps1
#>
[CmdletBinding()]
param(
    [Parameter(HelpMessage = "Label to filter on, e.g. 'voice2text' or 'cache'. Omit for all tasks.")]
    [string]$Label = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Path resolution -----------------------------------------------------------
$repoRoot   = Split-Path -Parent $PSScriptRoot          # scripts\ -> repo root
$beadsFile  = Join-Path $repoRoot ".beads\issues.jsonl"
$outputFile = Join-Path $repoRoot "ai-prompts\bead-tasks.md"

if (-not (Test-Path $beadsFile)) {
    Write-Error "Beads data store not found: $beadsFile"
    exit 1
}

# -- Load all issues (last-write-wins delta model) ----------------------------
$issueMap = @{}
Get-Content $beadsFile | Where-Object { $_.Trim() } | ForEach-Object {
    try {
        $rec = $_ | ConvertFrom-Json
        if (-not $issueMap.Contains($rec.id)) {
            $issueMap[$rec.id] = $rec
        } else {
            $rec.PSObject.Properties | ForEach-Object {
                $issueMap[$rec.id] | Add-Member -NotePropertyName $_.Name -NotePropertyValue $_.Value -Force
            }
        }
    } catch { }
}

# -- Build open-id lookup for blocked detection (full set) --------------------
$openIdSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($issue in $issueMap.Values) {
    if ($issue.status -eq "open" -or $issue.status -eq "in-progress") {
        [void]$openIdSet.Add($issue.id)
    }
}

# -- Filter: open or in-progress, optionally matching label ------------------
# NOTE: -like uses wildcard syntax where [ ] are metacharacters, so we use
# IndexOf with OrdinalIgnoreCase for a safe literal substring match.
$filtered = @($issueMap.Values | Where-Object {
    if ($_.status -ne "open" -and $_.status -ne "in-progress") { return $false }
    if ($Label) {
        return $_.title.IndexOf("[$Label]", [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    }
    return $true
})

# -- Annotate each filtered issue with blocked flag and blocker list ----------
$annotated = $filtered | ForEach-Object {
    $issue = $_
    $blockerIds = @()

    if ($issue.dependencies) {
        foreach ($dep in $issue.dependencies) {
            if ($dep.type -eq "blocks" -and $openIdSet.Contains($dep.depends_on_id)) {
                $blockerIds += $dep.depends_on_id
            }
        }
    }

    [PSCustomObject]@{
        Issue      = $issue
        IsBlocked  = ($blockerIds.Count -gt 0)
        BlockerIds = $blockerIds
    }
}

# -- Sort: priority asc, then unblocked before blocked, then id asc ----------
$sorted = @($annotated | Sort-Object `
    { if ($_.Issue.priority) { [int]$_.Issue.priority } else { 99 } },
    { if ($_.IsBlocked) { 1 } else { 0 } },
    { $_.Issue.id }
)

# -- Format lines --------------------------------------------------------------
$lines = $sorted | ForEach-Object {
    $a          = $_
    $issue      = $a.Issue
    $id         = $issue.id
    $title      = ($issue.title -replace "`r", "" -replace "`n", " ").Trim()
    $status     = $issue.status
    $priority   = if ($issue.priority) { "P$($issue.priority)" } else { "P99" }
    $blocked    = if ($a.IsBlocked) { "yes" } else { "no" }
    $blockedBy  = if ($a.BlockerIds.Count -gt 0) { $a.BlockerIds -join ", " } else { "" }
    $desc       = if ($issue.description) {
                      ($issue.description -replace "`r", "" -replace "`n", " ").Trim()
                  } else { "" }

    "[ $id ] [ $title ] [ $status ] [ $priority ] [ $blocked ] [ $blockedBy ] [ $desc ]"
}

# -- Write output --------------------------------------------------------------
$outputDir = Split-Path -Parent $outputFile
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
}

$labelDisplay = if ($Label) { $Label } else { "(all)" }
if ($sorted.Count -eq 0) {
    Write-Warning "No open/in-progress tasks found for label '$labelDisplay'. Writing empty file."
    Set-Content -Path $outputFile -Value "" -Encoding UTF8 -NoNewline
} else {
    $content = ($lines -join "`n") + "`n"
    [System.IO.File]::WriteAllText($outputFile, $content, [System.Text.UTF8Encoding]::new($false))
}

$absOutput = (Resolve-Path $outputFile).Path
Write-Host ""
Write-Host "=== proc-beads-01.ps1 ===" -ForegroundColor Cyan
Write-Host "  Label  : $labelDisplay" -ForegroundColor White
Write-Host "  Tasks  : $($sorted.Count) written" -ForegroundColor White
Write-Host "  Output : $absOutput" -ForegroundColor White
Write-Host ""
