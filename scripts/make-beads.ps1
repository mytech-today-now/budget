<#
.SYNOPSIS
    Generate Beads tasks from an OpenSpec change artifact tree.

.DESCRIPTION
    Reads openspec/changes/<ChangeName>/ (proposal.md, design.md, deltas.md, specs/,
    examples/, tests/, tasks.md, implementation.md, summary.md, cache.json), builds
    rich bead descriptions, creates all tasks via `bd create`, wires dependencies
    with `bd dep add`, and prints a summary.

    Supports pipeline input: an upstream OpenSpec generator can pipe the change name.

.PARAMETER ChangeName
    Name of the OpenSpec change — matches the directory under openspec/changes/.
    Example: "voice2text", "cache", "fallback-model"

.EXAMPLE
    pwsh -File .\scripts\make-beads.ps1 -ChangeName "voice2text"

.EXAMPLE
    .\scripts\generate-openspec.ps1 -ChangeName "cache" | pwsh -File .\scripts\make-beads.ps1
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName,
               HelpMessage = "OpenSpec change name, e.g. 'voice2text' or 'cache'")]
    [string]$ChangeName = ""
)

# ── begin ──────────────────────────────────────────────────────────────────────
begin {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = "Stop"
    $repoRoot    = Split-Path -Parent $PSScriptRoot   # scripts\ -> repo root
    $helpersPath = Join-Path $PSScriptRoot "beads-helpers.ps1"
    if (-not (Test-Path $helpersPath)) {
        Write-Error "beads-helpers.ps1 not found at: $helpersPath"; exit 1
    }
    . $helpersPath
}

# ── process ────────────────────────────────────────────────────────────────────
process {
    if (-not $ChangeName -and $_) { $ChangeName = ($_ | Out-String).Trim() }
}

