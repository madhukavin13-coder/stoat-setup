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

        switch ($Value.Trim().ToLower()) {
            "y"    { return $true }
            "yes"  { return $true }
            "n"    { return $false }
            "no"   { return $false }
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
    $MachinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")

    $env:Path = "$MachinePath;$UserPath"
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
        throw "Git was installed but is not available yet."
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

function Install-FirewallRules($Cloudflared) {
    Step "Configuring Windows Firewall..."

    $Rules = @(
        @{
            Name = "Stoat Cloudflared TCP 7844"
            Protocol = "TCP"
        },
        @{
            Name = "Stoat Cloudflared UDP 7844"
            Protocol = "UDP"
        }
    )

    foreach ($Rule in $Rules) {
        $Existing = Get-NetFirewallRule `
            -DisplayName $Rule.Name `
            -ErrorAction SilentlyContinue

        if ($Existing) {
            Set-NetFirewallRule `
                -DisplayName $Rule.Name `
                -Enabled True `
                -Direction Outbound `
                -Action Allow
        }
        else {
            New-NetFirewallRule `
                -DisplayName $Rule.Name `
                -Direction Outbound `
                -Action Allow `
                -Protocol $Rule.Protocol `
                -RemotePort 7844 `
                -Program $Cloudflared | Out-Null
        }
    }

    Step "Firewall rules ready."
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
    $Secrets = Join-Path $Directory "secrets.env"
    $SecretsExample = Join-Path $Directory "secrets.env.example"
    $WebEnv = Join-Path $Directory ".env.web"
    $Env = Join-Path $Directory ".env"
    $Revolt = Join-Path $Directory "Revolt.toml"
    $Livekit = Join-Path $Directory "livekit.yml"
    $StoatJson = Join-Path $Directory "stoat.json"

    if (-not (Test-Path $Generator)) {
        throw "generate_config.sh was not found."
    }

    Fix-LineEndings $Generator

    $VideoAnswer = if ($Video) { "y" } else { "n" }

    $ExistingConfig = (
        (Test-Path $Revolt) -or
        (Test-Path $WebEnv) -or
        (Test-Path $Env) -or
        (Test-Path $Livekit) -or
        (Test-Path $StoatJson)
    )

    if (-not (Test-Path $Secrets)) {
        if (-not (Test-Path $SecretsExample)) {
            throw "secrets.env.example was not found."
        }

        Step "Creating Stoat secrets file..."

        Copy-Item `
            -Path $SecretsExample `
            -Destination $Secrets `
            -Force
    }

    if ($ExistingConfig) {
        Step "Incomplete Stoat configuration detected."
        Step "Regenerating existing configuration."
        $GeneratorCommand = "./generate_config.sh --overwrite `"$Domain`""
    }
    else {
        Step "Generating Stoat configuration."
        $GeneratorCommand = "./generate_config.sh `"$Domain`""
    }

    $Command = @"
apk add --no-cache bash openssl coreutils >/dev/null 2>&1 &&
chmod +x ./generate_config.sh &&
printf "n\n$VideoAnswer\n" |
$GeneratorCommand
"@

    Step "Running Stoat configuration generator..."

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

    $RequiredFiles = @(
        "secrets.env",
        ".env",
        ".env.web",
        "Revolt.toml",
        "livekit.yml",
        "stoat.json"
    )

    foreach ($File in $RequiredFiles) {
        $Path = Join-Path $Directory $File

        if (-not (Test-Path $Path)) {
            throw "Stoat configuration is incomplete. Missing: $File"
        }
    }

    Step "Stoat configuration generated successfully."
}

function Validate-StoatConfig($Directory) {
    Step "Validating Stoat configuration..."

    $RequiredFiles = @(
        "secrets.env",
        ".env",
        ".env.web",
        "Revolt.toml",
        "livekit.yml",
        "stoat.json"
    )

    foreach ($File in $RequiredFiles) {
        $Path = Join-Path $Directory $File

        if (-not (Test-Path $Path)) {
            throw "Required Stoat configuration file is missing: $File"
        }
    }

    Set-Location $Directory

    docker compose config *> $null

    if ($LASTEXITCODE -ne 0) {
        throw "Docker Compose configuration validation failed."
    }

    Step "Stoat configuration is valid."
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

function Get-TunnelId($Cloudflared, $TunnelName) {
    $Json = & $Cloudflared tunnel list --output json 2>$null

    if (-not $Json) {
        return $null
    }

    try {
        $Parsed = $Json | ConvertFrom-Json

        $Tunnel = $Parsed |
            Where-Object { $_.name -eq $TunnelName } |
            Select-Object -First 1

        if ($Tunnel) {
            return $Tunnel.id
        }
    }
    catch {
        return $null
    }

    return $null
}

function Create-CloudflareConfig(
    $Directory,
    $Domain,
    $TunnelId
) {
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
    service: https://localhost:443
    originRequest:
      originServerName: $Domain
      noTLSVerify: true

  - service: http_status:404
"@ | Set-Content `
        -Path $Config `
        -Encoding UTF8

    return $Config
}

function Setup-Cloudflare(
    $Cloudflared,
    $Directory,
    $Domain
) {
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

    $TunnelId = Get-TunnelId `
        $Cloudflared `
        $TunnelName

    if ($TunnelId) {
        Step "Existing Cloudflare tunnel found: $TunnelName"
    }
    else {
        Step "Creating Cloudflare tunnel: $TunnelName"

        & $Cloudflared tunnel create $TunnelName

        if ($LASTEXITCODE -ne 0) {
            throw "Cloudflare tunnel creation failed."
        }

        $TunnelId = Get-TunnelId `
            $Cloudflared `
            $TunnelName

        if (-not $TunnelId) {
            throw "Tunnel was created but its ID could not be located."
        }
    }

    $Config = Create-CloudflareConfig `
        $Directory `
        $Domain `
        $TunnelId

    Step "Creating DNS route..."

    & $Cloudflared tunnel route dns `
        $TunnelName `
        $Domain

    if ($LASTEXITCODE -ne 0) {
        throw "Cloudflare DNS route creation failed."
    }

    Step "Validating Cloudflare configuration..."

    & $Cloudflared tunnel ingress validate `
        --config $Config

    if ($LASTEXITCODE -ne 0) {
        throw "Cloudflare tunnel configuration is invalid."
    }

    Step "Cloudflare tunnel configured."

    return @{
        Name = $TunnelName
        Id = $TunnelId
        Config = $Config
    }
}

try {
    Clear-Host

    Write-Host ""
    Write-Host "Stoat Setup" -ForegroundColor Cyan
    Write-Host "yoooo wachine mahcien ur gay" -ForegroundColor DarkGray
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

    Write-Host ""
    Write-Host "Preparing system..." -ForegroundColor Cyan
    Write-Host ""

    Install-Git
    Install-Docker

    $Cloudflared = Download-Cloudflared

    Install-FirewallRules $Cloudflared

    Write-Host ""
    Write-Host "Stoat" -ForegroundColor Cyan
    Write-Host ""

    Clone-Stoat $InstallDirectory

    $Secrets = Join-Path `
        $InstallDirectory `
        "secrets.env"

    $WebEnv = Join-Path `
        $InstallDirectory `
        ".env.web"

    $Env = Join-Path `
        $InstallDirectory `
        ".env"

    $Revolt = Join-Path `
        $InstallDirectory `
        "Revolt.toml"

    $Livekit = Join-Path `
        $InstallDirectory `
        "livekit.yml"

    $StoatJson = Join-Path `
        $InstallDirectory `
        "stoat.json"

    $ConfigComplete = (
        (Test-Path $Secrets) -and
        (Test-Path $WebEnv) -and
        (Test-Path $Env) -and
        (Test-Path $Revolt) -and
        (Test-Path $Livekit) -and
        (Test-Path $StoatJson)
    )

    if ($ConfigComplete) {
        Step "Complete Stoat configuration found."
        Step "Keeping existing secrets and configuration."
    }
    else {
        Step "Incomplete Stoat configuration detected."

        if (-not (Test-Path $Secrets)) {
            Step "Missing secrets.env"
        }

        if (-not (Test-Path $WebEnv)) {
            Step "Missing .env.web"
        }

        if (-not (Test-Path $Env)) {
            Step "Missing .env"
        }

        if (-not (Test-Path $Revolt)) {
            Step "Missing Revolt.toml"
        }

        if (-not (Test-Path $Livekit)) {
            Step "Missing livekit.yml"
        }

        if (-not (Test-Path $StoatJson)) {
            Step "Missing stoat.json"
        }

        Generate-Config `
            $InstallDirectory `
            $Domain `
            $Video
    }

    Validate-StoatConfig $InstallDirectory

    Start-Stoat $InstallDirectory

    $Cloudflare = Setup-Cloudflare `
        $Cloudflared `
        $InstallDirectory `
        $Domain

    Write-Host ""
    Write-Host "Stoat is running." -ForegroundColor Green
    Write-Host ""
    Write-Host "  URL: https://$Domain"
    Write-Host "  Location: $InstallDirectory"
    Write-Host ""
    Write-Host "Startup script:" -ForegroundColor Cyan
    Write-Host "  $InstallDirectory\startup.ps1"
    Write-Host ""
    Write-Host "Keep this PowerShell window open while the tunnel is running."
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Host "Setup failed:" -ForegroundColor Red
    Write-Host ""
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Read-Host "Press Enter to close"
    exit 1
}
