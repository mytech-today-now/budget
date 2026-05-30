<#
.SYNOPSIS
    Bump the semantic version, commit all changes, tag, and push to origin/main.

.DESCRIPTION
    Atomically bumps the version in package.json and the VERSION flat file,
    updates package-lock.json via `npm install --package-lock-only`, stages all
    tracked changes, commits with a Conventional Commit subject, creates an
    annotated git tag, and pushes both the commit and the tag to origin/main.

    Optionally runs quality gates (lint -> build -> test) before committing.
    Supports dry-run mode, pre-release identifiers, tag-only mode, and
    a -ChecksOnly mode that runs gates without touching git.

    The script never calls `npm version` so both version files and the lock
    file end up in the same commit. Husky pre-commit hooks run normally.

.PARAMETER Bump
    Semver segment to increment: major | minor | patch | prerelease.
    Mutually exclusive with -NoBump.

.PARAMETER PreId
    Pre-release identifier appended when -Bump prerelease is used.
    Defaults to "alpha". Example: -PreId beta -> v0.5.1-beta.0.

.PARAMETER NoBump
    Skip version bump entirely; use the current version as-is.
    Mutually exclusive with -Bump.

.PARAMETER Message
    Optional commit body text appended after the auto-generated subject.
    Also used as the subject suffix when -NoBump is set.

.PARAMETER RunChecks
    Run `npm run lint`, `npm run build`, and `npm test` before committing.
    Aborts on the first failing gate.

.PARAMETER ChecksOnly
    Run quality gates then exit without committing or pushing. Useful as a
    pre-PR sanity check.

.PARAMETER DryRun
    Print every action that would execute without touching any file, git
    object, or remote. Read-only git commands still run so safety checks
    remain meaningful.

.PARAMETER NoConfirm
    Skip the interactive confirmation prompt. Use in automation pipelines.

.PARAMETER TagOnly
    Create and push the version tag only; skip staging and committing.
    Useful when the commit already exists but the tag was not pushed.

.PARAMETER ForceTag
    Delete the local tag if it exists, recreate it, then force-push it to
    origin. Use when a tag needs to be re-signed or corrected.

.PARAMETER Verbose
    Built-in common parameter. Prints each git/npm command before executing it
    (propagates $VerbosePreference = 'Continue' to all helper functions).

.EXAMPLE
    .\scripts\bump-and-push.ps1 -Bump patch
    Bump patch (0.5.0 -> 0.5.1), stage all, commit, tag v0.5.1, push.

.EXAMPLE
    .\scripts\bump-and-push.ps1 -Bump minor -Message "add server-side video stitching"
    Bump minor, append custom body to commit message.

.EXAMPLE
    .\scripts\bump-and-push.ps1 -Bump major -RunChecks
    Run lint + build + test, then bump major and push.

.EXAMPLE
    .\scripts\bump-and-push.ps1 -Bump minor -DryRun
    Preview every action without touching anything.

.EXAMPLE
    .\scripts\bump-and-push.ps1 -NoBump -Message "chore: fix typo in README"
    Commit and push current changes without changing the version.

.EXAMPLE
    .\scripts\bump-and-push.ps1 -Bump prerelease -PreId beta
    Bump to next pre-release: 0.5.0 -> 0.5.1-beta.0 (or -beta.1 if already pre).

.EXAMPLE
    .\scripts\bump-and-push.ps1 -NoBump -TagOnly -ForceTag
    Re-create and force-push the current version tag.

.EXAMPLE
    .\scripts\bump-and-push.ps1 -ChecksOnly
    Run lint, build, and test; exit without committing.
#>

