param([string]$AppDir, [string]$DeploymentJson)
$ErrorActionPreference = 'Stop'
. (Join-Path $AppDir 'NightCityInstaller.ps1') -TestMode
$script:Root = $AppDir

$fail = 0; $pass = 0
function Check([string]$Name, [bool]$Cond, $Info) { if ($Cond) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $Name  $Info" -ForegroundColor Red } }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("ncl-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp | Out-Null
$script:DataDir = Join-Path $tmp 'data'

# ---- 1. ID parsing on every real Vortex source name + staging-style names
$dep = Get-Content $DeploymentJson -Raw | ConvertFrom-Json
$expect = @{ 'redscript'=1511; 'CET 1.38.1'=107; 'ArchiveXL'=4198; 'Codeware'=7780; 'Cyberware-EX'=9429; 'Expanded Dual'=35626; 'LootBeam'=36489; 'Mod Settings'=4885; 'Native Settings'=3518; 'RED4ext'=2380; 'RedData'=14139; 'RedFileSystem'=13378; 'RedHttpClient'=14192; 'RelentlessLive'=35703; 'TweakXL'=4197; 'Virtual Atelier'=2987; '2.5 ONLY - Enter Blackwall'=35785 }
foreach ($src in ($dep.files | % source | Sort-Object -Unique)) {
    $k = $expect.Keys | Where-Object { $src.StartsWith($_) } | Select-Object -First 1
    Check "parse '$src'" ((Get-NexusIdFromName $src) -eq $expect[$k]) "got $(Get-NexusIdFromName $src) want $($expect[$k])"
}
foreach ($pair in @(@('Input Loader-4575-0-2-5-1761400000', 4575), @('Let There Be Flight-5208-0-3-20-1761480000', 5208), @('Mod Settings v0.2.28 for 2.50-4885-0-2-28-1761700000', 4885), @('LootBeam 1.2.1-36489-1-2-1-1762180000', 36489), @('Some Mod Without Id', $null))) {
    Check "parse staging '$($pair[0])'" ((Get-NexusIdFromName $pair[0]) -eq $pair[1]) "got $(Get-NexusIdFromName $pair[0])"
}

# ---- 2. Installed detection from a fake game folder that uses the real deployment file
$game = Join-Path $tmp 'game'; $staging = Join-Path $tmp 'staging'
New-Item -ItemType Directory (Join-Path $game 'bin/x64') -Force | Out-Null
New-Item -ItemType Directory $staging | Out-Null
'' | Set-Content (Join-Path $game 'bin/x64/Cyberpunk2077.exe')
$dep.stagingPath = $staging
$dep | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $game 'vortex.deployment.json')
$ids = Get-InstalledNexusIds $game
Check 'installed contains ArchiveXL' ($ids.Contains(4198))
Check 'installed count' ($ids.Count -eq 17) "count $($ids.Count)"
New-Item -ItemType Directory (Join-Path $staging 'Input Loader-4575-0-2-5-1761400000') | Out-Null
Check 'staging folder detected' ((Get-InstalledNexusIds $game).Contains(4575))
$cfgPre = @{ gameDir = $game; nexusKey=''; modioToken=''; modioGameId=0; pauseBetweenBatches=$false }
$w = Get-PreflightWarnings $cfgPre
Check 'preflight clean with real frameworks' ($w.Count -eq 0) ($w -join ' | ')
Remove-Item (Join-Path $staging 'Input Loader-4575-0-2-5-1761400000')

# ---- 3. Nexus file selection
$patch = [datetime]'2026-10-22'
function U([string]$d) { [long]([datetimeoffset][datetime]::Parse($d + 'T12:00:00Z')).ToUnixTimeSeconds() }
$files = [pscustomobject]@{ files = @(
    [pscustomobject]@{ file_id=1; version='0.3.18'; category_name='OLD_VERSION'; is_primary=$false; uploaded_timestamp=(U '2026-09-13') },
    [pscustomobject]@{ file_id=2; version='0.3.19'; category_name='MAIN'; is_primary=$false; uploaded_timestamp=(U '2026-10-25') },
    [pscustomobject]@{ file_id=3; version='0.3.20'; category_name='MAIN'; is_primary=$true;  uploaded_timestamp=(U '2026-10-26') },
    [pscustomobject]@{ file_id=4; version='beta';   category_name='MAIN'; is_primary=$false; uploaded_timestamp=(U '2026-10-30') }) }
$s = Select-NexusMainFile $files $patch
Check 'prefers primary post-patch' ($s.file.file_id -eq 3 -and $s.postPatch)
$files2 = [pscustomobject]@{ files = @([pscustomobject]@{ file_id=9; version='1.0'; category_name='MAIN'; is_primary=$true; uploaded_timestamp=(U '2026-03-01') }) }
$s2 = Select-NexusMainFile $files2 $patch
Check 'flags pre-patch' ($s2.file.file_id -eq 9 -and -not $s2.postPatch)
$files3 = [pscustomobject]@{ files = @(
    [pscustomobject]@{ file_id=5; version='2.0'; category_name='MAIN'; is_primary=$true;  uploaded_timestamp=(U '2026-06-01') },
    [pscustomobject]@{ file_id=6; version='2.1'; category_name='MAIN'; is_primary=$false; uploaded_timestamp=(U '2026-10-24') }) }
Check 'falls back to newest post-patch when primary is old' ((Select-NexusMainFile $files3 $patch).file.file_id -eq 6)
Check 'no files -> null' ($null -eq (Select-NexusMainFile ([pscustomobject]@{ files = @() }) $patch))
Check 'download url' ((Get-NexusDownloadUrl 'cyberpunk2077' 5208 3) -eq 'https://www.nexusmods.com/cyberpunk2077/mods/5208?tab=files&file_id=3&nmm=1')

# ---- 4. mod.io matching
function MM($id, $name, $dl) { [pscustomobject]@{ id=$id; name=$name; stats=[pscustomobject]@{ downloads_total=$dl }; submitted_by=[pscustomobject]@{ username='x' } } }
$r = @((MM 1 'Immersive Rippers' 10), (MM 2 'Immersive Rippers - Dogtown' 5))
Check 'exact beats longer name' ((Select-ModioMatch $r 'Immersive Rippers' '').match.id -eq 1)
Check 'dogtown query' ((Select-ModioMatch $r 'Immersive Rippers Dogtown' '').match.id -eq 2)
$r = @((MM 3 'Challenging Breach Minigame' 1), (MM 4 'Challenging Breach Minigame - 0.5x Time' 1))
Check 'exclude variant' ((Select-ModioMatch $r 'Challenging Breach Minigame' '0.5x').match.id -eq 3)
$r = @((MM 5 'New Quest - Encore [DQC]' 1), (MM 6 'Encore Outfit Pack' 1))
Check 'strips prefix and tag' ((Select-ModioMatch $r 'Encore' '').match.id -eq 5)
$r = @((MM 7 "QoL - Interactive Judy's Apartment Devices" 1))
Check 'apostrophe + QoL prefix' ((Select-ModioMatch $r "Interactive Judy's Apartment Devices" '').match.id -eq 7)
$r = @((MM 8 'HoV - Actually Platinum Blond Hair' 50), (MM 9 'HoV - Actually Platinum Blond Hair v2' 90))
$sel = Select-ModioMatch $r 'Actually Platinum Blond' ''
Check 'ambiguous gives choices' ($null -eq $sel.match -and $sel.choices.Count -eq 2)
Check 'most popular picked' ((Select-MostPopular $sel.choices).id -eq 9)
Check 'no match' ($null -eq (Select-ModioMatch @((MM 10 'Something Else' 1)) 'Hot Fuzz' '').match)

