# Galaxy S24 battery-drain investigation and recurring diagnostics

This folder contains:

| File | What it is |
|---|---|
| `README.md` | This document: findings, the exact commands used in the investigation, how to run the script, the debloat reference and sources. |
| `Invoke-PhoneDiagnostics.ps1` | A **read-only** PowerShell script that repeats the whole investigation, writes a Markdown report with advice and keeps a history CSV. |
| `dashboard.template.html` | Template for the interactive dashboard. The script fills it with your data. |
| `reports\` | Created by the script. One folder per run (`report.md`, `summary.json`, `raw\` dumps), plus `history.csv` and **`dashboard.html`**. |

> **Safety:** nothing in this investigation, and nothing in the script, changes the phone. The script
> only runs `dumpsys`, `pm list`, `getprop`, `settings get`, `top` and `uptime`. It also has a deny-list
> that refuses `pm uninstall/disable/enable`, `cmd package`, `settings put`, `--reset`, `rm`,
> `am force-stop`, `reboot`, `svc` and `setprop` before anything is sent to the phone.

---

## 1. Device snapshot (20 Nov 2026, 23:01)

| Item | Value |
|---|---|
| Model | Samsung Galaxy S24, `SM-S921B` (Exynos 2400, Qualcomm FastConnect "cnss-kiwi" Wi-Fi) |
| Software | Android 17, build `CP2A.260605.016.S921BXXUIEZJD`, CSC `EUX` |
| Battery health | ASOC **95%**, BSOH 100%, first use 2025-01-03, "Good" health. **The battery is not the problem.** |
| Uptime at capture | 4h 31m, load average 21.7 / 18.1 / 17.6 |
| Users running | 0 = personal, 10 = work profile ("Jobbprofil", Intune), 95 = Dual Apps, 150 = Secure Folder |
| Apps | ~368 user-installed, 252 packages already disabled |
| RAM | 7.2 of 7.4 GB used, 3.5 GB of 8 GB swap used |

## 2. Findings

Measurement window: since the last full charge, **18h 47m on battery** (3h 06m screen on, 15h 41m screen off).

| Metric | Value | Normal |
|---|---|---|
| Total drain | 3,173 mAh (≈ 81% of the 3,900 mAh capacity) | – |
| Screen-off drain | 51% in 15.7 h = **3.3 %/h** (1,780 mAh) | 0.5–1 %/h |
| Screen-on drain | 36% in 3.1 h = 11.6 %/h | 8–15 %/h (fine) |
| Where the energy went | CPU 1,310 mAh, mobile radio 739 mAh (**621 while screen off**), screen 152, wakelocks 126 | – |

**Conclusion:** screen-on use is normal. The phone loses its battery because it **does not sleep with the screen off**.

### Issue 1 – Wi-Fi traffic keeps waking the phone (biggest cause)
- **Evidence**
  - Wakeup reasons: `qcom,cnss-kiwi` 10,033× and `wlan_pci_wake_irq` 9,904×, so about **20,000 wakeups from the Wi-Fi chip**.
  - Sleep attempts that failed: `SuspendControl.FailedSuspendDelay` 12,782×. `Device 0000:01:00.0 failed to suspend: error -11` 767× (that PCI device is the Wi-Fi chip).
  - `android.system.suspend-service` used 46 min of CPU retrying sleep.
  - The Wi-Fi multicast lock was held for **2h 52m** in total.
  - Holders at capture time: `MdnsServiceBrowserImpl` from Google Play services (uid 10274) and `NsdService` from system (uid 1000).
  - Wi-Fi wake reasons for the current Wi-Fi session: 399 data wakeups. Of these, **218 multicast**, 23 broadcast, **101 IPv6 Router Advertisements**, 158 unicast.
- **Why it matters:** Google's documentation for `WifiManager.MulticastLock` says that receiving multicast "can cause a noticeable battery drain". mDNS (device discovery for Cast, Quick Share, smart-home and Spotify Connect) needs that lock. Each multicast or RA packet on your network then wakes the phone.
- **Possible fixes** (you choose)
  1. Settings → Connected devices → Quick Share → *Contacts only* (or off).
  2. Settings → Location → Location services → turn off **Wi-Fi scanning** and **Bluetooth scanning**. Both are ON (`wifi_scan_always_enabled=1`, `ble_scan_always_enabled=1`).
  3. Identify the app doing discovery through `NsdService`. Candidates: Tuya Smart Life, SmartThings, Spotify, `com.cast4tv.miracast`, `com.phongphan.miracast`, Jabra. Put it in *Deep sleeping* or uninstall it.
  4. On the router: turn on IGMP snooping and multicast-to-unicast, increase the IPv6 RA interval, or test with IPv6 off.
  5. A test that settles it: one night on mobile data only (Wi-Fi off). If drain drops sharply, the cause is the Wi-Fi network.
  6. The One UI "Wi-Fi power saving" toggle no longer exists on One UI 7+ (Samsung support), so it can't be used.

### Issue 2 – Four Android users run at the same time
- **Evidence:** users 0, 10, 95 and 150 are all `running`. Each runs its own Google Play services: 59 + 21 + 22 + 23 service records. Profiles 0, 95 and 150 each have their own Facebook stubs. `com.facebook.appmanager` ran scheduled jobs in both user 0 and user 95, about 4.5 min of wakelock each.
- **Possible fixes**
  1. **Pause the work profile** outside work hours. You can schedule this in Digital Wellbeing. Google: paused work apps "won't run … or consume data and battery life".
  2. Remove Dual Messenger clones you don't use (Settings → Advanced features → Dual Messenger). This removes user 95.
  3. If you don't use Secure Folder, remove it (Secure Folder → Settings → More settings → Uninstall). This removes user 150.

### Issue 3 – Memory is full
- **Evidence:** 198 MB free RAM, 3.5 GB swap used, `kswapd0` used 9 min of CPU and `pagov` 8 min. About 368 apps are installed, plus four profiles.
- **Possible fixes:** uninstall apps you don't use (see section 6). Then try turning off RAM Plus (Device care → Memory → RAM Plus) and compare results.

### Issue 4 – Apps draining in the background

| App | Total | While not in use | Notes | Possible fix |
|---|---|---|---|---|
| **Kanpla** `dk.kanpla.unisonfm.twa` | 169 mAh | 168 mAh (cached) | 167 mAh of it is **mobile radio**, very abnormal | Deep sleeping or uninstall (use website) |
| **Outlook** (personal) | 92 mAh | 92 mAh | 397 `GOOGLE_C2DM` + 90 Firebase wakelocks | One account per profile, push only, or Sleeping |
| **Outlook** (work profile) | 63 mAh | 63 mAh | 129 Firebase wakelocks | Pause the work profile |
| **AliExpress** | 77 mAh | 18 mAh | 6 running services, sandboxed and GPU processes | Deep sleeping or uninstall |
| **WhatsApp** | 59 mAh | 54 mAh | Normal push | Keep |
| **Microsoft Launcher** | 40 mAh | – | Foreground service 18h 25m, alongside One UI Home | Uninstall if not your home screen |
| **Link to Windows** `com.microsoft.appmanager` | 14 mAh | – | Foreground service 17h 20m, 9 min CPU | Turn off when not used with your PC |
| **Samsung Health** | 24 mAh | – | ~20 min of worker wakelocks (heart-health score, policy) | Restrict background use if not needed |
| **YouTube** | 173 mAh | – | 1h 35m background audio (`AudioMix`) | Expected if you listen with the screen off |
| **Reddit** | 217 mAh | 8 mAh | Screen-on use | Normal |
| Teams (work), Gmail, Play Store | 35–49 mAh | – | Normal push and updates | Keep |

### Issue 5 – Weak signal and frequent network switching
- **Evidence:** weak cellular signal for 4h 13m, **294 connectivity changes** in 19h, about 25,000 modem/IPC wakelock events (`qcom_rx_wakelock`, `umts_ipc0/1`), and 621 mAh of mobile radio with the screen off.
- **Possible fixes**
  1. Use Wi-Fi Calling or LTE-only in places with poor coverage.
  2. Check NordVPN auto-connect and Always-on VPN.
  3. Wi-Fi → Intelligent Wi-Fi → turn off "Switch to mobile data".

### Issue 6 – One UI settings
- Battery → Background usage limits → turn on **Put unused apps to sleep**. Move rarely used apps to **Deep sleeping**: they never run in the background, per Samsung's documentation.
- Adaptive battery is already on (`adaptive_battery_management_enabled=1`).

### Issue 7 – Preinstalled bloat (see section 6)

---

## 3. Running the diagnostics script

### Requirements
- Windows with PowerShell 7+ (Windows PowerShell 5.1 should also work).
- Android platform-tools (`adb`) in `PATH`.
- Phone connected by USB, **USB debugging** on, and the "Allow USB debugging" prompt accepted ("Always allow from this computer").

### Usage
```powershell
cd C:\Users\asahi\source\ai\phone-battery-diagnostics