[CmdletBinding(DefaultParameterSetName = 'Bump')]
param(
    [Parameter(ParameterSetName = 'Bump')]
    [ValidateSet('major', 'minor', 'patch', 'prerelease')]
    [string] $Bump,

    [string]  $PreId      = 'alpha',
    [Parameter(ParameterSetName = 'NoBump')]
    [switch]  $NoBump,
    [string]  $Message    = '',
    [switch]  $RunChecks,
    [switch]  $ChecksOnly,
    [switch]  $DryRun,
    [switch]  $NoConfirm,
    [switch]  $TagOnly,
    [switch]  $ForceTag
    # -Verbose is a built-in common parameter; use $VerbosePreference -eq 'Continue' to test it.
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Repo root ----------------------------------------------------------------
$RepoRoot      = Split-Path $PSScriptRoot -Parent
$PkgJsonPath   = Join-Path $RepoRoot 'package.json'
$PkgLockPath   = Join-Path $RepoRoot 'package-lock.json'
$VersionPath   = Join-Path $RepoRoot 'VERSION'

# -- Colour support -----------------------------------------------------------
$NoColor = [bool]$env:NO_COLOR
function script:clr([string]$text, [string]$code) {
    if ($NoColor) { return $text }
    # Use [char]0x1B (ESC) - compatible with PS 5.1 and PS 7+.
    # Backtick-e (`e) only works in PS 6+, so we avoid it here.
    $e = [char]0x1B
    return "${e}[${code}m${text}${e}[0m"
}
function script:Cyan($t)   { clr $t '36' }
function script:Green($t)  { clr $t '32' }
function script:Yellow($t) { clr $t '33' }
function script:Red($t)    { clr $t '31' }
function script:Bold($t)   { clr $t '1'  }

function Write-Header([string]$text) {
    $pad = '-' * [Math]::Max(0, 44 - $text.Length)
    Write-Host ''
    Write-Host (Cyan "-- $text $pad")
}
function Write-Ok([string]$text)   { Write-Host (Green  "  + $text") }
function Write-Warn([string]$text) { Write-Host (Yellow "  ! $text") }
function Write-Err([string]$text)  { Write-Host (Red    "  x $text") }
function Write-Info([string]$text) { Write-Host "    $text" }


# ===============================================================================
# HELPERS
# ===============================================================================

# -- Assert-ExitCode ----------------------------------------------------------
# Call after every external process. Prints the failed command + exit code and
# terminates the script with exit 1.
function Assert-ExitCode([int]$code, [string]$cmd) {
    if ($code -ne 0) {
        Write-Err "Command failed (exit $code): $cmd"
        exit 1
    }
}

# -- Invoke-Step --------------------------------------------------------------
# Wraps a destructive or network action. In dry-run mode prints the command
# string and returns without executing.
function Invoke-Step([string]$label, [scriptblock]$action) {
    if ($VerbosePreference -eq 'Continue') { Write-Info (Yellow "  > $label") }
    if ($DryRun) {
        Write-Host (Yellow "  [DRY RUN] $label")
        return
    }
    & $action
}

# -- Invoke-Git ---------------------------------------------------------------
function Invoke-Git([string[]]$gitArgs, [switch]$PassThru, [switch]$AllowFail) {
    $cmd = "git $($gitArgs -join ' ')"
    if ($VerbosePreference -eq 'Continue') { Write-Info (Yellow "  > $cmd") }
    if ($PassThru) {
        $out = & git @gitArgs 2>&1
        if (-not $AllowFail) { Assert-ExitCode $LASTEXITCODE $cmd }
        # Always return a flat string so callers can safely call .Trim()
        return ($out -join "`n")
    }
    & git @gitArgs
    if (-not $AllowFail) { Assert-ExitCode $LASTEXITCODE $cmd }
}

# -- Invoke-Npm ---------------------------------------------------------------
function Invoke-Npm([string[]]$npmArgs, [switch]$PassThru, [switch]$AllowFail) {
    $cmd = "npm $($npmArgs -join ' ')"
    if ($VerbosePreference -eq 'Continue') { Write-Info (Yellow "  > $cmd") }
    if ($PassThru) {
        $out = & npm @npmArgs 2>&1
        if (-not $AllowFail) { Assert-ExitCode $LASTEXITCODE $cmd }
        return $out
    }
    & npm @npmArgs
    if (-not $AllowFail) { Assert-ExitCode $LASTEXITCODE $cmd }
}

# ===============================================================================
# SEMVER
# ===============================================================================

$SemverRx = '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?:-(?<pre>[a-zA-Z][a-zA-Z0-9]*)(?:\.(?<prenum>\d+))?)?$'

function Test-Semver([string]$v) { return [bool]($v -match $SemverRx) }

function Read-CurrentVersion {
    if (-not (Test-Path $PkgJsonPath)) {
        Write-Err "package.json not found at: $PkgJsonPath"; exit 1
    }
    $pkg = Get-Content $PkgJsonPath -Raw | ConvertFrom-Json
    if (-not (Test-Semver $pkg.version)) {
        Write-Err "package.json contains an invalid semver: '$($pkg.version)'"; exit 1
    }
    return $pkg.version
}

function Get-NewVersion([string]$current, [string]$bump, [string]$preId) {
    if (-not ($current -match $SemverRx)) {
        Write-Err "Cannot parse current version: '$current'"; exit 1
    }
    [int]$maj  = $Matches['major']
    [int]$min  = $Matches['minor']
    [int]$pat  = $Matches['patch']
    $pre       = $Matches['pre']      # may be $null
    $preNumStr = $Matches['prenum']   # may be $null

    switch ($bump) {
        'major'      { return "$($maj + 1).0.0" }
        'minor'      { return "$maj.$($min + 1).0" }
        'patch'      { return "$maj.$min.$($pat + 1)" }
        'prerelease' {
            if ($pre -and $null -ne $preNumStr -and $pre -eq $preId) {
                return "$maj.$min.$pat-${preId}.$([int]$preNumStr + 1)"
            }
            if ($pre) { return "$maj.$min.$pat-${preId}.0" }
            return "$maj.$min.$($pat + 1)-${preId}.0"
        }
    }
    Write-Err "Unknown bump type: '$bump'"; exit 1
}

function Write-VersionFiles([string]$newVersion) {
    # Rewrite package.json preserving all fields; use ConvertTo-Json depth 100
    $pkg = Get-Content $PkgJsonPath -Raw | ConvertFrom-Json
    $pkg.version = $newVersion
    # Use WriteAllText with UTF8 (no-BOM) - Set-Content -Encoding UTF8 adds a BOM on
    # Windows PowerShell 5.1, which breaks JSON parsers (e.g. lint-staged, Node.js loaders).
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($PkgJsonPath, ($pkg | ConvertTo-Json -Depth 100), $utf8NoBom)
    # Flat VERSION file - no trailing newline
    [System.IO.File]::WriteAllText($VersionPath, $newVersion, $utf8NoBom)
}

function Backup-VersionFiles {
    $tmp = [System.IO.Path]::GetTempPath()
    Copy-Item $PkgJsonPath  (Join-Path $tmp 'bap_pkg.bak')  -Force
    Copy-Item $VersionPath  (Join-Path $tmp 'bap_ver.bak')   -Force
    if (Test-Path $PkgLockPath) {
        Copy-Item $PkgLockPath (Join-Path $tmp 'bap_lock.bak') -Force
    }
}

function Restore-VersionFiles {
    $tmp = [System.IO.Path]::GetTempPath()
    $bPkg  = Join-Path $tmp 'bap_pkg.bak'
    $bVer  = Join-Path $tmp 'bap_ver.bak'
    $bLock = Join-Path $tmp 'bap_lock.bak'
    if (Test-Path $bPkg)  { Copy-Item $bPkg  $PkgJsonPath  -Force }
    if (Test-Path $bVer)  { Copy-Item $bVer  $VersionPath  -Force }
    if (Test-Path $bLock) { Copy-Item $bLock $PkgLockPath  -Force }
    Write-Warn 'Version files restored from pre-flight backup.'
}


# ===============================================================================
# GIT SAFETY CHECKS
# ===============================================================================

function Invoke-GitSafetyChecks([bool]$isDryRun) {
    Write-Header 'Git safety checks'

    # 1. git on PATH and inside a repo
    $gitVersion = & git --version 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Err 'git not found on PATH.'; exit 1 }
    Write-Ok $gitVersion

    $insideRepo = & git rev-parse --is-inside-work-tree 2>&1
    if ($LASTEXITCODE -ne 0 -or $insideRepo -ne 'true') {
        Write-Err 'Not inside a git repository. Run from the repo root.'
        exit 1
    }
    Write-Ok 'Inside a git repository'

    # 2. Current branch must be main
    $branch = (Invoke-Git @('rev-parse', '--abbrev-ref', 'HEAD') -PassThru).Trim()
    if ($branch -ne 'main') {
        if ($isDryRun) {
            Write-Warn "Not on main (current: $branch) - continuing in dry-run mode."
        } else {
            Write-Err "Must be on branch 'main'. Current branch: '$branch'"
            Write-Info "  Switch with: git checkout main"
            exit 1
        }
    } else {
        Write-Ok "On branch: main"
    }

    # 3. origin remote is reachable
    Write-Info 'Checking origin remote...'
    & git ls-remote --exit-code origin *>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Remote 'origin' is not reachable. Check your network or credentials."
        exit 1
    }
    $remoteUrl = (Invoke-Git @('remote', 'get-url', 'origin') -PassThru).Trim()
    Write-Ok "origin reachable: $remoteUrl"

    # 4. Local branch is not behind origin/main
    & git fetch origin main --quiet 2>&1 | Out-Null
    $behindCount = (& git rev-list --count HEAD..origin/main 2>&1).Trim()
    if ($LASTEXITCODE -eq 0 -and [int]$behindCount -gt 0) {
        Write-Err "Local main is $behindCount commit(s) behind origin/main."
        Write-Info "  Run: git pull --rebase origin main"
        exit 1
    }
    Write-Ok 'Local main is up-to-date with origin/main'

    return $branch, $remoteUrl
}

