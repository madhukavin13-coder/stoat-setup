$ErrorActionPreference = "Stop"

function Step($Text) {
    Write-Host "  $Text" -ForegroundColor DarkGray
}

function Ask($Prompt, $Default = "") {
    if ($Default) {
        $Value = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($Value)) {
            return $Default
        }
        return $Value.Trim()
    }

    return (Read-Host $Prompt).Trim()
}

function Ask-YesNo($Prompt, $Default = $true) {
    $Suffix = if ($Default) { "[Y/n]" } else { "[y/N]" }

    while ($true) {
        $Value = Read-Host "$Prompt $Suffix"

        if ([string]::IsNullOrWhiteSpace($Value)) {
            return $Default
        }

        switch -Regex ($Value.Trim().ToLower()) {
            "^(y|yes)$" { return $true }
            "^(n|no)$"  { return $false }
        }
    }
}

function Is-Admin {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = [Security.Principal.WindowsPrincipal]::new($Identity)

    return $Principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Restart-AsAdmin {
    if (Is-Admin) {
        return
    }

    Write-Host ""
    Write-Host "Administrator access is required." -ForegroundColor Yellow
    Write-Host "Restarting setup..."
    Write-Host ""

    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        "-NoProfile"
        "-ExecutionPolicy"
        "Bypass"
        "-File"
        "`"$PSCommandPath`""
    )

    exit
}

function Refresh-Path {
    $env:Path =
        [Environment]::GetEnvironmentVariable("Path", "Machine") +
        ";" +
        [Environment]::GetEnvironmentVariable("Path", "User")
}

function Require-Winget {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget is not available on this Windows installation."
    }
}

function Install-Git {
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Step "Git found."
        return
    }

    Step "Installing Git..."

    winget install `
        --id Git.Git `
        --exact `
        --accept-source-agreements `
        --accept-package-agreements

    if ($LASTEXITCODE -ne 0) {
        throw "Git installation failed."
    }

    Refresh-Path

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git was installed but is not available yet. Restart setup and try again."
    }
}

function Install-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Step "Installing Docker Desktop..."

        winget install `
            --id Docker.DockerDesktop `
            --exact `
            --accept-source-agreements `
            --accept-package-agreements

        if ($LASTEXITCODE -ne 0) {
            throw "Docker Desktop installation failed."
        }

        Refresh-Path
    }
    else {
        Step "Docker found."
    }

    $DockerDesktop = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"

    if (Test-Path $DockerDesktop) {
        Step "Starting Docker Desktop..."
        Start-Process $DockerDesktop -ErrorAction SilentlyContinue
    }

    Step "Waiting for Docker..."

    for ($i = 0; $i -lt 90; $i++) {
        docker info *> $null

        if ($LASTEXITCODE -eq 0) {
            Step "Docker is ready."
            return
        }

        Start-Sleep -Seconds 2
    }

    throw "Docker Desktop did not become ready."
}

function Download-Cloudflared {
    $Existing = Get-Command cloudflared -ErrorAction SilentlyContinue

    if ($Existing) {
        Step "cloudflared found."
        return $Existing.Source
    }

    $Directory = "C:\Cloudflared"
    $Executable = Join-Path $Directory "cloudflared.exe"

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $Directory | Out-Null

    Step "Downloading cloudflared..."

    Invoke-WebRequest `
        -Uri "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe" `
        -OutFile $Executable

    if (-not (Test-Path $Executable)) {
        throw "cloudflared download failed."
    }

    return $Executable
}

function Fix-LineEndings($File) {
    $Bytes = [System.IO.File]::ReadAllBytes($File)

    $Output = [System.Collections.Generic.List[byte]]::new()

    for ($i = 0; $i -lt $Bytes.Length; $i++) {
        if (
            $Bytes[$i] -eq 13 -and
            ($i + 1) -lt $Bytes.Length -and
            $Bytes[$i + 1] -eq 10
        ) {
            continue
        }

        $Output.Add($Bytes[$i])
    }

    [System.IO.File]::WriteAllBytes(
        $File,
        $Output.ToArray()
    )
}

function Clone-Stoat($Directory) {
    $Repo = "https://github.com/stoatchat/self-hosted.git"

    if (Test-Path (Join-Path $Directory ".git")) {
        Step "Existing Stoat repository found."
        Set-Location $Directory

        Step "Updating repository..."

        git pull

        if ($LASTEXITCODE -ne 0) {
            throw "Git could not update the Stoat repository."
        }

        return
    }

    if (Test-Path $Directory) {
        throw "$Directory already exists and is not a Stoat repository."
    }

    Step "Downloading Stoat..."

    git clone $Repo $Directory

    if ($LASTEXITCODE -ne 0) {
        throw "Stoat download failed."
    }

    Set-Location $Directory
}

function Generate-Config($Directory, $Domain, $Video) {
    $Generator = Join-Path $Directory "generate_config.sh"

    if (-not (Test-Path $Generator)) {
        throw "generate_config.sh was not found."
    }

    Fix-LineEndings $Generator

    $VideoAnswer = if ($Video) { "y" } else { "n" }

    Step "Generating Stoat configuration..."

    # Stoat's official generator is a Bash script.
    # Run it inside a temporary Linux container so Windows
    # does not need a native Bash/OpenSSL environment.
    $Command = @"
apk add --no-cache bash openssl coreutils >/dev/null 2>&1 &&
chmod +x ./generate_config.sh &&
printf "n\n$VideoAnswer\n" |
./generate_config.sh "$Domain"
"@

    docker run `
        --rm `
        -i `
        -v "${Directory}:/stoat" `
        -w /stoat `
        alpine:latest `
        sh -c $Command

    if ($LASTEXITCODE -ne 0) {
        throw "Stoat configuration generation failed."
    }
}

function Start-Stoat($Directory) {
    Set-Location $Directory

    Step "Downloading Stoat container images..."

    docker compose pull

    if ($LASTEXITCODE -ne 0) {
        throw "Docker could not download the Stoat images."
    }

    Step "Starting Stoat..."

    docker compose up -d

    if ($LASTEXITCODE -ne 0) {
        throw "Stoat failed to start."
    }

    Step "Checking Stoat containers..."

    docker compose ps
}

function Setup-Cloudflare($Cloudflared, $Directory, $Domain) {
    Write-Host ""
    Write-Host "Cloudflare Tunnel" -ForegroundColor Cyan
    Write-Host ""

    Step "Cloudflare login is required once."
    Step "A browser window will open."

    Write-Host ""
    Read-Host "Press Enter to continue"

    & $Cloudflared tunnel login

    if ($LASTEXITCODE -ne 0) {
        throw "Cloudflare login failed."
    }

    $TunnelName = "stoat-$($Domain -replace '[^a-zA-Z0-9-]', '-')"

    Step "Creating tunnel: $TunnelName"

    $TunnelList = & $Cloudflared tunnel list --output json 2>$null

    $ExistingTunnel = $null

    if ($TunnelList) {
        try {
            $Parsed = $TunnelList | ConvertFrom-Json
            $ExistingTunnel = $Parsed |
                Where-Object { $_.name -eq $TunnelName } |
                Select-Object -First 1
        }
        catch {
            $ExistingTunnel = $null
        }
    }

    if ($ExistingTunnel) {
        $TunnelId = $ExistingTunnel.id
        Step "Existing tunnel found."
    }
    else {
        & $Cloudflared tunnel create $TunnelName

        if ($LASTEXITCODE -ne 0) {
            throw "Cloudflare tunnel creation failed."
        }

        $TunnelList = & $Cloudflared tunnel list --output json

        $Parsed = $TunnelList | ConvertFrom-Json

        $Tunnel = $Parsed |
            Where-Object { $_.name -eq $TunnelName } |
            Select-Object -First 1

        if (-not $Tunnel) {
            throw "Cloudflare tunnel was created but could not be located."
        }

        $TunnelId = $Tunnel.id
    }

    $CloudflareDirectory = Join-Path $Directory "cloudflare"

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $CloudflareDirectory | Out-Null

    $Credentials = Join-Path `
        $env:USERPROFILE `
        ".cloudflared\$TunnelId.json"

    if (-not (Test-Path $Credentials)) {
        throw "Cloudflare tunnel credentials were not found."
    }

    $Config = Join-Path `
        $CloudflareDirectory `
        "config.yml"

    @"
tunnel: $TunnelId
credentials-file: $Credentials

ingress:
  - hostname: $Domain
    service: http://localhost:80

  - service: http_status:404
"@ | Set-Content `
        -Path $Config `
        -Encoding UTF8

    Step "Creating DNS route..."

    & $Cloudflared tunnel route dns $TunnelName $Domain

    if ($LASTEXITCODE -ne 0) {
        throw "Cloudflare DNS route creation failed."
    }

    Step "Cloudflare tunnel configured."

    Write-Host ""
    Write-Host "Starting tunnel..." -ForegroundColor Cyan
    Write-Host ""

    & $Cloudflared `
        tunnel `
        --config $Config `
        run $TunnelName
}

try {
    Clear-Host

    Write-Host ""
    Write-Host "Stoat Setup" -ForegroundColor Cyan
    Write-Host ""

    Restart-AsAdmin
    Require-Winget

    $Domain = Ask "Stoat domain"

    if ([string]::IsNullOrWhiteSpace($Domain)) {
        throw "A domain is required."
    }

    $Domain = $Domain.ToLower()

    if ($Domain -notmatch '^[a-z0-9][a-z0-9.-]*[a-z0-9]$') {
        throw "Invalid hostname."
    }

    $InstallDirectory = Ask `
        "Install directory" `
        "C:\Stoat"

    $Video = Ask-YesNo `
        "Enable voice, camera and screen sharing?" `
        $true

    $UseCloudflare = Ask-YesNo `
        "Set up Cloudflare Tunnel?" `
        $true

    Write-Host ""
    Write-Host "Preparing system..." -ForegroundColor Cyan
    Write-Host ""

    Install-Git
    Install-Docker

    Write-Host ""
    Write-Host "Stoat" -ForegroundColor Cyan
    Write-Host ""

    Clone-Stoat $InstallDirectory

    $Secrets = Join-Path $InstallDirectory "secrets.env"

    if (Test-Path $Secrets) {
        Step "Existing Stoat secrets detected."
        Step "Keeping the existing configuration."
    }
    else {
        Generate-Config `
            $InstallDirectory `
            $Domain `
            $Video
    }

    Start-Stoat $InstallDirectory

    if ($UseCloudflare) {
        $Cloudflared = Download-Cloudflared

        Setup-Cloudflare `
            $Cloudflared `
            $InstallDirectory `
            $Domain
    }

    Write-Host ""
    Write-Host "Stoat is running." -ForegroundColor Green
    Write-Host ""
    Write-Host "  URL: https://$Domain"
    Write-Host "  Location: $InstallDirectory"
    Write-Host ""
    Write-Host "Useful commands:" -ForegroundColor Cyan
    Write-Host "  cd $InstallDirectory"
    Write-Host "  docker compose ps"
    Write-Host "  docker compose logs -f"
    Write-Host "  docker compose restart"
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Host "Setup failed:" -ForegroundColor Red
    Write-Host ""
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    exit 1
}