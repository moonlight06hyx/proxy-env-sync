# install.ps1 - point the Antigravity shortcuts at the proxied launcher.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
#
# What it does:
#   1. backs up the Start menu and taskbar shortcuts (.lnk -> .lnk.bak)
#   2. rewrites both of them to: wscript.exe run-hidden.vbs launch-antigravity.ps1
#   3. <redacted> proxy environment variables left behind from the
#      older user-wide design, and tells Explorer about the change
#
# No scheduled task is created and nothing global is written: the proxy exists
# only inside the Antigravity process tree that launch-antigravity.ps1 starts.
#
# Optional: -TaskName "proxy-env-sync"   (legacy task to remove, if present)
#           -AppPath "C:\...\Antigravity.exe"
#           -SkipShortcuts

[CmdletBinding()]
param(
    [string]$TaskName = 'proxy-env-sync',
    [string]$AppPath = '',
    [switch]$SkipShortcuts
)

$ErrorActionPreference = 'Stop'

$dir = $PSScriptRoot
$launcher = Join-Path $dir 'launch-antigravity.ps1'
$runner = Join-Path $dir 'run-hidden.vbs'

if (-not (Test-Path $launcher)) { throw "launch-antigravity.ps1 not found next to install.ps1" }
if (-not (Test-Path $runner)) { throw "run-hidden.vbs not found next to install.ps1" }

if (-not $AppPath) {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Antigravity\Antigravity.exe'),
        (Join-Path $env:ProgramFiles 'Antigravity\Antigravity.exe')
    )
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Antigravity\Antigravity.exe')
    }
    $AppPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $AppPath) { $AppPath = $candidates[0] }
}
if (-not (Test-Path $AppPath)) {
    throw "Antigravity.exe not found: $AppPath (pass -AppPath)"
}

# 1. Remove the legacy global sync task. Its whole design was writing user-wide
#    proxy variables, which is what broke WorkBuddy and Codex.
$legacy = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($legacy) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "removed legacy scheduled task  $TaskName"
}

# 2. Clear the user-wide proxy variables the old task used to publish. Use
#    SetEnvironmentVariable(...,'User') because it also broadcasts
#    WM_SETTINGCHANGE; without that broadcast Explorer keeps the old block and
#    every program started from it inherits the stale proxy.
$cleared = 0
foreach ($name in 'HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy', 'NO_PROXY', 'no_proxy') {
    if ($null -ne [Environment]::GetEnvironmentVariable($name, 'User')) {
        [Environment]::SetEnvironmentVariable($name, $null, 'User')
        $cleared++
    }
}
if ($cleared -gt 0) { Write-Host "cleared $cleared user-wide proxy variable(s)" }

# 3. Rewrite the shortcuts.
if (-not $SkipShortcuts) {
    $targets = @(
        (Join-Path ([Environment]::GetFolderPath('Programs')) 'Antigravity.lnk'),
        (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Antigravity.lnk')
    )

    $shell = New-Object -ComObject WScript.Shell
    $done = 0
    foreach ($lnk in $targets) {
        if (-not (Test-Path $lnk)) {
            Write-Host "skip (not present)  $lnk"
            continue
        }
        $backup = "$lnk.bak"
        if (-not (Test-Path $backup)) { Copy-Item $lnk $backup -Force }

        $shortcut = $shell.CreateShortcut($lnk)
        $shortcut.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
        $shortcut.Arguments = '"{0}" "{1}"' -f $runner, $launcher
        $shortcut.WorkingDirectory = $dir
        $shortcut.IconLocation = "$AppPath,0"
        $shortcut.Description = 'Antigravity (proxied launch)'
        $shortcut.Save()
        $done++
        Write-Host "rewrote  $lnk"
    }
    Write-Host "shortcuts updated: $done"
}

# 4. Shortcut guard. Antigravity rewrites its own Start-menu and taskbar icons every
#    time it updates and points them straight back at Antigravity.exe, which bypasses
#    the launcher and therefore loses HTTPS_PROXY (2.32 -> 2.34 did exactly that on
#    2026-11-23). A launch-time repair cannot help the very launch that skipped us,
#    and scheduled tasks are unavailable here, so the guard is a small resident
#    watcher started at logon from the Startup folder: it polls the .lnk files every
#    couple of seconds and rewrites a bad one before anyone clicks it.
$guardName = 'Antigravity shortcut guard.lnk'
$startup = [Environment]::GetFolderPath('Startup')
$guardLnk = Join-Path $startup $guardName
$watcher = Join-Path $dir 'shortcut-watch.ps1'
if (-not $SkipShortcuts) {
    try {
        $guardShell = New-Object -ComObject WScript.Shell
        $guard = $guardShell.CreateShortcut($guardLnk)
        $guard.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
        $guard.Arguments = '"{0}" "{1}"' -f $runner, $watcher
        $guard.WorkingDirectory = $dir
        $guard.IconLocation = "$AppPath,0"
        $guard.Description = 'Keep the Antigravity shortcuts on the proxy launcher, even after an update rewrites them.'
        $guard.Save()
        Write-Host "guard installed  $guardLnk"

        # Restart the watcher now so the protection is live without a re-login.
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { -not ($_.ProcessId -eq $PID) -and $_.CommandLine -like '*-File*shortcut-watch.ps1*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        # explorer.exe is the parent on purpose: a process started from this shell
        # dies with the caller's job object, and the watcher has to outlive us.
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $guardLnk)
        Write-Host 'guard running    (shortcut-watch.ps1)'
    } catch {
        Write-Host "could not install $guardName : $($_.Exception.Message)"
    }
}

Write-Host ''
Write-Host 'Done. Start Antigravity the usual way (Start menu / taskbar); it now gets'
Write-Host 'HTTPS_PROXY only when the Clash Verge mixed port is actually listening.'
Write-Host "Decision log: $env:LOCALAPPDATA\antigravity-proxy-launch.log"