# ===============================================================================
# QUALITY GATES
# ===============================================================================

function Invoke-QualityGates {
    Write-Header 'Quality gates'
    Push-Location $RepoRoot
    $results = @{}

    $gates = @(
        @{ label = 'lint';  cmd = { & npm run lint  2>&1 } }
        @{ label = 'build'; cmd = { & npm run build 2>&1 } }
        @{ label = 'test';  cmd = {
            $env:AI_MOCK = 'true'
            & npm test 2>&1
            Remove-Item Env:AI_MOCK -ErrorAction SilentlyContinue
        }}
    )

    foreach ($gate in $gates) {
        $label = $gate.label
        Write-Info "Running npm run $label ..."
        $output = & $gate.cmd
        $ec     = $LASTEXITCODE
        if ($ec -eq 0) {
            Write-Ok "$label passed"
            $results[$label] = $true
        } else {
            Write-Err "$label FAILED (exit $ec)"
            # Print the last 20 lines of output for diagnostics
            $tail = ($output | Select-Object -Last 20) -join "`n"
            Write-Host (Red $tail)
            Pop-Location
            exit 1
        }
    }

    Pop-Location
    return $results
}

# ===============================================================================
# COMMIT, TAG, PUSH
# ===============================================================================

function Invoke-Commit([string]$subject, [string]$body) {
    Write-Header 'Staging and committing'

    Invoke-Step "git add -u" {
        Invoke-Git @('add', '-u')
    }
    # Always stage the version files explicitly (they may be untracked if new)
    foreach ($f in @($PkgJsonPath, $PkgLockPath, $VersionPath)) {
        if (Test-Path $f) {
            Invoke-Step "git add $(Split-Path $f -Leaf)" {
                Invoke-Git @('add', $f)
            }
        }
    }

    $commitArgs = @('commit', '-m', $subject)
    if ($body -and $body.Trim() -ne '') {
        $commitArgs += @('-m', $body.Trim())
    }

    Invoke-Step "git commit -m `"$subject`"" {
        & git @commitArgs
        Assert-ExitCode $LASTEXITCODE "git commit"
    }

    if (-not $DryRun) {
        $sha = (Invoke-Git @('rev-parse', '--short', 'HEAD') -PassThru).Trim()
        Write-Ok "Committed: $sha  $subject"
        return $sha
    }
    return '<dry-run>'
}

function Invoke-Tag([string]$tagName, [bool]$force) {
    Write-Header "Tagging $tagName"

    # Check if tag already exists locally (read-only - runs even in dry-run mode)
    $existingTag = (Invoke-Git @('tag', '-l', $tagName) -PassThru -AllowFail).Trim()
    if ([string]$existingTag -eq $tagName) {
        if ($force) {
            Invoke-Step "git tag -d $tagName  (force-delete existing)" {
                Invoke-Git @('tag', '-d', $tagName)
            }
            Write-Warn "Existing local tag '$tagName' deleted."
        } else {
            Write-Err "Tag '$tagName' already exists locally."
            Write-Info "  To overwrite: add -ForceTag to your command."
            exit 1
        }
    }

    Invoke-Step "git tag -a $tagName -m `"Release $tagName`"" {
        Invoke-Git @('tag', '-a', $tagName, '-m', "Release $tagName")
    }
    Write-Ok "Annotated tag created: $tagName"
}

