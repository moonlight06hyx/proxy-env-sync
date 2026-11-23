# uninstall.ps1 - restore the shortcuts and stop touching Antigravity's start.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
#
# Restores Antigravity.lnk from the .lnk.bak copies install.ps1 made. If there is
# no backup (the shortcut was created after install), it rewrites the shortcut to
# point straight at Antigravity.exe with --remote-debugging-port=0.
#
# Optional: -AppPath "C:\...\Antigravity.exe"

[CmdletBinding()]
param(
    [string]$AppPath = ''
)

$ErrorActionPreference = 'Stop'

if (-not $AppPath) {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Antigravity\Antigravity.exe'),
        (Join-Path $env:ProgramFiles 'Antigravity\Antigravity.exe')
    )
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Antigravity\Antigravity.exe')
    }
    $AppPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}

$targets = @(
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'Antigravity.lnk'),
    (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Antigravity.lnk')
)

foreach ($lnk in $targets) {
    if (-not (Test-Path $lnk)) { continue }
    $backup = "$lnk.bak"
    if (Test-Path $backup) {
        Copy-Item $backup $lnk -Force
        Remove-Item $backup -Force
        Write-Host "restored  $lnk"
        continue
    }
    if (-not $AppPath) {
        Write-Host "no backup and no Antigravity.exe found, left alone: $lnk"
        continue
    }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($lnk)
    $shortcut.TargetPath = $AppPath
    $shortcut.Arguments = '--remote-debugging-port=0'
    $shortcut.WorkingDirectory = Split-Path -Parent $AppPath
    $shortcut.Save()
    Write-Host "repointed straight at the app  $lnk"
}

Write-Host ''
Write-Host 'Uninstalled. Nothing global was ever written, so there is no environment'
Write-Host 'cleanup to do; launch-antigravity.ps1 can be deleted safely.'
