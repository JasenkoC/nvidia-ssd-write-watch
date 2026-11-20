#Requires -Version 5.1
<#
.SYNOPSIS
    Watchdog for the NVIDIA 621.14/621.24 "nvlog.nvlgstg" excessive-SSD-write bug.

.DESCRIPTION
    Samples the cumulative disk-write counters of NVDisplay.Container / nvcontainer and the
    size + timestamp of the NVIDIA diagnostic log (nvlog.nvlgstg). Each run compares against
    the previous snapshot, so the measured rate covers the whole gap between runs instead of
    a short, easy-to-miss sample window.

    Counters are used rather than file size on purpose: the bug rewrites the log in place,
    so a rewrite loop can grow the file by 0 bytes while generating gigabytes of I/O.

    Runs as a normal user. No administrator rights required.

.PARAMETER NvLogPath
    Explicit path to nvlog.nvlgstg. Auto-discovered when omitted.

.PARAMETER DataDir
    Where state/history/logs are kept. Defaults to %LOCALAPPDATA%\NvidiaSsdWatch.

.PARAMETER AffectedMaxDriverVersion
    Highest NVIDIA driver version known to be affected. A newer version triggers a one-time
    obsolescence notice suggesting uninstall. Default: 621.24.

.EXAMPLE
    .\Monitor-NvLogWrites.ps1
    .\Monitor-NvLogWrites.ps1 -AlertMbPerHour 100 -NoToast

.NOTES
    Exit codes: 0 OK, 1 WARN, 2 ALERT, 3 error, 4 baseline, 5 no NVIDIA install found.
