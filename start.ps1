$ErrorActionPreference = "Stop"

$StoatDir = "C:\Stoat"
$Cloudflared = "C:\Cloudflared\cloudflared.exe"
$Config = "$StoatDir\cloudflare\config.yml"

function Step($Text) {
    Write-Host "  $Text" -ForegroundColor DarkGray
}

try {
    Clear-Host

    Write-Host ""
    Write-Host "Stoat Startup" -ForegroundColor Cyan
    Write-Host ""

    if (-not (Test-Path $StoatDir)) {
        throw "Stoat installation was not found at $StoatDir."
    }

    if (-not (Test-Path $Cloudflared)) {
        $Command = Get-Command cloudflared -ErrorAction SilentlyContinue

        if ($Command) {
            $Cloudflared = $Command.Source
        }
        else {
            throw "cloudflared.exe was not found."
        }
    }

    if (-not (Test-Path $Config)) {
        throw "Cloudflare configuration was not found at $Config."
    }

    Step "Configuring Cloudflare firewall rules..."

    $TcpRule = Get-NetFirewallRule `
        -DisplayName "Stoat Cloudflared TCP 7844" `
        -ErrorAction SilentlyContinue

    if (-not $TcpRule) {
        New-NetFirewallRule `
            -DisplayName "Stoat Cloudflared TCP 7844" `
            -Direction Outbound `
            -Action Allow `
            -Protocol TCP `
            -RemotePort 7844 `
            -Program $Cloudflared | Out-Null
    }
    else {
        Set-NetFirewallRule `
            -DisplayName "Stoat Cloudflared TCP 7844" `
            -Enabled True `
            -Direction Outbound `
            -Action Allow
    }

    $UdpRule = Get-NetFirewallRule `
        -DisplayName "Stoat Cloudflared UDP 7844" `
        -ErrorAction SilentlyContinue

    if (-not $UdpRule) {
        New-NetFirewallRule `
            -DisplayName "Stoat Cloudflared UDP 7844" `
            -Direction Outbound `
            -Action Allow `
            -Protocol UDP `
            -RemotePort 7844 `
            -Program $Cloudflared | Out-Null
    }
    else {
        Set-NetFirewallRule `
            -DisplayName "Stoat Cloudflared UDP 7844" `
            -Enabled True `
            -Direction Outbound `
            -Action Allow
    }

    Step "Starting Docker Desktop..."

    $DockerDesktop = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"

    if (Test-Path $DockerDesktop) {
        Start-Process `
            $DockerDesktop `
            -ErrorAction SilentlyContinue
    }

    Step "Waiting for Docker..."

    $DockerReady = $false

    for ($i = 0; $i -lt 90; $i++) {
        docker info *> $null

        if ($LASTEXITCODE -eq 0) {
            $DockerReady = $true
            break
        }

        Start-Sleep -Seconds 2
    }

    if (-not $DockerReady) {
        throw "Docker Desktop did not become ready."
    }

    Step "Starting Stoat..."

    Set-Location $StoatDir

    docker compose up -d

    if ($LASTEXITCODE -ne 0) {
        throw "Stoat failed to start."
    }

    Step "Validating Cloudflare configuration..."

    & $Cloudflared `
        tunnel `
        ingress `
        validate `
        --config $Config

    if ($LASTEXITCODE -ne 0) {
        throw "Cloudflare configuration validation failed."
    }

    Step "Starting Cloudflare Tunnel..."
    Write-Host ""

    & $Cloudflared `
        tunnel `
        --config $Config `
        run
}
catch {
    Write-Host ""
    Write-Host "Startup failed:" -ForegroundColor Red
    Write-Host ""
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Read-Host "Press Enter to close"
    exit 1
}