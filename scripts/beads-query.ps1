# Beads Query Script - Full bd CLI parity
# Commands: list, show, ready, search, create, update, close, dep, stats
# Data store: .beads/issues.jsonl (append-only, last-write-wins)

[CmdletBinding()]
param(
    # Positional: the sub-command to execute (bare invocation or unknown command shows usage)
    [Parameter(Position=0)]
    [string]$Command = "",

    # Positional Arg1: issue id, dep sub-command (add|list|remove), search query, or new title
    [Parameter(Position=1)]
    [string]$Arg1 = "",

    # Positional Arg2: issue id for dep sub-commands; dep-id for dep add/remove
    [Parameter(Position=2)]
    [string]$Arg2 = "",

    # Positional Arg3: dep-id when the dep sub-command occupies Arg1 and issue-id occupies Arg2
    [Parameter(Position=3)]
    [string]$Arg3 = "",

    # Named params shared across commands
    [string]$Status      = "",          # issue status filter / new status value
    [string]$Title       = "",          # issue title (update)
    [string]$Description = "",          # issue description (create / update)
    [int]   $Priority    = 0,           # issue priority 1-3 (0 = not provided / use default)
    [string]$Type        = "task",      # issue_type value (create)
    [string]$Reason      = "",          # close reason (close)
    [string]$DepType     = "blocks",    # dependency relationship type (dep add)
    [int]   $Limit       = 0,           # max rows to return (0 = unlimited)
    [switch]$Json,                      # emit compact JSON instead of human-readable output
    [switch]$Claim                      # set status=in-progress and claimed_by=$env:USERNAME
)

$beadsFile = ".beads/issues.jsonl"
$beadsDir  = ".beads"

# -- Core helpers --------------------------------------------------------------

function Get-Issues {
    $map = @{}
    if (-not (Test-Path $beadsFile)) { return $map }
    Get-Content $beadsFile | Where-Object { $_.Trim() } | ForEach-Object {
        try {
            $rec = $_ | ConvertFrom-Json
            if (-not $map.Contains($rec.id)) {
                $map[$rec.id] = $rec
            } else {
                $rec.PSObject.Properties | ForEach-Object {
                    $map[$rec.id] | Add-Member -NotePropertyName $_.Name -NotePropertyValue $_.Value -Force
                }
            }
        } catch { }
    }
    return $map
}

function Add-IssueRecord([object]$record) {
    if (-not (Test-Path $beadsDir)) { New-Item -ItemType Directory -Path $beadsDir | Out-Null }
    $line = $record | ConvertTo-Json -Compress -Depth 10
    Add-Content -Path $beadsFile -Value $line -Encoding UTF8
}

function New-IssueId {
    $chars = '0123456789abcdefghijklmnopqrstuvwxyz'
    $map   = Get-Issues
    do {
        $id = 'bd-' + (-join (1..4 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] }))
    } while ($map.Contains($id))
    return $id
}