.\Invoke-PhoneDiagnostics.ps1                        # auto-detect phone, collect, analyze, report
.\Invoke-PhoneDiagnostics.ps1 -Serial RFCX90VT0AH    # choose device explicitly
.\Invoke-PhoneDiagnostics.ps1 -Full                  # also keep alarm/jobs/power/deviceidle/usagestats dumps
.\Invoke-PhoneDiagnostics.ps1 -Top 40                # longer ranked tables
.\Invoke-PhoneDiagnostics.ps1 -FromDir .\reports\2026-11-21_0800\raw   # re-analyze an old run (no phone needed)
.\Invoke-PhoneDiagnostics.ps1 -SelfTest              # run the parser self-checks
.\Invoke-PhoneDiagnostics.ps1 -Open                  # run, then open the dashboard in your browser
.\Invoke-PhoneDiagnostics.ps1 -DashboardOnly -Open   # no phone needed: rebuild + open the dashboard
Get-Help .\Invoke-PhoneDiagnostics.ps1 -Full         # built-in help
```

If the script refuses to run ("not digitally signed"): `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`, or run it once with `powershell -ExecutionPolicy Bypass -File .\Invoke-PhoneDiagnostics.ps1`.

### Output
```
reports\
  dashboard.html                   interactive dashboard (open in any browser, works offline)
  history.csv                      one row per run (trend over time)
  2026-11-21_0800\
    report.md                      human-readable report with advice
    summary.json                   the same analysis as structured data (feeds the dashboard)
    raw\*.txt                      exact phone output (keep for re-analysis or sharing with support)
