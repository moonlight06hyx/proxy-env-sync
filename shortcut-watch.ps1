# shortcut-watch.ps1 - keeps Antigravity's shortcuts pointing at the proxy launcher.
#
# Why a resident watcher: Antigravity rewrites its own Start-menu / taskbar shortcut
# on every update (2.32 -> 2.34 flipped the pin back to
# "Antigravity.exe --remote-debugging-port=9222"), and a shortcut that bypasses the
# launcher means no HTTPS_PROXY for language_server.exe, so the OAuth token refresh
# dies. Repairing at launch time cannot help the very launch that bypassed us, and
# scheduled tasks are not available on this machine, so we watch the .lnk files and
# fix them within a couple of seconds.
#
# Starts at logon from "Antigravity shortcut guard.lnk" in the Startup folder
# (wscript -> run-hidden.vbs -> this script). Stop it with uninstall.ps1.
#
# Cost: one powershell.exe process, ~2 s polling of five small folders (a stat per
# .lnk), no CPU while idle. Measured RSS is printed into the log at startup.

param(
    [string]$RepoDir = $PSScriptRoot,
    [string]$LogPath = (Join-Path $env:LOCALAPPDATA 'antigravity-shortcut-watch.log'),
    [int]$PollSeconds = 2,
    [int]$SweepMinutes = 10
)

$ErrorActionPreference = 'SilentlyContinue'

# Single instance: install.ps1 restarts the watcher, the Startup entry starts it too,
# so a named mutex keeps a second copy from doubling the resident cost.
$mutex = New-Object System.Threading.Mutex($false, 'AntigravityShortcutWatch')
if (-not $mutex.WaitOne(0)) { exit 0 }

# The mutex alone proved racy when two launchers start at once (explorer + logon),
# so also refuse to run next to another copy of this script.
$peers = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*-File*shortcut-watch.ps1*' })
if ($peers.Count -gt 0) { exit 0 }

function Add-WatchLog([string]$Path, [string]$Message) {
    try {
        $stamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
        Add-Content -Path $Path -Value ("{0}  {1}" -f $stamp, $Message) -Encoding UTF8
        if ((Get-Item $Path).Length -gt 65536) {
            $keep = Get-Content $Path -Tail 200
            Set-Content -Path $Path -Value $keep -Encoding UTF8
        }
    } catch {
        # logging must never take the watcher down
    }
}

function Get-ShortcutDirs {
    $dirs = @(
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'),
        (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch'),
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:PUBLIC 'Desktop')
    )
    $dirs | Where-Object { Test-Path $_ }
}

function Get-ShortcutPaths {
    $out = @()
    foreach ($dir in Get-ShortcutDirs) {
        $out += @(Get-ChildItem -Path $dir -Filter '*Antigravity*.lnk' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }
    $out
}

function Invoke-RepairPass([string]$RepoDir, [string]$LogPath) {
    $launcher = Join-Path $RepoDir 'launch-antigravity.ps1'
    if (-not (Test-Path $launcher)) { return }
    $exe = Join-Path $env:LOCALAPPDATA 'Programs\Antigravity\Antigravity.exe'
    $vbs = Join-Path $RepoDir 'run-hidden.vbs'
    $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
    $wantArgs = '"{0}" "{1}"' -f $vbs, $launcher
    $shell = New-Object -ComObject WScript.Shell
    $repaired = 0
    foreach ($lnk in Get-ShortcutPaths) {
        $shot = $shell.CreateShortcut($lnk)
        $target = [string]$shot.TargetPath
        $args = [string]$shot.Arguments
        $isLauncher = ($target -ieq $wscript) -and ($args -like ('*{0}*' -f 'launch-antigravity.ps1'))
        if ($isLauncher) { continue }
        try {
            $shot.TargetPath = $wscript
            $shot.Arguments = $wantArgs
            $shot.WorkingDirectory = $RepoDir
            if (Test-Path $exe) { $shot.IconLocation = '{0},0' -f $exe }
            $shot.Save()
            $repaired += 1
            Add-WatchLog $LogPath ('repaired shortcut: {0}  (was: {1} {2})' -f $lnk, $target, $args)
        } catch {
            Add-WatchLog $LogPath ('could not repair {0}: {1}' -f $lnk, $_.Exception.Message)
        }
    }
    $repaired
}

Add-WatchLog $LogPath 'watch started'
Invoke-RepairPass $RepoDir $LogPath | Out-Null
try {
    $me = Get-Process -Id $PID
    Add-WatchLog $LogPath ('watching; rss={0:N1} MB' -f ($me.WorkingSet64 / 1MB))
} catch {
    Write-Verbose 'could not read own working set'
}

$stamp = @{}
$lastSweep = Get-Date

while ($true) {
    Start-Sleep -Seconds $PollSeconds

    $changed = $false
    foreach ($lnk in Get-ShortcutPaths) {
        $t = ''
        try { $t = (Get-Item $lnk).LastWriteTimeUtc.Ticks.ToString() } catch { Write-Verbose "unreadable: $lnk"; continue }
        if ($stamp[$lnk] -ne $t) {
            $stamp[$lnk] = $t
            $changed = $true
        }
    }

    if ($changed) {
        $n = Invoke-RepairPass $RepoDir $LogPath
        if ($n -gt 0) {
            # our own writes touched the files; refresh the stamps we compare against
            foreach ($lnk in Get-ShortcutPaths) {
                try { $stamp[$lnk] = (Get-Item $lnk).LastWriteTimeUtc.Ticks.ToString() } catch { Write-Verbose "unreadable: $lnk" }
            }
        }
    }

    if (((Get-Date) - $lastSweep).TotalMinutes -ge $SweepMinutes) {
        $lastSweep = Get-Date
        Invoke-RepairPass $RepoDir $LogPath | Out-Null
    }
}
