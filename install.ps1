# install.ps1 - registers the scheduled task that keeps the proxy env in sync.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
#
# Optional: -IntervalMinutes 30   -TaskName "proxy-env-sync"

param(
    [string]$TaskName = 'proxy-env-sync',
    [int]$IntervalMinutes = 30
)

$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
$script = Join-Path $dir 'sync-proxy-env.ps1'
$dll = Join-Path $dir 'EnvBroadcast.dll'

if (-not (Test-Path $script)) { throw "sync-proxy-env.ps1 not found next to install.ps1" }

# Compile the broadcast helper once so the 30-minute runs never pay for csc.
if (-not (Test-Path $dll)) {
    $sig = @'
using System;
using System.Runtime.InteropServices;
public class EnvBroadcast {
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
}
'@
    Add-Type -TypeDefinition $sig -OutputAssembly $dll -OutputType Library
    Write-Host "built  $dll"
}

# Replace any earlier copy of this task (including the pre-rename dsh- name).
foreach ($old in @($TaskName, 'dsh-proxy-env-sync')) {
    if (Get-ScheduledTask -TaskName $old -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $old -Confirm:$false
        Write-Host "removed old task  $old"
    }
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""

$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$once = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
$trigger.Repetition = $once.Repetition

$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Description 'Keep HTTPS_PROXY/HTTP_PROXY pointed at the Clash Verge mixed port.' | Out-Null

Write-Host "registered task  $TaskName  (at logon, then every $IntervalMinutes min)"

# Run once so the current session is correct immediately.
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 3
$info = Get-ScheduledTaskInfo -TaskName $TaskName
Write-Host ("first run:  result={0}  last={1}" -f $info.LastTaskResult, $info.LastRunTime)
