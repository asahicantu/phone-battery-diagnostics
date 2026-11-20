<#
.SYNOPSIS
    Read-only battery and background-activity diagnostics for an Android (Samsung Galaxy) phone over adb.

.DESCRIPTION
    1. COLLECT  - runs read-only adb commands (dumpsys, pm list, getprop, top) and saves raw output
                  to reports\<timestamp>\raw\.
    2. ANALYZE  - parses the raw files: battery drain rate, top consumers per app, wakelocks,
                  wakeup reasons, Wi-Fi multicast holders, memory pressure, running services,
                  user profiles, scanning settings and preinstalled bloat.
    3. REPORT   - writes reports\<timestamp>\report.md with ranked tables and advice, and appends
                  one row to reports\history.csv so runs can be compared over time.

    The script NEVER changes anything on the phone. Every shell command is checked against a
    deny-list (uninstall, disable, settings put, --reset, ...) before it is sent.

.PARAMETER Serial
    adb serial of the phone. If omitted, the first physical device in state "device" is used.

.PARAMETER OutputRoot
    Folder that receives the timestamped report folders and history.csv. Default: .\reports next to the script.

.PARAMETER FromDir
    Skip collection and re-analyze an existing raw folder (e.g. reports\2026-11-20_2301\raw).

.PARAMETER Full
    Also save alarm, jobscheduler, power, deviceidle and usagestats dumps (~8 MB extra, not analyzed,
    useful for manual digging).

.PARAMETER Top
    Number of rows in ranked tables. Default 20.

.PARAMETER SelfTest
    Run the parser self-checks and exit.

.PARAMETER DashboardOnly
    Do not contact the phone; just rebuild reports\dashboard.html from existing runs.

.PARAMETER Open
    Open dashboard.html in the default browser when done.

.EXAMPLE
    .\Invoke-PhoneDiagnostics.ps1
.EXAMPLE
    .\Invoke-PhoneDiagnostics.ps1 -Serial RFCX90VT0AH -Full
.EXAMPLE
    .\Invoke-PhoneDiagnostics.ps1 -FromDir .\reports\2026-11-20_2301\raw