function Get-Timestamp { return (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ') }

function Test-IssueBlocked([object]$issue, [hashtable]$map) {
    if (-not $issue.dependencies) { return $false }
    foreach ($dep in $issue.dependencies) {
        if ($dep.type -eq "blocks" -and $map.Contains($dep.depends_on_id) -and
            $map[$dep.depends_on_id].status -ne "closed") {
            return $true
        }
    }
    return $false
}

# -- Display helpers -----------------------------------------------------------

function Get-StatusColor([string]$status) {
    $color = switch ($status) {
        "open"        { "Yellow" }
        "in-progress" { "Cyan"   }
        "closed"      { "Green"  }
        default       { "White"  }
    }
    return $color
}

function Format-IssueLine([object]$issue, [bool]$isBlocked = $false) {
    $sc         = Get-StatusColor $issue.status
    $priority   = if ($issue.priority)   { "P$($issue.priority)" } else { "P?" }
    $type       = if ($issue.issue_type) { "[$($issue.issue_type)]" } else { "[task]" }
    $blockedTag = if ($isBlocked) { " [blocked]" } else { "" }
    Write-Host "$($issue.id)"         -ForegroundColor White    -NoNewline
    Write-Host " $type "              -ForegroundColor DarkGray  -NoNewline
    Write-Host "$priority "           -ForegroundColor Magenta   -NoNewline
    Write-Host "[$($issue.status)]"   -ForegroundColor $sc       -NoNewline
    if ($isBlocked) {
        Write-Host $blockedTag        -ForegroundColor DarkYellow -NoNewline
    }
    Write-Host " - $($issue.title)"
}

# -- Commands ------------------------------------------------------------------

function Invoke-List {
    $map    = Get-Issues
    $issues = @($map.Values)
    if ($Status) { $issues = @($issues | Where-Object { $_.status -eq $Status }) }
    $issues = @($issues | Sort-Object { if ($_.priority) { [int]$_.priority } else { 99 } }, id)
    if ($Limit -gt 0) { $issues = @($issues | Select-Object -First $Limit) }
    if ($Json) { ConvertTo-Json -InputObject @($issues) -Depth 10 -Compress | Write-Output; return }
    Write-Host ""
    Write-Host "=== Beads Issues ===" -ForegroundColor Cyan
    Write-Host ""
    if ($issues.Count -eq 0) { Write-Host "(no issues)" -ForegroundColor Gray }
    else { $issues | ForEach-Object { Format-IssueLine $_ } }
    Write-Host ""
    Write-Host "Total: $($issues.Count) issues" -ForegroundColor Gray
    Write-Host ""
}

function Invoke-Show([string]$id) {
    $map = Get-Issues
    if (-not $map.Contains($id)) { Write-Error "Issue '$id' not found"; exit 1 }
    $issue = $map[$id]
    if ($Json) { $issue | ConvertTo-Json -Depth 10 | Write-Output; return }
    $sc = Get-StatusColor $issue.status
    Write-Host ""
    Write-Host "=== Issue: $($issue.id) ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Title:    " -NoNewline; Write-Host $issue.title    -ForegroundColor White
    Write-Host "Status:   " -NoNewline; Write-Host $issue.status   -ForegroundColor $sc
    Write-Host "Priority: P$($issue.priority)"
    Write-Host "Type:     $($issue.issue_type)"
    if ($issue.description) {
        Write-Host ""; Write-Host "Description:" -ForegroundColor Yellow
        Write-Host $issue.description -ForegroundColor Gray
    }
    if ($issue.labels -and @($issue.labels).Count) {
        Write-Host ""; Write-Host "Labels: $($issue.labels -join ', ')" -ForegroundColor Magenta
    }
    if ($issue.dependencies -and @($issue.dependencies).Count) {
        Write-Host ""; Write-Host "Dependencies:" -ForegroundColor Yellow
        $issue.dependencies | ForEach-Object { Write-Host "  [$($_.type)] $($_.depends_on_id)" -ForegroundColor DarkYellow }
    }
    if ($issue.close_reason) { Write-Host ""; Write-Host "Close reason: $($issue.close_reason)" -ForegroundColor Gray }
    Write-Host ""
}

function Invoke-Ready {
    $map     = Get-Issues
    $priSort = { if ($_.priority) { [int]$_.priority } else { 99 } }

    # Include open AND in-progress so callers see the full picture.
    $openOnly  = @($map.Values | Where-Object { $_.status -eq "open" -or $_.status -eq "in-progress" })
    $unblocked = @($openOnly | Where-Object { -not (Test-IssueBlocked $_ $map) } | Sort-Object $priSort)
    $blocked   = @($openOnly | Where-Object {       Test-IssueBlocked $_ $map  } | Sort-Object $priSort)

    # Combined: unblocked first (highest priority), then blocked (highest priority).
    # --limit 0 (default) = no cap; --limit N > 0 caps the combined total.
    $combined = @($unblocked) + @($blocked)
    $display  = if ($Limit -gt 0) { @($combined | Select-Object -First $Limit) } else { $combined }

    if ($Json) { ConvertTo-Json -InputObject @($display) -Depth 10 -Compress | Write-Output; return }

    Write-Host ""
    Write-Host "=== Open Beads: unblocked first, then blocked (highest priority first) ===" -ForegroundColor Cyan
    Write-Host ""

    if ($display.Count -eq 0) {
        Write-Host "(no open issues)" -ForegroundColor Gray
    } else {
        # Build a lookup of blocked IDs for O(1) checks.
        $blockedIds = @{}
        $blocked | ForEach-Object { $blockedIds[$_.id] = $true }

        $inUnblockedSection = $true
        foreach ($issue in $display) {
            $isBlocked = $blockedIds.Contains($issue.id)
            # Print section separator on first blocked item.
            if ($isBlocked -and $inUnblockedSection) {
                $inUnblockedSection = $false
                Write-Host ""
                Write-Host "--- Blocked ---" -ForegroundColor DarkYellow
                Write-Host ""
            }
            Format-IssueLine $issue $isBlocked
        }
    }

    Write-Host ""
    $limitNote = if ($Limit -gt 0 -and $combined.Count -gt $Limit) { " (showing $Limit of $($combined.Count))" } else { "" }
    Write-Host "$($unblocked.Count) unblocked | $($blocked.Count) blocked | $($openOnly.Count) open total$limitNote" -ForegroundColor Gray
    Write-Host ""
}

function Invoke-Search([string]$query) {
    $map    = Get-Issues
    $issues = @($map.Values | Where-Object {
        ($_.title       -match [regex]::Escape($query)) -or
        ($_.description -match [regex]::Escape($query))
    })
    if ($Json) { ConvertTo-Json -InputObject @($issues) -Depth 10 -Compress | Write-Output; return }
    Write-Host ""
    Write-Host "=== Search: '$query' ===" -ForegroundColor Cyan
    Write-Host ""
    if ($issues.Count -eq 0) { Write-Host "No issues found." -ForegroundColor Gray }
    else { $issues | ForEach-Object { Format-IssueLine $_ } }
    Write-Host ""
}

function Invoke-Create([string]$title) {
    if (-not $title.Trim()) { Write-Error "create requires a non-empty title"; exit 1 }
    $id          = New-IssueId
    $now         = Get-Timestamp
    $effectivePri = if ($Priority -gt 0) { $Priority } else { 3 }   # default priority = 3
    $record = [ordered]@{
        id           = $id
        title        = $title.Trim()
        status       = "open"
        priority     = $effectivePri
        issue_type   = $Type
        description  = $Description
        labels       = @()
        dependencies = @()
        claimed_by   = ""
        close_reason = ""
        created_at   = $now
        updated_at   = $now
    }
    Add-IssueRecord $record
    if ($Json) { $record | ConvertTo-Json -Depth 10 | Write-Output; return }
    Write-Host "Created: $id" -ForegroundColor Green
}

function Invoke-Update([string]$id) {
    $map = Get-Issues
    if (-not $map.Contains($id)) { Write-Error "Issue '$id' not found"; exit 1 }
    $now   = Get-Timestamp
    $delta = [ordered]@{ id = $id; updated_at = $now }
    if ($Claim)          { $delta["status"] = "in-progress"; $delta["claimed_by"] = $env:USERNAME }
    if ($Status)         { $delta["status"] = $Status }
    if ($Priority -gt 0) { $delta["priority"] = $Priority }   # 0 = not provided; any positive value updates
    if ($Title)          { $delta["title"] = $Title }
    if ($Description)    { $delta["description"] = $Description }
    Add-IssueRecord $delta
    $map = Get-Issues
    if ($Json) { $map[$id] | ConvertTo-Json -Depth 10 | Write-Output; return }
    Write-Host "Updated: $id" -ForegroundColor Green
}

function Invoke-Close([string]$id) {
    $map = Get-Issues
    if (-not $map.Contains($id)) { Write-Error "Issue '$id' not found"; exit 1 }
    $delta = [ordered]@{ id = $id; status = "closed"; close_reason = $Reason; updated_at = (Get-Timestamp) }
    Add-IssueRecord $delta
    $map = Get-Issues
    if ($Json) { $map[$id] | ConvertTo-Json -Depth 10 | Write-Output; return }
    Write-Host "Closed: $id" -ForegroundColor Green
}

function Invoke-Dep([string]$subCmd, [string]$id, [string]$depId) {
    $map = Get-Issues
    if (-not $map.Contains($id)) { Write-Error "Issue '$id' not found"; exit 1 }
    $issue = $map[$id]
    $deps  = [System.Collections.ArrayList]@(if ($issue.dependencies) { $issue.dependencies } else { @() })
    switch ($subCmd) {
        "add" {
            $deps.Add([pscustomobject]@{ type = $DepType; depends_on_id = $depId }) | Out-Null
            Add-IssueRecord ([ordered]@{ id = $id; dependencies = @($deps); updated_at = (Get-Timestamp) })
            Write-Host "Added dep: $id <--[$DepType]-- $depId" -ForegroundColor Green
        }
        "list" {
            if ($Json) {
                [ordered]@{ id = $id; dependencies = @($deps) } | ConvertTo-Json -Depth 10 | Write-Output
                return
            }
            Write-Host ""
            Write-Host "=== Dependencies: $id ===" -ForegroundColor Cyan
            Write-Host ""
            if ($deps.Count -eq 0) { Write-Host "  (none)" -ForegroundColor Gray }
            else {
                $deps | ForEach-Object {
                    $depStatus = if ($map.Contains($_.depends_on_id)) { $map[$_.depends_on_id].status } else { "unknown" }
                    $sc = Get-StatusColor $depStatus
                    Write-Host "  [$($_.type)] " -ForegroundColor DarkGray -NoNewline
                    Write-Host $_.depends_on_id   -ForegroundColor White   -NoNewline
                    Write-Host " [$depStatus]"    -ForegroundColor $sc
                }
            }
            Write-Host ""
            Write-Host "Total: $($deps.Count) dependenc$(if ($deps.Count -eq 1) { 'y' } else { 'ies' })" -ForegroundColor Gray
            Write-Host ""
        }
        "remove" {
            $deps = [System.Collections.ArrayList]@($deps | Where-Object { $_.depends_on_id -ne $depId })
            Add-IssueRecord ([ordered]@{ id = $id; dependencies = @($deps); updated_at = (Get-Timestamp) })
            Write-Host "Removed dep $depId from $id" -ForegroundColor Green
        }
        default { Write-Error "Unknown dep subcommand '$subCmd'. Use: add, list, remove"; exit 1 }
    }
}

function Invoke-Stats {
    $map      = Get-Issues
    $all      = @($map.Values)
    $byStatus = $all | Group-Object status
    $byPri    = $all | Group-Object priority | Sort-Object { [int]$_.Name }
    if ($Json) {
        $stats = [ordered]@{ total = $all.Count; by_status = [ordered]@{}; by_priority = [ordered]@{} }
        $byStatus | ForEach-Object { $stats.by_status[$_.Name]        = $_.Count }
        $byPri    | ForEach-Object { $stats.by_priority["P$($_.Name)"] = $_.Count }
        $stats | ConvertTo-Json -Depth 5 | Write-Output; return
    }
    Write-Host ""
    Write-Host "=== Beads Statistics ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Total issues: $($all.Count)" -ForegroundColor White
    Write-Host ""
    Write-Host "By Status:" -ForegroundColor Yellow
    $byStatus | ForEach-Object { Write-Host "  $($_.Name): $($_.Count)" }
    Write-Host ""
    Write-Host "By Priority:" -ForegroundColor Yellow
    $byPri | ForEach-Object { Write-Host "  P$($_.Name): $($_.Count)" }
    Write-Host ""
}

function Show-Usage {
    Write-Host ""
    Write-Host "beads-query.ps1 - Beads issue tracker (bd CLI parity)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Commands:" -ForegroundColor Yellow
    Write-Host "  list    [--status <s>] [--limit <n>] [--json]"
    Write-Host "  show    <id>  [--json]"
    Write-Host "  ready   [--limit <n>] [--json]   # unblocked first, then blocked; --limit 0 = all"
    Write-Host "  search  <query> [--json]"
    Write-Host "  create  <title> [-Description <d>] [-Priority <p>] [-Type <t>] [--json]"
    Write-Host "  update  <id> [--status <s>] [--claim] [-Priority <p>] [-Title <t>] [-Description <d>] [--json]"
    Write-Host "  close   <id> [--reason <r>] [--json]"
    Write-Host "  dep     add|list|remove <id> [dep-id] [-DepType <t>]"
    Write-Host "  stats   [--json]"
    Write-Host ""
}

# -- Dispatch ------------------------------------------------------------------

switch ($Command) {
    "list"   { Invoke-List }
    "show"   { if (-not $Arg1) { Write-Error "show requires an issue id"; exit 1 }; Invoke-Show   $Arg1 }
    "ready"  { Invoke-Ready }
    "search" { if (-not $Arg1) { Write-Error "search requires a query";    exit 1 }; Invoke-Search $Arg1 }
    "create" { if (-not $Arg1) { Write-Error "create requires a title";    exit 1 }; Invoke-Create $Arg1 }
    "update" { if (-not $Arg1) { Write-Error "update requires an id";      exit 1 }; Invoke-Update $Arg1 }
    "close"  { if (-not $Arg1) { Write-Error "close requires an id";       exit 1 }; Invoke-Close  $Arg1 }
    "dep"    {
        if (-not $Arg1) { Write-Error "dep requires a subcommand (add|list|remove)"; exit 1 }
        if (-not $Arg2) { Write-Error "dep requires an issue id"; exit 1 }
        Invoke-Dep $Arg1 $Arg2 $Arg3
    }
    "stats"  { Invoke-Stats }
    default  { Show-Usage }
}

