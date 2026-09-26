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
        return $Value
    }

    return Read-Host $Prompt
}

function Restart-AsAdmin {
    $CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($CurrentIdentity)

    if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Start-Process powershell.exe `
            -Verb RunAs `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""

        exit
    }
}

function Show-SetupWarning {
    Add-Type -AssemblyName System.Windows.Forms

    $Result = [System.Windows.Forms.MessageBox]::Show(
        "hiii wachine`n`nStoat setup is about to begin.",
        "Stoat Setup",
        [System.Windows.Forms.MessageBoxButtons]::OKCancel,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($Result -ne [System.Windows.Forms.DialogResult]::OK) {
        exit
    }
}

function Require-Winget {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget was not found. Install App Installer from Microsoft Store first."
    }
}

function Ensure-Git {
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Step "Git found."
        return
    }

    Step "Installing Git..."
    winget install --id Git.Git -e --source winget --accept-source-agreements --accept-package-agreements

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git installation failed."
    }

    Step "Git ready."
}

function Ensure-Docker {
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        Step "Docker found."
    }
    else {
        Step "Installing Docker Desktop..."
        winget install --id Docker.DockerDesktop -e --source winget --accept-source-agreements --accept-package-agreements
    }

    $DockerDesktop = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"

    if (Test-Path $DockerDesktop) {
        Step "Starting Docker Desktop..."
        Start-Process $DockerDesktop
    }

    Step "Waiting for Docker..."

    $Ready = $false

    for ($i = 0; $i -lt 90; $i++) {
        Start-Sleep -Seconds 2

        try {
            docker info *> $null

            if ($LASTEXITCODE -eq 0) {
                $Ready = $true
                break
            }
        }
        catch {
        }
    }

    if (-not $Ready) {
        throw "Docker did not become ready."
    }

    Step "Docker is ready."
}

function Ensure-Cloudflared {
    $Directory = "C:\Cloudflared"
    $Binary = Join-Path $Directory "cloudflared.exe"

    New-Item -ItemType Directory -Force -Path $Directory | Out-Null

    if (Test-Path $Binary) {
        Step "cloudflared found."
        return $Binary
    }

    Step "Downloading cloudflared..."

    $Url = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"

    Invoke-WebRequest `
        -Uri $Url `
        -OutFile $Binary

    if (-not (Test-Path $Binary)) {
        throw "cloudflared download failed."
    }

    Step "cloudflared ready."

    return $Binary
}