# ── end ────────────────────────────────────────────────────────────────────────
end {
    # -- Validate ---------------------------------------------------------------
    if (-not $ChangeName -or $ChangeName.Trim() -eq "") {
        Write-Error ("ChangeName is required. Pass -ChangeName or pipe it from another script.`n" +
                     "Usage: pwsh -File .\scripts\make-beads.ps1 -ChangeName `"voice2text`"")
        exit 1
    }
    $ChangeName = $ChangeName.Trim()

    # -- Locate change directory ------------------------------------------------
    $changeDir = Join-Path $repoRoot "openspec\changes\$ChangeName"
    if (-not (Test-Path $changeDir)) {
        Write-Error "OpenSpec change directory not found: $changeDir"; exit 1
    }

    # -- Artifact reader -------------------------------------------------------
    function Read-Artifact([string]$Path) {
        if (Test-Path $Path) { return (Get-Content $Path -Raw -Encoding UTF8) }
        return ""
    }

    # -- Read all text artifacts -----------------------------------------------
    $proposalText       = Read-Artifact (Join-Path $changeDir "proposal.md")
    $designText         = Read-Artifact (Join-Path $changeDir "design.md")
    $deltasText         = Read-Artifact (Join-Path $changeDir "deltas.md")
    $tasksText          = Read-Artifact (Join-Path $changeDir "tasks.md")
    $implementationText = Read-Artifact (Join-Path $changeDir "implementation.md")
    $summaryText        = Read-Artifact (Join-Path $changeDir "summary.md")
    if (-not $tasksText) {
        Write-Error "tasks.md not found or empty in: $changeDir"; exit 1
    }

    # .json manifest (cache.json preferred, then <ChangeName>.json)
    $manifestPath = Join-Path $changeDir "cache.json"
    if (-not (Test-Path $manifestPath)) { $manifestPath = Join-Path $changeDir "$ChangeName.json" }
    $manifest = if (Test-Path $manifestPath) {
        Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else { $null }

    # Spec .md files under specs/
    $specTexts = @{}
    $specsDir = Join-Path $changeDir "specs"
    if (Test-Path $specsDir) {
        Get-ChildItem $specsDir -Recurse -Filter "*.md" | ForEach-Object {
            $specTexts[$_.Name] = Get-Content $_.FullName -Raw -Encoding UTF8
        }
    }

    # All files under examples/ concatenated
    $examplesText = ""
    $examplesDir = Join-Path $changeDir "examples"
    if (Test-Path $examplesDir) {
        $examplesText = (Get-ChildItem $examplesDir -Recurse -File |
            ForEach-Object { Get-Content $_.FullName -Raw -Encoding UTF8 }) -join "`n"
    }

    # All test stub files concatenated
    $testsText = ""
    $testsDir = Join-Path $changeDir "tests"
    if (Test-Path $testsDir) {
        $testsText = (Get-ChildItem $testsDir -Recurse -File |
            ForEach-Object { Get-Content $_.FullName -Raw -Encoding UTF8 }) -join "`n"
    }

    # -- Parse tasks.md --------------------------------------------------------
    # Format: "## Phase heading" then "- [ ] N.M Task title" lines
    $parsedTasks  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $currentPhase = "General"
    $seqNum       = 0
    foreach ($line in ($tasksText -split "`n")) {
        if ($line -match '^##\s+(.+)') { $currentPhase = $Matches[1].Trim() }
        if ($line -match '^\s*-\s*\[[ x]\]\s*(\d+\.\d+)\s+(.+)') {
            $seqNum++
            $numStr = $Matches[1].Trim()
            $pts    = $numStr -split '\.'
            $parsedTasks.Add([PSCustomObject]@{
                Phase    = $currentPhase
                Number   = $numStr
                SeqNum   = $seqNum
                Title    = $Matches[2].Trim()
                MajorNum = [int]$pts[0]
                MinorNum = [int]$pts[1]
            })
        }
    }
    if ($parsedTasks.Count -eq 0) {
        Write-Error "No tasks parsed from tasks.md. Verify '- [ ] N.M Title' format."; exit 1
    }

    # -- New-Bead: calls beads-query.ps1 directly via splatting ---------------
    # NOTE: We bypass the `bd` wrapper's manual arg-parser because description
    # strings can start with '-' (e.g. "- [ ] 1.1 …" from tasks.md), which the
    # wrapper would misread as a flag name.  Splatting lets PowerShell bind
    # -Description to its declared [string] parameter regardless of the value.
    $queryPath = Join-Path $PSScriptRoot "beads-query.ps1"
    function New-Bead([string]$Title, [string]$Desc, [int]$Pri = 3, [string]$Typ = "task") {
        $p   = @{ Description = $Desc; Priority = $Pri; Type = $Typ }
        $raw = (& $script:queryPath create $Title @p) 6>&1 | Out-String
        if ($raw -match 'Created:\s*(bd-[a-z0-9]+)') { return $Matches[1] }
        throw "bd create did not return a bead ID.`nRaw output: $raw"
    }

    # -- Text helpers ----------------------------------------------------------
    function Flatten([string]$text) {
        return ($text -replace '[\r\n]+', ' ' -replace '\s{2,}', ' ').Trim()
    }

    # -- Build-TaskDescription -------------------------------------------------
    # Assembles a flat single-line description for one task from the artifact tree.
    function Build-TaskDescription($task) {
        $numEsc  = [regex]::Escape($task.Number)         # e.g. "3\.6"
        $tRef    = "T-{0:D3}" -f $task.SeqNum            # e.g. "T-012"
        $tRefEsc = [regex]::Escape($tRef)
        $parts   = [System.Collections.Generic.List[string]]::new()

        # 1. Full tasks.md line — often contains inline file refs and detail
        $taskLine = Search-Lines $tasksText "(?i)^\s*-\s*\[[ x]\]\s*$numEsc\s" 2
        if ($taskLine) { $parts.Add((Flatten $taskLine)) }

        # 2. implementation.md lines referencing this task number or T-NNN
        $implHit = Search-Lines $implementationText "(?i)$numEsc|$tRefEsc" 4
        if ($implHit) { $parts.Add((Flatten $implHit)) }

        # 3. Phase-level notes from implementation.md and design.md
        $phaseWords = ($task.Phase -split '[^a-zA-Z]' |
            Where-Object { $_.Length -gt 4 } | Select-Object -First 2) -join '|'
        if ($phaseWords) {
            $phaseHit = Search-Lines $implementationText "(?i)### .*($phaseWords)|($phaseWords).*note|($phaseWords).*must" 3
            if ($phaseHit) { $parts.Add((Flatten $phaseHit)) }
            $designHit = Search-Lines $designText "(?i)($phaseWords)" 2
            if ($designHit) { $parts.Add("Design: $(Flatten $designHit)") }
        }

        # 4. deltas.md rows matching key title keywords
        $stopWords = '^(the|and|with|from|into|this|that|each|have|will|add|create|implement|using|all|for|via)$'
        $titleWords = ($task.Title -replace '[`\[\]#\(\)]', '' -split '\s+' |
            Where-Object { $_.Length -gt 4 -and $_ -notmatch $stopWords } |
            Select-Object -First 3) -join '|'
        if ($titleWords) {
            $deltaHit = Search-Lines $deltasText "(?i)($titleWords)" 3
            if ($deltaHit) { $parts.Add("Deltas: $(Flatten $deltaHit)") }
        }

        # 5. Spec files — lines referencing the task number or T-NNN
        foreach ($kv in $specTexts.GetEnumerator()) {
            $hit = Search-Lines $kv.Value "(?i)$numEsc|$tRefEsc" 2
            if ($hit) { $parts.Add("Spec ($($kv.Key)): $(Flatten $hit)") }
        }

        # 6. examples/ or tests/ — lines matching the task number
        foreach ($src in @($examplesText, $testsText)) {
            $hit = Search-Lines $src "(?i)$numEsc|$tRefEsc" 2
            if ($hit) { $parts.Add((Flatten $hit)) }
        }

        $desc = if ($parts.Count -gt 0) { Flatten ($parts -join " | ") }
                else { "Task $($task.Number) ($tRef): $($task.Title). Phase: $($task.Phase)." }
        if ($desc.Length -gt 2000) { $desc = $desc.Substring(0, 1997) + "..." }
        return $desc
    }

    # -- Build-StoryDescription ------------------------------------------------
    function Build-StoryDescription {
        $parts = [System.Collections.Generic.List[string]]::new()

        # Stats from manifest
        if ($manifest) {
            $stats = @()
            if ($manifest.PSObject.Properties['tasksTotal'])        { $stats += "$($manifest.tasksTotal) tasks" }
            if ($manifest.PSObject.Properties['acceptanceCriteria']){ $stats += "$($manifest.acceptanceCriteria) ACs" }
            if ($manifest.PSObject.Properties['testsNew'])          { $stats += "$($manifest.testsNew) new tests" }
            if ($stats) { $parts.Add($stats -join ", ") }
            if ($manifest.PSObject.Properties['capabilities'] -and $manifest.capabilities) {
                $caps = ($manifest.capabilities | ForEach-Object { $_.name }) -join ", "
                $parts.Add("Capabilities: $caps")
            }
            if ($manifest.PSObject.Properties['filesModified'] -and $manifest.filesModified.Count -gt 0) {
                $parts.Add("Files modified: $($manifest.filesModified -join ', ')")
            }
            if ($manifest.PSObject.Properties['filesCreated'] -and $manifest.filesCreated.Count -gt 0) {
                $parts.Add("Files created: $($manifest.filesCreated -join ', ')")
            }
        }

        # Story points and priority from summary.md
        if ($summaryText) {
            $spHit = Search-Lines $summaryText "(?i)Story Points|Priority|Story Point" 2
            if ($spHit) { $parts.Add((Flatten $spHit)) }
        }

        # "What Changes" bullet points from proposal.md
        if ($proposalText) {
            $bullets = Search-Lines $proposalText "(?i)^-\s+.{10}" 8
            if ($bullets) { $parts.Add("Changes: $(Flatten $bullets)") }
        }

        $desc = if ($parts.Count -gt 0) { Flatten ($parts -join ". ") }
                else { Flatten ("$summaryText $proposalText") }
        if ($desc.Length -gt 2000) { $desc = $desc.Substring(0, 1997) + "..." }
        return $desc
    }

    # -- Build-StoryTitle ------------------------------------------------------
    function Build-StoryTitle {
        # Prefer capability names from manifest
        if ($manifest -and $manifest.PSObject.Properties['capabilities'] -and $manifest.capabilities) {
            $caps = ($manifest.capabilities | ForEach-Object { $_.name }) -join " + "
            return "[$ChangeName] $caps"
        }
        # Fall back to first substantive non-heading line of summary.md
        $firstLine = ($summaryText -split "`n") |
            Where-Object { $_.Trim() -and $_ -notmatch '^[#|]' } |
            Select-Object -First 1
        if ($firstLine -and $firstLine.Trim().Length -gt 5) {
            $clean = $firstLine.Trim()
            return "[$ChangeName] $($clean.Substring(0, [Math]::Min(80, $clean.Length)))"
        }
        return "[$ChangeName] $ChangeName feature implementation"
    }



    function Search-Lines([string]$src, [string]$pat, [int]$max = 5) {
        if (-not $src) { return "" }
        $hits = ($src -split "`n") | Where-Object { $_ -match $pat } | Select-Object -First $max
        return (($hits -join " ").Trim())
    }

    # Priority: 1=implementation, 2=test/env/docs/QA
    function Get-Priority([string]$title, [string]$phase) {
        $s = "$title $phase".ToLower()
        if ($s -match 'manual|smoke|code review|verify all|regression') { return 2 }
        if ($s -match '\btest\b|run.*test|npm|build|\.env|document|readme|env\.example') { return 2 }
        return 1
    }

    # Type: story | test | chore | task (default)
    function Get-Type([string]$title, [string]$phase) {
        $s = "$title $phase".ToLower()
        if ($s -match 'run.*test|full.*test.*suite|npm.*test') { return "test" }
        if ($s -match '\.env\.example|document.*env|readme') { return "chore" }
        return "task"
    }


    # ── Story bead ─────────────────────────────────────────────────────────────
    Write-Host "`n=== make-beads.ps1 — $ChangeName ===" -ForegroundColor Cyan
    Write-Host "`n[Story]" -ForegroundColor Yellow
    $storyTitle = Build-StoryTitle
    $storyDesc  = Build-StoryDescription
    $STORY      = New-Bead $storyTitle $storyDesc 1 "story"
    Write-Host "  $STORY : $storyTitle"

    # ── Task beads ─────────────────────────────────────────────────────────────
    # Map task.Number (e.g. "3.6") -> bead ID, used for dep wiring below.
    $taskIdMap = @{}
    foreach ($grp in ($parsedTasks | Group-Object -Property Phase)) {
        Write-Host "`n[$($grp.Name)]" -ForegroundColor Yellow
        foreach ($task in $grp.Group) {
            $tLabel = "T-{0:D3}" -f $task.SeqNum
            $title  = "[$ChangeName] ${tLabel}: $($task.Title)"
            $desc   = Build-TaskDescription $task
            $pri    = Get-Priority $task.Title $task.Phase
            $typ    = Get-Type     $task.Title $task.Phase
            $id     = New-Bead $title $desc $pri $typ
            $taskIdMap[$task.Number] = $id
            Write-Host "  $tLabel ($($task.Number)): $id"
        }
    }

    # ── Dependency wiring ──────────────────────────────────────────────────────
    # Strategy: sequential within each major phase; first task of each phase
    # is blocked by the last task of the preceding phase.
    # Story bead is blocked by the final task overall.
    Write-Host "`n[Wiring dependencies]" -ForegroundColor Yellow
    $depCount = 0
    function Wire([string]$child, [string]$blocker) {
        if ($child -and $blocker -and $child -ne $blocker) {
            bd dep add $child $blocker | Out-Null
            $script:depCount++
        }
    }

    $byMajor         = $parsedTasks | Group-Object -Property MajorNum | Sort-Object { [int]$_.Name }
    $lastPhaseLastId = $null
    foreach ($grp in $byMajor) {
        $phaseTasks = @($grp.Group | Sort-Object MinorNum)
        $firstId    = $taskIdMap[$phaseTasks[0].Number]
        # First task of this phase is blocked by last task of preceding phase
        if ($lastPhaseLastId -and $firstId) { Wire $firstId $lastPhaseLastId }
        # Sequential deps within the phase
        for ($i = 1; $i -lt $phaseTasks.Count; $i++) {
            $prev = $taskIdMap[$phaseTasks[$i - 1].Number]
            $curr = $taskIdMap[$phaseTasks[$i].Number]
            if ($prev -and $curr) { Wire $curr $prev }
        }
        $lastPhaseLastId = $taskIdMap[$phaseTasks[-1].Number]
    }
    # Story depends on final task
    if ($lastPhaseLastId) { Wire $STORY $lastPhaseLastId }

    Write-Host "  $depCount dependency edges wired." -ForegroundColor Green

    # ── Summary ────────────────────────────────────────────────────────────────
    Write-Host "`n=== Done ===" -ForegroundColor Cyan
    Write-Host "  Change : $ChangeName"                       -ForegroundColor White
    Write-Host "  Story  : $STORY"                            -ForegroundColor White
    Write-Host "  Tasks  : $($parsedTasks.Count) beads created" -ForegroundColor White
    Write-Host "  Deps   : $depCount dependency edges wired"  -ForegroundColor White
    Write-Host ""
    bd stats
    Write-Host "`n  Start: bd ready" -ForegroundColor DarkGray
    Write-Host ""
}
