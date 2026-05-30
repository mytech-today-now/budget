# Beads Helper Commands
# Dot-source this script to load the 'bd' alias and all helper functions:
#   . .\scripts\beads-helpers.ps1
#
# Then use bd just like the bd CLI:
#   bd list
#   bd create "My task" -Description "details" -Priority 2
#   bd update <id> --claim
#   bd close <id> --reason "done"
#   bd ready
#   bd stats

# -- Core bd alias -------------------------------------------------------------

function bd {
    $scriptPath = Join-Path $PSScriptRoot "beads-query.ps1"

    # Map lowercased flag names to the exact PowerShell param names in beads-query.ps1
    $paramMap = @{
        'status'      = 'Status'
        'title'       = 'Title'
        'description' = 'Description'
        'priority'    = 'Priority'
        'type'        = 'Type'
        'reason'      = 'Reason'
        'deptype'     = 'DepType'
        'limit'       = 'Limit'
        'json'        = 'Json'
        'claim'       = 'Claim'
    }

    $positional = @()
    $namedParams = @{}

    $i = 0
    while ($i -lt $args.Count) {
        $a = $args[$i]
        if ($a -match '^--?(.+)$') {
            $flagName = $Matches[1].ToLower()
            $psName   = if ($paramMap.Contains($flagName)) { $paramMap[$flagName] } else { $Matches[1] }
            # If the next element exists and doesn't start with '-', treat it as the value
            if (($i + 1) -lt $args.Count -and $args[$i + 1] -notmatch '^-') {
                $namedParams[$psName] = $args[$i + 1]
                $i += 2
            } else {
                $namedParams[$psName] = $true
                $i++
            }
        } else {
            $positional += $a
            $i++
        }
    }

    & $scriptPath @positional @namedParams
}

# -- Convenience wrappers ------------------------------------------------------

function bd-list-open  { bd list --status open }
function bd-list-all   { bd list }

function bd-show {
    param([string]$Id)
    bd show $Id
}

# Returns ALL open beads: unblocked first (P1→P2→P3), then blocked (P1→P2→P3).
# --limit 0 (default) shows every open bead. Pass -Limit <n> to cap the combined total.
function bd-ready {
    param([int]$Limit = 0)
    if ($Limit -gt 0) { bd ready --limit $Limit } else { bd ready --limit 0 }
}

function bd-create {
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Description = "",
        [int]   $Priority    = 3,
        [string]$Type        = "task"
    )
    bd create $Title -Description $Description -Priority $Priority -Type $Type
}

function bd-update {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Status      = "",
        [switch]$Claim,
        [int]   $Priority    = 0,
        [string]$Title       = "",
        [string]$Description = ""
    )
    $extra = @()
    if ($Claim)       { $extra += "--claim" }
    if ($Status)      { $extra += "--status"; $extra += $Status }
    if ($Priority)    { $extra += "-Priority"; $extra += $Priority }
    if ($Title)       { $extra += "-Title"; $extra += $Title }
    if ($Description) { $extra += "-Description"; $extra += $Description }
    bd update $Id @extra
}

function bd-close {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Reason = "Completed"
    )
    bd close $Id --reason $Reason
}

function bd-search {
    param([Parameter(Mandatory)][string]$Query)
    bd search $Query
}

function bd-dep { bd dep @args }

# List augment-extensions related tasks
function bd-list-augext {
    Write-Host ""
    Write-Host "=== Augment Extensions System Tasks ===" -ForegroundColor Cyan
    Write-Host ""
    bd search "augext"
}

# List character count related tasks
function bd-list-charcount {
    Write-Host ""
    Write-Host "=== Character Count Rule Installation Tasks ===" -ForegroundColor Cyan
    Write-Host ""
    bd search "charcount"
}

# Show help
function bd-help {
    Write-Host ""
    Write-Host "=== Beads Helper Commands ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Core alias:" -ForegroundColor Yellow
    Write-Host "  bd <command> [args]   # Full bd CLI parity via beads-query.ps1"
    Write-Host ""
    Write-Host "Convenience wrappers:" -ForegroundColor Yellow
    Write-Host "  bd-list-open          # bd list --status open"
    Write-Host "  bd-list-all           # bd list"
    Write-Host "  bd-show <id>          # bd show <id>"
    Write-Host "  bd-ready [-Limit <n>] # all open tasks: unblocked first then blocked, priority order"
    Write-Host "  bd-create <title>     # bd create <title> [-Description] [-Priority] [-Type]"
    Write-Host "  bd-update <id>        # bd update <id> [-Status] [-Claim] [-Priority]"
    Write-Host "  bd-close <id>         # bd close <id> [-Reason]"
    Write-Host "  bd-search <query>     # bd search <query>"
    Write-Host "  bd-dep [args]         # bd dep add|list|remove <id> [dep-id]"
    Write-Host "  bd-list-augext        # Show augment-extensions tasks"
    Write-Host "  bd-list-charcount     # Show character-count tasks"
    Write-Host "  bd-help               # Show this help"
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Yellow
    Write-Host "  bd list"
    Write-Host "  bd create `"Fix the login bug`" -Priority 1"
    Write-Host "  bd update bd-a1b2 --claim"
    Write-Host "  bd close bd-a1b2 --reason `"Fixed in PR #42`""
    Write-Host "  bd stats"
    Write-Host "  bd ready             # all open beads (unblocked first, then blocked)"
  Write-Host "  bd ready --limit 5   # top 5 from combined unblocked+blocked list"
    Write-Host ""
}

# -- Dot-source detection ------------------------------------------------------

if ($MyInvocation.InvocationName -eq '.') {
    Write-Host "Beads helper commands loaded. Run 'bd-help' for usage." -ForegroundColor Green
}

