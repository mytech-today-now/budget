#Requires -Version 5.1
<#
.SYNOPSIS
    Stop and optionally remove the ai-powered Docker container(s).

.DESCRIPTION
    Uses 'docker compose down' when a docker-compose.yml is present,
    otherwise stops and removes the named standalone container.

    By default containers are stopped but NOT removed (volumes and
    images are preserved).  Use -Remove to also delete the container,
    and -Volumes to also delete named volumes.

.PARAMETER Remove
    Remove the container(s) after stopping (equivalent to 'down --remove-orphans').
    For compose: adds '--rmi local' to also remove locally-built images.

.PARAMETER Volumes
    Also remove named volumes declared in the compose file (adds '-v').
    Only meaningful with compose. Implies -Remove.

.PARAMETER ContainerName
    Name of the standalone container to stop when no compose file is
    present. Default: ai-powered-proxy

.EXAMPLE
    # Graceful stop, keep container and volumes
    .\scripts\docker-stop.ps1

.EXAMPLE
    # Stop and remove containers + images
    .\scripts\docker-stop.ps1 -Remove

.EXAMPLE
    # Full teardown including volumes
    .\scripts\docker-stop.ps1 -Volumes
#>
[CmdletBinding()]
param(
    [switch] $Remove,
    [switch] $Volumes,
    [string] $ContainerName = "ai-powered-proxy"
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot\..   # always run from repo root

$Sep = "-" * 60
function Write-Step([string]$msg) { Write-Host "`n$Sep`n  $msg`n$Sep" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "  [OK]  $msg" -ForegroundColor Green }
function Write-Err([string]$msg)  { Write-Host "  [!!]  $msg" -ForegroundColor Red }
function Write-Info([string]$msg) { Write-Host "  --   $msg" -ForegroundColor DarkGray }

if ($Volumes) { $Remove = $true }   # volumes implies remove

$ComposeFile = "docker-compose.yml"

# ---------------------------------------------------------------------------
# 1. Verify Docker is available
# ---------------------------------------------------------------------------
Write-Step "Checking Docker ..."
try {
    $ver = & docker version --format "{{.Server.Version}}" 2>&1
    Write-Ok "Docker daemon $ver"
} catch {
    Write-Err "Docker is not running or not installed."
    exit 1
}

# ---------------------------------------------------------------------------
# 2. Stop via compose or standalone
# ---------------------------------------------------------------------------
if (Test-Path $ComposeFile) {
    # --- Compose path ---
    Write-Step "Stopping via docker compose ($ComposeFile) ..."

    $downArgs = @("compose", "down")
    if ($Remove)  { $downArgs += "--remove-orphans"; $downArgs += "--rmi"; $downArgs += "local" }
    if ($Volumes) { $downArgs += "-v" }

    & docker @downArgs
    if ($LASTEXITCODE -ne 0) { Write-Err "docker compose down failed."; exit 1 }

    if ($Remove)  { Write-Ok "Containers and local images removed." }
    if ($Volumes) { Write-Ok "Volumes removed." }
    if (-not $Remove -and -not $Volumes) { Write-Ok "Containers stopped (images/volumes preserved)." }

} else {
    # --- Standalone container ---
    Write-Step "Stopping container '$ContainerName' ..."

    $existing = & docker ps -a --filter "name=^${ContainerName}$" --format "{{.ID}}" 2>&1
    if (-not $existing) {
        Write-Info "Container '$ContainerName' not found - nothing to stop."
    } else {
        # Check if running
        $running = & docker ps --filter "name=^${ContainerName}$" --format "{{.ID}}" 2>&1
        if ($running) {
            & docker stop $ContainerName | Out-Null
            Write-Ok "Container '$ContainerName' stopped."
        } else {
            Write-Info "Container '$ContainerName' was already stopped."
        }

        if ($Remove) {
            & docker rm $ContainerName | Out-Null
            Write-Ok "Container '$ContainerName' removed."
        }
    }
}

# ---------------------------------------------------------------------------
# 3. Confirm nothing is still listening on the service ports
# ---------------------------------------------------------------------------
Write-Step "Checking ports 3001 / 5173 ..."

$listeners = Get-NetTCPConnection -LocalPort 3001, 5173 -State Listen -ErrorAction SilentlyContinue
if ($listeners) {
    foreach ($l in $listeners) {
        Write-Err "Port :$($l.LocalPort) still has PID $($l.OwningProcess) listening (non-Docker process?)."
    }
} else {
    Write-Ok "Ports 3001 and 5173 are free."
}

Write-Host ""

