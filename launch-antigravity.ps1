# launch-antigravity.ps1 - start Antigravity with the proxy variables it needs.
#
# Why this exists: Antigravity's language_server.exe is a Go program. Go's
# net/http resolves proxies with ProxyFromEnvironment, which reads only the
# HTTP_PROXY / HTTPS_PROXY / NO_PROXY environment variables and never looks at the
# Windows system proxy in HKCU\...\Internet Settings. With Clash Verge in
# system-proxy mode (no TUN), Antigravity therefore goes direct and its OAuth
# token exchange dies with EOF - the login spins forever.
#
# The proxy is scoped to this one launch instead of being set user-wide:
#   * read the mixed port Clash Verge is configured to use
#   * if something actually listens on it, put the variables in this process so
#     Antigravity inherits them; otherwise put nothing
#   * start Antigravity
#
# User-wide variables are deliberately avoided: a proxy URL pointing at a closed
# port is worse than no proxy, because every program that honours the variable
# fails, domestic sites included. That is exactly what broke WorkBuddy and Codex
# while Clash Verge was closed.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\launch-antigravity.ps1
#   ... -DryRun     # print the decision, start nothing (used by CI)

[CmdletBinding()]
param(
    # Path to Antigravity.exe. Empty means "look in the usual places".
    [string]$AppPath = '',

    # Clash Verge data directory.
    [string]$VergeDir = (Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'),

    # Ports that never go through the proxy.
    [string]$NoProxy = 'localhost,127.0.0.1,::1,*.local',

    # Used when no configuration file names a port.
    [int]$FallbackPort = 7897,

    # Where the launcher records what it decided.
    [string]$LogPath = (Join-Path $env:LOCALAPPDATA 'antigravity-proxy-launch.log'),

    # -DryRun prints the decision and touches nothing.
    [switch]$DryRun,

    # -RepairOnly checks the shortcuts and exits without starting anything. Use it
    # at logon or from another program: it is how the guard runs when it is not
    # going through the launcher itself.
    [switch]$RepairOnly
)

$ErrorActionPreference = 'Stop'

function Add-LaunchLog([string]$Path, [string]$Message) {
    try {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $line = '{0} {1}' -f (Get-Date).ToString('s'), $Message
        Add-Content -Path $Path -Value $line -Encoding UTF8
        if ((Get-Item $Path).Length -gt 32768) {
            $tail = Get-Content $Path -Tail 200
            Set-Content -Path $Path -Value $tail -Encoding UTF8
        }
    } catch {
        # A log write must never stop the launch.
        Write-Verbose $_.Exception.Message
    }
}

function Get-PortFromFile([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    # Verge writes "verge_mixed_port:" in clash-verge.yaml and "mixed-port:" in a
    # profile, so accept either separator.
    $hit = Select-String -Path $Path -Pattern '^\s*(?:verge_)?mixed[-_]port:\s*(\d+)' | Select-Object -First 1
    if ($hit -and $hit.Matches.Count -gt 0) { return [int]$hit.Matches[0].Groups[1].Value }
    return $null
}

function Get-VergePort([string]$Dir) {
    $port = Get-PortFromFile (Join-Path $Dir 'clash-verge.yaml')
    if ($port) { return $port }

    $profiles = Join-Path $Dir 'profiles'
    if (Test-Path $profiles) {
        $newest = Get-ChildItem $profiles -Filter *.yaml -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 5
        foreach ($file in $newest) {
            $found = Get-PortFromFile $file.FullName
            if ($found) { return $found }
        }
    }
    return $null
}

function Test-ProxyPort([int]$Port, [int]$TimeoutMs = 400) {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $task = $client.ConnectAsync('127.0.0.1', $Port)
        if (-not $task.Wait($TimeoutMs)) { $client.Close(); return $false }
        $ok = $client.Connected
        $client.Close()
        return $ok
    } catch {
        return $false
    }
}

function Resolve-AppPath([string]$Given) {
    if ($Given) { return $Given }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Antigravity\Antigravity.exe'),
        (Join-Path $env:ProgramFiles 'Antigravity\Antigravity.exe')
    )
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Antigravity\Antigravity.exe')
    }
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return $candidates[0]
}

function Get-ShortcutPaths {
    $dirs = @(
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'),
        (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch'),
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:PUBLIC 'Desktop')
    )
    foreach ($dir in $dirs) {
        if (-not (Test-Path $dir)) { continue }
        Get-ChildItem $dir -Filter 'Antigravity.lnk' -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName }
    }
}

