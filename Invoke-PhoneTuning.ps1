<#
.SYNOPSIS
    List background apps on an Android phone and (only after you confirm) restrict, stop, disable or
    re-enable them over adb. Every change is logged with its undo command.

.DESCRIPTION
    Uses catalog.json (shared with the Phone Tuner Android app) for recommendations:
      restrict  - apps that waste battery in the background on this phone
      keep      - apps that must stay unrestricted (messaging, MFA, watch, payments)
      debloat   - preinstalled packages: safe / optional / never touch
      tips      - settings fixes (some can be applied by command)

    What each action does on the phone (personal profile, user 0):
      Restrict   cmd appops set --user 0 <pkg> RUN_ANY_IN_BACKGROUND ignore   (= Android "Restricted" battery mode)
      Allow      cmd appops set --user 0 <pkg> RUN_ANY_IN_BACKGROUND allow
      ForceStop  am force-stop --user 0 <pkg>      (temporary: until you open the app or it gets a push)
      Disable    pm disable-user --user 0 <pkg>    (app disappears; data kept)
      Enable     pm enable --user 0 <pkg>
      KillBackground  am kill-all                  (kills cached background processes only; safe, temporary)

    Every change asks for confirmation (PowerShell ShouldProcess, ConfirmImpact High).
    Use -WhatIf to only print the commands. Use -Confirm:$false to skip the prompts.
    Changes are logged to reports\actions-log.csv; -Undo reverts them.

    adb cannot reach the work profile (user 10), Dual Apps (95) or Secure Folder (150): use the phone's settings for those.

.EXAMPLE
    .\Invoke-PhoneTuning.ps1                                   # status: running + recommended apps
.EXAMPLE
    .\Invoke-PhoneTuning.ps1 -All                              # status of every user-installed app
.EXAMPLE
    .\Invoke-PhoneTuning.ps1 -Recommended                      # guided: pick from recommendations, confirm once
.EXAMPLE
    .\Invoke-PhoneTuning.ps1 -Action Restrict -Package com.alibaba.aliexpresshd,dk.kanpla.unisonfm.twa
.EXAMPLE
    .\Invoke-PhoneTuning.ps1 -Action Disable -Package com.facebook.appmanager -WhatIf
.EXAMPLE
    .\Invoke-PhoneTuning.ps1 -KillBackground
.EXAMPLE
    .\Invoke-PhoneTuning.ps1 -Tips ; .\Invoke-PhoneTuning.ps1 -ApplyTip wifi-scan-off,ble-scan-off
