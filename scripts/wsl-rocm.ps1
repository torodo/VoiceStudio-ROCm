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

& wsl.exe -d $distro -- bash $wslScript $Command @Rest
$code = $LASTEXITCODE

if ($Command -in 'start', 'restart', 'update' -and $code -eq 0 -and -not $NoBrowser) {
    Start-Process 'http://localhost:3900'
}
exit $code
