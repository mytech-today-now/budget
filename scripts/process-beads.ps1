<#
.SYNOPSIS
    Batch-wraps lines from an input file with configurable pre/post text.

.DESCRIPTION
    Reads an input file, groups every N non-blank lines into batches,
    wraps each batch with pre/post text, and writes to stdout or a file.
    Batch number placeholder {{N}} in --pre/--post text is replaced with
    the 1-based batch number.
#>

[CmdletBinding(PositionalBinding = $false)]
param(
    [Alias("input")]
    [string]$InputFile,

    [Alias("output")]
    [string]$OutputFile,

    [int]$Skip = 3,

    [string]$Pre,

    [string]$Post,

    [Alias("h")]
    [switch]$Help
)

# ── Help ────────────────────────────────────────────────────────────
if ($Help -or $MyInvocation.BoundParameters.ContainsKey('h')) {
    $helpText = @"

process-beads.ps1 — Batch-wrap lines with pre/post text
========================================================

USAGE
    .\process-beads.ps1 [-input "path"] [-output "path"]
                        [-skip N]
                        [-pre "text"] [-post "text"]
                        [-help]

ARGUMENTS
    -input "path"
                Path to the input file.
                Default: beads-list.txt in the same directory as this script.

    -output "path"
                Path to the output file.
                Default: stdout (pipe-friendly).

    -skip N     Number of non-blank lines per batch.  Default: 3
                Every N lines are grouped into one batch regardless of
                blank lines in the input (blank lines are stripped).

    -pre "text" Text prepended before each batch.  Overrides the built-in
                default.  Use triple-quoted strings in PowerShell for
                multi-line values:
                    -pre @"
                    Line one
                    Line two
                    "@

    -post "text"
                Text appended after each batch.  Same rules as -pre.

    -help, -h   Show this help and exit.

BATCH NUMBER PLACEHOLDER
    Use {{N}} anywhere in -pre or -post text.  It will be replaced with
    the 1-based batch number for each batch.

    Example:  -pre "Batch {{N}}:"

OUTPUT FORMAT
    Each batch is separated by a line containing only:

        ---

    (blank line, three dashes, blank line)

EXAMPLES

    # Basic — 3 lines per batch, output to stdout
    .\process-beads.ps1 -input .\scripts\beads-list.txt

    # 5 lines per batch, write to file
    .\process-beads.ps1 -input .\input.txt -output .\output.txt -skip 5

    # Custom pre/post with batch number
    .\process-beads.ps1 -input .\input.txt -skip 2 ``
        -pre "=== Batch {{N}} ===" ``
        -post "--- end batch {{N}} ---"

    # Pipe to clipboard (Windows)
    .\process-beads.ps1 -input .\input.txt | Set-Clipboard

    # Multi-line pre text using PowerShell here-string
    `$pre = @"
    Using Augment AI, process the following tasks.
    Check completed.jsonl first. Skip if done.
    Batch {{N}}:
    "@
    .\process-beads.ps1 -input .\input.txt -pre `$pre

"@
    Write-Host $helpText
    exit 0
}

# ── Resolve defaults ────────────────────────────────────────────────
$scriptDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot      = Split-Path -Parent $scriptDir
$completedJsonl = Join-Path $repoRoot "completed.jsonl"
$IssuesJsonl = Join-Path $repoRoot ".beads\issues.jsonl"

if (-not $InputFile) {
    $InputFile = Join-Path $scriptDir "beads-tasks.md"
}

if (-not (Test-Path $InputFile)) {
    Write-Error "Input file not found: $InputFile"
    exit 1
}

# ── Default Pre/Post Instructions for Augmentcode AI ─────────────────────────────

$defaultPre = @"
Using Augmentcode AI (with Augment-extensions) in VS Code:
- Load bead tasks using 'scripts\beads-helpers.ps1' (dot-sourceit to get the 'bd' alias: `. .\scripts\beads-helpers.ps1`) or call 'scripts\beads-query.ps1' directly
- Check task completion status with "bd list --status open" or "bd ready " - skip any task whose status is not open/in-progress
- For each remaining task in this batch:
    - Claim the task before starting: "bd update <id> --claim"
    - Generate production-quality code that fully satisfies the bead task requirements
    - Follow professional coding standards at all times
    - Do not use stubs, placeholders, or incomplete implementations
    - Do not hallucinate or make up functionality
    - Never reuse the same code pattern for multiple distinct tasks
    - Address every TODO in the relevant files:
        • If a TODO is relevant, implement the required change
        • If a TODO is not relevant, explicitly document why it can be ignored
    - Do not proceed until all TODOs are explicitly resolved or justified
(batch {{N}}):

"@

$defaultPost = @"

After completing the tasks above:
- Mark the processed bead task(s) as closed in '$IssuesJsonl'.  Do NOT delete the bead task from '$IssuesJsonl' — only mark it as closed.
- Also record completion in '$completedJsonl'
"@

if ($PSBoundParameters.ContainsKey('Pre'))  { $usePre  = $Pre  } else { $usePre  = $defaultPre  }
if ($PSBoundParameters.ContainsKey('Post')) { $usePost = $Post } else { $usePost = $defaultPost }

# ── Read & filter blank lines ──────────────────────────────────────
$lines = Get-Content -Path $InputFile |
    Where-Object { $_.Trim() -ne "" }

if ($lines.Count -eq 0) {
    Write-Error "Input file is empty or contains only blank lines: $InputFile"
    exit 1
}

# ── Batch lines ─────────────────────────────────────────────────────
$batches = @()
for ($i = 0; $i -lt $lines.Count; $i += $Skip) {
    $end = [Math]::Min($i + $Skip, $lines.Count)
    $batch = $lines[$i..($end - 1)]
    $batches += , $batch   # comma keeps it as a nested array
}

# ── Build output ────────────────────────────────────────────────────
$separator = "`n`n---`n`n"
$result = [System.Text.StringBuilder]::new()

for ($b = 0; $b -lt $batches.Count; $b++) {
    $batchNum = $b + 1
    $batchBody = ($batches[$b] | ForEach-Object { $_.Trim() }) -join "`n"

    $pre  = $usePre  -replace '\{\{N\}\}', $batchNum
    $post = $usePost -replace '\{\{N\}\}', $batchNum

    if ($b -gt 0) { [void]$result.Append($separator) }
    [void]$result.Append($pre)
    [void]$result.Append($batchBody)
    [void]$result.Append($post)
}

# ── Output ──────────────────────────────────────────────────────────
$finalText = $result.ToString()

if ($OutputFile) {
    $finalText | Out-File -FilePath $OutputFile -Encoding utf8
    Write-Host "Processed $($batches.Count) batch(es) → $OutputFile"
} else {
    Write-Output $finalText
}