.EXAMPLE
    .\Invoke-PhoneTuning.ps1 -ShowLog ; .\Invoke-PhoneTuning.ps1 -Undo -Last 3
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Status')]
param(
    [string]$Serial,
    [Parameter(ParameterSetName = 'Status')][switch]$All,
    [Parameter(ParameterSetName = 'Action', Mandatory)][ValidateSet('Restrict', 'Allow', 'ForceStop', 'Disable', 'Enable')][string]$Action,
    [Parameter(ParameterSetName = 'Action', Mandatory)][string[]]$Package,
    [Parameter(ParameterSetName = 'Kill', Mandatory)][switch]$KillBackground,
    [Parameter(ParameterSetName = 'Recommended', Mandatory)][switch]$Recommended,
    [Parameter(ParameterSetName = 'Tips', Mandatory)][switch]$Tips,
    [Parameter(ParameterSetName = 'ApplyTip', Mandatory)][string[]]$ApplyTip,
    [Parameter(ParameterSetName = 'Undo', Mandatory)][switch]$Undo,
    [Parameter(ParameterSetName = 'Undo')][int]$Last = 1,
    [Parameter(ParameterSetName = 'Log', Mandatory)][switch]$ShowLog,
    [Parameter(ParameterSetName = 'SelfTest', Mandatory)][switch]$SelfTest,
    [string]$CatalogPath = (Join-Path $PSScriptRoot 'catalog.json'),
    [string]$LogPath = (Join-Path $PSScriptRoot 'reports\actions-log.csv')
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$Ctx = $PSCmdlet

$Actions = @{
    Restrict  = @{ Do = 'cmd appops set --user 0 {0} RUN_ANY_IN_BACKGROUND ignore'; Undo = 'cmd appops set --user 0 {0} RUN_ANY_IN_BACKGROUND allow'; What = 'block background running' }
    Allow     = @{ Do = 'cmd appops set --user 0 {0} RUN_ANY_IN_BACKGROUND allow'; Undo = 'cmd appops set --user 0 {0} RUN_ANY_IN_BACKGROUND ignore'; What = 'allow background running' }
    ForceStop = @{ Do = 'am force-stop --user 0 {0}'; Undo = $null; What = 'force stop (temporary)' }
    Disable   = @{ Do = 'pm disable-user --user 0 {0}'; Undo = 'pm enable --user 0 {0}'; What = 'disable package' }
    Enable    = @{ Do = 'pm enable --user 0 {0}'; Undo = 'pm disable-user --user 0 {0}'; What = 'enable package' }
}
$BucketNames = @{ 5 = 'exempted'; 10 = 'active'; 20 = 'working set'; 30 = 'frequent'; 40 = 'rare'; 45 = 'restricted'; 50 = 'never' }
$PackagePattern = '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$'   # package names go into a shell command: validate strictly

# ---------------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------------
function Test-PackageName([string]$Name) { $Name -match $PackagePattern }

function ConvertFrom-Selection([string]$Text, [int]$Max) {
    # "1,3-5" -> 1,3,4,5 ; "all" -> 1..Max
    if ($Text -match '^\s*all\s*$') { return 1..$Max }
    $out = foreach ($part in $Text -split '[,\s]+' | Where-Object { $_ }) {
        if ($part -match '^(\d+)-(\d+)$') { [int]$Matches[1]..[int]$Matches[2] }
        elseif ($part -match '^\d+$') { [int]$part }
        else { throw "Invalid selection '$part'. Use numbers like 1,3-5 or 'all'." }
    }
    @($out | Where-Object { $_ -ge 1 -and $_ -le $Max } | Sort-Object -Unique)
}

function Get-Catalog {
    if (-not (Test-Path $CatalogPath)) { throw "catalog.json not found at $CatalogPath" }
    Get-Content $CatalogPath -Raw | ConvertFrom-Json
}

function Resolve-Serial {
    if (-not (Get-Command adb -ErrorAction SilentlyContinue)) { throw 'adb not found in PATH. Install Android platform-tools.' }
    $lines = & adb devices | Select-Object -Skip 1 | Where-Object { $_ -match '\S' }
    $ok = @($lines | Where-Object { $_ -match '\tdevice$' -and $_ -notmatch '^emulator-' } | ForEach-Object { ($_ -split '\t')[0] })
    if ($script:Serial) { if ($ok -notcontains $script:Serial) { throw "Device $script:Serial not connected/authorized." }; return $script:Serial }
    if (-not $ok) {
        if ($lines -match '\tunauthorized') { throw 'Phone is "unauthorized": unlock it and accept the USB debugging prompt.' }
        throw 'No phone found. Connect it by USB (or "adb connect <ip>:<port>" for wireless debugging).'
    }
    if ($ok.Count -gt 1) { Write-Warning "Several devices found, using $($ok[0]). Use -Serial to choose." }
    $ok[0]
}

function Invoke-Adb([string]$Command) {
    $out = & adb -s $script:Serial shell $Command 2>&1 | ForEach-Object { "$_" }
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($out | Where-Object { $_ -notmatch 'SecurityException: Shell does not have permission|handleIncomingUser' }) }
}

function Get-PhoneState {
    $pk = { param($cmd) @((Invoke-Adb $cmd).Output | Where-Object { $_ -like 'package:*' } | ForEach-Object { ($_ -replace '^package:', '') -replace '\s.*$', '' }) }
    $state = [ordered]@{
        All        = [Collections.Generic.HashSet[string]](& $pk 'pm list packages --user 0')
        ThirdParty = [Collections.Generic.HashSet[string]](& $pk 'pm list packages -3 --user 0')
        Disabled   = [Collections.Generic.HashSet[string]](& $pk 'pm list packages -d --user 0')
        Restricted = [Collections.Generic.HashSet[string]]@((Invoke-Adb 'cmd appops query-op --user 0 RUN_ANY_IN_BACKGROUND ignore').Output | Where-Object { Test-PackageName $_.Trim() } | ForEach-Object { $_.Trim() })
        Bucket     = @{}
        Running    = @{}
    }
    foreach ($l in (Invoke-Adb 'am get-standby-bucket').Output) { if ($l -match '^(\S+): (\d+)$') { $state.Bucket[$Matches[1]] = [int]$Matches[2] } }
    foreach ($l in (Invoke-Adb 'ps -A -o USER,RSS,NAME').Output | Select-Object -Skip 1) {
        $f = $l.Trim() -split '\s+'
        if ($f.Count -lt 3 -or $f[0] -notmatch '^u(\d+)_a') { continue }
        $user = [int]$Matches[1]; $pkg = ($f[2] -split ':')[0]
        if (-not $state.Running.ContainsKey($pkg)) { $state.Running[$pkg] = [pscustomobject]@{ Procs = 0; RamMB = 0.0; Users = [Collections.Generic.SortedSet[int]]::new() } }
        $r = $state.Running[$pkg]; $r.Procs++; $r.RamMB += [double]$f[1] / 1024; [void]$r.Users.Add($user)
    }
    [pscustomobject]$state
}