# ---- 5. Engine end to end with mocked APIs
$script:Subscribed = New-Object 'System.Collections.Generic.List[int]'
$script:Catalog = @(
    (MM 101 'Deceptious Quest Core' 900), (MM 102 'Deceptious Bug Fixes [DQC]' 500),
    (MM 103 'New Quest - One More Light [DQC]' 400), (MM 104 'Borg Malorian Restored' 300),
    (MM 105 'HoV - Actually Platinum Blond Hair' 10), (MM 106 'HoV - Actually Platinum Blond Hair 2' 20))
function Invoke-RestMethod {
    param($Method = 'Get', $Uri, $Headers, $ContentType, $Body, $TimeoutSec)
    $u = [string]$Uri
    if ($u -like 'https://api.nexusmods.com/v1/games/cyberpunk2077/mods/*/files.json') {
        $id = [int]($u -replace '.*/mods/(\d+)/files.json', '$1')
        if ($id -eq 3543) { return [pscustomobject]@{ files = @([pscustomobject]@{ file_id = 777; version='1.4'; category_name='MAIN'; is_primary=$true; uploaded_timestamp=(U '2026-05-01') }) } }
        return [pscustomobject]@{ files = @([pscustomobject]@{ file_id = $id * 10; version='9.9'; category_name='MAIN'; is_primary=$true; uploaded_timestamp=(U '2026-10-25') }) }
    }
    if ($u -like 'https://api.mod.io/v1/games?name_id=*') { return [pscustomobject]@{ data = @([pscustomobject]@{ id = 5555; name = 'Cyberpunk 2077' }) } }
    if ($u -eq 'https://api.mod.io/v1/me') { return [pscustomobject]@{ username = 'tester' } }
    if ($u -like 'https://api.mod.io/v1/me/subscribed*') { return [pscustomobject]@{ data = @([pscustomobject]@{ id = 104 }) } }
    if ($u -match 'games/5555/mods\?_q=([^&]+)') {
        $q = [Uri]::UnescapeDataString($Matches[1])
        return [pscustomobject]@{ data = @($script:Catalog | Where-Object { (Normalize-Name $_.name).Contains((Normalize-Name $q)) }) }
    }
    if ($u -match 'games/5555/mods/(\d+)/dependencies') {
        if ($Matches[1] -eq '103') { return [pscustomobject]@{ data = @([pscustomobject]@{ mod_id = 101; name = 'Deceptious Quest Core' }) } }
        return [pscustomobject]@{ data = @() }
    }
    if ($Method -eq 'Post' -and $u -match 'games/5555/mods/(\d+)/subscribe') { $script:Subscribed.Add([int]$Matches[1]); return [pscustomobject]@{ id = [int]$Matches[1] } }
    throw "Unmocked call: $Method $u"
}

$opened = New-Object System.Collections.ArrayList
$banners = New-Object System.Collections.ArrayList
$ui = [pscustomobject]@{}
$ui | Add-Member ScriptMethod Log { param($m) }
$ui | Add-Member ScriptMethod SetStatus { param($k, $s, $d) }
$ui | Add-Member ScriptMethod Banner { param($t, $b) [void]$banners.Add($t) }
$ui | Add-Member ScriptMethod OpenUrl { param($u) [void]$opened.Add($u) }

$manifest = Load-Manifest (Join-Path $AppDir 'manifest.json')
Check 'manifest item count' ($manifest.items.Count -eq 113) "count $($manifest.items.Count)"
Check 'manifest unique keys' (@($manifest.items | % key | Sort-Object -Unique).Count -eq $manifest.items.Count)
Check 'every nexus item has an id' (@($manifest.items | ? { $_.source -eq 'nexus' -and -not $_.id }).Count -eq 0)
Check 'every batch defined' (@($manifest.items | ? { -not $manifest.batches.ContainsKey($_.batch) }).Count -eq 0)

$cfg = @{ gameDir = $game; nexusKey = 'KEY'; modioToken = 'TOK'; modioGameId = 0; pauseBetweenBatches = $false }
$state = @{}
$E = New-Engine $manifest $cfg $state $ui
New-Item -ItemType Directory (Join-Path $staging 'Stealthrunner-7616-1-11-2-1761400000') | Out-Null
$keys = @('nexus:4575', 'nexus:7616', 'nexus:3543', 'nexus:5208', 'modio:Deceptious Quest Core', 'modio:One More Light', 'modio:Borg Malorian Restored', 'modio:Actually Platinum Blond', 'modio:Hot Fuzz')
Start-Engine $E $keys
$guard = 0
while ($E.mode -ne 'done' -and $guard -lt 200) {
    $guard++
    Step-Engine $E
    if ($E.mode -eq 'waitNexus') {
        # simulate the user's click + Vortex install after the page opened
        $id = $E.current.id
        New-Item -ItemType Directory (Join-Path $staging "Mod-$id-1-0-1761500000") -Force | Out-Null
    }
}
Check 'engine finished' ($E.mode -eq 'done') "mode $($E.mode)"
Check 'nexus pages opened in order (skips installed Stealthrunner and pre-patch Zoomable Scopes)' (($opened -join ',') -eq 'https://www.nexusmods.com/cyberpunk2077/mods/4575?tab=files&file_id=45750&nmm=1,https://www.nexusmods.com/cyberpunk2077/mods/5208?tab=files&file_id=52080&nmm=1') ($opened -join ',')
Check 'Stealthrunner already (found in Vortex staging)' ($state['nexus:7616'].status -eq 'Already installed')
Check 'Zoomable pre-patch waits for a 2.5 file (not done)' ($state['nexus:3543'].status -eq 'Waiting for 2.5 update' -and -not $state['nexus:3543'].done)
Check 'Input Loader installed' ($state['nexus:4575'].status -eq 'Installed')
Check 'Borg already subscribed' ($state['modio:Borg Malorian Restored'].status -eq 'Already subscribed')
Check 'Hot Fuzz not found' ($state['modio:Hot Fuzz'].status -eq 'Not found')
Check 'subscriptions in order, dep not duplicated, popular HoV' (($script:Subscribed -join ',') -eq '101,103,106') ($script:Subscribed -join ',')
Check 'no checkpoint pauses by default' (-not ($banners | ? { $_ -like 'Batch done*' }))
Check 'counts' ($E.counts.installed -eq 2 -and $E.counts.subscribed -eq 3 -and $E.counts.already -eq 2 -and $E.counts.skipped -eq 1 -and $E.counts.failed -eq 1) ($E.counts | ConvertTo-Json -Compress)
Check 'state persisted' ((Load-State).Count -eq 9)

# resume: second run only queues what isn't done
$E2 = New-Engine $manifest $cfg (Load-State) $ui
Start-Engine $E2 $keys
Check 'resume re-queues unfinished (Zoomable waiting + Hot Fuzz)' (($E2.queue | % key) -join ',' -eq 'modio:Hot Fuzz,nexus:3543') (($E2.queue | % key) -join ',')