function Configure-Firewall {
    Step "Configuring Windows Firewall..."

    $Rules = @(
        @{
            Name = "Stoat Cloudflare TCP 7844"
            Protocol = "TCP"
            Port = "7844"
        },
        @{
            Name = "Stoat Cloudflare UDP 7844"
            Protocol = "UDP"
            Port = "7844"
        },
        @{
            Name = "Stoat LiveKit TCP 7881"
            Protocol = "TCP"
            Port = "7881"
        },
        @{
            Name = "Stoat LiveKit UDP 50000-50100"
            Protocol = "UDP"
            Port = "50000-50100"
        }
    )

    foreach ($Rule in $Rules) {
        if (-not (Get-NetFirewallRule -DisplayName $Rule.Name -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule `
                -DisplayName $Rule.Name `
                -Direction Inbound `
                -Action Allow `
                -Protocol $Rule.Protocol `
                -LocalPort $Rule.Port | Out-Null
        }
    }

    Step "Firewall rules ready."
}

function Download-Stoat {
    param(
        [string]$Directory
    )

    $Repo = "https://github.com/stoatchat/self-hosted.git"

    if (Test-Path (Join-Path $Directory ".git")) {
        Step "Existing Stoat repository found."

        Push-Location $Directory

        try {
            git fetch --all
            git reset --hard origin/main
        }
        finally {
            Pop-Location
        }

        return
    }

    if (Test-Path $Directory) {
        $Items = Get-ChildItem -LiteralPath $Directory -Force

        if ($Items.Count -gt 0) {
            throw "Install directory exists and is not an existing Stoat repository: $Directory"
        }
    }
    else {
        New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    }

    Step "Downloading Stoat..."

    git clone $Repo $Directory
}

function Fix-LineEndings {
    param(
        [string]$File
    )

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

function Get-GitBash {
    $Paths = @(
        "${env:ProgramFiles}\Git\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
    )

    foreach ($Path in $Paths) {
        if (Test-Path $Path) {
            return $Path
        }
    }

    $Git = Get-Command git -ErrorAction SilentlyContinue

    if ($Git) {
        $GitDirectory = Split-Path $Git.Source -Parent
        $Candidate = Join-Path $GitDirectory "bash.exe"

        if (Test-Path $Candidate) {
            return $Candidate
        }
    }

    throw "Git Bash was not found."
}

function Generate-Config {
    param(
        [string]$Directory,
        [string]$Domain,
        [bool]$EnableVideo
    )

    Step "Generating Stoat configuration..."

    $Generator = Join-Path $Directory "generate_config.sh"

    if (-not (Test-Path $Generator)) {
        throw "generate_config.sh was not found."
    }

    Fix-LineEndings $Generator

    $GitBash = Get-GitBash

    if ($EnableVideo) {
        $VideoAnswer = "y"
    }
    else {
        $VideoAnswer = "n"
    }

    Push-Location $Directory

    try {
        $Input = "n`n$VideoAnswer`n"

        $Input | & $GitBash -lc "./generate_config.sh '$Domain'"

        if ($LASTEXITCODE -ne 0) {
            throw "Stoat configuration generation failed."
        }
    }
    finally {
        Pop-Location
    }

    Step "Configuration generated."
}

function Validate-StoatConfig {
    param(
        [string]$Directory
    )

    $Paths = @(
        (Join-Path $Directory "secrets.env"),
        (Join-Path $Directory ".env.web"),
        (Join-Path $Directory ".env"),
        (Join-Path $Directory "Revolt.toml"),
        (Join-Path $Directory "livekit.yml"),
        (Join-Path $Directory "stoat.json")
    )

    foreach ($Path in $Paths) {
        if (-not (Test-Path $Path)) {
            throw "Missing required Stoat configuration file: $Path"
        }
    }

    Step "Stoat configuration is complete."
}

function Test-LiveKitPorts {
    Step "Checking LiveKit ports..."

    $Tcp = Get-NetTCPConnection `
        -LocalPort 7881 `
        -ErrorAction SilentlyContinue

    if ($Tcp) {
        $Owners = $Tcp |
            Select-Object -ExpandProperty OwningProcess -Unique |
            ForEach-Object {
                try {
                    Get-Process -Id $_ -ErrorAction Stop |
                        Select-Object -ExpandProperty ProcessName
                }
                catch {
                    "PID $_"
                }
            }

        throw "TCP port 7881 is already in use by: $($Owners -join ', ')"
    }

    $Udp = Get-NetUDPEndpoint `
        -LocalPort 50000 `
        -ErrorAction SilentlyContinue

    if ($Udp) {
        $Owners = $Udp |
            Select-Object -ExpandProperty OwningProcess -Unique |
            ForEach-Object {
                try {
                    Get-Process -Id $_ -ErrorAction Stop |
                        Select-Object -ExpandProperty ProcessName
                }
                catch {
                    "PID $_"
                }
            }

        throw "UDP port 50000 is already in use by: $($Owners -join ', ')"
    }

    $Excluded = netsh interface ipv4 show excludedportrange protocol=udp

    foreach ($Line in $Excluded) {
        if ($Line -match "^\s*(\d+)\s+(\d+)\s*$") {
            $Start = [int]$Matches[1]
            $End = [int]$Matches[2]

            if (($Start -le 50100) -and ($End -ge 50000)) {
                throw "Windows has reserved UDP port range $Start-$End, which overlaps LiveKit ports 50000-50100."
            }
        }
    }

    Step "LiveKit ports are available."
}

function Start-Stoat {
    param(
        [string]$Directory
    )

    Test-LiveKitPorts

    Push-Location $Directory

    try {
        Step "Pulling Stoat containers..."

        docker compose pull

        if ($LASTEXITCODE -ne 0) {
            throw "Docker image pull failed."
        }

        Step "Starting Stoat..."

        docker compose up -d

        if ($LASTEXITCODE -ne 0) {
            throw "Stoat failed to start."
        }
    }
    finally {
        Pop-Location
    }

    Step "Stoat containers are running."
}

function Get-TunnelId {
    param(
        [string]$Cloudflared
    )

    $Existing = & $Cloudflared tunnel list --output json 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Existing)) {
        return $null
    }

    try {
        $Tunnels = $Existing | ConvertFrom-Json

        if ($Tunnels -is [array]) {
            return $Tunnels[0].id
        }

        return $Tunnels.id
    }
    catch {
        return $null
    }
}

function Setup-Cloudflare {
    param(
        [string]$Cloudflared,
        [string]$Domain,
        [string]$Directory
    )

    Step "Checking Cloudflare authentication..."

    $Auth = & $Cloudflared tunnel list --output json 2>$null

    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "Cloudflare authentication is required." -ForegroundColor Yellow
        Write-Host ""

        & $Cloudflared tunnel login

        if ($LASTEXITCODE -ne 0) {
            throw "Cloudflare authentication failed."
        }
    }

    $TunnelName = "stoat-" + ($Domain -replace "[^a-zA-Z0-9-]", "-")

    Step "Checking Cloudflare tunnel..."

    $TunnelId = $null
    $TunnelList = & $Cloudflared tunnel list --output json 2>$null

    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($TunnelList)) {
        try {
            $Tunnels = $TunnelList | ConvertFrom-Json

            foreach ($Tunnel in $Tunnels) {
                if ($Tunnel.name -eq $TunnelName) {
                    $TunnelId = $Tunnel.id
                    break
                }
            }
        }
        catch {
        }
    }

    if (-not $TunnelId) {
        Step "Creating Cloudflare tunnel..."

        & $Cloudflared tunnel create $TunnelName

        if ($LASTEXITCODE -ne 0) {
            throw "Cloudflare tunnel creation failed."
        }

        $TunnelList = & $Cloudflared tunnel list --output json 2>$null

        try {
            $Tunnels = $TunnelList | ConvertFrom-Json

            foreach ($Tunnel in $Tunnels) {
                if ($Tunnel.name -eq $TunnelName) {
                    $TunnelId = $Tunnel.id
                    break
                }
            }
        }
        catch {
        }
    }

    if (-not $TunnelId) {
        throw "Could not determine Cloudflare tunnel ID."
    }

    $Credentials = Join-Path "$env:USERPROFILE\.cloudflared" "$TunnelId.json"
    $Config = Join-Path $env:USERPROFILE ".cloudflared\config.yml"

    if (-not (Test-Path $Credentials)) {
        throw "Cloudflare tunnel credentials were not found: $Credentials"
    }

    $ConfigLines = @(
        "tunnel: $TunnelId"
        "credentials-file: $Credentials"
        ""
        "ingress:"
        "  - hostname: $Domain"
        "    service: https://localhost:443"
        "    originRequest:"
        "      originServerName: $Domain"
        "      noTLSVerify: true"
        ""
        "  - service: http_status:404"
    )

    $ConfigLines | Set-Content -Path $Config -Encoding UTF8

    Step "Configuring Cloudflare DNS..."

    & $Cloudflared tunnel route dns $TunnelName $Domain

    if ($LASTEXITCODE -ne 0) {
        throw "Cloudflare DNS configuration failed."
    }

    Step "Starting Cloudflare tunnel..."

    Get-Process cloudflared -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    Start-Process `
        -FilePath $Cloudflared `
        -ArgumentList "tunnel --config `"$Config`" run $TunnelName" `
        -WindowStyle Hidden

    Start-Sleep -Seconds 3

    Step "Cloudflare tunnel started."

    return $TunnelName
}

try {
    Clear-Host

    Write-Host ""
    Write-Host "Stoat Setup" -ForegroundColor Cyan
    Write-Host "hiii wachine" -ForegroundColor DarkGray
    Write-Host ""

    Show-SetupWarning
    Restart-AsAdmin
    Require-Winget

    $Domain = Ask "Stoat domain" "stoat.webuildsites.org"
    $InstallDirectory = Ask "Install directory" "C:\Stoat"

    $VideoInput = Ask "Enable voice, camera and screen sharing?" "Y"
    $EnableVideo = $VideoInput -match "^(y|yes)$"

    Write-Host ""
    Write-Host "Preparing system..." -ForegroundColor Cyan
    Write-Host ""

    Ensure-Git
    Ensure-Docker

    $Cloudflared = Ensure-Cloudflared

    Configure-Firewall

    Write-Host ""
    Write-Host "Stoat" -ForegroundColor Cyan
    Write-Host ""

    Download-Stoat $InstallDirectory

    $Secrets = Join-Path $InstallDirectory "secrets.env"
    $WebEnv = Join-Path $InstallDirectory ".env.web"
    $Env = Join-Path $InstallDirectory ".env"
    $Revolt = Join-Path $InstallDirectory "Revolt.toml"
    $Livekit = Join-Path $InstallDirectory "livekit.yml"
    $StoatJson = Join-Path $InstallDirectory "stoat.json"

    $ConfigComplete = (
        (Test-Path $Secrets) -and
        (Test-Path $WebEnv) -and
        (Test-Path $Env) -and
        (Test-Path $Revolt) -and
        (Test-Path $Livekit) -and
        (Test-Path $StoatJson)
    )

    if (-not $ConfigComplete) {
        Generate-Config `
            -Directory $InstallDirectory `
            -Domain $Domain `
            -EnableVideo $EnableVideo
    }
    else {
        Step "Existing Stoat configuration found."
    }

    Validate-StoatConfig $InstallDirectory

    Start-Stoat $InstallDirectory

    $TunnelName = Setup-Cloudflare `
        -Cloudflared $Cloudflared `
        -Domain $Domain `
        -Directory $InstallDirectory

    Write-Host ""
    Write-Host "Stoat setup complete." -ForegroundColor Green
    Write-Host ""
    Write-Host "URL: https://$Domain" -ForegroundColor Cyan
    Write-Host "Install: $InstallDirectory" -ForegroundColor DarkGray
    Write-Host "Tunnel: $TunnelName" -ForegroundColor DarkGray
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Host "Setup failed." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""
    exit 1
}