```

### The dashboard (`reports\dashboard.html`)
The dashboard is rebuilt after every run. It is a single self-contained file: no internet connection, no server and no external libraries. Double-click it, or use `-Open`.

| Area | What you see |
|---|---|
| **Left menu** | **Trends**, plus every report, newest first. Each report shows its screen-off drain with a status badge (✓ Good / ! Watch / ▲ High / ✕ Critical) and its number of high-priority issues. |
| **Trends** | One tile per metric in `history.csv`: latest value, status, change since the previous run (marked *better* or *worse*), min · avg · max over all runs, and a mini trend line. Click a tile to chart that metric over time. The chart has a reference line where one applies (e.g. *healthy ≤ 1 %/h*), shows the exact value on hover, and opens the matching report when you click a point. Below the chart is a sortable, filterable table of all history rows. |
| **Report → Overview** | All metrics for that run, each compared with the previous report. Also: where the energy went (CPU, radio, screen…), the top advice items, and which profiles were running. |
| **Advice** | Every finding grouped by priority, each with a suggested fix. |
| **Apps** | Energy per app split into *in use / background / foreground service / idle*. Hover a bar for CPU, radio and wakelock details. Sortable table below. |
| **Wakeups** | What woke the CPU and kernel wakelocks, with Wi-Fi and modem sources tagged. Also the Wi-Fi multicast lock holders, the Wi-Fi wake reasons and the app wakelocks. |
| **Processes / Network / Services** | CPU time per process, data per app (mobile vs Wi-Fi), and running services per app and user. |
| **Debloat** | Safe and optional packages that are still enabled, with tick boxes. It builds `pm disable-user` commands and the matching undo commands, each with a **Copy** button. **Nothing is run.** You copy the commands and run them yourself. The never-touch list is shown for reference. |
| **Snapshot** | Device properties, battery values and settings, and the live `top` output at capture. |

Other details:
- The theme button cycles *auto → light → dark*. Your choice is remembered in that browser.
- Every chart has a table view, and status is always shown as icon + text, never by colour alone.
- The layout works on a phone screen.
- Runs made before the dashboard existed get their `summary.json` generated automatically from `raw\` the first time the dashboard is built.
- Battery statistics count **since the last full charge**. Runs taken while the phone stays on the charger repeat the same numbers. For meaningful trends, run once a day just before plugging in.

`history.csv` columns: `Timestamp, Model, Build, Level, HealthAsoc, TempC, OnBatteryH, ScreenOffH, ScreenOffPctPerHour, DischargeMah, WifiWakeups, FailedSuspend, UsersRunning, SwapUsedMB, ThirdPartyApps, TopBackgroundApp`.
Open it in Excel to see whether a change, for example pausing the work profile, actually lowered `ScreenOffPctPerHour` and `WifiWakeups`.

### How the script works

| Stage | Function | What it does |
|---|---|---|
| Find phone | `Resolve-Serial` | Parses `adb devices`, skips emulators, explains "unauthorized". |
| Collect | `Invoke-Collect` → `Invoke-AdbShell` | Runs the commands in the table below and saves each one to `raw\<name>.txt`. Each command is checked against `$DenyPattern` first. |
| Parse | `Read-BatteryStats` | From the `Statistics since last charge` block: summary lines, estimated power per UID (fg/bg/fgs/cached + cpu/radio/wakelock components), kernel wakelocks, wakeup reasons, partial wakelocks, CPU time per process. |
| | `Read-NetworkUsage` | Mobile/Wi-Fi bytes per UID from `--checkin` rows `9,<uid>,l,nt,mobRx,mobTx,wifiRx,wifiTx,…`. |
| | `Read-Services` | Counts `ServiceRecord{… u<user> <package>/…}` per app and `isForeground=true`. |
| | `Read-PackageMap`, `Get-UidLabel` | Turns UIDs into package names: `u10a336` → app id 10336 in user 10 → `com.microsoft.office.outlook`. Shared system UIDs (1000, 1041, …) get names. |
| Advice | `Get-Advice` | Rule-based thresholds (below). Severity HIGH / MEDIUM / LOW. |
| Report | `Write-Report`, `Add-History` | Markdown report and CSV row. A re-analysis with `-FromDir` does not add a CSV row, because it is the same measurement. |
| Dashboard | `Save-RunSummary`, `Write-Dashboard` | Writes `summary.json` for the run, then puts every run's summary plus `history.csv` into `dashboard.template.html` → `reports\dashboard.html`. |

Commands the script runs (all read-only):

| Raw file | adb shell command | Used for |
|---|---|---|
| `props.txt` | `getprop ro.product.model / ro.build.version.release / ro.build.display.id / ro.csc.sales_code / ro.build.version.sdk` | Device identity |
| `uptime.txt` | `uptime` | Uptime, load average |
| `battery.txt` | `dumpsys battery` | Level, temperature, health (ASOC), charging |
| `batterystats.txt` | `dumpsys batterystats` | Almost all analysis |
| `bs_checkin.txt` | `dumpsys batterystats --checkin` | Network bytes per app |
| `top.txt` | `top -b -n 1 -m <Top>` | Live CPU and memory snapshot |
| `services.txt` | `dumpsys activity services` | Running and foreground services |
| `wifi.txt` | `dumpsys wifi \| grep -E -A8 'Multicast Locks held\|Wlan Wake Reasons\|Active lock owners'` | Multicast lock holders, Wi-Fi wake reasons |
| `thermal.txt` | `dumpsys thermalservice` | Thermal state (raw, for reference) |
| `users.txt` | `pm list users` | Profiles and whether they run |
| `uids.txt` | `pm list packages -U --user 0` | UID → package map |
| `pkgs_3rd.txt`, `pkgs_disabled.txt`, `pkgs_sys_enabled.txt` | `pm list packages -3 / -d / -s -e --user 0` | App counts, bloat check |
| `settings.txt` | `settings get global wifi_scan_always_enabled …` (read only) | Scanning and adaptive-battery settings |
| `-Full` only | `dumpsys alarm / jobscheduler / power / deviceidle / usagestats` | Manual digging |

Advice thresholds (in `Get-Advice`):

| Rule | Threshold |
|---|---|
| Idle drain | screen-off ≥ 1.5 %/h → HIGH, ≥ 1.0 %/h → MEDIUM |
| Wi-Fi wakeups | sum of wakeup reasons matching `wlan\|cnss\|wifi` ≥ 2,000 |
| Multicast lock | any holder at capture time |
| IPv6 RA | > 50 RA wakeups in the current Wi-Fi session |
| Weak signal | ≥ 1 h |
| Connectivity churn | ≥ 100 changes |
| Modem wakeups | ≥ 10,000 `umts_ipc\|qcom_rx_wakelock\|rmnet\|radio-interface` events |
| Extra profiles | any running user other than 0 |
| Memory | swap ≥ 2 GB or free RAM < 5% |
| Too many apps | ≥ 200 user apps |
| Background app | bg + cached ≥ 25 mAh (≥ 50 → HIGH); core packages in `$ExpectedBackground` excluded |
| Persistent service | foreground service ≥ 6 h (core packages excluded) |
| Settings | Wi-Fi/BLE "always scanning" on, Adaptive battery off |
| Battery | ASOC < 80%, temperature ≥ 40 °C |

To adjust the rules, edit the arrays at the top of the script: `$SafeToDisable`, `$OptionalDisable`, `$NeverTouch`, `$ExpectedBackground`.

### Getting meaningful numbers
- `batterystats` counts **since the last full charge**. The best time to run the script is just before you plug in, after a normal day or a night off the charger.
- Optional, for a clean measurement window: run `adb shell dumpsys batterystats --reset` yourself once, unplug, use the phone normally, then run the script. This **does** change the phone's statistics (it only clears counters), so the script never does it.

### Running it on a schedule
The phone has to be connected with USB debugging authorised when the task runs, for example on your desk every evening. Example, daily at 22:30:
```powershell
$script = 'C:\Users\asahi\source\ai\phone-battery-diagnostics\Invoke-PhoneDiagnostics.ps1'
$action  = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
$trigger = New-ScheduledTaskTrigger -Daily -At 22:30
Register-ScheduledTask -TaskName 'PhoneBatteryDiagnostics' -Action $action -Trigger $trigger -Description 'Read-only adb battery diagnostics'
# remove later with: Unregister-ScheduledTask -TaskName PhoneBatteryDiagnostics -Confirm:$false
```
If the phone isn't connected, that run fails with "No phone found" and nothing is written.

---

## 4. Investigation log – every command that was run, with explanation

All commands were run from this PC. Output was saved locally. Nothing was written to the phone.

### Step 1 – Identify the device (failed: phone unauthorized)
```powershell
adb devices -l; adb shell getprop ro.product.model; ...
```
Result: `RFCX90VT0AH unauthorized` and an offline emulator `emulator-5562`. Every later command uses `-s RFCX90VT0AH` so the emulator is ignored. After you accepted the RSA prompt on the phone, the device showed as `device`.

### Step 2 – Device identity, battery state, uptime
```powershell
$s='RFCX90VT0AH'
adb devices
adb -s $s shell "getprop ro.product.model; getprop ro.build.version.release; getprop ro.build.display.id; getprop ro.csc.sales_code; dumpsys battery; uptime"
```
- `getprop` reads build properties: SM-S921B, Android 17, build S921BXXUIEZJD, CSC EUX.
- `dumpsys battery` gives level 16%, charging, temperature 34.6 °C. Samsung extras: `mSavedBatteryAsoc: [95]` (capacity health 95%), `battery FirstUseDate: [20250103]`, and an event log showing the phone was unplugged at 18:30 and plugged in at 22:56.
- `uptime` showed load average ~21, which is very high for a phone.

### Step 3 – Bulk read-only dumps to local files
```powershell
$d='...\scratchpad\phone'
adb -s $s shell dumpsys batterystats            > "$d\batterystats.txt"   # 6 MB: full history + stats since last charge
adb -s $s shell dumpsys batterystats --checkin  > "$d\bs_checkin.txt"     # machine-readable CSV form
adb -s $s shell top -b -n 1 -m 40               > "$d\top.txt"            # live CPU/memory snapshot
adb -s $s shell dumpsys power                   > "$d\power.txt"          # wakelocks held right now
adb -s $s shell dumpsys alarm                   > "$d\alarm.txt"          # scheduled alarms per app
adb -s $s shell dumpsys jobscheduler            > "$d\jobs.txt"           # background jobs per app
adb -s $s shell dumpsys activity services       > "$d\services.txt"       # running services
adb -s $s shell pm list packages -f -u          > "$d\pkgs_all.txt"       # all packages incl. uninstalled-for-user
adb -s $s shell pm list packages -3             > "$d\pkgs_3rd.txt"       # user-installed apps
adb -s $s shell pm list packages -d             > "$d\pkgs_disabled.txt"  # disabled packages
adb -s $s shell dumpsys deviceidle              > "$d\deviceidle.txt"     # Doze state and whitelist
adb -s $s shell dumpsys usagestats              > "$d\usage.txt"          # app usage / standby buckets
adb -s $s shell dumpsys thermalservice          > "$d\thermal.txt"        # thermal throttling state
```
- `pm list packages` printed `SecurityException: Shell does not have permission to access user 10 / 150`. That's normal: adb cannot see inside the work profile or Secure Folder. It is also how the extra profiles were discovered.
- `top` result: RAM 7.19 / 7.40 GB used, swap 3.5 GB. Processes from users `u10_` (work), `u150_` (Secure Folder) and `u0_` were all present.

### Step 4 – Battery summary and per-app energy (Bash + awk on the saved file)
```bash
grep -n -m5 -E "Statistics since last charge|Time on battery|..." batterystats.txt
awk '/Estimated power use/{f=1} f{print; n++} n>70{exit}' batterystats.txt
```
This reads the `Statistics since last charge` block: 18h47m on battery, 15h41m screen off. It also reads `Estimated power use (mAh)`: computed drain 3,159 mAh, with CPU 641 and mobile_radio 621 mAh while the screen was off.

### Step 5 – Map UIDs to package names
```bash
adb -s RFCX90VT0AH shell pm list packages -U > uids.txt
# "package:com.foo uid:10350" -> map 10350 -> com.foo
# batterystats uses u<user>a<n>  =>  appId = 10000 + n  (u10a336 = user 10, appId 10336)
```
The top-consumer table in Issue 4 came from this step, for example `u0a801` → `dk.kanpla.unisonfm.twa` and `u10a725` → Teams in the work profile.

### Step 6 – Signal, radio and Doze summary
```bash
sed -n '67762,67900p' batterystats.txt | grep -E -i "signal|radio|Mobile|discharge|Connectivity|wake|..."
```
Gave: screen-off discharge 1,780 mAh / 51%, weak signal 4h13m, 294 connectivity changes, Wi-Fi multicast wakelock 2h52m.

### Step 7 – Kernel wakelocks, app wakelocks, wakeup reasons
```bash
for s in "All kernel wake locks:" "All partial wake locks:" "All wakeup reasons:"; do
  awk -v s="$s" 'index($0,s){f=1;next} f&&/^  [A-Z]/&&!/^  (Kernel|Wake lock|Wakeup)/{exit} f' batterystats.txt | head -25