function Get-Advice($Pkg, $State, $Catalog) {
    $r = $Catalog.restrict | Where-Object pkg -EQ $Pkg
    if ($r) { return @('Restrict', $r.reason) }
    $k = $Catalog.keep | Where-Object pkg -EQ $Pkg
    if ($k) { return @('Keep', $k.reason) }
    foreach ($tier in 'safe', 'optional', 'never') {
        $d = $Catalog.debloat.$tier | Where-Object pkg -EQ $Pkg
        if ($d) { return @(@{ safe = 'Disable (safe)'; optional = 'Disable (optional)'; never = 'Never touch' }[$tier], "$($d.name). $($d.note)".Trim()) }
    }
    $b = $State.Bucket[$Pkg]
    if ($State.ThirdParty.Contains($Pkg) -and $b -ge 40 -and -not $State.Running.ContainsKey($Pkg)) { return @('Rarely used', 'Uninstall if you no longer need it.') }
    return @('', '')
}

function Write-Log([hashtable]$Row) {
    $dir = Split-Path $LogPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    [pscustomobject]$Row | Export-Csv $LogPath -Append -NoTypeInformation -Encoding UTF8
}

function Invoke-Change([string]$Label, [string]$Target, [string]$Command, [string]$UndoCommand, [string]$UndoOf = '') {
    if (-not $Ctx.ShouldProcess($Target, "$Label  ->  adb shell $Command")) { return $false }
    $r = Invoke-Adb $Command
    $text = ($r.Output -join ' ').Trim()
    $failed = $r.ExitCode -ne 0 -or $text -match 'Exception|Error|Failure|Unknown package|not found'
    $stamp = Get-Date -Format 's'
    Write-Log @{ Timestamp = $stamp; Action = $Label; Target = $Target; Command = $Command; Undo = $UndoCommand; Result = $(if ($failed) { 'FAILED' } else { 'OK' }); Output = $text.Substring(0, [math]::Min(300, $text.Length)); UndoOf = $UndoOf }
    if ($failed) { Write-Host "  FAILED  $Target : $text" -ForegroundColor Red } else { Write-Host "  OK      $Target $(if ($text) { ": $text" })" -ForegroundColor Green }
    -not $failed
}

function Invoke-PackageAction([string]$Name, [string[]]$Packages, $Catalog, $State) {
    $a = $Actions[$Name]
    foreach ($p in $Packages) {
        if (-not (Test-PackageName $p)) { Write-Warning "Skipping '$p': not a valid package name."; continue }
        if ($State -and -not $State.All.Contains($p)) { Write-Warning "Skipping $p : not installed for user 0."; continue }
        if ($Name -eq 'Disable' -and ($Catalog.debloat.never.pkg -contains $p)) { Write-Warning "Refusing to disable $p : on the never-touch list ($(($Catalog.debloat.never | Where-Object pkg -EQ $p).note))."; continue }
        if ($Name -in 'Restrict', 'ForceStop' -and ($Catalog.keep.pkg -contains $p)) { Write-Warning "$p is on the keep list: $(($Catalog.keep | Where-Object pkg -EQ $p).reason)" }
        $undo = if ($a.Undo) { $a.Undo -f $p } else { '' }
        [void](Invoke-Change "$Name ($($a.What))" $p ($a.Do -f $p) $undo)
    }
}