# checkpoints when enabled
Remove-Item (Join-Path $script:DataDir 'state.json')
Get-ChildItem $staging | Remove-Item -Recurse
$script:Subscribed.Clear(); $opened.Clear(); $banners.Clear()
$cfg.pauseBetweenBatches = $true
$E3 = New-Engine $manifest $cfg @{} $ui
Start-Engine $E3 @('nexus:4575', 'nexus:5208', 'modio:Deceptious Quest Core')
$cp = 0; $guard = 0
while ($E3.mode -ne 'done' -and $guard -lt 200) {
    $guard++
    Step-Engine $E3
    if ($E3.mode -eq 'waitNexus') { New-Item -ItemType Directory (Join-Path $staging "Mod-$($E3.current.id)-1-0-1761500000") -Force | Out-Null }
    if ($E3.mode -eq 'checkpoint') { $cp++; Invoke-EngineAction $E3 'Continue' }
}
Check 'two checkpoints (after batch 1 and 4)' ($cp -eq 2) "cp $cp"

# manual actions while waiting
$E4 = New-Engine $manifest $cfg @{} $ui
Start-Engine $E4 @('nexus:7238')
Step-Engine $E4
Check 'waiting' ($E4.mode -eq 'waitNexus')
Invoke-EngineAction $E4 'Skip'
Step-Engine $E4
Check 'skip finishes' ($E4.mode -eq 'done' -and $E4.counts.skipped -eq 1)

# no Nexus key: opens the plain files tab, no file check
$cfg5 = @{ gameDir = $game; nexusKey = ''; modioToken = ''; modioGameId = 0; pauseBetweenBatches = $false }
$opened.Clear()
$E5 = New-Engine $manifest $cfg5 @{} $ui
Start-Engine $E5 @('nexus:17642', 'modio:Encore')
Step-Engine $E5
Check 'no token -> mod.io item held, not done' ($E5.state['modio:Encore'].status -eq 'Needs mod.io token' -and -not $E5.state['modio:Encore'].done)
Step-Engine $E5
Check 'no token does not block Nexus; no key -> files tab' ($opened[0] -eq 'https://www.nexusmods.com/cyberpunk2077/mods/17642?tab=files')

# verify-tier mod without a Nexus key is held back, not installed blind
$opened.Clear()
$E6 = New-Engine $manifest $cfg5 @{} $ui
Start-Engine $E6 @('nexus:36374')
Step-Engine $E6
Check 'verify mod needs key' ($E6.state['nexus:36374'].status -eq 'Needs Nexus key' -and $opened.Count -eq 0 -and -not $E6.state['nexus:36374'].done)

# install snapshot: Vortex + mod.io subscriptions
New-Item -ItemType Directory (Join-Path $staging 'Input Loader-4575-0-2-5-1761400000') -Force | Out-Null
$subs = @((MM 101 'Deceptious Quest Core' 1), (MM 104 'Borg Malorian Restored' 1), (MM 4 'Challenging Breach Minigame - 0.5x Time' 1))
$snap = Get-InstallSnapshot $manifest $game $subs
Check 'snapshot nexus installed' ($snap['nexus:4575'].installed -and $snap['nexus:4575'].detail -match '^v.+ in Vortex$') ("$($snap['nexus:4575'] | ConvertTo-Json -Compress) | staging: $((Get-ChildItem $staging | % Name) -join ';')") $snap['nexus:4575'].detail
Check 'snapshot nexus missing' (-not $snap['nexus:7238'].installed)
Check 'snapshot modio subscribed' ($snap['modio:Deceptious Quest Core'].installed -and $snap['modio:Borg Malorian Restored'].installed)
Check 'snapshot modio excluded variant not counted' (-not $snap['modio:Challenging Breach Minigame'].installed)
Check 'snapshot modio unsubscribed' (-not $snap['modio:Hot Fuzz'].installed)
$snap2 = Get-InstallSnapshot $manifest $game $null
Check 'snapshot without token leaves mod.io unknown' (-not $snap2.ContainsKey('modio:Hot Fuzz') -and $snap2.ContainsKey('nexus:4575'))
Check 'manifest: verify flags loaded' (@($manifest.items | ? verify).Count -gt 20)
Check 'manifest: adult batch optional' (@($manifest.items | ? { $_.batch -eq 25 -and -not $_.optional }).Count -eq 0)

Remove-Item $tmp -Recurse -Force

Write-Host "install tests: passed $pass, failed $fail"

# ================= updater tests =================
$fail2 = 0
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("ncl-upd-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp | Out-Null
$script:DataDir = Join-Path $tmp 'data'
$game = Join-Path $tmp 'game'; $staging = Join-Path $tmp 'staging'
New-Item -ItemType Directory (Join-Path $game 'bin/x64') -Force | Out-Null
New-Item -ItemType Directory $staging | Out-Null
'' | Set-Content (Join-Path $game 'bin/x64/Cyberpunk2077.exe')
$dep = Get-Content $DeploymentJson -Raw | ConvertFrom-Json
$dep.stagingPath = $staging
$dep | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $game 'vortex.deployment.json')

# installed mods with versions + timestamps from the real deployment file
$mods = Get-InstalledNexusMods $game
Check 'installed mods count' ($mods.Count -eq 17) $mods.Count
Check 'ArchiveXL version' ($mods[4198].version -eq '1.28.6') $mods[4198].version
$axlTs = [long]([datetimeoffset][datetime]::Parse('2026-10-29T12:59:00Z')).ToUnixTimeSeconds()
Check 'ArchiveXL timestamp' ($mods[4198].ts -eq $axlTs) "$($mods[4198].ts) vs $axlTs"
Check 'CET name/version' ($mods[107].version -eq '1.38.1') $mods[107].version
Check 'LootBeam id' ($mods.ContainsKey(36489))
# staging folder with a newer file wins
New-Item -ItemType Directory (Join-Path $staging ('ArchiveXL-4198-1-29-0-' + ($axlTs + 86400))) | Out-Null
$mods = Get-InstalledNexusMods $game
Check 'staging newer version wins' ($mods[4198].version -eq '1.29.0' -and $mods[4198].family -eq 'ArchiveXL') "$($mods[4198].version) $($mods[4198].family)"
Remove-Item (Join-Path $staging ('ArchiveXL-4198-1-29-0-' + ($axlTs + 86400)))

# update detection
$inst = [pscustomobject]@{ id = 4198; name = 'ArchiveXL'; version = '1.28.6'; ts = $axlTs; family = '' }
$f = [pscustomobject]@{ files = @(
    [pscustomobject]@{ file_id = 1; version = '1.28.6'; category_name = 'MAIN'; uploaded_timestamp = $axlTs; file_name = 'ArchiveXL-4198-1-28-6-x.zip' },
    [pscustomobject]@{ file_id = 2; version = '1.29.0'; category_name = 'MAIN'; uploaded_timestamp = $axlTs + 5000; file_name = 'ArchiveXL-4198-1-29-0-x.zip' }) }
$u = Get-NexusModUpdate $f $inst
Check 'update found' ($u.newer -and $u.file.file_id -eq 2)
$f2 = [pscustomobject]@{ files = @([pscustomobject]@{ file_id = 1; version = '1.28.6'; category_name = 'MAIN'; uploaded_timestamp = $axlTs + 30; file_name = 'ArchiveXL-4198-1-28-6-x.zip' }) }
Check 'same file not an update' (-not (Get-NexusModUpdate $f2 $inst).newer)
$f3 = [pscustomobject]@{ files = @([pscustomobject]@{ file_id = 3; version = 'v1.28.6'; category_name = 'MAIN'; uploaded_timestamp = $axlTs + 9000; file_name = 'x' }) }
Check 'reupload of same version not an update' (-not (Get-NexusModUpdate $f3 $inst).newer)
$instFam = [pscustomobject]@{ id = 5208; name = 'LTBF'; version = '0.3.20'; ts = 1000; family = 'Let There Be Flight' }
$f4 = [pscustomobject]@{ files = @(
    [pscustomobject]@{ file_id = 7; version = '0.3.20'; category_name = 'MAIN'; uploaded_timestamp = 1000; file_name = 'Let There Be Flight-5208-0-3-20-1000.zip' },
    [pscustomobject]@{ file_id = 8; version = '0.4.0-mac'; category_name = 'MAIN'; uploaded_timestamp = 9000; file_name = 'LTBF macOS-5208-0-4-0-9000.zip' }) }
