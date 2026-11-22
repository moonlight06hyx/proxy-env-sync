# uninstall.ps1 - removes the scheduled task (and optionally the proxy env vars).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
#
# Add -ClearEnv to also delete HTTPS_PROXY / HTTP_PROXY / NO_PROXY from your
# user environment. By default they are left alone, because other tools may be
# using them already.

param(
    [string]$TaskName = 'proxy-env-sync',
    [switch]$ClearEnv
)

$ErrorActionPreference = 'Stop'

foreach ($name in @($TaskName, 'dsh-proxy-env-sync')) {
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        Write-Host "removed task  $name"
    } else {
        Write-Host "no such task  $name"
    }
}

$dll = Join-Path $PSScriptRoot 'EnvBroadcast.dll'
if (Test-Path $dll) {
    Remove-Item $dll -Force
    Write-Host "removed $dll"
}

if ($ClearEnv) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    foreach ($n in @('HTTPS_PROXY', 'HTTP_PROXY', 'NO_PROXY')) {
        if ($null -ne $key.GetValue($n, $null)) {
            $key.DeleteValue($n, $false)
            Write-Host "cleared  $n"
        }
    }
    $key.Close()
    Write-Host 'environment variables cleared (restart apps to see it)'
} else {
    Write-Host 'left HTTPS_PROXY / HTTP_PROXY / NO_PROXY as they are (-ClearEnv to delete them)'
}