function Invoke-Push([string]$tagName, [bool]$force) {
    Write-Header 'Pushing to origin'

    Invoke-Step 'git push origin main' {
        Invoke-Git @('push', 'origin', 'main')
    }
    Write-Ok 'Pushed commit(s) to origin/main'

    $pushTagArgs = @('push', 'origin', $tagName)
    if ($force) { $pushTagArgs += '--force' }
    $pushTagLabel = "git push origin $tagName$(if ($force) { ' --force' })"
    Invoke-Step $pushTagLabel {
        Invoke-Git $pushTagArgs
    }
    Write-Ok "Pushed tag: $tagName"
}

# ===============================================================================
# SUMMARY
# ===============================================================================

function Write-Summary(
    [string]$oldVersion, [string]$newVersion, [string]$tagName,
    [string]$branch,     [string]$remoteUrl,  [string]$commitSha,
    [string]$commitMsg,  [hashtable]$gateResults
) {
    $bar    = '-' * 45
    $checks = if ($null -eq $gateResults) { 'no' } else {
        $parts = $gateResults.Keys | Sort-Object | ForEach-Object { "$_$(if ($gateResults[$_]) { ' +' } else { ' x' })" }
        "yes  ($($parts -join '  '))"
    }
    Write-Host ''
    Write-Host (Cyan $bar)
    Write-Host (Bold ' bump-and-push  complete')
    Write-Host (Cyan $bar)
    Write-Host (Green " Old version : $oldVersion")
    Write-Host (Green " New version : $newVersion")
    Write-Host (Green " Tag         : $tagName")
    Write-Host       " Branch      : $branch"
    Write-Host       " Remote      : origin  ($remoteUrl)"
    Write-Host       " Commit      : $commitSha  $commitMsg"
    Write-Host       " Checks run  : $checks"
    if ($DryRun) { Write-Host (Yellow " *** DRY RUN - no changes were made ***") }
    Write-Host (Cyan $bar)
    Write-Host ''
}