# ---------------------------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------------------------
function Show-Status($State, $Catalog) {
    $interesting = [Collections.Generic.HashSet[string]]::new()
    foreach ($p in $State.Running.Keys) { if ($State.ThirdParty.Contains($p) -or $State.All.Contains($p) -and ($Catalog.restrict.pkg + $Catalog.keep.pkg) -contains $p) { [void]$interesting.Add($p) } }
    foreach ($p in $Catalog.restrict.pkg + $Catalog.debloat.safe.pkg + $Catalog.debloat.optional.pkg) { if ($State.All.Contains($p)) { [void]$interesting.Add($p) } }
    if ($All) { foreach ($p in $State.ThirdParty) { [void]$interesting.Add($p) } }

    $rows = foreach ($p in $interesting) {
        $run = $State.Running[$p]; $adv = Get-Advice $p $State $Catalog
        $b = $State.Bucket[$p]
        [pscustomobject]@{
            Package    = $p
            Running    = if ($run) { "{0:0} MB / {1}p (u{2})" -f $run.RamMB, $run.Procs, ($run.Users -join ',u') } else { '' }
            RamMB      = if ($run) { $run.RamMB } else { 0 }
            Background = if ($State.Disabled.Contains($p)) { 'DISABLED' } elseif ($State.Restricted.Contains($p)) { 'restricted' } else { 'allowed' }
            Bucket     = if ($null -ne $b) { $BucketNames[$b] } else { '' }
            Advice     = $adv[0]
            Why        = $adv[1]
        }
    }
    $rows | Sort-Object @{ e = 'RamMB'; Descending = $true }, Package | Format-Table Package, Running, Background, Bucket, Advice, Why -AutoSize -Wrap

    $todoR = @($rows | Where-Object { $_.Advice -eq 'Restrict' -and $_.Background -eq 'allowed' })
    $todoD = @($rows | Where-Object { $_.Advice -eq 'Disable (safe)' -and $_.Background -ne 'DISABLED' })
    $ram = ($State.Running.Values | Measure-Object RamMB -Sum).Sum
    Write-Host ("Running app processes: {0} apps, {1:0} MB RAM. Already restricted: {2}. Disabled: {3}." -f $State.Running.Count, $ram, $State.Restricted.Count, $State.Disabled.Count) -ForegroundColor Cyan
    if ($todoR -or $todoD) { Write-Host "Recommended: restrict $($todoR.Count) app(s), disable $($todoD.Count) bloat package(s). Run: .\Invoke-PhoneTuning.ps1 -Recommended" -ForegroundColor Yellow }
}

function Get-TipStatus($Catalog) {
    foreach ($t in $Catalog.tips) {
        $current = if ($t.check) { ((Invoke-Adb $t.check).Output -join ' ').Trim() } else { $null }
        [pscustomobject]@{
            Id = $t.id; Title = $t.title
            Status = if (-not $t.command) { 'manual' } elseif ($current -eq $t.goodValue) { 'done' } else { "to do (now: $current)" }
            Detail = $t.detail; Tip = $t
        }
    }
}

function Start-Recommended($State, $Catalog) {
    $items = [Collections.Generic.List[object]]::new()
    foreach ($r in $Catalog.restrict) {
        if ($State.All.Contains($r.pkg) -and -not $State.Restricted.Contains($r.pkg) -and -not $State.Disabled.Contains($r.pkg)) {
            $items.Add([pscustomobject]@{ Kind = 'Restrict'; Target = $r.pkg; Why = $r.reason; Command = $Actions.Restrict.Do -f $r.pkg; Undo = $Actions.Restrict.Undo -f $r.pkg })
        }
    }
    foreach ($d in $Catalog.debloat.safe) {
        if ($State.All.Contains($d.pkg) -and -not $State.Disabled.Contains($d.pkg)) {
            $items.Add([pscustomobject]@{ Kind = 'Disable'; Target = $d.pkg; Why = "$($d.name). $($d.note)".Trim(); Command = $Actions.Disable.Do -f $d.pkg; Undo = $Actions.Disable.Undo -f $d.pkg })
        }
    }
    foreach ($t in Get-TipStatus $Catalog | Where-Object { $_.Status -like 'to do*' }) {
        $items.Add([pscustomobject]@{ Kind = 'Setting'; Target = $t.Id; Why = $t.Title; Command = $t.Tip.command; Undo = $t.Tip.undo })
    }
    if (-not $items.Count) { Write-Host 'Nothing left to recommend: all recommendations are applied.' -ForegroundColor Green; return }

    $i = 0
    $items | ForEach-Object { $i++; [pscustomobject]@{ '#' = $i; Kind = $_.Kind; Target = $_.Target; Why = $_.Why } } | Format-Table -AutoSize -Wrap
    $sel = Read-Host "Which ones? (e.g. 1,3-5 | all | Enter = cancel)"
    if (-not $sel.Trim()) { Write-Host 'Cancelled. Nothing changed.'; return }
    $chosen = @(ConvertFrom-Selection $sel $items.Count | ForEach-Object { $items[$_ - 1] })
    if (-not $chosen) { Write-Host 'Nothing selected.'; return }

    Write-Host "`nThese commands will run on the phone:" -ForegroundColor Cyan
    $chosen | ForEach-Object { Write-Host "  adb shell $($_.Command)" }
    if ($WhatIfPreference) { Write-Host '(WhatIf: nothing executed)'; return }
    if ((Read-Host "Run $($chosen.Count) command(s)? Type YES to confirm") -cne 'YES') { Write-Host 'Cancelled. Nothing changed.'; return }
    $script:ConfirmPreference = 'None'   # already confirmed as a batch
    foreach ($c in $chosen) { [void](Invoke-Change "$($c.Kind) (recommended)" $c.Target $c.Command $c.Undo) }
}