done
```
- **Wakeup reasons** = which hardware interrupt woke the CPU. This step found the Wi-Fi chip storm: `cnss-kiwi`, `wlan_pci_wake_irq`, and `Device 0000:01:00.0 failed to suspend`.
- **Kernel wakelocks** = what kept the kernel awake: `FailedSuspendDelay` 12,782×, the modem `umts_ipc*`, `qcom_rx_wakelock`.
- **Partial wakelocks** = which app held the CPU: YouTube `AudioMix`, Samsung Health workers, Facebook appmanager in users 0 and 95, Outlook Firebase.

### Step 8 – Who holds the multicast lock, network bytes, alarm wakeups
```bash
for L in 72032 76954; do awk -v L=$L 'NR<=L && /^  [0-9u][0-9a-z]*:$/{h=$0} NR==L{print h; exit}' batterystats.txt; done   # owner UID of each multicast entry
awk -F, '$4=="nt"{...}' bs_checkin.txt      # mobile / wifi bytes per UID
awk -F, '$4=="wua"{...}' bs_checkin.txt     # wakeup alarms per UID
```
- The multicast lock time belonged to UID 1000 (system) and u0a274 (Google Play services).
- Data volumes were unremarkable: Reddit and Spotify were largest, all from screen-on use.

### Step 9 – CPU per process, VPN, settings, users
```bash
awk '/^  1000:$/{f=1;next} ... /^    Proc /{p=$2} /^      CPU:/{print p, $0}' batterystats.txt
adb -s RFCX90VT0AH shell "dumpsys connectivity | grep -iE 'VPN|NetworkAgentInfo\{' | head -8"
adb -s RFCX90VT0AH shell "for k in wifi_scan_always_enabled ble_scan_always_enabled ...; do echo \$k=\$(settings get global \$k); done"
adb -s RFCX90VT0AH shell "pm list users"
```
- One VPN network provider per user (0, 10, 95, 150). The active network at capture was LTE.
- `wifi_scan_always_enabled=1`, `ble_scan_always_enabled=1`, adaptive battery on, battery saver off.
- `pm list users` confirmed four running users: personal, Jobbprofil, DUAL_APP, Secure Folder.

### Step 10 – Rank all processes by CPU time and list user apps
```bash
awk '/^  [0-9u][0-9a-z]*:$/{u=$1} /^    Proc /{p=$2} /^      CPU:/{print u, p, $0}' batterystats.txt | <to-seconds> | sort -nr | head -25
sed 's/package://' pkgs_3rd.txt
```
- Top CPU: `system_server` 1h36m, Reddit 1h04m, audioserver 58m, YouTube, and `suspend-service` 46m. The last is almost all kernel time, from sleep retries.
- Also `kswapd0` 9m (memory pressure).
- About 368 user apps.

### Step 11 – Deep research (automated multi-agent web research)
The `deep-research` workflow searched 5 angles (Wi-Fi wakeups, multiple profiles, Samsung debloat lists, One UI battery settings, Android 17 adb restrictions). It fetched 20 sources and extracted 81 claims. Of the 25 claims it verified with 3 independent votes, 23 were confirmed and 2 refuted. Results are in section 7.

### Step 12 – Enabled preinstalled bloat and running services
```bash
adb -s RFCX90VT0AH shell pm list packages -s -e > sys_enabled.txt     # enabled system packages
grep -oE "ServiceRecord\{[^ ]+ u[0-9]+ [^ /]+" services.txt | awk '{print $2,$3}' | sort | uniq -c | sort -nr
```
Gave the list of bloat packages that are still enabled (section 6) and the service counts per user (Play services: 59 / 21 / 22 / 23).

### Step 13 – Confirm the multicast lock holders and Wi-Fi wake reasons
```powershell
adb -s RFCX90VT0AH shell "dumpsys wifi | grep -iE -A3 'multicast|mMulticast' | head -30"
```
- `Multicaster{MdnsServiceBrowserImpl uid=10274}` and `Multicaster{NsdService uid=1000}`.
- `Wlan Wake Reasons: … rxMulticast 218 rxBroadcast 23 icmp6Ra 101 …`.

The script automates steps 2–13 (except the web research). The Bash/awk parsing was rewritten in PowerShell (`Read-BatteryStats` and the other parsers) so the script runs without Bash.

---

## 5. Applying fixes later (not done; only with your go-ahead)

Settings changes (Issues 1–6) are done on the phone by hand. For debloating, use only the reversible commands:

```powershell
$s = 'RFCX90VT0AH'
adb -s $s shell pm disable-user --user 0 com.facebook.appmanager     # disable (reversible)
adb -s $s shell pm enable com.facebook.appmanager                    # undo
adb -s $s shell pm list packages -d | Select-String facebook         # verify
```
- `pm uninstall -k --user 0 <system app>` is **blocked on Android 17** without root ("only root can delete system app for a particular user"). If something was uninstalled per user on an older version, restore it with `adb shell cmd package install-existing <pkg>`.
- Disable in small batches, reboot, and use the phone for a day before the next batch. A disabled package may come back after a firmware update.
- `--user 0` only affects the personal profile. Users 95 and 150 cannot be reached from adb.

## 6. Debloat reference (packages present and enabled on this phone)

**Safe to disable** (community debloat lists agree, no known breakage):

| Package | What it is |
|---|---|
| `com.facebook.appmanager`, `com.facebook.services`, `com.facebook.system` | Meta preinstall stubs (updater and installer). Facebook/Messenger from Play Store keep working. |
| `com.samsung.android.aremoji`, `com.samsung.android.stickercenter` | AR Emoji and stickers |
| `com.samsung.android.app.sharelive` | Quick Share UI (disable only if you don't use Quick Share) |
| `com.samsung.android.forest` | Digital Wellbeing (Samsung). **Keep it if you use it to schedule the work-profile pause.** |
| `com.samsung.android.smartswitchassistant` | Smart Switch helper |
| `com.samsung.android.da.daagent` | Dual Messenger agent (disable only if you don't use Dual Messenger) |
| `com.samsung.android.bixby.agent`, `com.samsung.android.bixby.wakeup` | Bixby voice ("Hi Bixby" listener) |
| `com.samsung.android.game.gametools` | Game Booster overlay |
| `com.microsoft.skydrive` | OneDrive |
| `com.hiya.star` | Hiya caller ID / spam service |

**Optional** (only if you don't use the feature):

| Package | Breaks |
|---|---|
| `com.samsung.android.warrantycare` | Samsung Care+ warranty app |
| `com.samsung.android.rubin.app` | Customization Service (personalised suggestions) |
| `com.samsung.android.smartsuggestions` | Smart suggestions widget and actions |
| `com.samsung.android.mdx`, `com.samsung.android.mdx.kit`, `com.microsoft.appmanager` | Link to Windows / Phone Link |
| `com.sec.android.app.samsungapps` | Galaxy Store, which **updates Samsung apps and Good Lock** |
| `com.samsung.android.app.routines` | Modes and Routines |
| `com.google.android.partnersetup` | Google partner setup |

**Never touch:**

| Package | Why |
|---|---|
| `com.samsung.android.app.dressroom` | Setting wallpaper from One UI Home breaks |
| `com.osp.app.signin` | Samsung account sign-in, parts of Settings |
| `com.samsung.android.kgclient` | Knox Guard, causes a warning at boot |
| `com.google.android.modulemetadata` | Permission management in Settings breaks |
| `com.samsung.android.visionintelligence`, `com.samsung.android.bixbyvision.framework` | Camera, Bixby Vision and AR depend on them |
| `com.samsung.android.game.gos`, `com.sec.android.sdhms` | Come back on reboot; system performance services |
| all `com.samsung.android.knox.*`, `com.samsung.knox.securefolder` | The work profile and Secure Folder depend on them |

**Third-party apps:** these are ordinary uninstalls from the app drawer, and they give the biggest RAM gain. Groups that look duplicated or rarely used:
- about 20 crypto wallets and exchanges
- 5 Down Dog apps
- NewPipe, Tubular and Rumble alongside YouTube
- two Miracast apps
- uTorrent
- several OBD scanners
- Laerdal `.test` builds
- Temu and AliExpress
- six browsers (Chrome, Edge, Opera, Vivaldi, DuckDuckGo, Tor)

## 7. Research sources and confidence

| Claim | Confidence | Source |
|---|---|---|
| A multicast lock makes the Wi-Fi stack process multicast packets, which causes noticeable drain | High (3-0) | developer.android.com – `WifiManager.MulticastLock` |
| The "Wi-Fi power saving" toggle is gone on One UI 7.0+ | High (3-0) | Samsung support ANS10002534 |
| A work profile runs its own Play services and sync; pausing stops its apps and battery use; pausing can be scheduled | High (3-0) | support.google.com/work/android/answer/7029561, bayton.org work-profile battery FAQ |
| Deep sleeping apps never run in the background; "Put unused apps to sleep" works automatically | High (3-0) | Samsung support TSG10013631, developer.samsung.com app-management |
| Android 17 blocks `pm uninstall --user 0` for system apps without root; `disable-user` still works | Medium (3-0; seen on Pixel/Xiaomi, AOSP change) | zeli.app, UAD-NG FAQ / PR #1451 |
| Facebook stubs are safe to disable | Medium (3-0, community) | Willie169 Samsung debloat list, technastic, droidwin |
| dressroom, kgclient, osp.app.signin, modulemetadata and vision frameworks must stay | Medium (3-0, community) | Willie169, droidwin |
| Mass-removing entire debloat lists can cause crash-loops | Low (community) | matthieu-pierson/debloat-samsung-adb |

**Not verified by any source:**
- An S24-specific Wi-Fi driver bug.
- The battery cost of Dual Apps or Secure Folder.
- Drain caused by Microsoft Launcher or Link to Windows.

The "network chatter + mDNS" explanation for Issue 1 is based on the phone's own wake-reason counters. The one-night "Wi-Fi off" test confirms or rules it out.