Check 'other variant ignored' (-not (Get-NexusModUpdate $f4 $instFam).newer)
Check 'frameworks sort first' ((@(@{i=5646;n='Wannabe'}, @{i=107;n='CET'}, @{i=2380;n='RED4ext'}) | Sort-Object { Get-UpdateSortKey $_.i $_.n } | % i) -join ',' -eq '2380,107,5646')

# game version from RED4ext log
New-Item -ItemType Directory (Join-Path $game 'red4ext/logs') -Force | Out-Null
"[2026-11-03] [RED4ext] Product version: 2.50`n" | Set-Content (Join-Path $game 'red4ext/logs/red4ext-2026-11-03-21-19-53.log')
$script:SavedIsWin = $script:IsWin
Check 'game version' ((Get-GameVersion ($game -replace '/', '/')) -eq '2.50') (Get-GameVersion $game)

# update checker with mocks (Nexus files + mod.io subscriptions)
$script:Mo = 1
function Invoke-RestMethod {
    param($Method = 'Get', $Uri, $Headers, $ContentType, $Body, $TimeoutSec)
    $u = [string]$Uri
    if ($u -match 'nexusmods.com/v1/games/cyberpunk2077/mods/(\d+)/files.json') {
        $id = [int]$Matches[1]
        if ($id -eq 4198) { return $f }
        if ($id -eq 35785) { $e = New-Object System.Net.WebException('The remote server returned an error: (404) Not Found.'); throw $e }
        $m = $script:modsNow[$id]
        return [pscustomobject]@{ files = @([pscustomobject]@{ file_id = 1; version = $m.version; category_name = 'MAIN'; uploaded_timestamp = $m.ts; file_name = 'x' }) }
    }
    if ($u -like '*games?name_id=*') { return [pscustomobject]@{ data = @([pscustomobject]@{ id = 5555 }) } }
    if ($u -like '*/v1/me') { return [pscustomobject]@{ username = 'tester' } }
    if ($u -like '*me/subscribed*') {
        return [pscustomobject]@{ data = @([pscustomobject]@{ id = 101; name = 'Deceptious Quest Core'; date_updated = (1000 * $script:Mo); modfile = [pscustomobject]@{ version = "3.3.$($script:Mo)" } }) }
    }
    throw "Unmocked $u"
}
$script:modsNow = Get-InstalledNexusMods $game
$rowsSeen = New-Object System.Collections.ArrayList
$finished = @{ n = -1 }
$ui2 = [pscustomobject]@{}
$ui2 | Add-Member ScriptMethod Log { param($m) }
$ui2 | Add-Member ScriptMethod UpdateRow { param($r) [void]$rowsSeen.Add($r) }
$ui2 | Add-Member ScriptMethod CheckFinished { param($n) $finished.n = $n }
$cfgU = @{ gameDir = $game; nexusKey = 'K'; modioToken = 'T'; githubToken = ''; modioGameId = 0; pauseBetweenBatches = $false; checkOnStart = $true }
$st = @{}
$C = New-UpdateChecker $cfgU $st $ui2
Start-UpdateCheck $C
$g = 0; while (-not $C.done -and $g -lt 100) { $g++; Step-UpdateCheck $C }
Check 'checker finished' ($C.done)
Check 'one Nexus update (ArchiveXL)' ($finished.n -eq 1) $finished.n
Check 'first row is RED4ext (framework order)' ($rowsSeen[0].id -eq 2380) $rowsSeen[0].id
Check 'ArchiveXL row' (@($rowsSeen | ? { $_.id -eq 4198 -and $_.update -and $_.latest -eq '1.29.0' -and $_.fileId -eq 2 }).Count -eq 1)
Check 'hidden mod handled' (@($rowsSeen | ? { $_.id -eq 35785 -and -not $_.update }).Count -eq 1)
Check 'mod.io first check not flagged' (@($rowsSeen | ? { $_.source -eq 'mod.io' -and $_.status -like 'Up to date*' }).Count -eq 1)
# second check after mod.io mod changed
$script:Mo = 2; $rowsSeen.Clear()
$C = New-UpdateChecker $cfgU $st $ui2; Start-UpdateCheck $C
$g = 0; while (-not $C.done -and $g -lt 100) { $g++; Step-UpdateCheck $C }
Check 'mod.io change flagged' (@($rowsSeen | ? { $_.source -eq 'mod.io' -and $_.status -like 'Updated*' }).Count -eq 1)

# update engine: waits for a NEWER staging folder, not the existing install
$opened2 = New-Object System.Collections.ArrayList
$ui3 = [pscustomobject]@{}
$ui3 | Add-Member ScriptMethod Log { param($m) }
$ui3 | Add-Member ScriptMethod SetStatus { param($k, $s, $d) }
$ui3 | Add-Member ScriptMethod Banner { param($t, $b) }
$ui3 | Add-Member ScriptMethod OpenUrl { param($u) [void]$opened2.Add($u) }
$manifest = Load-Manifest (Join-Path $AppDir 'manifest.json')
$E = New-Engine $manifest $cfgU @{} $ui3
$row = @($rowsSeen | ? { $_.id -eq 4198 })[0]
Start-UpdateEngine $E @($row)
Step-Engine $E
Check 'update opens exact file' ($opened2[0] -eq 'https://www.nexusmods.com/cyberpunk2077/mods/4198?tab=files&file_id=2&nmm=1') $opened2[0]
Step-Engine $E
Check 'still waiting while only old version installed' ($E.mode -eq 'waitNexus')
New-Item -ItemType Directory (Join-Path $staging ('ArchiveXL-4198-1-29-0-' + ($axlTs + 5000))) | Out-Null
Step-Engine $E; Step-Engine $E
Check 'update detected and finished' ($E.mode -eq 'done' -and $E.counts.installed -eq 1) "$($E.mode) $($E.counts.installed)"
Check 'update not written to install state' (-not (Test-Path (Join-Path $script:DataDir 'state.json')) -or -not ((Load-State).ContainsKey('update:4198')))