#>
[CmdletBinding()]
param(
    [string]$Serial,
    [string]$OutputRoot = (Join-Path $PSScriptRoot 'reports'),
    [string]$FromDir,
    [switch]$Full,
    [int]$Top = 20,
    [switch]$SelfTest,
    [switch]$DashboardOnly,
    [switch]$Open
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture   # "3.3" not "3,3"

# ---------------------------------------------------------------------------------------------
# Package knowledge (sources and reasoning in README.md, section "Debloat reference")
# ---------------------------------------------------------------------------------------------
$SafeToDisable = @(
    'com.facebook.appmanager', 'com.facebook.services', 'com.facebook.system',
    'com.samsung.android.aremoji', 'com.samsung.android.aremojieditor', 'com.samsung.android.stickercenter',
    'com.samsung.android.app.sharelive', 'com.samsung.android.forest', 'com.samsung.android.smartswitchassistant',
    'com.samsung.android.da.daagent', 'com.samsung.android.bixby.agent', 'com.samsung.android.bixby.wakeup',
    'com.samsung.android.game.gametools', 'com.microsoft.skydrive', 'com.hiya.star',
    'com.samsung.android.arzone', 'com.samsung.android.app.tips', 'com.samsung.android.app.spage'
)
$OptionalDisable = @(
    'com.samsung.android.warrantycare', 'com.samsung.android.rubin.app', 'com.samsung.android.smartsuggestions',
    'com.samsung.android.mdx', 'com.samsung.android.mdx.kit', 'com.sec.android.app.samsungapps',
    'com.microsoft.appmanager', 'com.samsung.android.app.routines', 'com.google.android.partnersetup'
)
$NeverTouch = @(
    'com.samsung.android.app.dressroom', 'com.osp.app.signin', 'com.samsung.android.kgclient',
    'com.google.android.modulemetadata', 'com.samsung.android.visionintelligence',
    'com.samsung.android.bixbyvision.framework', 'com.samsung.android.game.gos', 'com.sec.android.sdhms',
    'com.samsung.knox.securefolder', 'com.samsung.android.knox.containercore'
)
# Core packages that are expected to run in the background: never suggested for sleeping / flagged as persistent
$ExpectedBackground = @(
    'com.android.vending', 'com.google.android.gms', 'com.google.android.gsf', 'com.android.systemui',
    'com.sec.android.app.launcher', 'com.google.android.ext.services', 'com.google.android.adservices.api',
    'com.google.android.mosey', 'com.sec.android.daemonapp', 'com.samsung.android.app.aodservice',
    'com.android.phone', 'com.sec.imsservice', 'com.google.android.as'
)
# Well-known shared system UIDs (no single package)
$SystemUidNames = @{
    0 = 'root/kernel'; 1000 = 'system (system_server + system apps)'; 1001 = 'radio (phone/telephony)'
    1002 = 'bluetooth'; 1010 = 'wifi HAL'; 1013 = 'media'; 1041 = 'audioserver'; 1046 = 'media codec'
    1047 = 'cameraserver'; 1073 = 'network stack'; 2000 = 'adb shell'
}

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------
function ConvertTo-Seconds([string]$Text) {
    # "1d 2h 3m 4s 500ms" -> seconds (double)
    $sec = 0.0
    foreach ($m in [regex]::Matches($Text, '(\d+)(ms|d|h|m|s)\b')) {
        $n = [double]$m.Groups[1].Value
        switch ($m.Groups[2].Value) { 'd' { $sec += $n * 86400 } 'h' { $sec += $n * 3600 } 'm' { $sec += $n * 60 } 's' { $sec += $n } 'ms' { $sec += $n / 1000 } }
    }
    $sec
}

function Format-Duration([double]$Seconds) {
    $ts = [TimeSpan]::FromSeconds($Seconds)
    if ($ts.TotalHours -ge 1) { '{0}h {1:00}m' -f [int][math]::Floor($ts.TotalHours), $ts.Minutes }
    elseif ($ts.TotalMinutes -ge 1) { '{0}m {1:00}s' -f $ts.Minutes, $ts.Seconds }
    else { '{0:0.0}s' -f $ts.TotalSeconds }
}

function Get-AppId([string]$Uid) {
    # u10a336 -> 10336 ; 1010336 -> 10336 ; 1000 -> 1000
    if ($Uid -match '^u(\d+)[a-z](\d+)$') { return 10000 + [int]$Matches[2] }
    if ($Uid -match '^\d+$') { return [int]([long]$Uid % 100000) }
    return $null
}

function Get-UserId([string]$Uid) {
    if ($Uid -match '^u(\d+)[a-z]\d+$') { return [int]$Matches[1] }
    if ($Uid -match '^\d+$') { return [int][math]::Floor([long]$Uid / 100000) }
    return 0
}

function Read-Lines([string]$Dir, [string]$Name) {
    $p = Join-Path $Dir $Name
    if (Test-Path $p) { return [IO.File]::ReadAllLines($p) }
    Write-Verbose "missing raw file: $Name"
    return @()
}

function ConvertTo-MdTable($Rows, [string[]]$Columns) {
    if (-not $Rows) { return @('_(none)_', '') }
    $out = [Collections.Generic.List[string]]::new()
    $out.Add('| ' + ($Columns -join ' | ') + ' |')
    $out.Add('|' + (($Columns | ForEach-Object { '---' }) -join '|') + '|')
    foreach ($r in $Rows) {
        $cells = foreach ($c in $Columns) { ("$($r.$c)" -replace '\|', '/') }
        $out.Add('| ' + ($cells -join ' | ') + ' |')
    }
    $out.Add('')
    $out
}

# ---------------------------------------------------------------------------------------------
# adb (read-only guard)
# ---------------------------------------------------------------------------------------------
$DenyPattern = '--reset|\b(pm\s+(uninstall|disable|disable-user|enable|clear|install|hide|suspend|grant|revoke)|cmd\s+package|settings\s+(put|delete)|rm|am\s+(force-stop|kill)|reboot|svc|wipe|setprop)\b'

function Invoke-AdbShell([string]$Command) {
    if ($Command -match $DenyPattern) { throw "Refusing to run a command that could change the phone: $Command" }
    $out = & adb -s $script:Serial shell $Command 2>&1 | ForEach-Object { "$_" }
    # Secondary users (work profile / Secure Folder) are not accessible to the shell; drop those noise lines
    $out | Where-Object { $_ -notmatch 'SecurityException: Shell does not have permission|handleIncomingUser' }
}

function Resolve-Serial {
    if (-not (Get-Command adb -ErrorAction SilentlyContinue)) { throw 'adb not found in PATH. Install Android platform-tools.' }
    $lines = & adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '\S' }
    $unauth = $lines | Where-Object { $_ -match '\tunauthorized' }
    $ok = $lines | Where-Object { $_ -match '\tdevice$' -and $_ -notmatch '^emulator-' } | ForEach-Object { ($_ -split '\t')[0] }
    if ($script:Serial) {
        if ($ok -notcontains $script:Serial) { throw "Device $script:Serial not in 'device' state. adb devices:`n$($lines -join "`n")" }
        return $script:Serial
    }
    if (-not $ok) {
        if ($unauth) { throw 'Phone is "unauthorized": unlock it and accept the "Allow USB debugging?" prompt, then retry.' }
        throw 'No phone found. Connect via USB with USB debugging enabled.'
    }
    if (@($ok).Count -gt 1) { Write-Warning "Several devices found, using $($ok[0]). Use -Serial to choose." }
    @($ok)[0]
}

# ---------------------------------------------------------------------------------------------
# 1. COLLECT
# ---------------------------------------------------------------------------------------------
function Invoke-Collect([string]$RawDir) {
    New-Item -ItemType Directory -Force $RawDir | Out-Null
    $jobs = [ordered]@{
        'props.txt'          = 'echo model=$(getprop ro.product.model); echo android=$(getprop ro.build.version.release); echo build=$(getprop ro.build.display.id); echo csc=$(getprop ro.csc.sales_code); echo sdk=$(getprop ro.build.version.sdk)'
        'uptime.txt'         = 'uptime'
        'battery.txt'        = 'dumpsys battery'
        'batterystats.txt'   = 'dumpsys batterystats'
        'bs_checkin.txt'     = 'dumpsys batterystats --checkin'
        'top.txt'            = "top -b -n 1 -m $Top"
        'services.txt'       = 'dumpsys activity services'
        'wifi.txt'           = "dumpsys wifi | grep -E -A8 'Multicast Locks held|Wlan Wake Reasons|Active lock owners'"
        'thermal.txt'        = 'dumpsys thermalservice'
        'users.txt'          = 'pm list users'
        'uids.txt'           = 'pm list packages -U --user 0'
        'pkgs_3rd.txt'       = 'pm list packages -3 --user 0'
        'pkgs_disabled.txt'  = 'pm list packages -d --user 0'
        'pkgs_sys_enabled.txt' = 'pm list packages -s -e --user 0'
        'settings.txt'       = 'for k in wifi_scan_always_enabled ble_scan_always_enabled mobile_data_always_on adaptive_battery_management_enabled low_power; do echo global.$k=$(settings get global $k); done; echo secure.location_mode=$(settings get secure location_mode)'
    }
    if ($Full) {
        $jobs['alarm.txt'] = 'dumpsys alarm'; $jobs['jobs.txt'] = 'dumpsys jobscheduler'
        $jobs['power.txt'] = 'dumpsys power'; $jobs['deviceidle.txt'] = 'dumpsys deviceidle'
        $jobs['usage.txt'] = 'dumpsys usagestats'
    }
    foreach ($k in $jobs.Keys) {
        Write-Host "  collecting $k" -ForegroundColor DarkGray
        $lines = Invoke-AdbShell $jobs[$k]
        [IO.File]::WriteAllLines((Join-Path $RawDir $k), [string[]]$lines)
    }
}

# ---------------------------------------------------------------------------------------------
# 2. ANALYZE
# ---------------------------------------------------------------------------------------------
function Read-PackageMap([string[]]$Lines) {
    $map = @{}
    foreach ($l in $Lines) {
        if ($l -match '^package:(\S+) uid:(\S+)') {
            foreach ($u in $Matches[2] -split ',') {
                $id = [int]$u
                if (-not $map.ContainsKey($id)) { $map[$id] = [Collections.Generic.List[string]]::new() }
                $map[$id].Add($Matches[1])
            }
        }
    }
    $map
}

function Get-UidLabel([string]$Uid, $PkgMap) {
    $app = Get-AppId $Uid; $user = Get-UserId $Uid
    $prefix = if ($user -gt 0) { "[user $user] " } else { '' }
    if ($null -eq $app) { return "$prefix$Uid" }
    if ($SystemUidNames.ContainsKey($app)) { return "$prefix$($SystemUidNames[$app])" }
    if ($PkgMap.ContainsKey($app)) {
        $p = $PkgMap[$app]
        $name = ($p | Select-Object -First 2) -join ', '
        if ($p.Count -gt 2) { $name += " (+$($p.Count - 2))" }
        return "$prefix$name"
    }
    "$prefix(uid $Uid, not in user 0)"
}

function Read-BatteryStats([string[]]$Lines) {
    $start = 0
    for ($i = 0; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -like 'Statistics since last charge:*') { $start = $i; break } }

    $s = [ordered]@{}
    $patterns = [ordered]@{
        TimeOnBattery = '^\s+Time on battery: (.+?) \('
        ScreenOffTime = '^\s+Time on battery screen off: (.+?) \('
        ScreenOnTime  = '^\s+Screen on: (.+?) \('
        DischargeMah  = '^\s+Discharge: ([\d.]+) mAh'
        ScreenOffMah  = '^\s+Screen off discharge: ([\d.]+) mAh'
        ScreenOnMah   = '^\s+Screen on discharge: ([\d.]+) mAh'
        PctScreenOn   = '^\s+Amount discharged while screen on: (\d+)'
        PctScreenOff  = '^\s+Amount discharged while screen off: (\d+)'
        WeakSignal    = '^\s+Weak signal time: (.+?)\s*$'
        MobileActive  = '^\s+Mobile active time: (.+?)\s*$'
        ConnChanges   = '^\s+Connectivity changes: (\d+)'
        PartialWlTotal = '^\s+Total partial wakelock time: (.+?)\s*$'
        MulticastTime = '^\s+Total WiFi Multicast wakelock time: (.+?)\s*$'
        CapacityMah   = '^\s+Capacity: (\d+),'
    }
    $power = [Collections.Generic.List[object]]::new()
    $kernel = [Collections.Generic.List[object]]::new()
    $partial = [Collections.Generic.List[object]]::new()
    $wakeups = [Collections.Generic.List[object]]::new()
    $procs = [Collections.Generic.List[object]]::new()
    $globalPower = [ordered]@{}
    $summaryDone = $false; $inEstimate = $false; $inGlobal = $false; $curUid = $null; $curProc = $null; $lastPower = $null

    for ($i = $start; $i -lt $Lines.Count; $i++) {
        $l = $Lines[$i]
        if (-not $summaryDone) {
            foreach ($k in $patterns.Keys) {
                if (-not $s.Contains($k) -and $l -match $patterns[$k]) { $s[$k] = $Matches[1] }
            }
            if ($s.Contains('CapacityMah')) { $summaryDone = $true }   # summary lines all precede "Capacity:"
        }
        if ($l -match '^\s+Estimated power use') { $inEstimate = $true; continue }
        if ($inEstimate -and $l -match '^    Global') { $inGlobal = $true; continue }
        if ($inGlobal -and $l -match '^      \(') { $inGlobal = $false }   # stop at the first "(on battery, ...)" sub-block
        if ($inGlobal -and $l -match '^    (\w+): ([\d.]+)') { $globalPower[$Matches[1]] = [double]$Matches[2] }

        if ($l -match '^  UID (\S+): ([\d.]+)(.*)$') {
            $inGlobal = $false
            $o = [ordered]@{ Uid = $Matches[1]; TotalMah = [double]$Matches[2] }
            foreach ($m in [regex]::Matches($Matches[3], '(fg|bg|fgs|cached): ([\d.]+)(?: \(([^)]+)\))?')) {
                $o["$($m.Groups[1].Value)Mah"] = [double]$m.Groups[2].Value
                $o["$($m.Groups[1].Value)Sec"] = ConvertTo-Seconds $m.Groups[3].Value
            }
            $lastPower = $o; $power.Add($o); continue
        }
        if ($lastPower -and $l -match '^      [a-z]' -and -not $lastPower.Contains('components')) {
            $lastPower['components'] = $true
            foreach ($m in [regex]::Matches($l, '(?:^|\s)(screen|cpu|audio|video|mobile_radio|wifi|wakelock|sensors|gnss|bluetooth|camera)=([\d.]+)')) {
                $lastPower[$m.Groups[1].Value] = [double]$m.Groups[2].Value
            }
            continue
        }
        if ($l -match '^  Kernel Wake lock (.+?): (.+?) \((\d+) times\)') {
            $kernel.Add([pscustomobject]@{ Name = $Matches[1]; Seconds = ConvertTo-Seconds $Matches[2]; Count = [int]$Matches[3] }); continue
        }
        if ($l -match '^  Wake lock (\S+) (.+?): (\d.*?) \((\d+) times\)') {
            $partial.Add([pscustomobject]@{ Uid = $Matches[1]; Name = $Matches[2]; Seconds = ConvertTo-Seconds $Matches[3]; Count = [int]$Matches[4] }); continue
        }
        if ($l -match '^  Wakeup reason (.+?): (\d.*?) \((\d+) times\)') {
            $wakeups.Add([pscustomobject]@{ Reason = $Matches[1]; Seconds = ConvertTo-Seconds $Matches[2]; Count = [int]$Matches[3] }); continue
        }
        if ($l -match '^  (\d+|u\d+[a-z]\d+):\s*$') { $curUid = $Matches[1]; continue }
        if ($curUid -and $l -match '^    Proc (.+):\s*$') { $curProc = $Matches[1]; continue }
        if ($curUid -and $curProc -and $l -match '^      CPU: (.+?) usr \+ (.+?) krn') {
            $procs.Add([pscustomobject]@{ Uid = $curUid; Process = $curProc; UserSec = ConvertTo-Seconds $Matches[1]; KernelSec = ConvertTo-Seconds $Matches[2]
                    CpuSec = (ConvertTo-Seconds $Matches[1]) + (ConvertTo-Seconds $Matches[2]) })
            $curProc = $null
        }
    }
    [pscustomobject]@{
        Summary = $s; GlobalPower = $globalPower
        Power = $power | ForEach-Object { [pscustomobject]$_ }
        Kernel = $kernel; Partial = $partial; Wakeups = $wakeups; Procs = $procs
    }
}

function Read-NetworkUsage([string[]]$Lines) {
    # checkin "nt" row: 9,<uid>,l,nt,mobileRx,mobileTx,wifiRx,wifiTx,...  (bytes)
    $acc = @{}
    foreach ($l in $Lines) {
        $f = $l -split ','
        if ($f.Count -gt 8 -and $f[3] -eq 'nt') {
            $u = $f[1]
            if (-not $acc.ContainsKey($u)) { $acc[$u] = @(0.0, 0.0) }
            $acc[$u][0] += [double]$f[4] + [double]$f[5]
            $acc[$u][1] += [double]$f[6] + [double]$f[7]
        }
    }
    foreach ($k in $acc.Keys) { [pscustomobject]@{ Uid = $k; MobileMB = [math]::Round($acc[$k][0] / 1MB, 1); WifiMB = [math]::Round($acc[$k][1] / 1MB, 1) } }
}

function Read-Services([string[]]$Lines) {
    $all = @{}; $fg = @{}; $cur = $null
    foreach ($l in $Lines) {
        if ($l -match 'ServiceRecord\{\S+ u(\d+) ([^/ ]+)') { $cur = "u$($Matches[1]) $($Matches[2])"; $all[$cur] = 1 + $all[$cur]; continue }
        if ($cur -and $l -match 'isForeground=true') { $fg[$cur] = 1 + $fg[$cur] }
    }
    $all.Keys | ForEach-Object { [pscustomobject]@{ App = $_; Services = $all[$_]; Foreground = [int]$fg[$_] } } | Sort-Object Services -Descending
}

function Read-KeyValues([string[]]$Lines) {
    $h = @{}; foreach ($l in $Lines) { if ($l -match '^([\w.]+)=(.*)$') { $h[$Matches[1]] = $Matches[2].Trim() } }; $h
}

# ---------------------------------------------------------------------------------------------
# 3. ADVICE
# ---------------------------------------------------------------------------------------------
function Get-Advice($D) {
    $adv = [Collections.Generic.List[object]]::new()
    function Add-Advice($Sev, $Area, $Finding, $Fix) { $adv.Add([pscustomobject]@{ Severity = $Sev; Area = $Area; Finding = $Finding; Suggestion = $Fix }) }

    if ($D.ScreenOffRate -ge 1.5) {
        Add-Advice 'HIGH' 'Idle drain' ("Screen-off drain {0:0.0}%/h (healthy is 0.5-1%/h)." -f $D.ScreenOffRate) 'Work through the Wi-Fi, profile and background-app items below.'
    } elseif ($D.ScreenOffRate -ge 1.0) {
        Add-Advice 'MEDIUM' 'Idle drain' ("Screen-off drain {0:0.0}%/h, slightly above normal." -f $D.ScreenOffRate) 'Check the background apps table.'
    }
    if ($D.WifiWakeups -ge 2000) {
        Add-Advice 'HIGH' 'Wi-Fi wakeups' "$($D.WifiWakeups) wakeups from the Wi-Fi chip (wlan/cnss), $($D.FailedSuspend) failed-suspend events." 'Network chatter (multicast/mDNS/IPv6 RA) is waking the phone. Turn off Location > Wi-Fi/Bluetooth scanning, set Quick Share to Contacts only, put Cast/smart-home apps to Deep sleeping, check router (IGMP snooping / multicast-to-unicast / IPv6 RA interval). Test one night on mobile data only.'
    }
    if ($D.MulticastHolders) {
        Add-Advice 'MEDIUM' 'Wi-Fi multicast' ("Multicast lock held by: " + (($D.MulticastHolders | ForEach-Object { "$($_.Tag) ($($_.Label))" }) -join '; ')) 'mDNS/device discovery keeps the Wi-Fi radio receiving all multicast. Identify the app doing discovery (Cast, Spotify Connect, SmartThings, Tuya, Miracast apps) and restrict it.'
    }
    if ($D.WlanWake -and $D.WlanWake.icmp6Ra -gt 50) {
        Add-Advice 'LOW' 'Router' "IPv6 Router Advertisements caused $($D.WlanWake.icmp6Ra) Wi-Fi wakeups." 'Increase the RA interval on the router, or test with IPv6 disabled.'
    }
    $weak = ConvertTo-Seconds "$($D.Stats.Summary.WeakSignal)"
    if ($weak -ge 3600) { Add-Advice 'MEDIUM' 'Cellular' "Weak signal for $(Format-Duration $weak)." 'Weak signal makes the modem work harder: use Wi-Fi Calling or LTE-only where coverage is bad.' }
    $cc = [int]("0" + $D.Stats.Summary.ConnChanges)
    if ($cc -ge 100) { Add-Advice 'MEDIUM' 'Connectivity' "$cc connectivity changes since last charge." 'Look at VPN auto-connect / Always-on VPN, Intelligent Wi-Fi "Switch to mobile data", flaky Wi-Fi.' }
    if ($D.ModemWakeCount -ge 10000) { Add-Advice 'MEDIUM' 'Modem' "$($D.ModemWakeCount) modem/IPC kernel wakelock events." 'Usually push traffic + weak signal. Reduce apps with constant push (see background table).' }

    $others = @($D.Users | Where-Object { $_.Id -ne 0 -and $_.Running })
    if ($others.Count -gt 0) {
        Add-Advice 'MEDIUM' 'User profiles' ("$($others.Count + 1) users running: " + (($D.Users | ForEach-Object { "$($_.Id)=$($_.Name)" }) -join ', ')) 'Each profile runs its own Google Play services and apps. Pause the work profile out of hours (schedulable in Digital Wellbeing); remove Dual Messenger / Secure Folder if unused.'
    }
    if ($D.SwapUsedMB -ge 2048 -or ($D.MemTotalMB -gt 0 -and $D.MemFreeMB / $D.MemTotalMB -lt 0.05)) {
        Add-Advice 'MEDIUM' 'Memory' ("RAM free {0} MB of {1} MB, swap used {2} MB." -f $D.MemFreeMB, $D.MemTotalMB, $D.SwapUsedMB) 'Constant swapping (kswapd) keeps the CPU awake. Uninstall unused apps; try RAM Plus off.'
    }
    if ($D.Load1 -ge 12) { Add-Advice 'LOW' 'CPU load' "Load average $($D.Load1) at collection time." 'Expected if the phone was just woken; repeat a few minutes after screen-off to compare.' }
    if ($D.ThirdPartyCount -ge 200) { Add-Advice 'MEDIUM' 'Apps' "$($D.ThirdPartyCount) user-installed apps." 'Uninstall apps you have not used in months; put the rest to Deep sleeping.' }

    foreach ($a in $D.CachedDrainers) {
        $sev = if ($a.IdleMah -ge 50) { 'HIGH' } else { 'MEDIUM' }
        Add-Advice $sev 'Background app' ("{0}: {1:0} mAh while not in use (cached/bg), radio {2:0} mAh." -f $a.App, $a.IdleMah, $a.Radio) 'If you do not need its notifications in real time: Battery > Background usage limits > Sleeping / Deep sleeping, or uninstall. For mail/chat apps reduce sync frequency or accounts instead.'
    }
    foreach ($a in $D.LongFgs) { Add-Advice 'LOW' 'Persistent service' ("{0}: foreground service running {1}." -f $a.App, $a.FgsTime) 'Fine if you need it; otherwise disable the feature or the app.' }

    if ($D.Settings['global.wifi_scan_always_enabled'] -eq '1') { Add-Advice 'LOW' 'Settings' 'Wi-Fi scanning (always) is ON.' 'Settings > Location > Location services > Wi-Fi scanning: off.' }
    if ($D.Settings['global.ble_scan_always_enabled'] -eq '1') { Add-Advice 'LOW' 'Settings' 'Bluetooth scanning (always) is ON.' 'Settings > Location > Location services > Bluetooth scanning: off.' }
    if ($D.Settings['global.adaptive_battery_management_enabled'] -eq '0') { Add-Advice 'MEDIUM' 'Settings' 'Adaptive battery is OFF.' 'Turn it on in Battery > More battery settings.' }
    if ($D.BloatEnabled) { Add-Advice 'LOW' 'Debloat' ("Safe-to-disable packages still enabled: " + ($D.BloatEnabled -join ', ')) 'See README "Debloat reference" - disable only with pm disable-user, in small batches.' }
    if ($D.HealthAsoc -and $D.HealthAsoc -lt 80) { Add-Advice 'HIGH' 'Battery health' "Battery capacity at $($D.HealthAsoc)%." 'Battery is worn; consider replacement.' }
    if ($D.TempC -ge 40) { Add-Advice 'MEDIUM' 'Temperature' "Battery at $($D.TempC) C." 'Heat accelerates wear and drain; check what is running.' }

    foreach ($sev in 'HIGH', 'MEDIUM', 'LOW') { $adv | Where-Object Severity -EQ $sev }   # stable order within a severity
}

# ---------------------------------------------------------------------------------------------
# Main analysis -> data object
# ---------------------------------------------------------------------------------------------
function Invoke-Analyze([string]$RawDir) {
    $props = Read-KeyValues (Read-Lines $RawDir 'props.txt')
    $settings = Read-KeyValues (Read-Lines $RawDir 'settings.txt')
    $pkgMap = Read-PackageMap (Read-Lines $RawDir 'uids.txt')
    $stats = Read-BatteryStats (Read-Lines $RawDir 'batterystats.txt')
    $battery = (Read-Lines $RawDir 'battery.txt') -join "`n"
    $topLines = Read-Lines $RawDir 'top.txt'
    $wifi = Read-Lines $RawDir 'wifi.txt'

    $D = [ordered]@{ Props = $props; Settings = $settings; Stats = $stats; TopLines = $topLines }

    # battery state
    if ($battery -match '(?m)^\s+level: (\d+)') { $D.Level = [int]$Matches[1] }
    if ($battery -match '(?m)^\s+temperature: (\d+)') { $D.TempC = [int]$Matches[1] / 10 }
    if ($battery -match 'mSavedBatteryAsoc: \[(\d+)\]') { $D.HealthAsoc = [int]$Matches[1] }
    if ($battery -match 'battery FirstUseDate: \[(\d+)\]') { $D.FirstUse = $Matches[1] }
    $D.Charging = $battery -match '(?m)^\s+(AC|USB|Wireless) powered: true'

    # drain rate
    $offH = (ConvertTo-Seconds "$($stats.Summary.ScreenOffTime)") / 3600
    $onH = (ConvertTo-Seconds "$($stats.Summary.ScreenOnTime)") / 3600
    $D.ScreenOffHours = [math]::Round($offH, 2); $D.ScreenOnHours = [math]::Round($onH, 2)
    $D.ScreenOffRate = if ($offH -gt 0.5) { [math]::Round([double]("0" + $stats.Summary.PctScreenOff) / $offH, 2) } else { 0 }
    $D.ScreenOnRate = if ($onH -gt 0.2) { [math]::Round([double]("0" + $stats.Summary.PctScreenOn) / $onH, 2) } else { 0 }

    # wakeups
    $D.WifiWakeups = ($stats.Wakeups | Where-Object Reason -Match 'wlan|cnss|wifi' | Measure-Object Count -Sum).Sum + 0
    $D.FailedSuspend = ($stats.Kernel | Where-Object Name -EQ 'SuspendControl.FailedSuspendDelay' | Measure-Object Count -Sum).Sum + 0
    $D.ModemWakeCount = ($stats.Kernel | Where-Object Name -Match 'umts_ipc|qcom_rx_wakelock|rmnet|radio-interface' | Measure-Object Count -Sum).Sum + 0

    # wifi multicast + wake reasons
    $D.MulticastHolders = @(foreach ($l in $wifi) {
            foreach ($m in [regex]::Matches($l, 'Multicaster\{(\S+) uid=(\d+)\}')) {
                [pscustomobject]@{ Tag = $m.Groups[1].Value; Uid = $m.Groups[2].Value; Label = Get-UidLabel $m.Groups[2].Value $pkgMap }
            }
        })
    $wl = $wifi | Where-Object { $_ -match 'Wlan Wake Reasons' } | Select-Object -First 1
    if ($wl) { $h = @{}; foreach ($m in [regex]::Matches($wl, '(\w+) (\d+)')) { $h[$m.Groups[1].Value] = [int]$m.Groups[2].Value }; $D.WlanWake = $h }

    # memory / load
    foreach ($l in $topLines) {
        if ($l -match 'Mem:\s+(\d+)K total,\s+(\d+)K used,\s+(\d+)K free') { $D.MemTotalMB = [int]($Matches[1] / 1024); $D.MemFreeMB = [int]($Matches[3] / 1024) }
        if ($l -match 'Swap:\s+(\d+)K total,\s+(\d+)K used') { $D.SwapUsedMB = [int]($Matches[2] / 1024) }
    }
    $up = (Read-Lines $RawDir 'uptime.txt') -join ' '
    if ($up -match 'load average: ([\d.]+)') { $D.Load1 = [double]$Matches[1] }
    if ($up -match 'up\s+(.+?),\s+\d+ users') { $D.Uptime = $Matches[1] }

    # users
    $D.Users = @(foreach ($l in (Read-Lines $RawDir 'users.txt')) {
            if ($l -match 'UserInfo\{(\d+):([^:]*):') { [pscustomobject]@{ Id = [int]$Matches[1]; Name = $Matches[2]; Running = $l -match 'running' } }
        })

    # packages
    $D.ThirdPartyCount = @(Read-Lines $RawDir 'pkgs_3rd.txt' | Where-Object { $_ -like 'package:*' }).Count
    $D.DisabledCount = @(Read-Lines $RawDir 'pkgs_disabled.txt' | Where-Object { $_ -like 'package:*' }).Count
    $sysEnabled = @(Read-Lines $RawDir 'pkgs_sys_enabled.txt' | ForEach-Object { $_ -replace '^package:', '' })
    $D.BloatEnabled = @($SafeToDisable | Where-Object { $sysEnabled -contains $_ })
    $D.OptionalEnabled = @($OptionalDisable | Where-Object { $sysEnabled -contains $_ })

    # per-app power, labelled
    $D.PowerRows = @($stats.Power | Sort-Object TotalMah -Descending | Select-Object -First $Top | ForEach-Object {
            [pscustomobject]@{
                App = Get-UidLabel $_.Uid $pkgMap; Uid = $_.Uid; 'Total mAh' = $_.TotalMah
                'Screen-on fg mAh' = $_.fgMah; 'Background mAh' = $_.bgMah; 'FG-service mAh' = $_.fgsMah; 'Cached mAh' = $_.cachedMah
                'CPU' = $_.cpu; 'Mobile radio' = $_.mobile_radio; 'Wakelock' = $_.wakelock
                'FGS time' = if ($_.fgsSec -ge 60) { Format-Duration $_.fgsSec } else { '' }
            }
        })
    # app UIDs (appId >= 10000) that are not core background components
    $isCandidate = { $id = Get-AppId $_.Uid; $id -ge 10000 -and -not ($pkgMap.ContainsKey($id) -and @($pkgMap[$id] | Where-Object { $ExpectedBackground -contains $_ }).Count) }
    # apps draining while not in use: bg + cached energy
    $D.CachedDrainers = @($stats.Power | Where-Object $isCandidate | ForEach-Object {
            [pscustomobject]@{ App = Get-UidLabel $_.Uid $pkgMap; IdleMah = [double]$_.bgMah + [double]$_.cachedMah; Radio = [double]$_.mobile_radio }
        } | Where-Object IdleMah -GE 25 | Sort-Object IdleMah -Descending)
    $D.LongFgs = @($stats.Power | Where-Object $isCandidate | Where-Object { $_.fgsSec -ge 6 * 3600 } | ForEach-Object {
            [pscustomobject]@{ App = Get-UidLabel $_.Uid $pkgMap; FgsTime = Format-Duration $_.fgsSec; FgsSec = $_.fgsSec }
        } | Sort-Object FgsSec -Descending)

    $D.KernelRows = @($stats.Kernel | Sort-Object Count -Descending | Select-Object -First $Top | ForEach-Object { [pscustomobject]@{ 'Kernel wakelock' = $_.Name; Times = $_.Count; Held = Format-Duration $_.Seconds; Sec = [math]::Round($_.Seconds, 1) } })
    $D.WakeupRows = @($stats.Wakeups | Sort-Object Count -Descending | Select-Object -First $Top | ForEach-Object { [pscustomobject]@{ 'Wakeup reason' = $_.Reason; Times = $_.Count; Duration = Format-Duration $_.Seconds; Sec = [math]::Round($_.Seconds, 1) } })
    $D.PartialRows = @($stats.Partial | Sort-Object Seconds -Descending | Select-Object -First $Top | ForEach-Object { [pscustomobject]@{ App = Get-UidLabel $_.Uid $pkgMap; Wakelock = ($_.Name -replace '/@eM_ADDR/.*', ''); Held = Format-Duration $_.Seconds; Times = $_.Count; Sec = [math]::Round($_.Seconds, 1) } })
    $D.ProcRows = @($stats.Procs | Sort-Object CpuSec -Descending | Select-Object -First $Top | ForEach-Object { [pscustomobject]@{ Process = $_.Process; Owner = Get-UidLabel $_.Uid $pkgMap; CPU = Format-Duration $_.CpuSec; CpuSec = [math]::Round($_.CpuSec, 1); 'Kernel share' = ('{0:0}%' -f (100 * $_.KernelSec / [math]::Max($_.CpuSec, 0.001))) } })
    $D.NetRows = @(Read-NetworkUsage (Read-Lines $RawDir 'bs_checkin.txt') | Sort-Object { $_.MobileMB + $_.WifiMB } -Descending | Select-Object -First $Top | ForEach-Object { [pscustomobject]@{ App = Get-UidLabel $_.Uid $pkgMap; 'Mobile MB' = $_.MobileMB; 'Wi-Fi MB' = $_.WifiMB } })
    $D.ServiceRows = @(Read-Services (Read-Lines $RawDir 'services.txt') | Select-Object -First $Top)
    $D.TopBgApp = ($D.CachedDrainers | Select-Object -First 1).App

    $D.Advice = Get-Advice ([pscustomobject]$D)
    [pscustomobject]$D
}

# ---------------------------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------------------------
function Write-Report($D, [string]$Path) {
    $s = $D.Stats.Summary
    $r = [Collections.Generic.List[string]]::new()
    $r.Add("# Phone diagnostics - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"); $r.Add('')
    $r.Add("**Device:** $($D.Props.model)  |  Android $($D.Props.android)  |  build $($D.Props.build)  |  CSC $($D.Props.csc)  |  uptime $($D.Uptime)"); $r.Add('')
    $r.Add('## Battery'); $r.Add('')
    $r.Add("- Level **$($D.Level)%**, temperature $($D.TempC) C, capacity health (ASOC) **$($D.HealthAsoc)%**, first use $($D.FirstUse), charging now: $($D.Charging)")
    $r.Add("- Since last charge: on battery $($s.TimeOnBattery); screen on $($D.ScreenOnHours) h, screen off $($D.ScreenOffHours) h")
    $r.Add("- Drain: total $($s.DischargeMah) mAh (screen on $($s.ScreenOnMah) mAh / screen off $($s.ScreenOffMah) mAh)")
    $r.Add("- **Screen-off drain rate: $($D.ScreenOffRate) %/h** (healthy: 0.5-1 %/h). Screen-on: $($D.ScreenOnRate) %/h")
    $r.Add("- Weak signal $($s.WeakSignal); connectivity changes $($s.ConnChanges); partial wakelocks total $($s.PartialWlTotal); Wi-Fi multicast lock total $($s.MulticastTime)")
    $r.Add("- Wi-Fi chip wakeups: **$($D.WifiWakeups)**, failed suspends: **$($D.FailedSuspend)**, modem wake events: $($D.ModemWakeCount)")
    $r.Add("- Memory: $($D.MemFreeMB) MB free of $($D.MemTotalMB) MB, swap used $($D.SwapUsedMB) MB, load avg $($D.Load1)")
    $r.Add("- Users: " + (($D.Users | ForEach-Object { "$($_.Id) ($($_.Name)$(if ($_.Running) { ', running' }))" }) -join '; '))
    $r.Add("- Apps: $($D.ThirdPartyCount) user-installed, $($D.DisabledCount) disabled"); $r.Add('')

    $r.Add('## Advice (most important first)'); $r.Add('')
    $r.AddRange([string[]](ConvertTo-MdTable $D.Advice @('Severity', 'Area', 'Finding', 'Suggestion')))

    $r.Add('## Where the energy went (global, mAh)'); $r.Add('')
    $r.Add(($D.Stats.GlobalPower.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '); $r.Add('')

    $r.Add("## Top $Top consumers per app (since last charge)"); $r.Add('')
    $r.Add('_fg = in use on screen; Background/Cached = while you were NOT using it; FG-service = persistent notification service._'); $r.Add('')
    $r.AddRange([string[]](ConvertTo-MdTable $D.PowerRows @('App', 'Total mAh', 'Screen-on fg mAh', 'Background mAh', 'FG-service mAh', 'Cached mAh', 'CPU', 'Mobile radio', 'Wakelock', 'FGS time')))

    $r.Add('## Wi-Fi multicast lock holders (right now)'); $r.Add('')
    $r.AddRange([string[]](ConvertTo-MdTable $D.MulticastHolders @('Tag', 'Uid', 'Label')))
    if ($D.WlanWake) { $r.Add('Wi-Fi wake reasons (current Wi-Fi session): ' + (($D.WlanWake.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', ')); $r.Add('') }

    $r.Add('## Wakeup reasons (what woke the CPU)'); $r.Add('')
    $r.AddRange([string[]](ConvertTo-MdTable $D.WakeupRows @('Wakeup reason', 'Times', 'Duration')))
    $r.Add('## Kernel wakelocks'); $r.Add('')
    $r.AddRange([string[]](ConvertTo-MdTable $D.KernelRows @('Kernel wakelock', 'Times', 'Held')))
    $r.Add('## App wakelocks (partial)'); $r.Add('')
    $r.AddRange([string[]](ConvertTo-MdTable $D.PartialRows @('App', 'Wakelock', 'Held', 'Times')))
    $r.Add('## Top processes by CPU time'); $r.Add('')
    $r.AddRange([string[]](ConvertTo-MdTable $D.ProcRows @('Process', 'Owner', 'CPU', 'Kernel share')))
    $r.Add('## Network data per app'); $r.Add('')
    $r.AddRange([string[]](ConvertTo-MdTable $D.NetRows @('App', 'Mobile MB', 'Wi-Fi MB')))
    $r.Add('## Running services (by count)'); $r.Add('')
    $r.AddRange([string[]](ConvertTo-MdTable $D.ServiceRows @('App', 'Services', 'Foreground')))

    $r.Add('## Debloat status'); $r.Add('')
    $r.Add("- Safe to disable, still enabled: $(if ($D.BloatEnabled) { $D.BloatEnabled -join ', ' } else { 'none' })")
    $r.Add("- Optional (only if you do not use the feature), enabled: $(if ($D.OptionalEnabled) { $D.OptionalEnabled -join ', ' } else { 'none' })")
    $r.Add("- Never touch: $($NeverTouch -join ', ')"); $r.Add('')

    $r.Add('## Live CPU snapshot (top)'); $r.Add(''); $r.Add('```'); $r.AddRange([string[]]$D.TopLines); $r.Add('```')
    [IO.File]::WriteAllLines($Path, [string[]]$r)
}

function Add-History($D, [string]$CsvPath) {
    [pscustomobject]@{
        Timestamp = Get-Date -Format 's'; Model = $D.Props.model; Build = $D.Props.build; Level = $D.Level; HealthAsoc = $D.HealthAsoc; TempC = $D.TempC
        OnBatteryH = [math]::Round((ConvertTo-Seconds "$($D.Stats.Summary.TimeOnBattery)") / 3600, 2); ScreenOffH = $D.ScreenOffHours
        ScreenOffPctPerHour = $D.ScreenOffRate; DischargeMah = $D.Stats.Summary.DischargeMah; WifiWakeups = $D.WifiWakeups; FailedSuspend = $D.FailedSuspend
        UsersRunning = @($D.Users | Where-Object Running).Count; SwapUsedMB = $D.SwapUsedMB; ThirdPartyApps = $D.ThirdPartyCount; TopBackgroundApp = $D.TopBgApp
    } | Export-Csv -Path $CsvPath -Append -NoTypeInformation -Encoding UTF8
}

# ---------------------------------------------------------------------------------------------
# Dashboard (summary.json per run + one self-contained dashboard.html)
# ---------------------------------------------------------------------------------------------
function Save-RunSummary($D, [string]$RunId, [string]$RawDir, [string]$Path) {
    $s = $D.Stats.Summary
    $bs = Join-Path $RawDir 'batterystats.txt'
    $captured = if (Test-Path $bs) { (Get-Item $bs).LastWriteTime } else { Get-Date }
    $summary = [ordered]@{
        id = $RunId; capturedAt = $captured.ToString('s'); device = $D.Props; settings = $D.Settings
        battery = [ordered]@{ level = $D.Level; tempC = $D.TempC; healthAsoc = $D.HealthAsoc; firstUse = $D.FirstUse; charging = [bool]$D.Charging }
        metrics = [ordered]@{
            screenOffRate = $D.ScreenOffRate; screenOnRate = $D.ScreenOnRate; screenOffHours = $D.ScreenOffHours; screenOnHours = $D.ScreenOnHours
            onBatteryHours = [math]::Round((ConvertTo-Seconds "$($s.TimeOnBattery)") / 3600, 2)
            dischargeMah = [double]("0" + $s.DischargeMah); screenOffMah = [double]("0" + $s.ScreenOffMah); screenOnMah = [double]("0" + $s.ScreenOnMah)
            wifiWakeups = $D.WifiWakeups; failedSuspend = $D.FailedSuspend; modemWakes = $D.ModemWakeCount; connChanges = [int]("0" + $s.ConnChanges)
            weakSignalHours = [math]::Round((ConvertTo-Seconds "$($s.WeakSignal)") / 3600, 2)
            multicastHours = [math]::Round((ConvertTo-Seconds "$($s.MulticastTime)") / 3600, 2)
            partialWakelockHours = [math]::Round((ConvertTo-Seconds "$($s.PartialWlTotal)") / 3600, 2)
            memTotalMB = $D.MemTotalMB; memFreeMB = $D.MemFreeMB; swapUsedMB = $D.SwapUsedMB; load1 = $D.Load1; uptime = $D.Uptime
            thirdPartyApps = $D.ThirdPartyCount; disabledPackages = $D.DisabledCount
        }
        globalPower = $D.Stats.GlobalPower; users = $D.Users; advice = @($D.Advice)
        apps = $D.PowerRows; kernel = $D.KernelRows; wakeups = $D.WakeupRows; partial = $D.PartialRows; procs = $D.ProcRows
        network = $D.NetRows; services = $D.ServiceRows; multicast = $D.MulticastHolders; wlanWake = $D.WlanWake
        bloat = [ordered]@{ safe = $D.BloatEnabled; optional = $D.OptionalEnabled; never = $NeverTouch }
        top = $D.TopLines
    }
    [IO.File]::WriteAllText($Path, ($summary | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}

function Write-Dashboard([string]$Root) {
    $template = Join-Path $PSScriptRoot 'dashboard.template.html'
    if (-not (Test-Path $template)) { Write-Warning "dashboard.template.html not found next to the script; dashboard skipped."; return $null }
    $runs = foreach ($dir in Get-ChildItem $Root -Directory -ErrorAction SilentlyContinue) {
        $json = Join-Path $dir.FullName 'summary.json'
        $raw = Join-Path $dir.FullName 'raw'
        if (-not (Test-Path $json) -and (Test-Path (Join-Path $raw 'batterystats.txt'))) {
            Write-Host "  backfilling summary for $($dir.Name)" -ForegroundColor DarkGray   # runs made before the dashboard existed
            Save-RunSummary (Invoke-Analyze $raw) $dir.Name $raw $json
        }
        if (Test-Path $json) { [IO.File]::ReadAllText($json) }
    }
    $csv = Join-Path $Root 'history.csv'
    $history = if (Test-Path $csv) { @(Import-Csv $csv) } else { @() }
    $data = '{"generated":' + (ConvertTo-Json (Get-Date -Format 's')) + ',"runs":[' + (@($runs) -join ',') + '],"history":[' + (($history | ForEach-Object { ConvertTo-Json $_ -Compress }) -join ',') + ']}'
    $data = $data -replace '</', '<\/'   # keep "</script>" inside data from closing the script tag
    $out = Join-Path $Root 'dashboard.html'
    [IO.File]::WriteAllText($out, ([IO.File]::ReadAllText($template).Replace('/*__DASHBOARD_DATA__*/null', $data)), [Text.UTF8Encoding]::new($false))
    $out
}

# ---------------------------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------------------------
function Invoke-SelfTest {
    $script:fail = 0
    function Assert($Cond, $Msg) { if ($Cond) { Write-Host "  ok   $Msg" -ForegroundColor Green } else { Write-Host "  FAIL $Msg" -ForegroundColor Red; $script:fail++ } }
    Assert ((ConvertTo-Seconds '1h 2m 3s 500ms') -eq 3723.5) 'ConvertTo-Seconds'
    Assert ((ConvertTo-Seconds '1d 0h 0m') -eq 86400) 'ConvertTo-Seconds days'
    Assert ((Get-AppId 'u10a336') -eq 10336) 'AppId u10a336'
    Assert ((Get-AppId '1010336') -eq 10336) 'AppId numeric secondary user'
    Assert ((Get-UserId 'u150a274') -eq 150) 'UserId u150a274'
    Assert ('pm uninstall -k --user 0 x' -match $DenyPattern) 'deny uninstall'
    Assert ('settings put global x 1' -match $DenyPattern) 'deny settings put'
    Assert ('dumpsys batterystats --reset' -match $DenyPattern) 'deny stats reset'
    Assert (-not ('dumpsys batterystats --checkin' -match $DenyPattern)) 'allow checkin'
    Assert (-not ('pm list packages -U --user 0' -match $DenyPattern)) 'allow pm list'
    $sample = @(
        'Statistics since last charge:',
        '  Time on battery: 18h 47m 25s 335ms (99,5%) realtime, 9h uptime',
        '  Time on battery screen off: 15h 41m 40s 421ms (83,5%) realtime',
        '    Amount discharged while screen off: 51',
        '  Estimated power use (mAh):',
        '  UID u0a801: 169 fg: 0.745 (46s 489ms) bg: 4.44 (5h 44m 49s 368ms) cached: 164 (1h 7m 38s 90ms)',
        '      screen=0.139 cpu=2.41 cpu:fg=0.366 mobile_radio=167 mobile_radio:fg=0.378',
        '  Kernel Wake lock qcom_rx_wakelock: 22m 9s 318ms (19219 times) realtime',
        '  Wakeup reason 43 s2idle_wakeup:481 wlan_pci_wake_irq: 1h 5m 15s 749ms (9895 times) realtime',
        '  Wake lock u0a296 AudioMix: 1h 34m 39s 127ms (0 times) max=3927371 realtime',
        '  1000:', '    Proc system:', '      CPU: 46m 45s 220ms usr + 49m 34s 510ms krn ; 0ms fg'
    )
    $st = Read-BatteryStats $sample
    $p = $st.Power | Select-Object -First 1
    Assert ($p.Uid -eq 'u0a801' -and $p.TotalMah -eq 169 -and $p.cachedMah -eq 164 -and $p.mobile_radio -eq 167 -and $p.cpu -eq 2.41) 'power line + components'
    Assert ($st.Kernel[0].Count -eq 19219) 'kernel wakelock'
    Assert ($st.Wakeups[0].Reason -like '*wlan_pci_wake_irq' -and $st.Wakeups[0].Count -eq 9895) 'wakeup reason'
    Assert ($st.Partial[0].Name -eq 'AudioMix') 'partial wakelock'
    Assert ([math]::Floor($st.Procs[0].CpuSec) -eq 5779) 'proc cpu'
    Assert ($st.Summary.PctScreenOff -eq '51') 'summary pct'
    if ($script:fail) { throw "$($script:fail) self-test(s) failed" }
    Write-Host 'All self-tests passed.' -ForegroundColor Green
}

# ---------------------------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------------------------
if ($SelfTest) { Invoke-SelfTest; return }

if ($DashboardOnly) {
    $dash = Write-Dashboard $OutputRoot
    if ($dash) { Write-Host "Dashboard: $dash" -ForegroundColor Green; if ($Open) { Start-Process $dash } }
    return
}

$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
if ($FromDir) {
    $rawDir = (Resolve-Path $FromDir).Path
    $runDir = Join-Path $OutputRoot "$stamp-reanalysis"
} else {
    $Serial = Resolve-Serial
    $runDir = Join-Path $OutputRoot $stamp
    $rawDir = Join-Path $runDir 'raw'
    Write-Host "Collecting read-only diagnostics from $Serial ..." -ForegroundColor Cyan
    Invoke-Collect $rawDir
}
New-Item -ItemType Directory -Force $runDir | Out-Null

Write-Host 'Analyzing ...' -ForegroundColor Cyan
$data = Invoke-Analyze $rawDir
$reportPath = Join-Path $runDir 'report.md'
Write-Report $data $reportPath
Save-RunSummary $data (Split-Path $runDir -Leaf) $rawDir (Join-Path $runDir 'summary.json')
if (-not $FromDir) { Add-History $data (Join-Path $OutputRoot 'history.csv') }   # a re-analysis is the same measurement; don't count it twice
$dash = Write-Dashboard $OutputRoot

Write-Host ''
Write-Host ("Screen-off drain: {0} %/h | Wi-Fi wakeups: {1} | users running: {2} | swap: {3} MB" -f $data.ScreenOffRate, $data.WifiWakeups, @($data.Users | Where-Object Running).Count, $data.SwapUsedMB) -ForegroundColor Yellow
$data.Advice | Format-Table Severity, Area, Finding -Wrap -AutoSize
Write-Host "Report:  $reportPath" -ForegroundColor Green
Write-Host "History: $(Join-Path $OutputRoot 'history.csv')" -ForegroundColor Green
if ($dash) { Write-Host "Dashboard: $dash" -ForegroundColor Green; if ($Open) { Start-Process $dash } }
