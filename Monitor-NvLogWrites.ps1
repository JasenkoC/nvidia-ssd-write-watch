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
    [switch]$NoToast,
    [switch]$TestToast
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '2.0'

$DefaultNvLog = 'C:\ProgramData\NVIDIA Corporation\nvtopps\nct\nvlog.nvlgstg'
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
            $found = Get-ChildItem 'C:\ProgramData\NVIDIA Corporation' -Recurse -Filter 'nvlog.nvlgstg' `
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
            # Every container restarted between runs: rate is unknowable, fall back to file growth.
            $status = 'RESTARTED'; $exitCode = 0
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

    # ---- persist ----------------------------------------------------------
    if (-not (Test-Path -LiteralPath $CsvPath)) {
        Set-Content -LiteralPath $CsvPath -Value 'Timestamp,ElapsedMin,GapHours,NvWriteBytesDelta,MBperHour,NvlogBytes,NvlogDelta,Touched,MatchedPids,Status' -Encoding UTF8
    }
    $csvLine = '{0},{1:N1},{2:N2},{3},{4:N2},{5},{6},{7},{8},{9}' -f `
        (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $gapMinutes, $gapHours, $deltaBytes,
        $mbPerHour, $logSize, $logDelta, $logTouched, $matchedPids, $status
    Add-Content -LiteralPath $CsvPath -Value $csvLine -Encoding UTF8

    $state = [pscustomobject]@{
        Version     = $ScriptVersion
        TimeUtc     = $now.ToString('o')
        Pids        = $current
        LogPath     = $NvLogPath
        LogSize     = $logSize
        LogWriteUtc = [string]$logWrite
        Status      = $status
    }
    $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StatePath -Encoding UTF8

    Write-RunLog ("status={0} mbPerHour={1:N2} deltaBytes={2} gapMin={3:N1} nvlog={4} logDelta={5} touched={6} pids={7}" -f `
        $status, $mbPerHour, $deltaBytes, $gapMinutes, $logSize, $logDelta, $logTouched, $matchedPids)

    # ---- alert ------------------------------------------------------------
    if ($status -eq 'ALERT') {
        $body = ('NVDisplay.Container wrote {0:N0} MB in {1:N0} min ({2:N0} MB/h). nvlog.nvlgstg is {3:N1} MB. See {4}' -f `
            ($deltaBytes / 1MB), $gapMinutes, $mbPerHour, (($logSize) / 1MB), $CsvPath)
        $msg = ('{0}  ALERT: {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $body)
        Set-Content -LiteralPath $AlertPath -Value $msg -Encoding UTF8
        if (-not $NoToast) { [void](Send-Toast -Title 'NVIDIA SSD watchdog: excessive writes' -Body $body) }
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
