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
Check 'resume re-queues unfinished (Zoomable waiting + Hot Fuzz)' (($E2.queue | % key) -join ',' -eq 'nexus:3543,modio:Hot Fuzz') (($E2.queue | % key) -join ',')

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
Check 'no key -> files tab' ($opened[0] -eq 'https://www.nexusmods.com/cyberpunk2077/mods/17642?tab=files')
Invoke-EngineAction $E5 "It's installed"
Step-Engine $E5
Check 'no token -> pauses with message' ($E5.mode -eq 'paused')

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
Write-Host "TOTAL passed $pass, failed $fail"
if ($fail -gt 0) { exit 1 }
