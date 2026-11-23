# sync-proxy-env.ps1
# Keeps Windows proxy ENVIRONMENT VARIABLES in step with Clash Verge's mixed port.
#
# Why this exists: Go programs (Antigravity's language_server.exe among them)
# resolve proxies with net/http's ProxyFromEnvironment, which reads only
# HTTP_PROXY / HTTPS_PROXY / NO_PROXY. They never look at the Windows "system
# proxy" in HKCU\...\Internet Settings. So with Verge in system-proxy mode and
# no TUN, those programs go direct and their OAuth token exchange dies on EOF.
#
# Runs from a scheduled task: at logon, then every 30 minutes. A run with
# nothing to change finishes in ~0.2 s; a run that does change something takes
# ~0.4 s. Nothing stays resident.

param(
    [string]$VergeDir = (Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'),
    [string]$NoProxy = 'localhost,127.0.0.1,::1,*.local',
    [string]$LogPath = (Join-Path $env:LOCALAPPDATA 'dsh-proxy-env-sync.log'),
    [int]$FallbackPort = 7897,
    # -DryRun prints what it would do and touches nothing. Used by CI.
    [switch]$DryRun,
    # -SkipPortCheck pretends the proxy is listening. Only for tests.
    [switch]$SkipPortCheck
)

$ErrorActionPreference = 'SilentlyContinue'

$vergeYaml = Join-Path $VergeDir 'clash-verge.yaml'
$profilesDir = Join-Path $VergeDir 'profiles'

function Get-PortFromFile([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    # Verge writes "verge_mixed_port:" in clash-verge.yaml and "mixed-port:" in
    # a profile, so accept either separator.
    $hit = Select-String -Path $path -Pattern '^\s*(?:verge_)?mixed[-_]port:\s*(\d+)' | Select-Object -First 1
    if ($hit -and $hit.Matches.Count -gt 0) { return [int]$hit.Matches[0].Groups[1].Value }
    return $null
}

function Get-VergePort {
    $port = Get-PortFromFile $vergeYaml
    if ($port) { return $port }
    # Fall back to the newest profile files under profiles\.
    $candidates = Get-ChildItem $profilesDir -Filter *.yaml -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 5
    foreach ($c in $candidates) {
        $p = Get-PortFromFile $c.FullName
        if ($p) { return $p }
    }
    return $null
}

$port = Get-VergePort
if (-not $port) { $port = $FallbackPort }
if (-not $port -or $port -lt 1 -or $port -gt 65535) { exit 0 }

function Test-ProxyPort([int]$p, [int]$timeoutMs = 400) {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $task = $client.ConnectAsync('127.0.0.1', $p)
        if (-not $task.Wait($timeoutMs)) { $client.Close(); return $false }
        $ok = $client.Connected
        $client.Close()
        return $ok
    } catch { return $false }
}

# Publish the variables only while a proxy really listens on that port. A
# proxy URL pointing at a closed port is worse than no proxy at all: every
# program that honours the variable then fails, domestic sites included. That
# is what broke WorkBuddy and Codex while Clash Verge was closed.
$live = if ($SkipPortCheck) { $true } else { Test-ProxyPort $port }
$want = "http://127.0.0.1:$port"

if ($DryRun) {
    $cur = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    $now = if ($cur) { [string]$cur.GetValue('HTTPS_PROXY', '') } else { '' }
    if ($cur) { $cur.Close() }
    if ($live) {
        Write-Output "would-set HTTPS_PROXY/HTTP_PROXY=$want NO_PROXY=$NoProxy (current=$now)"
    } else {
        Write-Output "would-clear HTTPS_PROXY/HTTP_PROXY/NO_PROXY (current=$now)"
    }
    exit 0
}

$changed = $false

# Write HKCU\Environment directly instead of using
# [Environment]::SetEnvironmentVariable: that call broadcasts WM_SETTINGCHANGE
# itself with a ~1 s per-window timeout, which turns one write into ~7 s. We do
# a single cheap broadcast below instead.
$envKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
if ($envKey) {
    if ($live) {
        foreach ($name in @('HTTPS_PROXY', 'HTTP_PROXY')) {
            if ([string]$envKey.GetValue($name, '') -ne $want) {
                $envKey.SetValue($name, $want, 'String')
                $changed = $true
            }
        }
        if ([string]$envKey.GetValue('NO_PROXY', '') -ne $NoProxy) {
            $envKey.SetValue('NO_PROXY', $NoProxy, 'String')
            $changed = $true
        }
    } else {
        foreach ($name in @('HTTPS_PROXY', 'HTTP_PROXY', 'NO_PROXY', 'https_proxy', 'http_proxy', 'no_proxy')) {
            if ($null -ne $envKey.GetValue($name, $null)) {
                $envKey.DeleteValue($name, $false)
                $changed = $true
            }
        }
    }
    $envKey.Close()
}

if (-not $changed) { exit 0 }

# Tell running apps (Explorer included) that the user environment changed, so
# processes they launch from now on inherit the new value.
$sig = @'
using System;
using System.Runtime.InteropServices;
public class EnvBroadcast {
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
}
'@
$dll = Join-Path $PSScriptRoot 'EnvBroadcast.dll'
if (-not ('EnvBroadcast' -as [type])) {
    if (Test-Path $dll) {
        try { Add-Type -Path $dll -ErrorAction Stop } catch { Add-Type -TypeDefinition $sig | Out-Null }
    } else {
        Add-Type -TypeDefinition $sig | Out-Null
    }
}
$result = [UIntPtr]::Zero
# 100 ms per window: plenty for well-behaved windows, and it stops a few hung
# windows from stretching this into a multi-second run.
[void][EnvBroadcast]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 100, [ref]$result)

$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
if ($live) {
    "$stamp  proxy env -> $want" | Add-Content -Path $LogPath -Encoding UTF8
} else {
    "$stamp  proxy env cleared (port $port closed)" | Add-Content -Path $LogPath -Encoding UTF8
}
if ((Get-Item $LogPath).Length -gt 51200) {
    $keep = Get-Content $LogPath -Tail 200
    Set-Content -Path $LogPath -Value $keep -Encoding UTF8
}