# app self-update with a fake GitHub
$script:AppVersion = '1.2.0'   # pin: the test writes 1.3.0 (newer) and 1.2.0 (same)
$repo = Join-Path $tmp 'repo'; New-Item -ItemType Directory $repo | Out-Null
$appRoot = Join-Path $tmp 'app'; New-Item -ItemType Directory $appRoot | Out-Null
'old ps1' | Set-Content (Join-Path $appRoot 'NightCityInstaller.ps1')
'old manifest' | Set-Content (Join-Path $appRoot 'manifest.json')
'new ps1' | Set-Content (Join-Path $repo 'NightCityInstaller.ps1')
'new manifest' | Set-Content (Join-Path $repo 'manifest.json')
function Write-Version($ver, [hashtable]$override) {
    $files = foreach ($n in 'NightCityInstaller.ps1', 'manifest.json') { [ordered]@{ path = $n; sha256 = $(if ($override -and $override[$n]) { $override[$n] } else { (Get-FileHash (Join-Path $repo $n) -Algorithm SHA256).Hash }) } }
    [ordered]@{ version = $ver; notes = 'test'; files = @($files) } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $repo 'version.json')
}
$script:GhAuth = @()
function Invoke-WebRequest {
    param($Uri, $Headers, $OutFile, [switch]$UseBasicParsing, $TimeoutSec)
    $script:GhAuth += [string]$Headers['Authorization']
    if ($Headers['Authorization'] -ne 'Bearer GH') { $e = New-Object System.Net.WebException('The remote server returned an error: (404) Not Found.'); throw $e }
    $name = [Uri]::UnescapeDataString(([string]$Uri -replace '^.*/contents/', '' -replace '\?.*$', ''))
    Copy-Item (Join-Path $repo $name) $OutFile
}
$script:Root = $appRoot
Write-Version '1.3.0' $null
$threw = $false; try { Test-AppUpdate '' } catch { $threw = $_.Exception.Message -like '*private*' }
Check 'no token on private repo explains' $threw
$info = Test-AppUpdate 'GH'
Check 'newer version offered' ($info -and $info.version -eq '1.3.0')
Write-Version '1.2.0' $null
Check 'same version not offered' ($null -eq (Test-AppUpdate 'GH'))
Write-Version '1.3.0' @{ 'manifest.json' = 'DEADBEEF' }
$threw = $false; try { Install-AppUpdate (Test-AppUpdate 'GH') 'GH' } catch { $threw = $true }
Check 'bad hash aborts' $threw
Check 'nothing changed after bad hash' ((Get-Content (Join-Path $appRoot 'NightCityInstaller.ps1')) -eq 'old ps1')
$bad = [pscustomobject]@{ version = '9.9.9'; files = @([pscustomobject]@{ path = '..\evil.ps1'; sha256 = 'x' }) }
$threw = $false; try { Install-AppUpdate $bad 'GH' } catch { $threw = $_.Exception.Message -like '*unsafe*' }
Check 'path traversal blocked' $threw
Write-Version '1.3.0' $null
$bk = Install-AppUpdate (Test-AppUpdate 'GH') 'GH'
Check 'files replaced' ((Get-Content (Join-Path $appRoot 'NightCityInstaller.ps1')) -eq 'new ps1' -and (Get-Content (Join-Path $appRoot 'manifest.json')) -eq 'new manifest')
Check 'backup kept' ((Get-Content (Join-Path $bk 'NightCityInstaller.ps1')) -eq 'old ps1')

Remove-Item $tmp -Recurse -Force

# ================= 1.3 tests: tokens, discovery, locked/updatable rows =================
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("ncl-13-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp | Out-Null
$script:DataDir = Join-Path $tmp 'data'
$game = Join-Path $tmp 'game'; $staging = Join-Path $tmp 'staging'
New-Item -ItemType Directory (Join-Path $game 'bin/x64') -Force | Out-Null; New-Item -ItemType Directory $staging | Out-Null
$dep = Get-Content $DeploymentJson -Raw | ConvertFrom-Json; $dep.stagingPath = $staging
$dep | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $game 'vortex.deployment.json')

# token kinds + API path
$jwe = 'eyJlbmMiOiJBMTI4Q0JDIn0.AAAA_bb-cc.DDDD.EEEE-ff.GGGG'
Check 'oauth2 token detected' ((Get-ModioTokenKind $jwe) -eq 'oauth2')
Check 'PAT detected' ((Get-ModioTokenKind 'modio_pat_1234567890abcdef') -eq 'pat')
Check 'empty token' ((Get-ModioTokenKind '  ') -eq 'none')
Set-ModioBase 'https://u-12345.modapi.io'; Check 'api path adds /v1' ($script:ModioBase -eq 'https://u-12345.modapi.io/v1') $script:ModioBase
Set-ModioBase 'https://g-3456.modapi.io/v1/'; Check 'api path trims slash' ($script:ModioBase -eq 'https://g-3456.modapi.io/v1')
Set-ModioBase 'https://evil.example.com/v1'; Check 'foreign host refused' ($script:ModioBase -eq 'https://api.mod.io/v1')
Set-ModioBase ''; Check 'default api path' ($script:ModioBase -eq 'https://api.mod.io/v1')

# blocklist
Check 'block HUD' ((Get-DiscoveryBlockReason 'DynamicHUD - Contextual HUD') -like 'HUD*')
Check 'block translation' ((Get-DiscoveryBlockReason 'RomanceHangoutsEnhanced-11590-2.5.3-CHS') -like 'Translation*')
Check 'block German' ((Get-DiscoveryBlockReason 'German Language for Appearance Menu Mod') -ne $null)
Check 'block old version' ((Get-DiscoveryBlockReason 'The Kings Outfit for 2.31 and lower') -like '*older*')
Check 'block dual wield' ((Get-DiscoveryBlockReason 'Gorilla Akimbo') -like '*Dual*')
Check 'allow normal mod' ($null -eq (Get-DiscoveryBlockReason 'Villa V - North Oak Player Mansion'))
Check 'allow "it" word' ($null -eq (Get-DiscoveryBlockReason 'Make It Rain - Better Weather'))

# mocked APIs for discovery
$P = [long]([datetimeoffset][datetime]'2026-10-22T00:00:00Z').ToUnixTimeSeconds()
$script:Calls = New-Object System.Collections.ArrayList
$script:LastHeaders = $null
function NX($id, $name, $end, $dl, $ts, [bool]$adult = $false) { [pscustomobject]@{ mod_id = $id; name = $name; available = $true; status = 'published'; endorsement_count = $end; mod_downloads = $dl; updated_timestamp = $ts; contains_adult_content = $adult } }
$script:NexusMods = @{
    50001 = (NX 50001 'Cool New Quest' 120 9000 ($P + 1000))
    50002 = (NX 50002 'Shiny HUD Overhaul' 300 20000 ($P + 2000))
    50003 = (NX 50003 'Tiny Tweak' 2 40 ($P + 3000))
    50004 = (NX 50004 'Spicy Body Pack' 80 15000 ($P + 4000) $true)
    4198  = (NX 4198 'ArchiveXL' 9999 999999 ($P + 5000))
}
function Invoke-RestMethod {
    param($Method = 'Get', $Uri, $Headers, $ContentType, $Body, $TimeoutSec)
    $u = [string]$Uri; [void]$script:Calls.Add($u); $script:LastHeaders = $Headers
    if ($u -like '*mods/updated.json*') { return ,@(
        [pscustomobject]@{ mod_id = 50001; latest_file_update = $P + 1000 }, [pscustomobject]@{ mod_id = 50002; latest_file_update = $P + 2000 },
        [pscustomobject]@{ mod_id = 50003; latest_file_update = $P + 3000 }, [pscustomobject]@{ mod_id = 50004; latest_file_update = $P + 4000 },
        [pscustomobject]@{ mod_id = 4198; latest_file_update = $P + 5000 }, [pscustomobject]@{ mod_id = 50009; latest_file_update = $P - 9999 }) }
    if ($u -like '*mods/trending.json') { return ,@((NX 50010 'Trending Gun Pack' 500 50000 ($P + 100)), (NX 50011 'Old Classic' 900 90000 ($P - 5000))) }
    if ($u -like '*mods/latest_added.json' -or $u -like '*mods/latest_updated.json') { return ,@() }
    if ($u -match 'nexusmods.com/v1/games/cyberpunk2077/mods/(\d+)\.json$') { return $script:NexusMods[[int]$Matches[1]] }
    if ($u -like '*games?name_id=*') { return [pscustomobject]@{ data = @([pscustomobject]@{ id = 5555 }) } }
    if ($u -match 'games/5555/mods\?_limit=100&_offset=0') { return [pscustomobject]@{ data = @(
        [pscustomobject]@{ id = 101; name = 'Deceptious Quest Core'; maturity_option = 0 },
        [pscustomobject]@{ id = 701; name = 'Brand New Gig'; maturity_option = 0 },
        [pscustomobject]@{ id = 702; name = 'Steamy Thing'; maturity_option = 2 }) } }
    if ($u -like '*/v1/me') { return [pscustomobject]@{ username = 'tester' } }
    if ($u -like '*me/subscribed*') { return [pscustomobject]@{ data = @() } }
    if ($Method -eq 'Post' -and $u -match 'mods/(\d+)/subscribe') { return [pscustomobject]@{ id = [int]$Matches[1] } }
    if ($u -match 'mods/(\d+)/dependencies') { return [pscustomobject]@{ data = @() } }
    if ($u -match 'games/5555/mods\?_q=') { throw "search should not run for discovered mod.io items: $u" }
    throw "Unmocked $u"
}
$null = Invoke-Modio Get 'me' "  $jwe  "
Check 'bearer header trimmed' ($script:LastHeaders['Authorization'] -eq "Bearer $jwe")
Check 'platform header' ($script:LastHeaders['X-Modio-Platform'] -eq 'windows')

