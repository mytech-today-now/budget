#Requires -Version 5.1
<#
.SYNOPSIS
    Build (if needed) and start the ai-powered Docker container.

.DESCRIPTION
    Uses 'docker compose up' to bring up the service defined in
    docker-compose.yml at the repository root.  If no compose file
    exists, falls back to a plain 'docker run' invocation using
    sensible defaults for this repo.

    After starting, the script waits for the proxy health endpoint
    to respond and prints a status summary.

.PARAMETER Port
    Host port to map to the container's proxy port. Default: 3001

.PARAMETER VitePort
    Host port to map to the container's Vite port. Default: 5173

.PARAMETER Mock
    Start the proxy in mock mode inside the container. Default: $true

.PARAMETER NoBuild
    Skip 'docker compose build' and use the existing image.

.PARAMETER Detach
    Run containers in the background (detached). Default: $true

.EXAMPLE
    # Normal start (detached, mock mode)
    .\scripts\docker-start.ps1

.EXAMPLE
    # Force image rebuild then start
    .\scripts\docker-start.ps1 -NoBuild:$false

.EXAMPLE
    # Start in live mode (real providers)
    .\scripts\docker-start.ps1 -Mock:$false
#>
[CmdletBinding()]
param(
    [int]    $Port     = 3001,
    [int]    $VitePort = 5173,
    [switch] $Mock     = $true,
    [switch] $NoBuild,
    [switch] $Detach   = $true
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot\..   # always run from repo root

$Sep = "-" * 60
function Write-Step([string]$msg) { Write-Host "`n$Sep`n  $msg`n$Sep" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "  [OK]  $msg" -ForegroundColor Green }
function Write-Err([string]$msg)  { Write-Host "  [!!]  $msg" -ForegroundColor Red }

$ComposeFile = "docker-compose.yml"
$ImageName   = "ai-powered"
$ContainerName = "ai-powered-proxy"

# ---------------------------------------------------------------------------
# 1. Verify Docker is available
# ---------------------------------------------------------------------------
Write-Step "Checking Docker ..."
try {
    $ver = & docker version --format "{{.Server.Version}}" 2>&1
    Write-Ok "Docker daemon $ver"
} catch {
    Write-Err "Docker is not running or not installed. Start Docker Desktop first."
    exit 1
}

# ---------------------------------------------------------------------------
# 2. Choose compose vs plain docker run
# ---------------------------------------------------------------------------
if (Test-Path $ComposeFile) {
    # --- Compose path ---
    Write-Step "Starting via docker compose ($ComposeFile) ..."

    $buildArg = if ($NoBuild) { "--no-build" } else { "--build" }

    $env:AI_MOCK     = if ($Mock) { "true" } else { "false" }
    $env:PROXY_PORT  = $Port
    $env:VITE_PORT   = $VitePort

    $composeArgs = @("compose", "up", $buildArg)
    if ($Detach) { $composeArgs += "--detach" }

    & docker @composeArgs
    if ($LASTEXITCODE -ne 0) { Write-Err "docker compose up failed."; exit 1 }
    Write-Ok "Containers started via compose."

} else {
    # --- Fallback: plain docker run ---
    Write-Step "No docker-compose.yml found - using plain docker run ..."

    # Build image if it doesn't exist or if NoBuild was not requested
    $existing = & docker images -q $ImageName 2>&1
    if (-not $existing -or -not $NoBuild) {
        Write-Step "Building Docker image '$ImageName' ..."
        & docker build -t $ImageName .
        if ($LASTEXITCODE -ne 0) { Write-Err "docker build failed."; exit 1 }
        Write-Ok "Image built: $ImageName"
    } else {
        Write-Ok "Using existing image: $ImageName"
    }

    # Remove any stale container with the same name
    & docker rm -f $ContainerName 2>$null | Out-Null

    $mockEnv = if ($Mock) { "true" } else { "false" }

    $runArgs = @(
        "run", "--name", $ContainerName,
        "-p", "${Port}:3001",
        "-p", "${VitePort}:5173",
        "-e", "AI_MOCK=$mockEnv"
    )
    if ($Detach) { $runArgs += "-d" }
    $runArgs += $ImageName

    & docker @runArgs
    if ($LASTEXITCODE -ne 0) { Write-Err "docker run failed."; exit 1 }
    Write-Ok "Container '$ContainerName' started."
}

# ---------------------------------------------------------------------------
# 3. Health check
# ---------------------------------------------------------------------------
if ($Detach) {
    Write-Step "Waiting for proxy health check on :$Port ..."
    $ok = $false
    for ($i = 1; $i -le 20; $i++) {
        Start-Sleep -Seconds 1
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("127.0.0.1", $Port)
            $tcp.Close()
            $ok = $true
            break
        } catch { <# still starting #> }
    }
    if ($ok) {
        Write-Ok "Proxy healthy -> http://localhost:$Port"
        Write-Ok "Vite UI      -> http://localhost:$VitePort"
    } else {
        Write-Err "Proxy did not become healthy after 20 s. Check container logs:"
        Write-Host "  docker logs $ContainerName" -ForegroundColor Yellow
        exit 1
    }
}

Write-Host ""

