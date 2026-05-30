<#
.SYNOPSIS
    Wrapper that processes bead-tasks.md through process-beads.ps1.

.DESCRIPTION
    Calls process-beads.ps1 with pre-configured paths:
      Input  : ai-prompts\bead-tasks.md
      Output : ai-prompts\bead-tasks-processed.md

    All parameters supported by process-beads.ps1 (-skip, -pre, -post)
    can be forwarded via -ExtraArgs, or the defaults defined in
    process-beads.ps1 will be used.

.PARAMETER Skip
    Number of non-blank lines per batch.  Forwarded to process-beads.ps1.
    Default: 3 (process-beads.ps1 default).

.PARAMETER Pre
    Text prepended before each batch.  Forwarded to process-beads.ps1.
    Use {{N}} as a placeholder for the 1-based batch number.

.PARAMETER Post
    Text appended after each batch.  Forwarded to process-beads.ps1.
    Use {{N}} as a placeholder for the 1-based batch number.

.EXAMPLE
    # Run with defaults
    .\scripts\proc-beads.ps1

.EXAMPLE
    # Override batch size
    .\scripts\proc-beads.ps1 -Skip 5

.EXAMPLE
    # Custom pre/post text
    .\scripts\proc-beads.ps1 -Pre "Batch {{N}} start:" -Post "Batch {{N}} end."
#>

[CmdletBinding(PositionalBinding = $false)]
param(
    [int]$Skip,
    [string]$Pre,
    [string]$Post
)

# ── Resolve absolute paths ───────────────────────────────────────────
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Split-Path -Parent $scriptDir
$processor = Join-Path $repoRoot "scripts\process-beads.ps1"
$inputFile = Join-Path $repoRoot "ai-prompts\bead-tasks.md"
$outputFile= Join-Path $repoRoot "ai-prompts\bead-tasks-processed.md"

# ── Validate prerequisites ───────────────────────────────────────────
if (-not (Test-Path $processor)) {
    Write-Error "Processor script not found: $processor"
    exit 1
}

if (-not (Test-Path $inputFile)) {
    Write-Error "Input file not found: $inputFile"
    exit 1
}

# ── Build argument hashtable (named-parameter splatting) ─────────────
$callArgs = @{
    InputFile  = $inputFile
    OutputFile = $outputFile
}

if ($PSBoundParameters.ContainsKey('Skip')) { $callArgs['Skip'] = $Skip }
if ($PSBoundParameters.ContainsKey('Pre'))  { $callArgs['Pre']  = $Pre  }
if ($PSBoundParameters.ContainsKey('Post')) { $callArgs['Post'] = $Post }

# ── Invoke processor ─────────────────────────────────────────────────
Write-Host "Input  : $inputFile"
Write-Host "Output : $outputFile"
Write-Host ""

& $processor @callArgs