$manifestD = Load-Manifest (Join-Path $AppDir 'manifest.json')
$cfgD = @{ gameDir = $game; nexusKey = 'K'; modioToken = 'T'; githubToken = ''; modioGameId = 0; pauseBetweenBatches = $false; checkOnStart = $true; modioApiPath = ''; discoverOnStart = $true }
$found = @{ keys = $null }
$uiD = [pscustomobject]@{}
$uiD | Add-Member ScriptMethod Log { param($m) }
$uiD | Add-Member ScriptMethod DiscoveryFinished { param($k) $found.keys = @($k) }
$before = $manifestD.items.Count
$D = New-Discovery $manifestD $cfgD (Read-DiscoveryStore) (Get-InstalledNexusIds $game) $uiD
$g = 0; while (-not $D.done -and $g -lt 200) { $g++; Step-Discovery $D }
Check 'discovery finished' $D.done
$keys = ($found.keys | Sort-Object) -join ','
Check 'discovery adds the right mods' ($keys -eq 'modio:id:701,modio:id:702,nexus:50001,nexus:50004,nexus:50010') $keys
Check 'HUD mod rejected with reason' ($D.store.nexus['50002'].reason -like 'HUD*')
Check 'little-used rejected' ($D.store.nexus['50003'].reason -like 'Little-used*')
Check 'installed ArchiveXL not re-added' (-not (Test-InManifest $manifestD 'nexus:4198'))
Check 'pre-patch trending mod rejected' ($D.store.nexus['50011'].reason -eq 'No file since the patch')
Check 'pre-patch update feed entry ignored' (-not $D.store.nexus.ContainsKey('50009'))
Check 'mod.io already-listed skipped' ($D.store.modio['101'].reason -eq 'Already in the list')
$i701 = $manifestD.items | ? key -eq 'modio:id:701'; $i702 = $manifestD.items | ? key -eq 'modio:id:702'
$i1 = $manifestD.items | ? key -eq 'nexus:50001'; $i4 = $manifestD.items | ? key -eq 'nexus:50004'
Check 'mod.io find ticked by default' ($i701.batch -eq 90 -and -not $i701.optional -and $i701.modioId -eq 701)
Check 'mature mod.io find unticked' ($i702.batch -eq 91 -and $i702.optional)
Check 'nexus find is verify + unticked' ($i1.batch -eq 92 -and $i1.optional -and $i1.verify)
Check 'adult nexus find in adult group' ($i4.batch -eq 93)
Check 'manifest grew' ($manifestD.items.Count -eq $before + 5)
Check 'store saved' (Test-Path (Join-Path $script:DataDir 'discovered.json'))
# second run: nothing new, details not fetched again
$script:Calls.Clear()
$m2 = Load-Manifest (Join-Path $AppDir 'manifest.json')
$pre = Add-DiscoveredToManifest $m2 (Read-DiscoveryStore) (Get-InstalledNexusIds $game)
Check 'stored finds re-added on next start' ($pre.Count -eq 5)
$D2 = New-Discovery $m2 $cfgD (Read-DiscoveryStore) (Get-InstalledNexusIds $game) $uiD
$g = 0; while (-not $D2.done -and $g -lt 200) { $g++; Step-Discovery $D2 }
Check 'second run finds nothing new' ($found.keys.Count -eq 0) ($found.keys -join ',')
Check 'second run does not refetch details' (@($script:Calls | ? { $_ -match '/mods/\d+\.json$' }).Count -eq 0) (@($script:Calls) -join ' ')

# discovered mod.io item subscribes by id (no search)
$uiE = [pscustomobject]@{}
$uiE | Add-Member ScriptMethod Log { param($m) }
$uiE | Add-Member ScriptMethod SetStatus { param($k, $s, $d) }
$uiE | Add-Member ScriptMethod Banner { param($t, $b) }
$opened3 = New-Object System.Collections.ArrayList
$uiE | Add-Member ScriptMethod OpenUrl { param($u) [void]$opened3.Add($u) }
$cfgD.modioGameId = 5555
$EE = New-Engine $m2 $cfgD @{} $uiE
Start-Engine $EE @('modio:id:701')
Step-Engine $EE
Check 'discovered mod.io subscribed by id' ($EE.state['modio:id:701'].status -eq 'Subscribed' -and (@($script:Calls) -match 'mods/701/subscribe').Count -eq 1)

# installed list mod with an update goes through the update path
$axlTs = [long]([datetimeoffset][datetime]::Parse('2026-10-29T12:59:00Z')).ToUnixTimeSeconds()
New-Item -ItemType Directory (Join-Path $staging ('Wannabe Edgerunner-5646-3-0-1-' + $axlTs)) | Out-Null
$EU = New-Engine $m2 $cfgD @{} $uiE
$EU.updates = @{ 5646 = [pscustomobject]@{ id = 5646; latest = '3.1.0'; latestTs = $axlTs + 50000; fileId = 999; installed = '3.0.1' } }
Start-Engine $EU @('nexus:5646')
Step-Engine $EU
Check 'installed mod with update opens update file' ($opened3[-1] -eq 'https://www.nexusmods.com/cyberpunk2077/mods/5646?tab=files&file_id=999&nmm=1' -and $EU.mode -eq 'waitNexus') $opened3[-1]
Step-Engine $EU
Check 'old version does not count as updated' ($EU.mode -eq 'waitNexus')
New-Item -ItemType Directory (Join-Path $staging ('Wannabe Edgerunner-5646-3-1-0-' + ($axlTs + 50000))) | Out-Null
Step-Engine $EU; Step-Engine $EU
Check 'update recognised' ($EU.mode -eq 'done' -and $EU.counts.installed -eq 1)
$EN = New-Engine $m2 $cfgD @{} $uiE
Start-Engine $EN @('nexus:5646')
Step-Engine $EN
Check 'installed mod without update stays skipped as installed' ($EN.state['nexus:5646'].status -eq 'Already installed')

Remove-Item $tmp -Recurse -Force


# ================= 1.4 tests: flat lists, requirements, manual installs, health, console-only =================
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("ncl-14-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp | Out-Null
$script:DataDir = Join-Path $tmp 'data'; $script:ModInfoCache = $null
$game = Join-Path $tmp 'game'; $staging = Join-Path $tmp 'staging'
New-Item -ItemType Directory (Join-Path $game 'bin/x64') -Force | Out-Null; New-Item -ItemType Directory $staging | Out-Null
$dep = Get-Content $DeploymentJson -Raw | ConvertFrom-Json; $dep.stagingPath = $staging
$dep | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $game 'vortex.deployment.json')

