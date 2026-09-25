$ErrorActionPreference = Stop

$StoatDir = CStoat
$Cloudflared = CCloudflaredcloudflared.exe
$CloudflareConfig = $StoatDircloudflareconfig.yml

Write-Host 
Write-Host Stoat Startup -ForegroundColor Cyan
Write-Host 

Write-Host Starting Docker... -ForegroundColor DarkGray
Start-Process CProgram FilesDockerDockerDocker Desktop.exe -ErrorAction SilentlyContinue

Write-Host Waiting for Docker... -ForegroundColor DarkGray

for ($i = 0; $i -lt 60; $i++) {
    docker info  $null

    if ($LASTEXITCODE -eq 0) {
        break
    }

    Start-Sleep -Seconds 2
}

if ($LASTEXITCODE -ne 0) {
    Write-Host Docker did not start. -ForegroundColor Red
    exit 1
}

Write-Host Starting Stoat... -ForegroundColor DarkGray

Set-Location $StoatDir
docker compose up -d

if ($LASTEXITCODE -ne 0) {
    Write-Host Stoat failed to start. -ForegroundColor Red
    exit 1
}

Write-Host Stoat containers started. -ForegroundColor Green
Write-Host 
Write-Host Starting Cloudflare Tunnel... -ForegroundColor DarkGray
Write-Host 

if (-not (Test-Path $Cloudflared)) {
    $Cloudflared = (Get-Command cloudflared -ErrorAction SilentlyContinue).Source
}

if (-not $Cloudflared) {
    Write-Host cloudflared.exe was not found. -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $CloudflareConfig)) {
    Write-Host Cloudflare config not found -ForegroundColor Red
    Write-Host $CloudflareConfig
    exit 1
}

& $Cloudflared tunnel --config $CloudflareConfig run