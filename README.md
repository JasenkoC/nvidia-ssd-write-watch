# NVIDIA SSD-Write Watchdog

Watches for the **NVIDIA 621.14 / 621.24 GeForce driver bug** that makes
`NVDisplay.Container.exe` rewrite `nvlog.nvlgstg` continuously — draining SSDs by
up to 30 GB/hour while the PC sits idle.

Reports upstream: [TechPowerUp](https://www.techpowerup.com/354996/latest-nvidia-drivers-might-cause-excessive-ssd-writing),
[Igor's Lab](https://www.igorslab.de/en/geforce-drivers-write-gigabytes-to-ssds-nvdisplay-container-exe-suspected/).

Because the bug is intermittent — many people on the affected driver see nothing at all —
this runs on a schedule and only speaks up when the write rate actually misbehaves.

> **Temporary workaround — fixed in 621.35.** This tool only matters while the affected
> driver versions (621.14 / 621.24) are installed. NVIDIA's
> [621.35 hotfix](https://nvidia.custhelp.com/app/answers/detail/a_id/5940/~/geforce-hotfix-display-driver-version-621.35)
> resolves the bug, so on that version or newer the watchdog is obsolete and should be
> removed — see [When this becomes obsolete](#when-this-becomes-obsolete).

## Portability

Nothing assumes `C:\`, `C:\Program Files`, a particular user name, or an English Windows.
Every path resolves through environment variables:

| Variable | Used for | Correct when |
|---|---|---|
| `%ProgramData%` | locating `nvlog.nvlgstg` | Windows itself is installed on `D:` or elsewhere |
| `%LOCALAPPDATA%` | state, history, deployed script | profiles are redirected or roam |
| `%SystemRoot%` | PowerShell executable in the scheduled task | drive letters differ from the default |

Numbers are formatted with the invariant culture, so the CSV stays parsable on a German,
Czech or French Windows where the decimal separator is a comma. Status values and the
thresholds themselves are locale-independent.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (built in)
- **No administrator rights**

## Install

Download the three files into one folder, then:

```powershell
Get-ChildItem .\*.ps1 | Unblock-File
powershell -ExecutionPolicy Bypass -File .\Install-NvidiaSsdWatch.ps1
```

`Install-NvidiaSsdWatch.ps1` copies the monitor to `%LOCALAPPDATA%\NvidiaSsdWatch`,
sends a test notification, and registers a scheduled task called
`NVIDIA-SSD-WriteWatch` that samples every 30 minutes. It is idempotent — re-run it to upgrade.

**It runs with no visible window.** The task launches the monitor through a generated
`run-hidden.vbs`, because Task Scheduler would otherwise open a console window each run —
and with Windows Terminal as the default console host, `-WindowStyle Hidden` still flashes a
Terminal window before PowerShell can hide it. `wscript.exe` is a GUI-subsystem host, so no
window is ever created. If VBScript has been removed or blocked by policy, the installer
detects this and falls back to a plain PowerShell action (which may flash).

Files must stay together as a set: `Install-NvidiaSsdWatch.ps1` looks for
`Monitor-NvLogWrites.ps1` in its own folder.

## What it measures

Each run reads the **cumulative** disk-write counters of `NVDisplay.Container` and
`nvcontainer`, plus the size and timestamp of the NVIDIA diagnostic log. It compares against
the previous snapshot, so the reported rate covers the whole gap between runs.

Counters matter: the bug **rewrites the log in place**, so a rewrite loop can add 0 bytes to
the file while generating gigabytes of I/O. File-size monitoring alone would miss it.

| Measured rate | Result |
|---|---|
| < 50 MB/h | `OK`, logged silently |
| ≥ 50 MB/h, or the log timestamp changes | `WARN`, logged only |
| ≥ 300 MB/h, or `nvlog.nvlgstg` grows ≥ 1 GB in one gap | `ALERT` → Windows toast + `last-alert.txt` |

Typical healthy system: ~0–20 MB/h. Affected systems: 1,000–30,000 MB/h.
Both thresholds are configurable parameters on `Monitor-NvLogWrites.ps1`.

## If it alerts

The toast is deliberately short — it names the symptom and the two fastest remedies. The full
runbook is written to `%LOCALAPPDATA%\NvidiaSsdWatch\last-alert.txt`, so the guidance survives
the notification disappearing:

> **ALERT** NVDisplay.Container wrote 4,096 MB in 30 minutes (8,192 MB/h).

That means something in the NVIDIA display container is rewriting `nvlog.nvlgstg` continuously.
It can add up to 30 GB/hour of SSD writes while the machine sits idle. Stop the writes,
fastest first:

1. **Update the NVIDIA driver** — if a build newer than 621.24 exists, install it.
2. **Roll back to 621.01** — the last version reported clean (under 2 MB per 5 minutes idle).
3. **Remove the NVIDIA App**, keeping the display driver. Reports point at the app's display
   container rather than the driver core, and removing the app stopped the writes for several people.
4. **Interim measures** — turn off Instant Replay and the in-game overlay; or stop the
   `NVDisplay.ContainerLocalSystem` service, delete
   `%ProgramData%\NVIDIA Corporation\nvtopps\nct\nvlog.nvlgstg`, then start the service again.

Turn the watchdog off while you work on it, then turn it back on to confirm the fix:

```powershell
schtasks /End  /TN "NVIDIA-SSD-WriteWatch"   # pause
schtasks /Run  /TN "NVIDIA-SSD-WriteWatch"   # resume / re-check
```

Leaving it disabled is the one thing not to do — the whole point is to catch this if it comes back.

## When this becomes obsolete

**This is a temporary workaround, not a permanent tool.** The bug lives in the NVIDIA
GeForce 621.14 / 621.24 display container. **NVIDIA fixed it in driver 621.35**, so on that
version or newer there is nothing left to catch and the watchdog should be removed.

- **Download:** [GeForce 621.35 hotfix driver](https://international.download.nvidia.com/Windows/621.35hf/621.35-desktop-notebook-win10-win11-64bit-international-dch.hf.exe)
  — desktop and notebook, Windows 10/11 64-bit, DCH
- **Release information:** [NVIDIA — GeForce Hotfix Display Driver version 621.35](https://nvidia.custhelp.com/app/answers/detail/a_id/5940/~/geforce-hotfix-display-driver-version-621.35)

Check what you are running:

```powershell
nvidia-smi --query-gpu=driver_version --format=csv,noheader
```

| Driver version | What to do |
|---|---|
| **621.35 or newer** | Fixed — remove the watchdog, after confirming below |
| **621.14 or 621.24** | Keep the watchdog running |
| **621.01** (older, unaffected) | Harmless — it will just report `OK`, or uninstall it |

Don't uninstall on the version number alone. After installing the fixed driver, let two or
three samples land and check that they report `OK` with a near-zero rate:

```powershell
Get-Content "$env:LOCALAPPDATA\NvidiaSsdWatch\history.csv" -Tail 5
```

Then remove it:

```powershell
powershell -ExecutionPolicy Bypass -File .\Uninstall-NvidiaSsdWatch.ps1
```

A stale watchdog is not dangerous, only noise — but a `WARN` triggered by some future
driver's ordinary logging would have you chasing a bug that no longer exists.

**It also tells you when that day arrives.** Every run reads the installed driver with
`nvidia-smi --query-gpu=driver_version`. If the version is newer than the last known
affected one (`621.24` by default, override with `-AffectedMaxDriverVersion`), the watchdog
writes `obsolete-notice.txt` and shows a **one-time** notification reminding you to uninstall.
It never removes itself and never repeats the notice for the same driver version.

## Checking on it

```powershell
schtasks /Query /TN "NVIDIA-SSD-WriteWatch" /V /FO LIST
schtasks /Run   /TN "NVIDIA-SSD-WriteWatch"          # check now
Get-Content "$env:LOCALAPPDATA\NvidiaSsdWatch\history.csv" -Tail 5
Get-Content "$env:LOCALAPPDATA\NvidiaSsdWatch\watch.log"  -Tail 20
```

`history.csv` columns: timestamp, gap, bytes written by the NVIDIA containers, MB/hour,
log size, log growth, whether the log was touched, how many process counters matched, status.

Status values: `BASELINE` (first run), `OK`, `WARN`, `ALERT`, `SHORT` (runs under 5 minutes
apart — rate skipped), `RESTARTED` (containers restarted, counters reset), `NO-NVIDIA`.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\Uninstall-NvidiaSsdWatch.ps1
powershell -ExecutionPolicy Bypass -File .\Uninstall-NvidiaSsdWatch.ps1 -KeepData
```

## Caveats

- **Toasts can be muted** by Focus Assist / Do Not Disturb. `history.csv` and
  `last-alert.txt` are the durable record.
- The task runs only **while you are logged on** (`Interactive`, `Limited`). Missed runs
  execute at next logon because `StartWhenAvailable` is set.
- If the containers restart between runs, that interval logs as `RESTARTED` and the rate is
  skipped rather than guessed.
- This is a **monitor, not a fix**. If it alerts, the real fixes are: roll back to 621.01,
  install NVIDIA's patched driver, or remove the NVIDIA App.
- Some antivirus/EDR products flag scripts that create scheduled tasks. The script is plain
  text — read it before running it, as with anything you download.

## Files

| File | Purpose |
|---|---|
| `Monitor-NvLogWrites.ps1` | The sampler. Safe to run by hand at any time. |
| `Install-NvidiaSsdWatch.ps1` | Deploys the monitor and registers the task. |
| `Uninstall-NvidiaSsdWatch.ps1` | Removes task and data. |
| `run-hidden.vbs` | Generated at install time; launches the monitor with no window. |

## Licence

[MIT](LICENSE) — do whatever you like with it.