# flat lists (5.1 shape and 7 shape)
$nested = ,@([pscustomobject]@{ a = 1 }, [pscustomobject]@{ a = 2 })
Check 'flatten 5.1-style array' ((ConvertTo-FlatList $nested).Count -eq 2)
Check 'flatten plain array' ((ConvertTo-FlatList @(1, 2, 3)).Count -eq 3)
Check 'flatten empty' ((ConvertTo-FlatList $null).Count -eq 0)

# requirements from text
$d1 = "[b]Requirements[/b]<br />- Cyber Engine Tweaks<br />- ArchiveXL<br />- Native Interactions Framework<br />Optional: Appearance Menu Mod<br /><br />[b]Installation[/b]<br />Use Vortex. Compatible with Codeware."
$r1 = (Get-RequirementsFromText $d1 36373 | % name) -join ','
Check 'requirements section parsed' ($r1 -eq 'Cyber Engine Tweaks,ArchiveXL,Native Interactions Framework') $r1
$zh = Get-Content (Join-Path $AppDir '../tests/arasaka-readme.txt') -Raw -ErrorAction SilentlyContinue
if ($zh) { $r2 = (Get-RequirementsFromText $zh 36373 | % name) -join ','; Check 'Chinese readme requirements' ($r2 -match 'Native Interactions Framework' -and $r2 -match 'ArchiveXL') $r2 }
Check 'no requirements section' ((Get-RequirementsFromText 'A cool mod that adds hats. Works with AMM.' 1).Count -eq 0)
Check 'self not required' (-not ((Get-RequirementsFromText 'Requirements: ArchiveXL' 4198) | ? id -eq 4198))

# manual install plans
$ex = Join-Path $game 'V2077/mod-extra-files'
function MkFile($p) { New-Item -ItemType Directory (Split-Path $p -Parent) -Force | Out-Null; 'x' | Set-Content $p }
MkFile "$ex/DocsOnly/README.txt"
MkFile "$ex/Nested Pack/MyMod v2/archive/pc/mod/nested.archive"
MkFile "$ex/Nested Pack/MyMod v2/r6/scripts/Nested/a.reds"
MkFile "$ex/Loose Bits/loose.archive"; MkFile "$ex/Loose Bits/thing.reds"; MkFile "$ex/Loose Bits/thing.yaml"; MkFile "$ex/Loose Bits/weird.bin"
MkFile "$ex/CetThing/CoolCet/init.lua"; MkFile "$ex/CetThing/CoolCet/modules/a.lua"
MkFile "$ex/RedModThing/mods/RedModThing/info.json"
$p0 = Get-ManualInstallPlan "$ex/DocsOnly" 'DocsOnly'
Check 'docs-only: nothing to copy' ($p0.copy.Count -eq 0 -and $p0.docs.Count -eq 1)
$p1 = Get-ManualInstallPlan "$ex/Nested Pack" 'Nested Pack'
Check 'nested game folders found' ((($p1.copy | % dest | sort) -join ',') -eq 'archive/pc/mod/nested.archive,r6/scripts/Nested/a.reds') (($p1.copy | % dest) -join ',')
$p2 = Get-ManualInstallPlan "$ex/Loose Bits" 'Loose Bits'
Check 'loose files placed by type' ((($p2.copy | % dest | sort) -join ',') -eq 'archive/pc/mod/loose.archive,r6/scripts/Loose Bits/thing.reds,r6/tweaks/Loose Bits/thing.yaml' -and $p2.unknown.Count -eq 1) (($p2.copy | % dest) -join ',')
$p3 = Get-ManualInstallPlan "$ex/CetThing" 'CetThing'
Check 'CET mod folder placed' ((($p3.copy | % dest | sort) -join ',') -eq 'bin/x64/plugins/cyber_engine_tweaks/mods/CoolCet/init.lua,bin/x64/plugins/cyber_engine_tweaks/mods/CoolCet/modules/a.lua') (($p3.copy | % dest) -join ',')
$p4 = Get-ManualInstallPlan "$ex/RedModThing" 'RedModThing'
Check 'REDmod detected' ($p4.redmod)
MkFile (Join-Path $game 'archive/pc/mod/loose.archive')
$res = Invoke-ManualInstall $game $p2 'nexus:99'
Check 'manual install copies, never overwrites' ($res.copied.Count -eq 2 -and $res.skipped.Count -eq 1 -and (Test-Path (Join-Path $game 'r6/scripts/Loose Bits/thing.reds')))
Check 'manual install recorded' ((Get-Content (Join-Path $script:DataDir 'manual-installs.json') -Raw) -match 'thing.reds')
Check 'extra folder found by name' ((Get-ExtraFilesFolder $game 'Loose Bits' 0) -like '*Loose Bits')

# health + crash guard
New-Item -ItemType Directory (Join-Path $game 'r6/cache/modded') -Force | Out-Null
New-Item -ItemType Directory (Join-Path $game 'red4ext/logs') -Force | Out-Null
"[2026-11-04 02:04:26.141] [warning ] [ 78908] [RED4ext] scc invocation failed with an error: Failed to load the original script cache" | Set-Content (Join-Path $game 'red4ext/logs/red4ext-2026-11-04-02-04-05.log')
$h = Get-HealthIssues $game
Check 'health: empty modded cache' (@($h | ? id -eq 'empty-modded-cache').Count -eq 1)
Check 'health: scc failure' (@($h | ? id -eq 'scc-failed').Count -eq 1 -and (@($h | ? id -eq 'scc-failed')[0].detail -match 'original script cache'))
Check 'health: parked files' (@($h | ? id -like 'extra:*').Count -ge 3)
Check 'health: REDmod mod' (@($h | ? id -like 'redmod:*').Count -eq 1)
Check 'health: missing script cache flagged' (@($h | ? id -eq 'script-cache-missing').Count -eq 1)
[IO.File]::WriteAllBytes((Join-Path $game 'r6/cache/final.redscripts'), (New-Object byte[] 4297))
Check 'health: replaced script cache flagged' (@(Get-HealthIssues $game | ? { $_.id -eq 'script-cache-damaged' -and $_.fix -eq 'steam-verify' }).Count -eq 1)
[IO.File]::WriteAllBytes((Join-Path $game 'r6/cache/final.redscripts'), (New-Object byte[] (21MB)))
Check 'health: full-size script cache is fine' (@(Get-HealthIssues $game | ? id -like 'script-cache-*').Count -eq 0)
Check 'repair renames empty folder' ((Repair-EmptyModdedCache $game) -and -not (Test-Path (Join-Path $game 'r6/cache/modded')) -and @(Get-ChildItem (Join-Path $game 'r6/cache') -Directory | ? Name -like '_modded_empty_*').Count -eq 1)
New-Item -ItemType Directory (Join-Path $game 'r6/cache/modded') -Force | Out-Null; 'x' | Set-Content (Join-Path $game 'r6/cache/modded/final.redscripts')
Check 'repair leaves a filled folder alone' (-not (Repair-EmptyModdedCache $game) -and (Test-Path (Join-Path $game 'r6/cache/modded/final.redscripts')))