function Start-Undo {
    if (-not (Test-Path $LogPath)) { Write-Host 'No actions logged yet.'; return }
    $log = @(Import-Csv $LogPath)
    $undone = [Collections.Generic.HashSet[string]]@($log | Where-Object UndoOf | ForEach-Object UndoOf)
    $todo = @($log | Where-Object { $_.Result -eq 'OK' -and $_.Undo -and -not $_.UndoOf -and -not $undone.Contains("$($_.Timestamp)|$($_.Target)") } | Select-Object -Last $Last)
    if (-not $todo) { Write-Host 'Nothing to undo.'; return }
    [array]::Reverse($todo)
    foreach ($row in $todo) { [void](Invoke-Change "Undo: $($row.Action)" $row.Target $row.Undo $row.Command "$($row.Timestamp)|$($row.Target)") }
}

function Invoke-SelfTest {
    $fail = 0
    function Check($c, $m) { if ($c) { Write-Host "  ok   $m" -ForegroundColor Green } else { Write-Host "  FAIL $m" -ForegroundColor Red; $script:failCount++ } }
    $script:failCount = 0
    Check (Test-PackageName 'com.alibaba.aliexpresshd') 'valid package'
    Check (Test-PackageName 'com.Slack') 'valid package with capitals'
    Check (-not (Test-PackageName 'com.foo; reboot')) 'rejects shell injection'
    Check (-not (Test-PackageName 'com.foo$(id)')) 'rejects command substitution'
    Check (-not (Test-PackageName 'nodot')) 'rejects name without dot'
    Check ((ConvertFrom-Selection '1,3-5' 10) -join ',' -eq '1,3,4,5') 'selection ranges'
    Check ((ConvertFrom-Selection 'all' 3) -join ',' -eq '1,2,3') 'selection all'
    Check ((ConvertFrom-Selection '2,2,99' 5) -join ',' -eq '2') 'selection dedupe + bounds'
    $c = Get-Catalog
    Check ($c.restrict.Count -gt 0 -and $c.debloat.never.Count -gt 0) 'catalog loads'
    Check (@($c.restrict.pkg + $c.keep.pkg + $c.debloat.safe.pkg + $c.debloat.optional.pkg + $c.debloat.never.pkg | Where-Object { -not (Test-PackageName $_) }).Count -eq 0) 'catalog package names valid'
    Check (@($c.restrict.pkg | Where-Object { $c.keep.pkg -contains $_ }).Count -eq 0) 'no package both restrict and keep'
    if ($script:failCount) { throw "$($script:failCount) self-test(s) failed" }
    Write-Host 'All self-tests passed.' -ForegroundColor Green
}

# ---------------------------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------------------------
if ($SelfTest) { Invoke-SelfTest; return }
if ($ShowLog) { if (Test-Path $LogPath) { Import-Csv $LogPath | Format-Table Timestamp, Action, Target, Result, Undo -AutoSize -Wrap } else { 'No actions logged yet.' }; return }

$catalog = Get-Catalog
$Serial = Resolve-Serial

switch ($PSCmdlet.ParameterSetName) {
    'Status' { Write-Host "Reading app state from $Serial ..." -ForegroundColor Cyan; Show-Status (Get-PhoneState) $catalog }
    'Action' { Invoke-PackageAction $Action $Package $catalog (Get-PhoneState) }
    'Kill' { [void](Invoke-Change 'Kill cached background processes' 'all background apps' 'am kill-all' '') }
    'Recommended' { Start-Recommended (Get-PhoneState) $catalog }
    'Tips' { Get-TipStatus $catalog | Format-Table Id, Status, Title, Detail -AutoSize -Wrap }
    'ApplyTip' {
        foreach ($id in $ApplyTip) {
            $t = $catalog.tips | Where-Object id -EQ $id
            if (-not $t) { Write-Warning "Unknown tip '$id'. See -Tips."; continue }
            if (-not $t.command) { Write-Host "$($t.title): manual step - $($t.detail)" -ForegroundColor Yellow; continue }
            [void](Invoke-Change "Setting: $($t.title)" $t.id $t.command $t.undo)
        }
    }
    'Undo' { Start-Undo }
}
