# Windows launcher for VoiceStudio's ROCm backend running in WSL2.
# Forwards to scripts/wsl-rocm.sh inside the distribution:
#
#   .\scripts\wsl-rocm.ps1            # start, then open http://localhost:3900
#   .\scripts\wsl-rocm.ps1 stop
#   .\scripts\wsl-rocm.ps1 status | logs | restart | update
#   .\scripts\wsl-rocm.ps1 key        # copy the API key to the clipboard
#   .\scripts\wsl-rocm.ps1 build      # build this checkout's image and use it
#   .\scripts\wsl-rocm.ps1 install voxcpm2   # install an engine inside the backend
#
# The distribution defaults to Ubuntu; set VOICESTUDIO_WSL_DISTRO to change it.
# start keeps the WSL2 VM alive (hidden background wsl.exe) until stop.
param(
    [ValidateSet('start', 'stop', 'restart', 'status', 'logs', 'key', 'update', 'build', 'install', 'help')]
    [string]$Command = 'start',
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest = @(),
    [switch]$NoBrowser
)
$ErrorActionPreference = 'Stop'

$distro = if ($env:VOICESTUDIO_WSL_DISTRO) { $env:VOICESTUDIO_WSL_DISTRO } else { 'Ubuntu' }
$script = Join-Path $PSScriptRoot 'wsl-rocm.sh'
$wslScript = (& wsl.exe -d $distro -- wslpath -a ($script -replace '\\', '/')).Trim()
if ($LASTEXITCODE -ne 0 -or -not $wslScript) {
    throw "WSL distribution '$distro' is not available (wsl -l -v)."
}

# WSL2 shuts its VM down once no wsl.exe process is attached, and that stops the
# Docker daemon and the backend container with it (a running container does not
# count). A hidden `sleep infinity` keeps the VM up for as long as the backend
# should run; `stop` ends it so the VM can idle out again.
$keepAliveFile = Join-Path $env:LOCALAPPDATA 'VoiceStudio\wsl-keepalive.pid'

function Get-KeepAlive {
    if (-not (Test-Path $keepAliveFile)) { return $null }
    $id = 0
    $raw = "$(Get-Content $keepAliveFile -ErrorAction SilentlyContinue | Select-Object -First 1)".Trim()
    if (-not [int]::TryParse($raw, [ref]$id)) { return $null }
    Get-Process -Id $id -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -eq 'wsl' }
}

function Start-KeepAlive {
    if (Get-KeepAlive) { return }
    $p = Start-Process wsl.exe -WindowStyle Hidden -PassThru `
        -ArgumentList '-d', $distro, '--exec', 'sleep', 'infinity'
    New-Item -ItemType Directory -Force -Path (Split-Path $keepAliveFile) | Out-Null
    Set-Content -Path $keepAliveFile -Value $p.Id
}

function Stop-KeepAlive {
    Get-KeepAlive | Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-Item $keepAliveFile -ErrorAction SilentlyContinue
}

if ($Command -in 'start', 'restart', 'update', 'build') { Start-KeepAlive }

& wsl.exe -d $distro -- bash $wslScript $Command @Rest
$code = $LASTEXITCODE

if ($Command -eq 'stop' -and $code -eq 0) { Stop-KeepAlive }
# A failed first start must not leave the VM pinned awake with nothing running.
if ($Command -eq 'start' -and $code -ne 0) { Stop-KeepAlive }

if ($Command -in 'start', 'restart', 'update' -and $code -eq 0 -and -not $NoBrowser) {
    Start-Process 'http://localhost:3900'
}
exit $code