# ===============================================================================
# MAIN
# ===============================================================================

function Main {
    # -- Parameter validation -------------------------------------------------
    if (-not $Bump -and -not $NoBump -and -not $ChecksOnly) {
        Write-Err 'Specify either -Bump <major|minor|patch|prerelease> or -NoBump (or -ChecksOnly).'
        Write-Info 'Run: Get-Help .\scripts\bump-and-push.ps1 -Full'
        exit 1
    }
    if ($Bump -and $NoBump) {
        Write-Err '-Bump and -NoBump are mutually exclusive.'
        exit 1
    }
    if ($TagOnly -and -not $NoBump -and -not $Bump) {
        Write-Err '-TagOnly requires either -Bump or -NoBump to identify the version.'
        exit 1
    }

    Set-Location $RepoRoot

    # -- -ChecksOnly shortcut -------------------------------------------------
    if ($ChecksOnly) {
        Invoke-QualityGates | Out-Null
        Write-Ok 'All quality gates passed. Nothing committed or pushed (-ChecksOnly).'
        return
    }

    # -- Git safety checks ----------------------------------------------------
    $branch, $remoteUrl = Invoke-GitSafetyChecks -isDryRun $DryRun.IsPresent

    # -- Read current version -------------------------------------------------
    $oldVersion = Read-CurrentVersion
    Write-Header "Version"
    Write-Info   "Current version: $(Green $oldVersion)"

    # -- Compute new version --------------------------------------------------
    if ($NoBump) {
        $newVersion = $oldVersion
        Write-Info   "No bump requested - keeping: $(Green $newVersion)"
    } else {
        $newVersion = Get-NewVersion -current $oldVersion -bump $Bump -preId $PreId
        if (-not (Test-Semver $newVersion)) {
            Write-Err "Computed version '$newVersion' is not valid semver. Aborting."
            exit 1
        }
        Write-Info "New version:     $(Green $newVersion)  (bump: $Bump)"
    }

    $tagName = "v$newVersion"

    # -- Guard: nothing to do -------------------------------------------------
    if ($NoBump) {
        $status = (Invoke-Git @('status', '--porcelain') -PassThru).Trim()
        if ($status -eq '' -and -not $TagOnly) {
            Write-Warn 'Working tree is clean and -NoBump is set - nothing to commit.'
            exit 0
        }
    }

    # -- Quality gates (optional) ---------------------------------------------
    $gateResults = $null
    if ($RunChecks -or $ChecksOnly) {
        $gateResults = Invoke-QualityGates
    }

    # -- Interactive confirmation ---------------------------------------------
    if (-not $NoConfirm -and -not $DryRun) {
        Write-Host ''
        Write-Host (Yellow "  About to: bump $oldVersion -> $newVersion, commit, tag $tagName, push to origin/main")
        $answer = Read-Host '  Proceed? [y/N]'
        if ($answer -notmatch '^[Yy]') {
            Write-Warn 'Aborted by user.'
            exit 0
        }
    }

    # -- Build commit subject -------------------------------------------------
    # Conventional Commit type pattern: "type:" or "type(scope):" at the start.
    $ccPrefix = '^[a-z]+(\([^)]+\))?!?:'
    $commitSubject = if ($NoBump) {
        $trimmed = $Message.Trim()
        if ($trimmed -ne '' -and $trimmed -match $ccPrefix) {
            # Message already has a Conventional Commit prefix - use verbatim.
            $trimmed
        } elseif ($trimmed -ne '') {
            "chore: $trimmed"
        } else {
            'chore: maintenance'
        }
    } else {
        "chore(release): bump version to $tagName"
    }
    $commitBody = if ($Bump -and $Message -and $Message.Trim() -ne '') { $Message.Trim() } else { '' }

    # -- Write version files + lock file (guarded by try/finally backup) ------
    $versionFilesWritten = $false
    try {
        if (-not $NoBump -and -not $TagOnly) {
            Backup-VersionFiles

            Write-Header 'Writing version files'
            Invoke-Step "Write $newVersion -> package.json + VERSION" {
                Write-VersionFiles $newVersion
            }
            $versionFilesWritten = $true

            # Sync package-lock.json without downloading packages
            Invoke-Step 'npm install --package-lock-only --ignore-scripts' {
                & npm install --package-lock-only --ignore-scripts --quiet
                Assert-ExitCode $LASTEXITCODE 'npm install --package-lock-only'
            }
            Write-Ok "package.json, VERSION, package-lock.json updated to $newVersion"
        }

        # -- Commit (skip if -TagOnly) -----------------------------------------
        $commitSha = '<skipped>'
        if (-not $TagOnly) {
            $commitSha = Invoke-Commit -subject $commitSubject -body $commitBody
        }

        # -- Tag ---------------------------------------------------------------
        Invoke-Tag -tagName $tagName -force $ForceTag.IsPresent

        # -- Push --------------------------------------------------------------
        Invoke-Push -tagName $tagName -force $ForceTag.IsPresent

    } catch {
        Write-Err "Unexpected error: $_"
        if ($versionFilesWritten -and -not $DryRun) {
            Restore-VersionFiles
        }
        exit 1
    }

    # -- Summary ---------------------------------------------------------------
    Write-Summary `
        -oldVersion  $oldVersion `
        -newVersion  $newVersion `
        -tagName     $tagName `
        -branch      $branch `
        -remoteUrl   $remoteUrl `
        -commitSha   $commitSha `
        -commitMsg   $commitSubject `
        -gateResults $gateResults
}

# -- Entry point ---------------------------------------------------------------
Main
