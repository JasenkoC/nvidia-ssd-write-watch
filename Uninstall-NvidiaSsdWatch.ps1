#Requires -Version 5.1
<#
.SYNOPSIS
    Removes the NVIDIA SSD-write watchdog scheduled task.

.PARAMETER KeepData
    Keep the history/logs instead of deleting them.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Uninstall-NvidiaSsdWatch.ps1
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'NVIDIA-SSD-WriteWatch',
    [string]$DataDir  = (Join-Path $env:LOCALAPPDATA 'NvidiaSsdWatch'),
    [switch]$KeepData
)

$ErrorActionPreference = 'Continue'

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Green
} else {
    Write-Host "Scheduled task '$TaskName' was not present."
}

if ($KeepData) {
    Write-Host "Kept data in $DataDir"
} elseif (Test-Path -LiteralPath $DataDir) {
    Remove-Item -LiteralPath $DataDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $DataDir) {
        Write-Warning "Could not fully remove $DataDir (a file may be in use)."
    } else {
        Write-Host "Removed data in $DataDir."
    }
}