#>
[CmdletBinding()]
param(
    [string]$NvLogPath          = '',
    [string]$DataDir            = (Join-Path $env:LOCALAPPDATA 'NvidiaSsdWatch'),
    [double]$AlertMbPerHour     = 300,
    [double]$WarnMbPerHour      = 50,
    [double]$AlertNvlogGrowthMb = 1024,
    [double]$MinGapMinutes      = 5,
    [string]$AffectedMaxDriverVersion = '621.24',
    [switch]$NoToast,
    [switch]$TestToast
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '2.6'

# Invariant culture so decimal separators stay '.' in the CSV and alert text regardless of
# the machine's regional settings (a German or Czech Windows would otherwise write '1,5').
[System.Threading.Thread]::CurrentThread.CurrentCulture   = [Globalization.CultureInfo]::InvariantCulture
[System.Threading.Thread]::CurrentThread.CurrentUICulture = [Globalization.CultureInfo]::InvariantCulture

$DefaultNvLog = Join-Path $env:ProgramData 'NVIDIA Corporation\nvtopps\nct\nvlog.nvlgstg'
$ProjectUrl   = 'https://github.com/JasenkoC/nvidia-ssd-write-watch'
$StatePath    = Join-Path $DataDir 'state.json'
$CsvPath      = Join-Path $DataDir 'history.csv'
$AlertPath    = Join-Path $DataDir 'last-alert.txt'
$RunLog       = Join-Path $DataDir 'watch.log'

New-Item -ItemType Directory -Path $DataDir -Force | Out-Null

function Write-RunLog {
    param([string]$Message)
    try {
        Add-Content -LiteralPath $RunLog -Value ("{0}  {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message)
    } catch { }
}

function Send-Toast {
    param([string]$Title, [string]$Body)
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $texts = $template.GetElementsByTagName('text')
        $texts.Item(0).AppendChild($template.CreateTextNode($Title)) | Out-Null
        $texts.Item(1).AppendChild($template.CreateTextNode($Body))   | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
        # PowerShell's registered AUMID, so no packaging or registration is needed.
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
        return $true
    } catch {
        Write-RunLog ("Toast failed: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

function Get-NvidiaDriverVersion {
    # nvidia-smi reports the marketing version ("621.24"). It is absent on machines
    # with no NVIDIA driver, in which case the obsolescence check is simply skipped.
    try {
        $smi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
        if (-not $smi) { return $null }
        $out = & $smi.Source --query-gpu=driver_version --format=csv,noheader 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
        $first = @($out)[0]
        if ($first) { return ([string]$first).Trim() }
    } catch { }
    return $null
}

if ($TestToast) {
    $ok = Send-Toast -Title 'NVIDIA SSD watchdog test' -Body 'Notifications work. You will see this if nvlog.nvlgstg starts churning.'
    Write-Output ("Toast delivered: {0}" -f $ok)
    if (-not $ok) { exit 3 }
    exit 0
}

try {
    $now = [datetime]::UtcNow

    # ---- resolve the log path (configurable, then default, then discovered) ----
    if (-not $NvLogPath) {
        if (Test-Path -LiteralPath $DefaultNvLog) {
            $NvLogPath = $DefaultNvLog
        } else {
            $found = Get-ChildItem (Join-Path $env:ProgramData 'NVIDIA Corporation') -Recurse -Filter 'nvlog.nvlgstg' `
                -File -Force -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $NvLogPath = $found.FullName }
        }
    }

    # ---- current snapshot -------------------------------------------------
    $logSize = $null; $logWrite = $null
    if ($NvLogPath -and (Test-Path -LiteralPath $NvLogPath)) {
        $fi = Get-Item -LiteralPath $NvLogPath -Force
        $logSize  = [int64]$fi.Length
        $logWrite = $fi.LastWriteTimeUtc
    }

    $current = @{}
    foreach ($p in @(Get-Process -Name 'NVDisplay.Container', 'nvcontainer' -ErrorAction SilentlyContinue)) {
        $c = Get-CimInstance -ClassName Win32_PerfRawData_PerfProc_Process -Filter "IDProcess=$($p.Id)" -ErrorAction SilentlyContinue
        if ($c) { $current["$($p.Id)"] = [int64]$c.IOWriteBytesPersec }
    }

    if ($current.Count -eq 0 -and -not $logSize) {
        Write-RunLog "status=NO-NVIDIA (no containers running, no diagnostic log found)"
        Write-Output "NO-NVIDIA | nothing to watch (no NVIDIA containers and no nvlog.nvlgstg)"
        exit 5
    }

    # ---- previous snapshot ------------------------------------------------
    $prev = $null
    if (Test-Path -LiteralPath $StatePath) {
        try { $prev = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json } catch { $prev = $null }
    }

    $status      = 'BASELINE'
    $exitCode    = 4
    $deltaBytes  = 0
    $matchedPids = 0
    $gapHours    = 0
    $gapMinutes  = 0
    $mbPerHour   = 0
    $logDelta    = 0
    $logTouched  = $false

    if ($prev) {
        $prevTime = [datetime]::Parse($prev.TimeUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        $gapMinutes = ($now - $prevTime).TotalMinutes
        $gapHours   = $gapMinutes / 60.0

        foreach ($kv in $current.GetEnumerator()) {
            $old = $prev.Pids.PSObject.Properties[$kv.Key]
            if ($old -and [int64]$old.Value -le $kv.Value) {
                $deltaBytes += ($kv.Value - [int64]$old.Value)
                $matchedPids++
            }
        }

        if ($null -ne $prev.LogSize -and $null -ne $logSize) { $logDelta = $logSize - [int64]$prev.LogSize }
        if ($null -ne $prev.LogWriteUtc -and $null -ne $logWrite) {
            $logTouched = ([string]$logWrite -ne [string]$prev.LogWriteUtc)
        }

        if ($gapHours -gt 0) { $mbPerHour = ($deltaBytes / 1MB) / $gapHours }

        if ($gapMinutes -lt $MinGapMinutes) {
            $status = 'SHORT'; $exitCode = 0
        }
        elseif ($matchedPids -eq 0) {
            # No counters could be paired: either the containers restarted, or this is a
            # driver-only install with no display container. Fall back to log growth so
            # those machines are still watched instead of silently reporting nothing.
            if (($logDelta / 1MB) -ge $AlertNvlogGrowthMb) {
                $status = 'ALERT'; $exitCode = 2
            } else {
                $status = 'RESTARTED'; $exitCode = 0
            }
        }
        elseif ($mbPerHour -ge $AlertMbPerHour -or ($logDelta / 1MB) -ge $AlertNvlogGrowthMb) {
            $status = 'ALERT'; $exitCode = 2
        }
        elseif ($mbPerHour -ge $WarnMbPerHour -or $logTouched) {
            $status = 'WARN'; $exitCode = 1
        }
        else {
            $status = 'OK'; $exitCode = 0
        }
    }

    # ---- obsolescence: has a newer driver appeared? -----------------------
    # A version above the last known-affected one means the bug is probably fixed and
    # this watchdog has done its job. Notified once per driver version, never auto-removed.
    $driverVersion   = Get-NvidiaDriverVersion
    $obsoleteVersion = $null
    $vInstalled = [version]'0.0'
    $vAffected  = [version]'0.0'
    if ($driverVersion -and
        [version]::TryParse($driverVersion, [ref]$vInstalled) -and
        [version]::TryParse($AffectedMaxDriverVersion, [ref]$vAffected) -and
        $vInstalled -gt $vAffected) {
        $obsoleteVersion = $driverVersion
    }
    $alreadyNotified = if ($prev) { $prev.ObsoleteNotified } else { $null }

    # ---- persist ----------------------------------------------------------
    if (-not (Test-Path -LiteralPath $CsvPath)) {
        Set-Content -LiteralPath $CsvPath -Value 'Timestamp,ElapsedMin,GapHours,NvWriteBytesDelta,MBperHour,NvlogBytes,NvlogDelta,Touched,MatchedPids,Status' -Encoding UTF8
    }
    $csvLine = '{0},{1:N1},{2:N2},{3},{4:N2},{5},{6},{7},{8},{9}' -f `
        (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $gapMinutes, $gapHours, $deltaBytes,
        $mbPerHour, $logSize, $logDelta, $logTouched, $matchedPids, $status
    Add-Content -LiteralPath $CsvPath -Value $csvLine -Encoding UTF8

    $state = [pscustomobject]@{
        Version          = $ScriptVersion
        TimeUtc          = $now.ToString('o')
        Pids             = $current
        LogPath          = $NvLogPath
        LogSize          = $logSize
        LogWriteUtc      = [string]$logWrite
        Status           = $status
        DriverVersion    = $driverVersion
        ObsoleteNotified = $(if ($obsoleteVersion) { $obsoleteVersion } else { $alreadyNotified })
    }
    $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StatePath -Encoding UTF8

    Write-RunLog ("status={0} mbPerHour={1:N2} deltaBytes={2} gapMin={3:N1} nvlog={4} logDelta={5} touched={6} pids={7} driver={8}" -f `
        $status, $mbPerHour, $deltaBytes, $gapMinutes, $logSize, $logDelta, $logTouched, $matchedPids, $driverVersion)

    if ($obsoleteVersion -and $obsoleteVersion -ne $alreadyNotified) {
        $notice = @"
{0}  DRIVER UPDATED - WATCHDOG OBSOLETE

Detected NVIDIA driver {1}, which is newer than the last known affected version {2}.

If this driver contains NVIDIA's fix for the nvlog.nvlgstg write loop, this watchdog is
no longer needed. Confirm before removing it: let two or three scheduled samples land and
check that they report OK with a near-zero rate.

  Get-Content "$CsvPath" -Tail 5

Then uninstall:

  powershell -ExecutionPolicy Bypass -File .\Uninstall-NvidiaSsdWatch.ps1

Keeping it running is harmless - just noise - but a WARN caused by a future driver's
ordinary logging would send you chasing a bug that no longer exists.

Reported affected versions: 621.14 and 621.24.
"@ -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $obsoleteVersion, $AffectedMaxDriverVersion

        Set-Content -LiteralPath (Join-Path $DataDir 'obsolete-notice.txt') -Value $notice -Encoding UTF8
        Write-RunLog ("obsolete: driver {0} is newer than {1}" -f $obsoleteVersion, $AffectedMaxDriverVersion)
        if (-not $NoToast) {
            [void](Send-Toast -Title "NVIDIA driver $obsoleteVersion detected" `
                -Body "Newer than the affected $AffectedMaxDriverVersion - this watchdog is probably no longer needed. See obsolete-notice.txt to uninstall.")
        }
    }

    # ---- alert ------------------------------------------------------------
    if ($status -eq 'ALERT') {
        $humanDelta = Format-Bytes $deltaBytes
        $humanRate  = if ($mbPerHour -ge 1024) { '{0:N1} GB/h' -f ($mbPerHour / 1024) } else { '{0:N0} MB/h' -f $mbPerHour }

        # Toast is intentionally short: it names the symptom and the two fastest remedies.
        $toastBody = ('{0} in {1:N0} min ({2}). To stop: update the NVIDIA driver, or roll back to 621.01. Details in last-alert.txt' -f `
            $humanDelta, $gapMinutes, $humanRate)

        # The file carries the full runbook, so the information survives the toast disappearing.
        $alertText = @"
{0}  ALERT  (watchdog v{1})

NVDisplay.Container wrote {2} in {3:N0} minutes ({4}).
nvlog.nvlgstg is currently {5}.
Threshold: {6:N0} MB/h.

WHAT THIS MEANS
  Something in the NVIDIA display container is rewriting nvlog.nvlgstg
  continuously. This is the signature of the GeForce 621.14 / 621.24 bug,
  which has been reported to add up to 30 GB/hour of SSD writes at idle.

HOW TO STOP THE WRITES  (fastest first)
  1. Update the NVIDIA driver, if a build newer than 621.24 is available.
  2. Roll back to 621.01 - the last version reported clean (under 2 MB per
     5 minutes of idle writes).
  3. Remove the NVIDIA App, keeping the display driver. Reports point at
     the app's display container rather than the driver core.
  4. Interim: turn off Instant Replay and the in-game overlay, or stop the
     'NVIDIA Display Container LS' service, delete
     $env:ProgramData\NVIDIA Corporation\nvtopps\nct\nvlog.nvlgstg,
     then start the service again.

TURN THIS WATCHDOG OFF WHILE YOU WORK
  schtasks /End /TN "NVIDIA-SSD-WriteWatch"
  (re-enable with: schtasks /Run /TN "NVIDIA-SSD-WriteWatch")

Full history : {7}
Project      : {8}

"@ -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $ScriptVersion, $humanDelta, $gapMinutes,
       $humanRate, $(if ($null -ne $logSize) { Format-Bytes $logSize } else { 'not found' }),
       $AlertMbPerHour, $CsvPath, $ProjectUrl

        Set-Content -LiteralPath $AlertPath -Value $alertText -Encoding UTF8
        if (-not $NoToast) { [void](Send-Toast -Title 'NVIDIA SSD write bug detected' -Body $toastBody) }
    }

    Write-Output ("{0} | {1} | {2:N2} MB/h | {3:N0} MB over {4:N0} min | nvlog {5} bytes" -f `
        (Get-Date).ToString('HH:mm:ss'), $status, $mbPerHour, ($deltaBytes / 1MB), $gapMinutes, $logSize)

    exit $exitCode
}
catch {
    Write-RunLog ("ERROR: {0}" -f $_.Exception.Message)
    Write-Output ("ERROR: {0}" -f $_.Exception.Message)
    exit 3
}
