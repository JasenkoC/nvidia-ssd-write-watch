#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the NVIDIA SSD-write watchdog: copies the monitor and registers a scheduled task.

.DESCRIPTION
    Idempotent. Safe to re-run to upgrade. No administrator rights required.

.PARAMETER TaskName
    Name of the scheduled task. Default: NVIDIA-SSD-WriteWatch

.PARAMETER DataDir
    Where the monitor keeps state/history. Default: %LOCALAPPDATA%\NvidiaSsdWatch

.PARAMETER IntervalMinutes
    How often to sample. Default: 30

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-NvidiaSsdWatch.ps1

.NOTES
    If Windows blocks the script, unblock it first:
        Get-ChildItem .\*.ps1 | Unblock-File
#>
[CmdletBinding()]
param(
    [string]$TaskName        = 'NVIDIA-SSD-WriteWatch',
    [string]$DataDir         = (Join-Path $env:LOCALAPPDATA 'NvidiaSsdWatch'),
    [int]$IntervalMinutes    = 30,
    [switch]$NoToastTest
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Text) Write-Host $Text -ForegroundColor Cyan }

# ---- preflight ------------------------------------------------------------
if ($PSVersionTable.PSEdition -ne 'Desktop' -and $PSVersionTable.PSVersion.Major -lt 5) {
    throw "Windows PowerShell 5.1 or newer is required."
}
if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6 -and $env:OS -ne 'Windows_NT') {
    throw "This watchdog is Windows-only (it reads Windows perf counters and uses Task Scheduler)."
}
if (-not (Test-Path (Join-Path $env:ProgramData 'NVIDIA Corporation')) -and
    -not (Get-Process -Name 'NVDisplay.Container' -ErrorAction SilentlyContinue)) {
    Write-Warning "No NVIDIA install detected on this machine. Installing anyway; the monitor will exit with code 5 until NVIDIA software is present."
}

# Resolve PowerShell from %SystemRoot% rather than PATH, so the task works when Windows is
# installed on a drive other than C: and regardless of PATH customisation.
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }

$source = Join-Path $PSScriptRoot 'Monitor-NvLogWrites.ps1'
if (-not (Test-Path -LiteralPath $source)) {
    throw "Monitor-NvLogWrites.ps1 not found next to this installer ($PSScriptRoot). Keep the two files together."
}

# ---- deploy ---------------------------------------------------------------
Write-Step "`n[1/4] Deploying monitor to $DataDir"
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
$target = Join-Path $DataDir 'monitor.ps1'
Copy-Item -LiteralPath $source -Destination $target -Force
Unblock-File -LiteralPath $target -ErrorAction SilentlyContinue
"      -> $target"

# ---- toast check ----------------------------------------------------------
Write-Step "[2/4] Checking notification support"
if ($NoToastTest) {
    "      skipped (-NoToastTest)"
} else {
    $toastResult = & $psExe -NoProfile -ExecutionPolicy Bypass -File $target -TestToast -DataDir $DataDir
    "      -> $toastResult"
    if ($toastResult -notmatch 'True') {
        Write-Warning "Toast notification failed. Alerts will still be written to $DataDir\last-alert.txt, but you will not get a popup."
    }
}

# ---- task -----------------------------------------------------------------
Write-Step "[3/4] Registering scheduled task '$TaskName' (every $IntervalMinutes min)"
$tr = '"' + $psExe + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $target + '" -DataDir "' + $DataDir + '"'
& schtasks.exe /Create /F /TN $TaskName /SC MINUTE /MO $IntervalMinutes /TR $tr | Out-Null
if ($LASTEXITCODE -ne 0) { throw "schtasks failed to create '$TaskName' (exit $LASTEXITCODE)." }

$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
Set-ScheduledTask -TaskName $TaskName -Settings $settings | Out-Null

# ---- first run ------------------------------------------------------------
Write-Step "[4/4] Running once to establish a baseline"
& $psExe -NoProfile -ExecutionPolicy Bypass -File $target -DataDir $DataDir
$first = $LASTEXITCODE

$info = Get-ScheduledTaskInfo -TaskName $TaskName
Write-Host "`nInstalled." -ForegroundColor Green
Write-Host "  Task      : $TaskName"
Write-Host "  Schedule  : every $IntervalMinutes minutes (next: $($info.NextRunTime))"
Write-Host "  Data      : $DataDir"
Write-Host "  Thresholds: warn $('{0:N0}' -f 50) MB/h, alert $('{0:N0}' -f 300) MB/h"
Write-Host "`nCheck it anytime:"
Write-Host "  schtasks /Run /TN `"$TaskName`""
Write-Host "  Get-Content `"$DataDir\history.csv`" -Tail 5"
Write-Host "`nRemove it:"
Write-Host "  powershell -ExecutionPolicy Bypass -File .\Uninstall-NvidiaSsdWatch.ps1"

if ($first -eq 5) { Write-Warning "Monitor reported no NVIDIA install; it will retry on the next scheduled run." }