# mod.io account check
$oldLocal = $env:LOCALAPPDATA; $oldPublic = $env:PUBLIC
$env:LOCALAPPDATA = Join-Path $tmp 'la'; $env:PUBLIC = Join-Path $tmp 'pub'
$sess0 = Get-GameModioSession 8254
Check 'modio: no session means not linked' (@(Get-ModioLinkIssues $sess0 'RJCalzone' 5 30 | ? id -eq 'modio-not-linked').Count -eq 1)
$ud = Join-Path $env:LOCALAPPDATA 'mod.io/8254/50716111627241556'; New-Item -ItemType Directory $ud -Force | Out-Null
'{"OAuth":{"Token":"secret-value","ExpiryDate":1},"Profile":{"user_id":99,"username":"OtherUser"}}' | Set-Content (Join-Path $ud 'user.json')
New-Item -ItemType Directory (Join-Path $env:PUBLIC 'mod.io/8254/metadata') -Force | Out-Null
$sess1 = Get-GameModioSession 8254
Check 'modio: session user read' (($sess1.users -contains 'OtherUser') -and $sess1.hasToken -and $sess1.installed -eq 0)
$i1 = @(Get-ModioLinkIssues $sess1 'RJCalzone' 5 30)
Check 'modio: account mismatch flagged' (@($i1 | ? id -eq 'modio-account-mismatch').Count -eq 1 -and @($i1 | ? id -eq 'modio-nothing-downloaded').Count -eq 1)
Check 'modio: matching account not flagged' (@(Get-ModioLinkIssues $sess1 'OtherUser' 99 30 | ? id -eq 'modio-account-mismatch').Count -eq 0)
$script:Root = $tmp; Write-ModioReport $sess1 'RJCalzone' 5 30 $i1
$rep = Get-Content (Join-Path $tmp 'modio-check.txt') -Raw
Check 'modio: report has no token value' (($rep -match 'OtherUser') -and ($rep -notmatch 'secret-value'))
$env:LOCALAPPDATA = $oldLocal; $env:PUBLIC = $oldPublic

# engine: requirement first, dependent held when the requirement has no 2.5 file
$P2 = [long]([datetimeoffset][datetime]'2026-10-22T00:00:00Z').ToUnixTimeSeconds()
$script:Calls = New-Object System.Collections.ArrayList
function Invoke-RestMethod {
    param($Method = 'Get', $Uri, $Headers, $ContentType, $Body, $TimeoutSec)
    $u = [string]$Uri; [void]$script:Calls.Add($u)
    if ($u -match 'nexusmods.com/v1/games/cyberpunk2077/mods/(\d+)\.json$') {
        $id = [int]$Matches[1]
        $desc = if ($id -eq 36373) { 'Requirements<br />- Cyber Engine Tweaks<br />- Native Interactions Framework 1.1.4+' } else { 'A mod.' }
        return [pscustomobject]@{ mod_id = $id; name = "Mod $id"; summary = 's'; description = $desc; author = 'a'; version = '1'; endorsement_count = 50; mod_downloads = 5000; picture_url = "https://img/$id.jpg"; contains_adult_content = $false; available = $true; status = 'published'; updated_timestamp = $P2 + 10 }
    }
    if ($u -match 'mods/(\d+)/files.json') {
        $id = [int]$Matches[1]
        $ts = if ($id -eq 21422) { $P2 - 86400 } else { $P2 + 3600 }
        return [pscustomobject]@{ files = @([pscustomobject]@{ file_id = $id * 10; version = '1.0'; category_name = 'MAIN'; is_primary = $true; uploaded_timestamp = $ts; file_name = "x-$id-1-0.zip" }) }
    }
    if ($u -like '*/v1/me') { return [pscustomobject]@{ username = 'tester' } }
    if ($u -like '*me/subscribed*') { return [pscustomobject]@{ data = @() } }
    if ($u -like '*games?name_id=*') { return [pscustomobject]@{ data = @([pscustomobject]@{ id = 5555 }) } }
    if ($u -match 'games/5555/mods\?_q=Quickhack') { if ($Headers.ContainsKey('X-Modio-Platform')) { return [pscustomobject]@{ data = @() } } else { return [pscustomobject]@{ data = @([pscustomobject]@{ id = 801; name = 'Quickhack Loadouts' }) } } }
    if ($u -match 'games/5555/mods\?_q=') { return [pscustomobject]@{ data = @() } }
    throw "Unmocked $u"
}
$opened4 = New-Object System.Collections.ArrayList
$uiR = [pscustomobject]@{}
$uiR | Add-Member ScriptMethod Log { param($m) }
$uiR | Add-Member ScriptMethod SetStatus { param($k, $s, $d) }
$uiR | Add-Member ScriptMethod Banner { param($t, $b) }
$uiR | Add-Member ScriptMethod OpenUrl { param($u) [void]$opened4.Add($u) }
$addedRows = New-Object System.Collections.ArrayList
$uiR | Add-Member ScriptMethod AddItem { param($it) [void]$addedRows.Add($it.key) }
$mR = Load-Manifest (Join-Path $AppDir 'manifest.json')
$cfgR = @{ gameDir = $game; nexusKey = 'K'; modioToken = 'T'; githubToken = ''; modioGameId = 5555; pauseBetweenBatches = $false; checkOnStart = $true; modioApiPath = ''; discoverOnStart = $true }
$ER = New-Engine $mR $cfgR @{} $uiR
Start-Engine $ER @('nexus:36373', 'modio:Quickhack Loadouts')
$g = 0; while ($ER.mode -ne 'done' -and $g -lt 50) { $g++; Step-Engine $ER }
Check 'console-only mod.io mod recognised' ($ER.state['modio:Quickhack Loadouts'].status -eq 'Console only' -and $ER.state['modio:Quickhack Loadouts'].done)
Check 'requirement queued before dependent' ((($ER.queue | % key) -join ',') -eq 'modio:Quickhack Loadouts,nexus:21422,nexus:36373') (($ER.queue | % key) -join ',')
Check 'requirement without 2.5 file waits' ($ER.state['nexus:21422'].status -eq 'Waiting for 2.5 update')
Check 'dependent held for its requirement' ($ER.state['nexus:36373'].status -eq 'Needs Native Interactions Framework' -and -not $ER.state['nexus:36373'].done) $ER.state['nexus:36373'].status
Check 'no download page opened for held mod' ($opened4.Count -eq 0)
Check 'requirement added to the list' ($addedRows -contains 'nexus:21422' -or (Test-InManifest $mR 'nexus:21422'))
Check 'mod info cached with picture' ((Get-ModInfoCache)['nexus:36373'].images[0] -eq 'https://img/36373.jpg')

# post-install: parked files placed + readme requirement picked up
$EP = New-Engine $mR $cfgR @{} $uiR
Start-Engine $EP @('nexus:36108')
Step-Engine $EP
Check 'waiting for click (36108)' ($EP.mode -eq 'waitNexus')
MkFile "$ex/Sell Apartments/SellApartments/archive/pc/mod/sa.archive"
"Requirements:`n- Audioware" | Set-Content "$ex/Sell Apartments/README.txt"
New-Item -ItemType Directory (Join-Path $staging 'Sell Apartments-36108-1-0-1-1761600000') | Out-Null
Step-Engine $EP
Check 'post-install placed parked archive' (Test-Path (Join-Path $game 'archive/pc/mod/sa.archive'))
Check 'post-install queued readme requirement next' ($EP.queue.Count -ge 2 -and $EP.queue[1].key -eq 'nexus:12001') (($EP.queue | % key) -join ',')

Remove-Item $tmp -Recurse -Force

Write-Host "TOTAL passed $pass, failed $fail"
if ($fail -gt 0) { exit 1 }