# Antigravity rewrites its own pinned shortcut whenever it updates (it points the
# icon straight back at Antigravity.exe, without the proxy variables). That is how
# the launcher silently stopped being used on 2026-11-23. Repair the shortcuts each
# time the launcher runs, and from -RepairOnly at logon / DSH start, so a bad icon
# lasts at most one launch instead of until someone notices.
function Set-ShortcutLinks([string]$RepoDir, [string]$Exe) {
    $vbs = Join-Path $RepoDir 'run-hidden.vbs'
    $script = Join-Path $RepoDir 'launch-antigravity.ps1'
    if (-not (Test-Path $vbs) -or -not (Test-Path $script)) { return }
    $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
    $wantArgs = '"{0}" "{1}"' -f $vbs, $script
    $shell = $null
    try { $shell = New-Object -ComObject WScript.Shell } catch { return }
    foreach ($lnk in Get-ShortcutPaths) {
        try {
            $shortcut = $shell.CreateShortcut($lnk)
            $target = [string]$shortcut.TargetPath
            $currentArgs = [string]$shortcut.Arguments
            if ($target -match 'wscript\.exe$' -and $currentArgs -like ('*' + (Split-Path $script -Leaf) + '*')) { continue }
            $shortcut.TargetPath = $wscript
            $shortcut.Arguments = $wantArgs
            $shortcut.WorkingDirectory = $RepoDir
            $shortcut.IconLocation = '{0},0' -f $Exe
            $shortcut.Save()
            Add-LaunchLog $LogPath ('repaired shortcut: {0}' -f $lnk)
        } catch {
            Add-LaunchLog $LogPath ('could not repair shortcut {0}: {1}' -f $lnk, $_.Exception.Message)
        }
    }
}

$exe = Resolve-AppPath $AppPath

# Runs on every launch (and standalone with -RepairOnly), so a shortcut the app
# rewrote during an update gets pointed back here before it is used again.
if (-not $DryRun) {
    Set-ShortcutLinks $PSScriptRoot $exe
    if ($RepairOnly) {
        Add-LaunchLog $LogPath 'shortcut check only, nothing started'
        exit 0
    }
}

$port = Get-VergePort $VergeDir
if (-not $port) { $port = $FallbackPort }
if (-not $port -or $port -lt 1 -or $port -gt 65535) {
    if (-not $DryRun) { Add-LaunchLog $LogPath 'no usable port, refusing to start' }
    exit 0
}

$live = Test-ProxyPort $port
$url = 'http://127.0.0.1:{0}' -f $port

if ($DryRun) {
    if ($live) {
        Write-Output ('would start "{0}" with HTTPS_PROXY={1}' -f $exe, $url)
    } else {
        Write-Output ('would start "{0}" with no proxy (port {1} is closed)' -f $exe, $port)
    }
    exit 0
}

# Drop every proxy variable first, in both spellings. Windows environment blocks
# are case-insensitive, so a process can hold HTTPS_PROXY and https_proxy at once
# and Start-Process then refuses to build a child environment from that dictionary
# ("an item with the same key has already been added").
foreach ($name in 'HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy', 'NO_PROXY', 'no_proxy', 'ALL_PROXY', 'all_proxy') {
    Remove-Item ('Env:{0}' -f $name) -ErrorAction SilentlyContinue
}

# DSH injects ELECTRON_RUN_AS_NODE=1 into its own process tree. An Electron app
# that inherits it starts as plain Node, rejects every Chromium switch and exits
# immediately, so drop it before launching anything Electron-based.
Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue

if ($live) {
    $env:HTTPS_PROXY = $url
    $env:HTTP_PROXY = $url
    $env:NO_PROXY = $NoProxy
    Add-LaunchLog $LogPath ('proxy on, port {0} is listening' -f $port)
} else {
    Add-LaunchLog $LogPath ('no proxy, port {0} is closed' -f $port)
}

if (-not (Test-Path $exe)) {
    Add-LaunchLog $LogPath ('Antigravity.exe not found: {0}' -f $exe)
    exit 1
}

# Start-Process keeps this launcher short-lived and lets Antigravity run on its
# own; the original shortcut passed --remote-debugging-port=0, so keep that.
Start-Process -FilePath $exe -ArgumentList '--remote-debugging-port=0' -WorkingDirectory (Split-Path -Parent $exe)
Add-LaunchLog $LogPath 'started Antigravity'
