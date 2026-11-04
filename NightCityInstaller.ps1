# Night City Installer
# Installs the "Night City Load Order" mod list for Cyberpunk 2077 patch 2.5, in order.
#  - Nexus mods: opens each mod's download page; you click "Slow download"; Vortex installs it;
#    this app detects the install and moves on. (Nexus requires that click on free accounts.)
#  - mod.io mods: subscribes your mod.io account to each mod (and its requirements) through the
#    official mod.io API. The game downloads them from its Mods menu on next launch.
# Your keys are stored encrypted for your Windows user only (DPAPI) and are sent only to
# api.nexusmods.com and api.mod.io.

param([switch]$TestMode)

$ErrorActionPreference = 'Stop'
$script:AppName    = 'Night City Installer'
$script:AppVersion = '1.3.0'
$script:Root       = $PSScriptRoot
$script:IsWin      = ($env:OS -eq 'Windows_NT')
if ($env:LOCALAPPDATA) { $script:DataDir = Join-Path $env:LOCALAPPDATA 'NightCityInstaller' }
else { $script:DataDir = Join-Path ([IO.Path]::GetTempPath()) 'NightCityInstaller' }
$script:DefaultGameDir = 'C:\Steam Modded\Steam\steamapps\common\Cyberpunk 2077'
$script:NexusBase = 'https://api.nexusmods.com/v1'
$script:ModioBase = 'https://api.mod.io/v1'
$script:Glyph = @{ ok = [string][char]0x2713; up = [string][char]0x2191; dot = [string][char]0x2022 }
$script:FrameworkIds = @{ 107='Cyber Engine Tweaks'; 2380='RED4ext'; 1511='redscript'; 4198='ArchiveXL'; 4197='TweakXL'; 7780='Codeware'; 4885='Mod Settings'; 3518='Native Settings UI' }

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# ---------------------------------------------------------------- storage

function Ensure-DataDir { if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null } }

function Protect-Text([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($script:IsWin) { return (ConvertTo-SecureString -String $Text -AsPlainText -Force | ConvertFrom-SecureString) }
    return 'b64:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))   # test runs on non-Windows only
}

function Unprotect-Text([string]$Blob) {
    if ([string]::IsNullOrEmpty($Blob)) { return '' }
    if ($Blob.StartsWith('b64:')) { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Blob.Substring(4))) }
    try {
        $ss = ConvertTo-SecureString -String $Blob
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    } catch { return '' }
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
}

function Write-JsonFile([string]$Path, $Object) {
    Ensure-DataDir
    $tmp = "$Path.tmp"
    ($Object | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Load-Config {
    $c = Read-JsonFile (Join-Path $script:DataDir 'config.json')
    $cfg = @{ gameDir = ''; nexusKey = ''; modioToken = ''; githubToken = ''; modioGameId = 0; pauseBetweenBatches = $false; checkOnStart = $true; modioApiPath = ''; discoverOnStart = $true }
    if ($c) {
        if ($c.PSObject.Properties['pauseBetweenBatches']) { $cfg.pauseBetweenBatches = [bool]$c.pauseBetweenBatches }
        if ($c.PSObject.Properties['checkOnStart']) { $cfg.checkOnStart = [bool]$c.checkOnStart }
        if ($c.PSObject.Properties['discoverOnStart']) { $cfg.discoverOnStart = [bool]$c.discoverOnStart }
        if ($c.PSObject.Properties['modioApiPath'] -and $c.modioApiPath) { $cfg.modioApiPath = [string]$c.modioApiPath }
        if ($c.PSObject.Properties['githubToken'] -and $c.githubToken) { $cfg.githubToken = Unprotect-Text ([string]$c.githubToken) }
        if ($c.gameDir)     { $cfg.gameDir = [string]$c.gameDir }
        if ($c.nexusKey)    { $cfg.nexusKey = Unprotect-Text ([string]$c.nexusKey) }
        if ($c.modioToken)  { $cfg.modioToken = Unprotect-Text ([string]$c.modioToken) }
        if ($c.modioGameId) { $cfg.modioGameId = [int]$c.modioGameId }
    }
    if (-not $cfg.gameDir -and (Test-Path -LiteralPath $script:DefaultGameDir)) { $cfg.gameDir = $script:DefaultGameDir }
    Set-ModioBase $cfg.modioApiPath
    return $cfg
}

function Save-Config($cfg) {
    Write-JsonFile (Join-Path $script:DataDir 'config.json') ([ordered]@{
        gameDir = $cfg.gameDir; nexusKey = (Protect-Text $cfg.nexusKey); modioToken = (Protect-Text $cfg.modioToken); modioGameId = $cfg.modioGameId
        pauseBetweenBatches = [bool]$cfg.pauseBetweenBatches; checkOnStart = [bool]$cfg.checkOnStart; githubToken = (Protect-Text $cfg.githubToken)
        modioApiPath = [string]$cfg.modioApiPath; discoverOnStart = [bool]$cfg.discoverOnStart })
    Set-ModioBase $cfg.modioApiPath
}

function Load-State {
    $s = Read-JsonFile (Join-Path $script:DataDir 'state.json')
    $h = @{}
    if ($s) { foreach ($p in $s.PSObject.Properties) { $h[$p.Name] = @{ status = [string]$p.Value.status; detail = [string]$p.Value.detail; done = [bool]$p.Value.done } } }
    return $h
}

function Save-State($state) { Write-JsonFile (Join-Path $script:DataDir 'state.json') $state }

function Load-Manifest([string]$Path) {
    if (-not $Path) { $Path = Join-Path $script:Root 'manifest.json' }
    $m = Read-JsonFile $Path
    if (-not $m) { throw "manifest.json not found next to the app ($Path)." }
    $items = New-Object System.Collections.ArrayList
    $order = 0
    foreach ($x in $m.mods) {
        $key = if ($x.source -eq 'nexus') { "nexus:$($x.id)" } else { "modio:$($x.query)" }
        $null = $items.Add([pscustomobject]@{
            key = $key; kind = 'install'; order = $order; batch = [int]$x.batch; source = [string]$x.source; name = [string]$x.name
            id = if ($x.id) { [int]$x.id } else { 0 }; query = [string]$x.query; exclude = [string]$x.exclude
            optional = [bool]$x.optional; verify = [bool]$x.verify; note = [string]$x.note; modioId = 0; discovered = $false })
        $order++
    }
    $batches = @{}
    foreach ($b in $m.batches) { $batches[[int]$b.id] = [pscustomobject]@{ id = [int]$b.id; name = [string]$b.name; source = [string]$b.source } }
    return [pscustomobject]@{ game = [string]$m.game; patchDate = [datetime]::Parse([string]$m.patchDate, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AssumeUniversal,AdjustToUniversal'); items = $items; batches = $batches }
}

# ---------------------------------------------------------------- Vortex detection

# Vortex names installed mods "<name> <nexusId> <version> <date> <hash>" (deployment file) or
# "<name>-<nexusId>-<version>-<timestamp>" (staging folders). The Nexus ID is the first
# 2-6 digit number that sits between separators and is followed by a version number.
function Get-NexusIdFromName([string]$Name) {
    $m = [regex]::Match($Name, '(?:^|[\s-])(\d{2,6})[\s-]v?\d')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return $null
}

function Get-VortexInfo([string]$GameDir) {
    $info = [pscustomobject]@{ deploymentFound = $false; stagingPath = ''; ids = (New-Object 'System.Collections.Generic.HashSet[int]') }
    $dep = Join-Path $GameDir 'vortex.deployment.json'
    if (Test-Path -LiteralPath $dep) {
        $d = Read-JsonFile $dep
        $info.deploymentFound = $true
        if ($d.stagingPath) { $info.stagingPath = [string]$d.stagingPath }
        foreach ($src in ($d.files | ForEach-Object { $_.source } | Sort-Object -Unique)) {
            $id = Get-NexusIdFromName $src
            if ($id) { $null = $info.ids.Add($id) }
        }
    }
    return $info
}

# IDs of every mod Vortex has installed: deployed ones plus anything in its staging folder
# (a mod appears in staging as soon as Vortex finishes installing it, before deployment).
function Get-InstalledNexusIds([string]$GameDir) {
    $info = Get-VortexInfo $GameDir
    $set = $info.ids
    if ($info.stagingPath -and (Test-Path -LiteralPath $info.stagingPath)) {
        foreach ($dir in (Get-ChildItem -LiteralPath $info.stagingPath -Directory -ErrorAction SilentlyContinue)) {
            $id = Get-NexusIdFromName $dir.Name
            if ($id) { $null = $set.Add($id) }
        }
    }
    return ,$set
}

# Every Nexus mod Vortex has installed, with the installed version and file timestamp.
# Deployment sources look like "ArchiveXL 4198 1.28.6 2026-10-29T12-59Z VquAqYEdu";
# staging folders look like "ArchiveXL-4198-1-28-6-1761742740" (archive name + upload time).
function Get-InstalledNexusMods([string]$GameDir) {
    $mods = @{}
    $add = {
        param($id, $name, $ver, [long]$ts, $family)
        if (-not $mods.ContainsKey($id) -or $ts -gt $mods[$id].ts) {
            $mods[$id] = [pscustomobject]@{ id = $id; name = $name; version = $ver; ts = $ts; family = $family }
        }
    }
    $info = Get-VortexInfo $GameDir
    $dep = Join-Path $GameDir 'vortex.deployment.json'
    if ($info.deploymentFound) {
        $d = Read-JsonFile $dep
        foreach ($src in ($d.files | ForEach-Object { $_.source } | Sort-Object -Unique)) {
            $m = [regex]::Match($src, '^(?<name>.*?)\s(?<id>\d{2,6})\s(?<ver>\S+)\s(?<d>\d{4}-\d{2}-\d{2})T(?<h>\d{2})-(?<mi>\d{2})Z(\s\S+)?$')
            if ($m.Success) {
                $dt = [datetime]::ParseExact("$($m.Groups['d'].Value) $($m.Groups['h'].Value):$($m.Groups['mi'].Value)", 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AssumeUniversal,AdjustToUniversal')
                $ts = [long]([datetimeoffset]$dt).ToUnixTimeSeconds()
                & $add ([int]$m.Groups['id'].Value) $m.Groups['name'].Value $m.Groups['ver'].Value $ts ''
            } else {
                $id = Get-NexusIdFromName $src
                if ($id) { & $add $id $src '' 0 '' }
            }
        }
    }
    if ($info.stagingPath -and (Test-Path -LiteralPath $info.stagingPath)) {
        foreach ($dir in (Get-ChildItem -LiteralPath $info.stagingPath -Directory -ErrorAction SilentlyContinue)) {
            $m = [regex]::Match($dir.Name, '^(?<name>.*?)-(?<id>\d{2,6})-(?<ver>.+?)-(?<ts>\d{9,11})$')
            if ($m.Success) {
                & $add ([int]$m.Groups['id'].Value) $m.Groups['name'].Value ($m.Groups['ver'].Value -replace '-', '.') ([long]$m.Groups['ts'].Value) $m.Groups['name'].Value
            } else {
                $id = Get-NexusIdFromName $dir.Name
                if ($id) { & $add $id $dir.Name '' 0 '' }
            }
        }
    }
    return $mods
}

# True when Vortex has the mod, and (for updates) a file at least as new as MinTs.
function Test-NexusInstalled([string]$GameDir, $Item) {
    $mods = Get-InstalledNexusMods $GameDir
    if (-not $mods.ContainsKey([int]$Item.id)) { return $false }
    $min = 0
    if ($Item.PSObject.Properties['minTs']) { $min = [long]$Item.minTs }
    if ($min -le 0) { return $true }
    return ($mods[[int]$Item.id].ts -ge ($min - 120))
}

function Normalize-Version([string]$v) { return (([string]$v).ToLowerInvariant() -replace '^v', '' -replace '[^0-9a-z.]', '.' -replace '\.+', '.').Trim('.') }

# Newest MAIN file for an installed mod, and whether it is newer than what Vortex has.
# When the mod has several MAIN variants, only files from the same family (archive name) count.
function Get-NexusModUpdate($FilesResponse, $Installed) {
    $main = @(@($FilesResponse.files) | Where-Object { [string]$_.category_name -eq 'MAIN' })
    if ($main.Count -eq 0) { return $null }
    if ($Installed.family) {
        $fam = $Installed.family.ToLowerInvariant()
        $same = @($main | Where-Object { ([string]$_.file_name).ToLowerInvariant() -like "$fam-$($Installed.id)-*" })
        if ($same.Count -gt 0) { $main = $same }
    }
    $newest = $main | Sort-Object { [long]$_.uploaded_timestamp } -Descending | Select-Object -First 1
    $newer = $false
    if ($Installed.ts -gt 0) {
        $newer = ([long]$newest.uploaded_timestamp -gt ($Installed.ts + 120)) -and ((Normalize-Version $newest.version) -ne (Normalize-Version $Installed.version))
    } else {
        $newer = ((Normalize-Version $newest.version) -ne (Normalize-Version $Installed.version))
    }
    return [pscustomobject]@{ file = $newest; version = [string]$newest.version; ts = [long]$newest.uploaded_timestamp; newer = $newer }
}

# Frameworks update first, in dependency order; everything else follows by name.
$script:FrameworkOrder = @(2380, 107, 1511, 4198, 4197, 7780, 4575, 4885, 3518)
function Get-UpdateSortKey([int]$Id, [string]$Name) {
    $i = [array]::IndexOf($script:FrameworkOrder, $Id)
    if ($i -ge 0) { return ('0{0:D2}' -f $i) }
    return ('1' + $Name.ToLowerInvariant())
}

function Get-GameVersion([string]$GameDir) {
    $logDir = Join-Path $GameDir 'red4ext\logs'
    if (Test-Path -LiteralPath $logDir) {
        $f = Get-ChildItem -LiteralPath $logDir -Filter 'red4ext-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($f) {
            $m = Select-String -LiteralPath $f.FullName -Pattern 'Product version:\s*(\S+)' -List
            if ($m) { return $m.Matches[0].Groups[1].Value }
        }
    }
    $exe = Join-Path $GameDir 'bin\x64\Cyberpunk2077.exe'
    if (Test-Path -LiteralPath $exe) { try { $v = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion; if ($v) { return $v.Trim() } } catch {} }
    return ''
}

function Test-NxmHandler {
    if (-not $script:IsWin) { return $true }
    foreach ($k in 'Registry::HKEY_CURRENT_USER\Software\Classes\nxm\shell\open\command', 'Registry::HKEY_CLASSES_ROOT\nxm\shell\open\command') {
        try { $v = (Get-ItemProperty -LiteralPath $k -ErrorAction Stop).'(default)'; if ($v -match 'Vortex') { return $true } } catch {}
    }
    return $false
}

# ---------------------------------------------------------------- web helpers

function Get-HttpStatus($err) {
    try { if ($err.Exception.Response) { return [int]$err.Exception.Response.StatusCode } } catch {}
    # Fallback: PowerShell 5.1 says "(404) Not Found", PowerShell 7 says "404 (Not Found)".
    $m = [regex]::Match([string]$err.Exception.Message, '\(?\b([45]\d\d)\b\)?\s*\(?(Not Found|Unauthorized|Forbidden|Too Many Requests|Bad Request|Internal Server Error|Service Unavailable)')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return 0
}

function Invoke-Nexus([string]$Path, [string]$Key) {
    $h = @{ apikey = $Key; Accept = 'application/json'; 'Application-Name' = 'NightCityInstaller'; 'Application-Version' = $script:AppVersion }
    return Invoke-RestMethod -Method Get -Uri "$($script:NexusBase)/$Path" -Headers $h -TimeoutSec 30
}

# mod.io is moving from OAuth 2 access tokens to Personal Access Tokens. Both are sent the same
# way (Authorization: Bearer), so the app accepts either in the same field. The API path can be
# overridden with the one shown on mod.io/me/access (for example https://u-12345.modapi.io/v1).
function Set-ModioBase([string]$Path) {
    $p = ([string]$Path).Trim()
    if ($p -match '^https://[A-Za-z0-9.-]+(\.mod\.io|\.modapi\.io)(/v1)?/?$') {
        $p = $p.TrimEnd('/'); if ($p -notmatch '/v1$') { $p += '/v1' }
        $script:ModioBase = $p
    } else { $script:ModioBase = 'https://api.mod.io/v1' }
}

# OAuth 2 tokens from mod.io are JWE strings (five dot-separated parts starting with eyJ).
function Get-ModioTokenKind([string]$Token) {
    $t = ([string]$Token).Trim()
    if (-not $t) { return 'none' }
    if ($t -match '^eyJ[\w-]*\.[\w-]*\.[\w-]*\.[\w-]*\.[\w-]*$') { return 'oauth2' }
    return 'pat'
}

function Invoke-Modio([string]$Method, [string]$Path, [string]$Token) {
    $h = @{ Authorization = "Bearer $(([string]$Token).Trim())"; Accept = 'application/json'; 'X-Modio-Platform' = 'windows' }
    if ($Method -eq 'Post') {
        return Invoke-RestMethod -Method Post -Uri "$($script:ModioBase)/$Path" -Headers $h -ContentType 'application/x-www-form-urlencoded' -Body '' -TimeoutSec 30
    }
    return Invoke-RestMethod -Method Get -Uri "$($script:ModioBase)/$Path" -Headers $h -TimeoutSec 30
}

function UrlEnc([string]$s) { return [Uri]::EscapeDataString($s) }

# ---------------------------------------------------------------- Nexus logic

function ConvertFrom-Unix([long]$t) { return ([datetime]'1970-01-01Z').ToUniversalTime().AddSeconds($t) }

# Picks the file to install. Prefers the author's primary MAIN file when it was uploaded on or
# after the patch date, then the newest post-patch MAIN file, then (flagged) the best pre-patch one.
function Select-NexusMainFile($FilesResponse, [datetime]$PatchDate) {
    $all = @($FilesResponse.files)
    $main = @($all | Where-Object { [string]$_.category_name -eq 'MAIN' })
    if ($main.Count -eq 0) { $main = @($all | Where-Object { @('OLD_VERSION','ARCHIVED','DELETED','MISCELLANEOUS') -notcontains [string]$_.category_name }) }
    if ($main.Count -eq 0) { return $null }
    $withDate = foreach ($f in $main) { [pscustomobject]@{ file = $f; date = (ConvertFrom-Unix ([long]$f.uploaded_timestamp)); primary = [bool]$f.is_primary } }
    $post = @($withDate | Where-Object { $_.date -ge $PatchDate.ToUniversalTime() })
    $pick = $null
    if ($post.Count -gt 0) {
        $prim = @($post | Where-Object { $_.primary })
        if ($prim.Count -gt 0) { $pick = $prim | Sort-Object date -Descending | Select-Object -First 1 }
        else { $pick = $post | Sort-Object date -Descending | Select-Object -First 1 }
        return [pscustomobject]@{ file = $pick.file; date = $pick.date; postPatch = $true }
    }
    $prim = @($withDate | Where-Object { $_.primary })
    if ($prim.Count -gt 0) { $pick = $prim | Sort-Object date -Descending | Select-Object -First 1 }
    else { $pick = $withDate | Sort-Object date -Descending | Select-Object -First 1 }
    return [pscustomobject]@{ file = $pick.file; date = $pick.date; postPatch = $false }
}

function Get-NexusDownloadUrl([string]$Game, [int]$ModId, $FileId) {
    if ($FileId) { return "https://www.nexusmods.com/$Game/mods/$ModId`?tab=files&file_id=$FileId&nmm=1" }
    return "https://www.nexusmods.com/$Game/mods/$ModId`?tab=files"
}

# ---------------------------------------------------------------- mod.io logic

function Normalize-Name([string]$s) {
    if (-not $s) { return '' }
    $t = $s -replace '\[[^\]]*\]', ' '
    $t = $t -replace '^\s*(New Quest|QoL|HoV)\s*[-:\u2013\u2014]\s*', ''
    return (($t.ToLowerInvariant()) -replace '[^a-z0-9]', '')
}

function Select-ModioMatch($Results, [string]$Query, [string]$Exclude) {
    $cands = @($Results | Where-Object { -not ($Exclude -and ([string]$_.name).ToLowerInvariant().Contains($Exclude.ToLowerInvariant())) })
    $nq = Normalize-Name $Query
    $exact = @($cands | Where-Object { (Normalize-Name $_.name) -eq $nq -or ((([string]$_.name).ToLowerInvariant()) -replace '[^a-z0-9]', '') -eq $nq })
    if ($exact.Count -eq 1) { return [pscustomobject]@{ match = $exact[0]; choices = @() } }
    if ($exact.Count -gt 1) { return [pscustomobject]@{ match = $null; choices = $exact } }
    $contains = @($cands | Where-Object { (Normalize-Name $_.name).Contains($nq) })
    if ($contains.Count -eq 1) { return [pscustomobject]@{ match = $contains[0]; choices = @() } }
    if ($contains.Count -gt 1) { return [pscustomobject]@{ match = $null; choices = $contains } }
    return [pscustomobject]@{ match = $null; choices = @() }
}

function Select-MostPopular($Choices) {
    return (@($Choices) | Sort-Object -Property @{ Expression = { try { [long]$_.stats.downloads_total } catch { 0 } } } -Descending | Select-Object -First 1)
}

function Resolve-ModioGameId([string]$Token) {
    $r = Invoke-Modio Get 'games?name_id=cyberpunk2077' $Token
    $g = @($r.data) | Select-Object -First 1
    if (-not $g) {
        $r = Invoke-Modio Get ('games?_q=' + (UrlEnc 'Cyberpunk 2077')) $Token
        $g = @($r.data) | Where-Object { $_.name -match 'Cyberpunk 2077' } | Select-Object -First 1
    }
    if (-not $g) { throw 'Could not find Cyberpunk 2077 on mod.io.' }
    return [int]$g.id
}

function Get-ModioSubscribed([int]$GameId, [string]$Token) {
    $set = New-Object 'System.Collections.Generic.HashSet[int]'
    $offset = 0
    while ($true) {
        $r = Invoke-Modio Get "me/subscribed?game_id=$GameId&_limit=100&_offset=$offset" $Token
        foreach ($m in @($r.data)) { $null = $set.Add([int]$m.id) }
        $n = @($r.data).Count
        if ($n -lt 100) { break }
        $offset += 100
    }
    return ,$set
}

function Search-Modio([int]$GameId, [string]$Query, [string]$Token) {
    $r = Invoke-Modio Get "games/$GameId/mods?_q=$(UrlEnc $Query)&_limit=30" $Token
    return @($r.data)
}

function Get-ModioDependencies([int]$GameId, [int]$ModId, [string]$Token) {
    try { $r = Invoke-Modio Get "games/$GameId/mods/$ModId/dependencies" $Token } catch { if ((Get-HttpStatus $_) -eq 404) { return @() } else { throw } }
    return @($r.data)
}

function Add-ModioSubscription([int]$GameId, [int]$ModId, [string]$Token) {
    $null = Invoke-Modio Post "games/$GameId/mods/$ModId/subscribe" $Token
}

# ---------------------------------------------------------------- app self-update
# New versions are published to a GitHub repo as version.json plus the app files.
# version.json: { "version": "1.2.0", "notes": "...", "files": [ { "path": "NightCityInstaller.ps1", "sha256": "..." }, ... ] }
# The repo is public, so no token is needed. A token (Contents: Read-only) is only used if the repo is ever made private.

$script:UpdateRepo = 'Sirtacoburrito/NightCityInstaller'
$script:UpdateRef  = 'main'

function Save-RepoFile([string]$Path, [string]$Token, [string]$OutFile) {
    $h = @{ 'User-Agent' = 'NightCityInstaller'; Accept = 'application/vnd.github.raw+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    if ($Token) { $h['Authorization'] = "Bearer $Token" }
    $uri = "https://api.github.com/repos/$($script:UpdateRepo)/contents/$(UrlEnc $Path)?ref=$($script:UpdateRef)"
    Invoke-WebRequest -Uri $uri -Headers $h -OutFile $OutFile -UseBasicParsing -TimeoutSec 60 | Out-Null
}

function Test-SafeFileName([string]$Name) { return ($Name -match '^[A-Za-z0-9][A-Za-z0-9 ._-]*$' -and $Name -notmatch '\.\.') }

# Returns the parsed version.json when it offers a newer version than this app, otherwise $null.
function Test-AppUpdate([string]$Token) {
    Ensure-DataDir
    $tmp = Join-Path $script:DataDir 'version-check.json'
    try { Save-RepoFile 'version.json' $Token $tmp }
    catch {
        $code = Get-HttpStatus $_
        if ($code -eq 404 -and -not $Token) { throw 'The update repo could not be found. It may have been made private or renamed; a GitHub token under Accounts is only needed for a private repo.' }
        if ($code -eq 404 -or $code -eq 401) { throw 'GitHub refused access. If you added a GitHub token under Accounts, check it, or clear it (the public repo needs none).' }
        throw
    }
    $j = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    if (-not $j.version) { throw 'version.json in the update repo has no version.' }
    if ([version]$j.version -gt [version]$script:AppVersion) { return $j }
    return $null
}

# Downloads every file, checks its SHA-256, backs up the current files, then swaps them in.
function Install-AppUpdate($Info, [string]$Token) {
    $stage = Join-Path $script:DataDir ('update-' + $Info.version)
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    $files = @($Info.files)
    if ($files.Count -eq 0) { throw 'The update lists no files.' }
    foreach ($f in $files) {
        $name = [string]$f.path
        if (-not (Test-SafeFileName $name)) { throw "The update contains an unsafe file name: $name" }
        $out = Join-Path $stage $name
        Save-RepoFile $name $Token $out
        $hash = (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash
        if ($hash -ine [string]$f.sha256) { throw "Download check failed for $name. Nothing was changed." }
    }
    $backup = Join-Path $script:DataDir ('backup-' + $script:AppVersion)
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach ($f in $files) {
        $cur = Join-Path $script:Root ([string]$f.path)
        if (Test-Path -LiteralPath $cur) { Copy-Item -LiteralPath $cur -Destination (Join-Path $backup ([string]$f.path)) -Force }
    }
    foreach ($f in $files) { Copy-Item -LiteralPath (Join-Path $stage ([string]$f.path)) -Destination (Join-Path $script:Root ([string]$f.path)) -Force }
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    return $backup
}

# ---------------------------------------------------------------- engine (UI-independent)
# The UI object supplies: Log(msg) SetStatus(key,status,detail) Banner(text, [string[]]buttons) OpenUrl(url) Choose(title, items) -> index or -1

function New-Engine($Manifest, $Config, $State, $UI) {
    return [pscustomobject]@{
        manifest = $Manifest; config = $Config; state = $State; ui = $UI
        queue = @(); pos = 0; mode = 'idle'; current = $null; purpose = 'install'; modioNoted = $false; updates = @{}
        currentBatch = 0; workInBatch = 0; lastSource = ''
        waitStart = [datetime]::MinValue; reminded = $false; sleepUntil = [datetime]::MinValue
        installed = $null; subscribed = $null
        counts = @{ installed = 0; subscribed = 0; skipped = 0; already = 0; failed = 0 }
        clock = { [datetime]::UtcNow }
    }
}

function Set-ItemState($E, $Item, [string]$Status, [string]$Detail, [bool]$Done) {
    if ($Item.kind -ne 'update') {
        $E.state[$Item.key] = @{ status = $Status; detail = $Detail; done = $Done }
        Save-State $E.state
    }
    $E.ui.SetStatus($Item.key, $Status, $Detail)
}

function Start-Engine($E, [string[]]$CheckedKeys) {
    $E.queue = @($E.manifest.items | Where-Object { $CheckedKeys -contains $_.key -and -not ($E.state.ContainsKey($_.key) -and $E.state[$_.key].done) } | Sort-Object order)
    $E.pos = 0; $E.current = $null; $E.currentBatch = 0; $E.workInBatch = 0
    if ($E.queue.Count -eq 0) { $E.mode = 'done'; $E.ui.Banner('Nothing to do: every ticked mod is already installed or skipped.', @()); return }
    $E.mode = 'running'
    $nm = @($E.queue | Where-Object { $_.source -eq 'modio' }).Count
    $E.ui.Log("Starting: $($E.queue.Count) mods queued. The $nm mod.io mods go first (no clicks needed), then the Nexus mods.")
}

# Queue Nexus updates (rows from the update check) instead of the install list.
function Start-UpdateEngine($E, $Updates) {
    $E.purpose = 'update'
    $E.queue = @($Updates | ForEach-Object {
        [pscustomobject]@{ key = "update:$($_.id)"; kind = 'update'; order = 0; batch = 0; source = 'nexus'; name = $_.name
            id = [int]$_.id; fileId = $_.fileId; version = $_.latest; minTs = [long]$_.latestTs; query = ''; exclude = ''; optional = $false } })
    $E.pos = 0; $E.current = $null; $E.currentBatch = 0; $E.workInBatch = 0
    if ($E.queue.Count -eq 0) { $E.mode = 'done'; $E.ui.Banner('No updates ticked.', @()); return }
    $E.mode = 'running'
    $E.ui.Log("Updating $($E.queue.Count) mods.")
}

# ---- update checker: one mod per Step call so the window stays responsive

function New-UpdateChecker($Config, $State, $UI) {
    return [pscustomobject]@{ config = $Config; state = $State; ui = $UI; todo = @(); pos = 0; results = (New-Object System.Collections.ArrayList); done = $false; phase = 'nexus' }
}

function Start-UpdateCheck($C) {
    $mods = Get-InstalledNexusMods $C.config.gameDir
    $C.todo = @($mods.Values | Sort-Object { Get-UpdateSortKey $_.id $_.name })
    $C.pos = 0; $C.results.Clear(); $C.done = $false
    $C.phase = if ($C.config.nexusKey) { 'nexus' } else { 'modio' }
    if (-not $C.config.nexusKey) {
        foreach ($m in $C.todo) {
            $row = [pscustomobject]@{ key = "upd:$($m.id)"; source = 'Nexus'; id = $m.id; name = $m.name; installed = $m.version; latest = ''; latestTs = 0; fileId = $null; status = 'Add a Nexus key under Accounts to check'; update = $false; framework = ($script:FrameworkOrder -contains $m.id) }
            $null = $C.results.Add($row); $C.ui.UpdateRow($row)
        }
    }
}

function Step-UpdateCheck($C) {
    if ($C.done) { return }
    if ($C.phase -eq 'nexus') {
        if ($C.pos -ge $C.todo.Count) { $C.phase = 'modio'; return }
        $m = $C.todo[$C.pos]; $C.pos++
        $row = [pscustomobject]@{ key = "upd:$($m.id)"; source = 'Nexus'; id = $m.id; name = $m.name; installed = $m.version; latest = ''; latestTs = 0; fileId = $null; status = ''; update = $false; framework = ($script:FrameworkOrder -contains $m.id) }
        try {
            $files = Invoke-Nexus "games/cyberpunk2077/mods/$($m.id)/files.json" $C.config.nexusKey
            $u = Get-NexusModUpdate $files $m
            if (-not $u) { $row.status = 'No main file on Nexus' }
            else {
                $row.latest = $u.version; $row.latestTs = $u.ts; $row.fileId = $u.file.file_id
                if ($u.newer) { $row.update = $true; $row.status = 'Update available (' + (ConvertFrom-Unix $u.ts).ToString('yyyy-MM-dd') + ')' } else { $row.status = 'Up to date' }
            }
        } catch {
            $code = Get-HttpStatus $_
            $row.status = if ($code -eq 404) { 'Not on Nexus (hidden or removed)' } elseif ($code -eq 401) { 'Nexus key rejected' } else { 'Check failed: ' + $_.Exception.Message }
        }
        $null = $C.results.Add($row)
        $C.ui.UpdateRow($row)
        return
    }
    if ($C.phase -eq 'modio') {
        $C.phase = 'end'
        if ($C.config.modioToken) {
            try {
                if (-not $C.config.modioGameId) { $C.config.modioGameId = Resolve-ModioGameId $C.config.modioToken; Save-Config $C.config }
                $seen = @{}
                if ($C.state.ContainsKey('__modioSeen') -and $C.state['__modioSeen'].detail) { $seen = ConvertFrom-SeenString $C.state['__modioSeen'].detail }
                $subs = Get-ModioSubscribedDetails $C.config.modioGameId $C.config.modioToken
                $newSeen = @{}
                foreach ($s in $subs) {
                    $newSeen["$($s.id)"] = [long]$s.date_updated
                    $prev = if ($seen.ContainsKey("$($s.id)")) { [long]$seen["$($s.id)"] } else { 0 }
                    $ver = ''; try { $ver = [string]$s.modfile.version } catch {}
                    $st = if ($prev -gt 0 -and [long]$s.date_updated -gt $prev) { 'Updated ' + (ConvertFrom-Unix ([long]$s.date_updated)).ToString('yyyy-MM-dd') + ': the game installs it on next launch' } else { 'Up to date (the game keeps mod.io mods updated)' }
                    $row = [pscustomobject]@{ key = "updm:$($s.id)"; source = 'mod.io'; id = [int]$s.id; name = [string]$s.name; installed = ''; latest = $ver; latestTs = [long]$s.date_updated; fileId = $null; status = $st; update = $false; framework = $false }
                    $null = $C.results.Add($row); $C.ui.UpdateRow($row)
                }
                $C.state['__modioSeen'] = @{ status = ''; detail = (ConvertTo-SeenString $newSeen); done = $false }
                Save-State $C.state
            } catch { $C.ui.Log('mod.io check failed: ' + $_.Exception.Message) }
        }
        return
    }
    $C.done = $true
    $n = @($C.results | Where-Object { $_.update }).Count
    $C.state['__lastCheck'] = @{ status = ''; detail = (Get-Date).ToString('yyyy-MM-dd HH:mm'); done = $false }
    Save-State $C.state
    $C.ui.CheckFinished($n)
}

function ConvertTo-SeenString($h) { return (($h.Keys | ForEach-Object { "$_=$($h[$_])" }) -join ';') }
function ConvertFrom-SeenString([string]$s) { $h = @{}; foreach ($p in ($s -split ';')) { if ($p -match '^(\d+)=(\d+)$') { $h[$Matches[1]] = [long]$Matches[2] } }; return $h }

function Get-ModioSubscribedDetails([int]$GameId, [string]$Token) {
    $all = New-Object System.Collections.ArrayList
    $offset = 0
    while ($true) {
        $r = Invoke-Modio Get "me/subscribed?game_id=$GameId&_limit=100&_offset=$offset" $Token
        foreach ($m in @($r.data)) { $null = $all.Add($m) }
        if (@($r.data).Count -lt 100) { break }
        $offset += 100
    }
    return $all
}

function Complete-Item($E, [string]$Kind) {
    switch ($Kind) {
        'installed'  { $E.counts.installed++;  $E.workInBatch++ }
        'subscribed' { $E.counts.subscribed++; $E.workInBatch++ }
        'skipped'    { $E.counts.skipped++ }
        'already'    { $E.counts.already++ }
        'failed'     { $E.counts.failed++ }
    }
    $E.current = $null; $E.pos++; $E.mode = 'running'; $E.reminded = $false
}

function Get-CheckpointText($E, [int]$BatchId) {
    $b = $E.manifest.batches[$BatchId]
    if ($b.source -eq 'modio') {
        return "Batch done: $($b.name). Start the game and open Mods from the main menu so it downloads your new mod.io subscriptions (sign in with the same mod.io account). Load a save, check that everything works, close the game, then click Continue."
    }
    return "Batch done: $($b.name). Vortex deploys automatically, so start the game now, load a save and check that it runs. Close the game, then click Continue."
}

function Step-Engine($E) {
    $now = & $E.clock
    if ($now -lt $E.sleepUntil) { return }
    switch ($E.mode) {
        'waitNexus' {
            if (Test-NexusInstalled $E.config.gameDir $E.current) {
                $verb = if ($E.current.kind -eq 'update') { 'Updated' } else { 'Installed' }
                Set-ItemState $E $E.current $verb "$verb by Vortex" $true
                $E.ui.Log("${verb}: $($E.current.name)")
                Complete-Item $E 'installed'
            } elseif (-not $E.reminded -and ($now - $E.waitStart).TotalMinutes -ge 10) {
                $E.reminded = $true
                $E.ui.Banner("Still waiting for $($E.current.name). If Vortex already installed it, click 'It's installed'. If the download didn't start, open the page again and click 'Slow download' (or 'Mod manager download').", @('Open page again', "It's installed", 'Skip'))
            }
            return
        }
        'running' { }
        default { return }
    }

    if ($E.pos -ge $E.queue.Count -and $E.purpose -eq 'update') {
        $E.mode = 'done'
        $c = $E.counts
        $E.ui.Banner("Updates finished. Updated $($c.installed), $($c.already) were already current, $($c.skipped) skipped, $($c.failed) failed. Start the game once to make sure everything loads.", @())
        $E.ui.Log('Updates done.')
        return
    }
    if ($E.pos -ge $E.queue.Count) {
        $E.mode = 'done'
        $c = $E.counts
        $E.ui.Banner("Finished. Installed $($c.installed) from Nexus, subscribed to $($c.subscribed) on mod.io, $($c.already) were already in place, $($c.skipped) skipped, $($c.failed) failed. Start the game once more so it downloads the last mod.io subscriptions.", @())
        $E.ui.Log('All done.')
        return
    }

    $item = $E.queue[$E.pos]

    if ($E.purpose -eq 'install' -and $item.source -eq 'nexus' -and $E.pos -gt 0 -and $E.queue[$E.pos - 1].source -eq 'modio' -and $E.counts.subscribed -gt 0 -and -not $E.modioNoted) {
        $E.modioNoted = $true
        $E.ui.Log("mod.io done: subscribed to $($E.counts.subscribed) mods. Start the game and open Mods > My Collection to download them (any time, even while the Nexus part runs).")
    }

    # batch checkpoint
    if ($E.config.pauseBetweenBatches -and $E.currentBatch -ne 0 -and $item.batch -ne $E.currentBatch -and $E.workInBatch -gt 0) {
        $E.mode = 'checkpoint'
        $E.ui.Banner((Get-CheckpointText $E $E.currentBatch), @('Continue'))
        return
    }
    if ($item.batch -ne $E.currentBatch) { $E.currentBatch = $item.batch; $E.workInBatch = 0 }

    $E.current = $item
    try {
        if ($item.source -eq 'nexus') { Step-Nexus $E $item } else { Step-Modio $E $item }
    } catch {
        $code = Get-HttpStatus $_
        if ($code -eq 429) {
            $E.sleepUntil = $now.AddSeconds(60)
            $E.ui.Log("Rate limited by the server. Waiting a minute before retrying $($item.name).")
            $E.current = $null
            return
        }
        $msg = $_.Exception.Message
        if ($code -eq 401) { $msg = 'The key or token was rejected. Check it under Accounts.' }
        Set-ItemState $E $item 'Failed' $msg $false
        $E.ui.Log("Failed: $($item.name): $msg")
        Complete-Item $E 'failed'
    }
}

function Step-Nexus($E, $item) {
    if ($item.kind -eq 'update') {
        if (Test-NexusInstalled $E.config.gameDir $item) {
            Set-ItemState $E $item 'Up to date' 'Already on the newest file' $true
            Complete-Item $E 'already'; return
        }
        Open-NexusItem $E $item (Get-NexusDownloadUrl $E.manifest.game $item.id $item.fileId) "Updating to v$($item.version)"
        return
    }
    $ids = Get-InstalledNexusIds $E.config.gameDir
    if ($ids.Contains($item.id) -and $E.updates -and $E.updates.ContainsKey([int]$item.id)) {
        # work on a copy so the list entry itself stays an ordinary install item
        $u = $E.updates[[int]$item.id]
        $upd = $item.PSObject.Copy()
        $upd | Add-Member -NotePropertyName minTs -NotePropertyValue ([long]$u.latestTs) -Force
        $upd.kind = 'update'
        $E.current = $upd
        Open-NexusItem $E $upd (Get-NexusDownloadUrl $E.manifest.game $item.id $u.fileId) "Updating to v$($u.latest)"
        return
    }
    if ($ids.Contains($item.id)) {
        Set-ItemState $E $item 'Already installed' 'Found in Vortex' $true
        Complete-Item $E 'already'
        return
    }
    $fileId = $null; $detail = 'Pick the newest main file'
    if ($item.verify -and -not $E.config.nexusKey) {
        # These mods have no published 2.5 confirmation, so they only install after the app has
        # checked Nexus for a post-patch file. That check needs the Nexus key.
        Set-ItemState $E $item 'Needs Nexus key' 'Add your Nexus key under Accounts so the app can confirm a 2.5 file' $false
        $E.ui.Log("Skipped $($item.name): needs the Nexus key to confirm a 2.5 file.")
        Complete-Item $E 'skipped'
        return
    }
    if ($E.config.nexusKey) {
        $files = Invoke-Nexus "games/$($E.manifest.game)/mods/$($item.id)/files.json" $E.config.nexusKey
        $sel = Select-NexusMainFile $files $E.manifest.patchDate
        if (-not $sel) {
            Set-ItemState $E $item 'Failed' 'No downloadable main file on Nexus' $false
            Complete-Item $E 'failed'; return
        }
        $fileId = $sel.file.file_id
        $detail = "v$($sel.file.version), uploaded $($sel.date.ToString('yyyy-MM-dd'))"
        if (-not $sel.postPatch) {
            # Keep the setup 2.5-safe without asking: a file older than the patch is skipped, and
            # left open (not done) so a later run installs it once the author posts a 2.5 file.
            Set-ItemState $E $item 'Waiting for 2.5 update' "Newest file ($detail) is older than patch 2.5" $false
            $E.ui.Log("Waiting: $($item.name) has no 2.5 file yet. It will install once the author posts one.")
            Complete-Item $E 'skipped'
            return
        }
    }
    Open-NexusItem $E $item (Get-NexusDownloadUrl $E.manifest.game $item.id $fileId) $detail
}

function Open-NexusItem($E, $item, [string]$Url, [string]$Detail) {
    $E.current | Add-Member -NotePropertyName pendingUrl -NotePropertyValue $Url -Force
    $E.ui.OpenUrl($Url)
    $E.mode = 'waitNexus'; $E.waitStart = (& $E.clock); $E.reminded = $false
    $E.ui.SetStatus($item.key, 'Waiting for your click', $Detail)
    $E.ui.Banner("Your browser opened $($item.name) on Nexus. Click 'Slow download' (or 'Mod manager download'). Vortex downloads and installs it, and this app moves on by itself.", @('Open page again', "It's installed", 'Skip'))
}

function Step-Modio($E, $item) {
    $tok = $E.config.modioToken
    if (-not $tok) {
        Set-ItemState $E $item 'Needs mod.io token' 'Add your mod.io token under Accounts, then click Start again' $false
        Complete-Item $E 'skipped'
        return
    }
    if (-not $E.config.modioGameId) { $E.config.modioGameId = Resolve-ModioGameId $tok; Save-Config $E.config }
    $gid = $E.config.modioGameId
    if (-not $E.subscribed) {
        try { $me = Invoke-Modio Get 'me' $tok; $E.ui.Log("mod.io: subscribing for account '$($me.username)'. This must be the account linked in the game's Mods menu.") } catch {}
        $E.subscribed = Get-ModioSubscribed $gid $tok
    }

    $mod = $null; $sel = [pscustomobject]@{ match = $null; choices = @() }
    if ($item.modioId) { $mod = [pscustomobject]@{ id = [int]$item.modioId; name = $item.name } }
    else {
        $results = Search-Modio $gid $item.query $tok
        $sel = Select-ModioMatch $results $item.query $item.exclude
        $mod = $sel.match
    }
    if (-not $mod -and $sel.choices.Count -gt 0) {
        # No prompt: take the most-downloaded match and record the choice.
        $mod = Select-MostPopular $sel.choices
        $others = @($sel.choices | Where-Object { $_.id -ne $mod.id } | ForEach-Object { $_.name }) -join '; '
        $E.ui.Log("Several matches for '$($item.query)'. Picked the most downloaded: '$($mod.name)'. Others: $others")
    }
    if (-not $mod) {
        Set-ItemState $E $item 'Not found' "No mod.io match for '$($item.query)'. It may have been removed from the catalog." $false
        $E.ui.Log("Not found on mod.io: $($item.name)")
        Complete-Item $E 'failed'; return
    }
    $mid = [int]$mod.id
    if ($E.subscribed.Contains($mid)) {
        Set-ItemState $E $item 'Already subscribed' ([string]$mod.name) $true
        Complete-Item $E 'already'; return
    }
    foreach ($dep in (Get-ModioDependencies $gid $mid $tok)) {
        $did = [int]$dep.mod_id
        if ($did -and -not $E.subscribed.Contains($did)) {
            Add-ModioSubscription $gid $did $tok
            $null = $E.subscribed.Add($did)
            $E.ui.Log("Subscribed to requirement '$($dep.name)' for $($item.name)")
        }
    }
    Add-ModioSubscription $gid $mid $tok
    $null = $E.subscribed.Add($mid)
    Set-ItemState $E $item 'Subscribed' ([string]$mod.name) $true
    $E.ui.Log("Subscribed: $($mod.name)")
    Complete-Item $E 'subscribed'
}

# Banner button handler, shared by the GUI and tests.
function Invoke-EngineAction($E, [string]$Action) {
    $item = $E.current
    switch ($Action) {
        'Continue'        { if ($E.mode -eq 'checkpoint') { $E.workInBatch = 0; $E.currentBatch = 0; $E.mode = 'running'; $E.ui.Banner('', @()) } }
        'Open page again' { if ($item -and $item.pendingUrl) { $E.ui.OpenUrl($item.pendingUrl) } }
        "It's installed"  { if ($item) { Set-ItemState $E $item 'Installed' 'Marked installed by you' $true; $E.ui.Log("Marked installed: $($item.name)"); Complete-Item $E 'installed'; $E.ui.Banner('', @()) } }
        'Skip'            { if ($item) { Set-ItemState $E $item 'Skipped' 'Skipped by you' $true; $E.ui.Log("Skipped: $($item.name)"); Complete-Item $E 'skipped'; $E.ui.Banner('', @()) } }
    }
}

# What is already in place for every list item, without asking any server about Nexus:
# Nexus mods come from Vortex's files; mod.io mods are matched against your subscriptions
# (pass $null when there is no mod.io token, and those rows stay "unknown").
function Get-InstallSnapshot($Manifest, [string]$GameDir, $ModioSubs) {
    $snap = @{}
    $nexus = Get-InstalledNexusMods $GameDir
    foreach ($it in $Manifest.items) {
        if ($it.source -eq 'nexus') {
            if ($nexus.ContainsKey($it.id)) { $snap[$it.key] = [pscustomobject]@{ installed = $true; detail = "v$($nexus[$it.id].version) in Vortex" } }
            else { $snap[$it.key] = [pscustomobject]@{ installed = $false; detail = '' } }
        } elseif ($null -ne $ModioSubs) {
            if ($it.modioId) { $hit = @($ModioSubs | Where-Object { [int]$_.id -eq [int]$it.modioId }) | Select-Object -First 1 }
            else {
                $sel = Select-ModioMatch $ModioSubs $it.query $it.exclude
                $hit = $sel.match
            }
            if (-not $hit -and -not $it.modioId -and $sel.choices.Count -gt 0) { $hit = $sel.choices[0] }
            if ($hit) { $snap[$it.key] = [pscustomobject]@{ installed = $true; detail = "Subscribed: $($hit.name)" } }
            else { $snap[$it.key] = [pscustomobject]@{ installed = $false; detail = '' } }
        }
    }
    return $snap
}

# ---------------------------------------------------------------- discovery
# On start-up the app looks for more mods that work with the current game version and adds them
# to the list as unticked "Discovered" groups, remembered in discovered.json between runs.
#  - Nexus: mods whose latest file was uploaded after the patch (Nexus "updated" feed, plus the
#    trending / latest lists), filtered for quality and for clashes with this setup. They are
#    "verify" mods: the installer re-checks the post-patch file before installing.
#  - mod.io: every mod in the official catalog, which CD PROJEKT RED approves for the current patch.

$script:DiscoveryRules = @(
    @{ re = '\bhud\b'; why = 'HUD mods clash with your custom HUD layout' },
    @{ re = 'dismember'; why = 'Clashes with Relentless Live Dismember' },
    @{ re = 'dual[ -]?wield|akimbo'; why = 'Overlaps Expanded Dual Wielding' },
    @{ re = 'wardrobe'; why = 'Overlaps Equipment-EX' },
    @{ re = 'flashlight'; why = 'You already have Simple Flashlight' },
    @{ re = 'load game menu|save (game )?menu'; why = 'Overlaps Filter Saves by Lifepath and Type' },
    @{ re = 'zoom(able)? scope|magnify'; why = 'You already have Zoomable Scopes' },
    @{ re = '2\.31 and lower|\bfor (patch |game )?2\.(0|1|2|3)[0-9]?\b|\bpre[- ]?2\.5\b'; why = 'Made for an older game version' },
    @{ re = 'unofficial (fix|patch|build)|community[- ]fix'; why = 'Unofficial framework build' },
    @{ re = '\btrainer\b'; why = 'External trainer tool' },
    @{ re = '\bamm\b|appearance menu mod|\bacu\b|appearance change unlocker'; why = 'Needs AMM or ACU, which have no 2.5 build yet' },
    @{ re = 'reshade'; why = 'Needs ReShade installed outside Vortex' },
    @{ re = '\bpreset\b'; why = 'Character preset (needs other tools)' },
    @{ re = "translation|locali[sz]ation|language pack|traduc|bersetzung|\b(rus|chs|cht|ptbr|pt-br)\b|_(ru|cn|chs|cht|ptbr|br|es|fr|de|pl|jp|kr)\b|german|french|spanish|italian|polish|japanese|korean|chinese|russian|turkish|ukrainian|portuguese|brazilian|\bportugu"; why = 'Translation of another mod' },
    @{ re = "modders? resource|\btemplate\b|tutorial|\bguide\b|\bwolvenkit\b"; why = 'Resource or guide for modders' }
)

function Get-DiscoveryBlockReason([string]$Name) {
    foreach ($r in $script:DiscoveryRules) { if ($Name -imatch $r.re) { return $r.why } }
    return $null
}

function Read-DiscoveryStore {
    $d = Read-JsonFile (Join-Path $script:DataDir 'discovered.json')
    $store = @{ nexus = @{}; modio = @{} }
    if ($d) {
        foreach ($k in 'nexus', 'modio') {
            if ($d.PSObject.Properties[$k]) { foreach ($p in $d.$k.PSObject.Properties) { $store[$k][$p.Name] = $p.Value } }
        }
    }
    return $store
}
function Save-DiscoveryStore($Store) { Write-JsonFile (Join-Path $script:DataDir 'discovered.json') $Store }

function ConvertTo-NexusRecord($Obj, [long]$FileTs, [long]$PatchTs) {
    $name = [string]$Obj.name
    $why = $null
    if (-not $Obj.available -or ([string]$Obj.status -and [string]$Obj.status -ne 'published')) { $why = 'Not available on Nexus' }
    if (-not $why) { $why = Get-DiscoveryBlockReason $name }
    $end = 0; try { $end = [int]$Obj.endorsement_count } catch {}
    $dl = 0; try { $dl = [int]$Obj.mod_downloads } catch {}
    if (-not $why -and $end -lt 10 -and $dl -lt 1000) { $why = 'Little-used so far (under 10 endorsements and 1,000 downloads)' }
    $ts = if ($FileTs -gt 0) { $FileTs } else { [long]$Obj.updated_timestamp }
    if (-not $why -and $ts -lt $PatchTs) { $why = 'No file since the patch' }
    return [pscustomobject]@{ id = [int]$Obj.mod_id; name = $name; adult = [bool]$Obj.contains_adult_content; endorse = $end; downloads = $dl
        ts = $ts; accepted = (-not $why); reason = [string]$why; checked = [long]([datetimeoffset][datetime]::UtcNow).ToUnixTimeSeconds() }
}

function New-Discovery($Manifest, $Config, $Store, $InstalledIds, $UI) {
    return [pscustomobject]@{ manifest = $Manifest; config = $Config; store = $Store; installed = $InstalledIds; ui = $UI
        phase = 'nexus-list'; queue = @(); pos = 0; budget = 60; done = $false; newKeys = (New-Object System.Collections.ArrayList)
        patchTs = [long]([datetimeoffset]$Manifest.patchDate.ToUniversalTime()).ToUnixTimeSeconds() }
}

function Test-InManifest($Manifest, [string]$Key) { return [bool]($Manifest.items | Where-Object { $_.key -eq $Key } | Select-Object -First 1) }

function Step-Discovery($D) {
    if ($D.done) { return }
    $game = $D.manifest.game
    $now = [long]([datetimeoffset][datetime]::UtcNow).ToUnixTimeSeconds()
    switch ($D.phase) {
        'nexus-list' {
            $D.phase = 'nexus-details'
            if (-not $D.config.nexusKey) { $D.phase = 'modio'; return }
            $key = $D.config.nexusKey
            $cands = @{}
            try {
                foreach ($u in @(Invoke-Nexus "games/$game/mods/updated.json?period=1m" $key)) {
                    if ([long]$u.latest_file_update -ge $D.patchTs) { $cands[[int]$u.mod_id] = [long]$u.latest_file_update }
                }
            } catch { $D.ui.Log('Discovery: Nexus update feed failed: ' + $_.Exception.Message) }
            foreach ($feed in 'trending', 'latest_added', 'latest_updated') {
                try {
                    foreach ($o in @(Invoke-Nexus "games/$game/mods/$feed.json" $key)) {
                        $id = [int]$o.mod_id
                        if ($D.store.nexus.ContainsKey("$id") -or $D.installed.Contains($id) -or (Test-InManifest $D.manifest "nexus:$id")) { continue }
                        $fts = if ($cands.ContainsKey($id)) { $cands[$id] } else { 0 }
                        $D.store.nexus["$id"] = ConvertTo-NexusRecord $o $fts $D.patchTs
                    }
                } catch { $D.ui.Log("Discovery: Nexus $feed list failed: " + $_.Exception.Message) }
            }
            $todo = foreach ($id in ($cands.Keys | Sort-Object { $cands[$_] } -Descending)) {
                if ($D.installed.Contains($id) -or (Test-InManifest $D.manifest "nexus:$id")) { continue }
                $rec = $D.store.nexus["$id"]
                # look again at mods rejected only for being little-used, once a week
                if ($rec -and -not ($rec.reason -like 'Little-used*' -and ($now - [long]$rec.checked) -gt 604800)) { continue }
                [pscustomobject]@{ id = $id; fts = $cands[$id] }
            }
            $D.queue = @($todo | Select-Object -First $D.budget)
            $D.pos = 0
            return
        }
        'nexus-details' {
            if ($D.pos -ge $D.queue.Count) { $D.phase = 'modio'; return }
            $c = $D.queue[$D.pos]; $D.pos++
            try {
                $o = Invoke-Nexus "games/$game/mods/$($c.id).json" $D.config.nexusKey
                $D.store.nexus["$($c.id)"] = ConvertTo-NexusRecord $o $c.fts $D.patchTs
            } catch {
                $code = Get-HttpStatus $_
                if ($code -eq 429) { $D.ui.Log('Discovery: Nexus rate limit reached; carrying on next time.'); $D.phase = 'modio' }
                elseif ($code -in @(403, 404)) { $D.store.nexus["$($c.id)"] = [pscustomobject]@{ id = $c.id; name = ''; adult = $false; endorse = 0; downloads = 0; ts = $c.fts; accepted = $false; reason = 'Hidden or removed'; checked = $now } }
            }
            return
        }
        'modio' {
            $D.phase = 'finish'
            $tok = $D.config.modioToken
            if (-not $tok) { return }
            try {
                if (-not $D.config.modioGameId) { $D.config.modioGameId = Resolve-ModioGameId $tok; Save-Config $D.config }
                $gid = $D.config.modioGameId
                $known = @($D.manifest.items | Where-Object { $_.source -eq 'modio' })
                $offset = 0
                while ($offset -lt 2000) {
                    $r = Invoke-Modio Get "games/$gid/mods?_limit=100&_offset=$offset" $tok
                    foreach ($m in @($r.data)) {
                        $mid = [int]$m.id
                        if ($D.store.modio.ContainsKey("$mid")) { continue }
                        $listed = $false
                        foreach ($k in $known) { if (-not $k.modioId -and (Select-ModioMatch @($m) $k.query $k.exclude).match) { $listed = $true; break } }
                        $mature = $false; try { $mature = ([int]$m.maturity_option -gt 0) } catch {}
                        $D.store.modio["$mid"] = [pscustomobject]@{ id = $mid; name = [string]$m.name; mature = $mature; accepted = (-not $listed); reason = $(if ($listed) { 'Already in the list' } else { '' }); checked = $now }
                    }
                    if (@($r.data).Count -lt 100) { break }
                    $offset += 100
                }
            } catch { $D.ui.Log('Discovery: mod.io catalog failed: ' + $_.Exception.Message) }
            return
        }
        'finish' {
            Save-DiscoveryStore $D.store
            foreach ($it in (Add-DiscoveredToManifest $D.manifest $D.store $D.installed)) { $null = $D.newKeys.Add($it.key) }
            $D.done = $true
            $D.ui.DiscoveryFinished(@($D.newKeys))
            return
        }
    }
}

# Adds accepted discoveries that are not yet in the list. Returns the items it added.
function Add-DiscoveredToManifest($Manifest, $Store, $InstalledIds) {
    $defs = @{ 90 = @('Discovered on mod.io', 'modio'); 91 = @('Discovered on mod.io (mature)', 'modio'); 92 = @('Discovered on Nexus (new 2.5 files)', 'nexus'); 93 = @('Discovered on Nexus (adult 18+)', 'nexus') }
    foreach ($b in $defs.Keys) { if (-not $Manifest.batches.ContainsKey($b)) { $Manifest.batches[$b] = [pscustomobject]@{ id = $b; name = $defs[$b][0]; source = $defs[$b][1] } } }
    $added = New-Object System.Collections.ArrayList
    $order = @($Manifest.items).Count
    foreach ($rec in @($Store.modio.Values | Sort-Object { [string]$_.name })) {
        if (-not $rec.accepted) { continue }
        $key = "modio:id:$($rec.id)"
        if (Test-InManifest $Manifest $key) { continue }
        $it = [pscustomobject]@{ key = $key; kind = 'install'; order = $order++; batch = $(if ($rec.mature) { 91 } else { 90 }); source = 'modio'; name = [string]$rec.name
            id = 0; query = [string]$rec.name; exclude = ''; optional = [bool]$rec.mature; verify = $false; note = 'Found in the official mod.io catalog (approved for this patch)'; modioId = [int]$rec.id; discovered = $true }
        $null = $Manifest.items.Add($it); $null = $added.Add($it)
    }
    foreach ($rec in @($Store.nexus.Values | Sort-Object { [int]$_.endorse } -Descending)) {
        if (-not $rec.accepted) { continue }
        $id = [int]$rec.id
        if ($InstalledIds -and $InstalledIds.Contains($id)) { continue }
        $key = "nexus:$id"
        if (Test-InManifest $Manifest $key) { continue }
        $it = [pscustomobject]@{ key = $key; kind = 'install'; order = $order++; batch = $(if ($rec.adult) { 93 } else { 92 }); source = 'nexus'; name = [string]$rec.name
            id = $id; query = ''; exclude = ''; optional = $true; verify = $true
            note = "Found on Nexus: $($rec.endorse) endorsements. Check its page for extra requirements before ticking."; modioId = 0; discovered = $true }
        $null = $Manifest.items.Add($it); $null = $added.Add($it)
    }
    return $added
}

function Get-PreflightWarnings($Config) {
    $w = New-Object System.Collections.ArrayList
    if (-not $Config.gameDir -or -not (Test-Path -LiteralPath (Join-Path $Config.gameDir 'bin\x64\Cyberpunk2077.exe'))) {
        $null = $w.Add('Choose your Cyberpunk 2077 folder (the one that contains bin\x64\Cyberpunk2077.exe).')
        return $w
    }
    $info = Get-VortexInfo $Config.gameDir
    if (-not $info.deploymentFound) { $null = $w.Add("Vortex hasn't deployed to this folder yet, so installs can't be detected. Open Vortex, manage Cyberpunk 2077 and deploy once.") }
    else {
        $missing = @($script:FrameworkIds.Keys | Where-Object { -not $info.ids.Contains([int]$_) } | ForEach-Object { $script:FrameworkIds[$_] })
        if ($missing.Count -gt 0) { $null = $w.Add('Missing frameworks in Vortex: ' + ($missing -join ', ') + '. Install their 2.5 versions first.') }
    }
    if (-not (Test-NxmHandler)) { $null = $w.Add("Vortex isn't set to handle Nexus download links. In Vortex: Settings > Downloads > turn on 'Handle Nexus links'.") }
    return $w
}

# ---------------------------------------------------------------- GUI

function Start-App {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()

    Ensure-DataDir
    $script:LogFile = Join-Path $script:DataDir 'log.txt'
    $manifest = Load-Manifest
    $config = Load-Config
    $state = Load-State
    $startIds = $null
    if ($config.gameDir -and (Test-Path -LiteralPath $config.gameDir)) { $startIds = Get-InstalledNexusIds $config.gameDir }
    $null = Add-DiscoveredToManifest $manifest (Read-DiscoveryStore) $startIds

    $font = New-Object Drawing.Font('Segoe UI', 9.5)
    $bold = New-Object Drawing.Font('Segoe UI Semibold', 10.5)

    $form = New-Object Windows.Forms.Form
    $form.Text = "$($script:AppName) $($script:AppVersion)"
    $form.Size = New-Object Drawing.Size(1100, 820)
    $form.MinimumSize = New-Object Drawing.Size(880, 620)
    $form.StartPosition = 'CenterScreen'
    $form.Font = $font

    # ---- top: game folder + accounts
    $top = New-Object Windows.Forms.TableLayoutPanel
    $top.Dock = 'Top'; $top.AutoSize = $true; $top.ColumnCount = 4; $top.Padding = New-Object Windows.Forms.Padding(10, 10, 10, 4)
    [void]$top.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize')))
    [void]$top.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
    [void]$top.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize')))
    [void]$top.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize')))
    $lblGame = New-Object Windows.Forms.Label; $lblGame.Text = 'Game folder'; $lblGame.AutoSize = $true; $lblGame.Anchor = 'Left'
    $txtGame = New-Object Windows.Forms.TextBox; $txtGame.Text = $config.gameDir; $txtGame.Dock = 'Fill'
    $btnBrowse = New-Object Windows.Forms.Button; $btnBrowse.Text = 'Browse...'; $btnBrowse.AutoSize = $true
    $btnAccounts = New-Object Windows.Forms.Button; $btnAccounts.Text = 'Accounts...'; $btnAccounts.AutoSize = $true
    $lblAcct = New-Object Windows.Forms.Label; $lblAcct.AutoSize = $true; $lblAcct.ForeColor = [Drawing.Color]::DimGray
    $top.Controls.Add($lblGame, 0, 0); $top.Controls.Add($txtGame, 1, 0); $top.Controls.Add($btnBrowse, 2, 0); $top.Controls.Add($btnAccounts, 3, 0)
    $top.Controls.Add($lblAcct, 1, 1); $top.SetColumnSpan($lblAcct, 3)

    # ---- banner
    $banner = New-Object Windows.Forms.Panel
    $banner.Dock = 'Top'; $banner.Height = 92; $banner.BackColor = [Drawing.Color]::FromArgb(255, 246, 214); $banner.Padding = New-Object Windows.Forms.Padding(12, 8, 12, 8)
    $bannerText = New-Object Windows.Forms.Label; $bannerText.Dock = 'Fill'; $bannerText.Font = $bold
    $bannerBtns = New-Object Windows.Forms.FlowLayoutPanel; $bannerBtns.Dock = 'Bottom'; $bannerBtns.Height = 36; $bannerBtns.FlowDirection = 'LeftToRight'
    $banner.Controls.Add($bannerText); $banner.Controls.Add($bannerBtns)

    # ---- tabs
    $tabs = New-Object Windows.Forms.TabControl; $tabs.Dock = 'Fill'
    $tabInstall = New-Object Windows.Forms.TabPage; $tabInstall.Text = 'Install'
    $tabUpdates = New-Object Windows.Forms.TabPage; $tabUpdates.Text = 'Updates'
    [void]$tabs.TabPages.Add($tabInstall); [void]$tabs.TabPages.Add($tabUpdates)

    # Install tab
    $list = New-Object Windows.Forms.ListView
    $list.View = 'Details'; $list.CheckBoxes = $true; $list.FullRowSelect = $true; $list.Dock = 'Fill'; $list.HideSelection = $false
    [void]$list.Columns.Add('Mod', 330); [void]$list.Columns.Add('Source', 70); [void]$list.Columns.Add('Status', 150); [void]$list.Columns.Add('Detail', 470)
    $rows = @{}
    $locked = New-Object 'System.Collections.Generic.HashSet[string]'
    $updatesById = @{}
    $groupCount = @{ n = 0 }
    $ensureGroup = {
        param([int]$bid)
        if ($list.Groups["b$bid"]) { return }
        $groupCount.n++; $b = $manifest.batches[$bid]
        $src = if ($b.source -eq 'modio') { 'mod.io' } else { 'Nexus' }
        [void]$list.Groups.Add((New-Object Windows.Forms.ListViewGroup("b$bid", "$($groupCount.n). $($b.name)   [$src]")))
    }
    $addRow = {
        param($it)
        & $ensureGroup $it.batch
        $row = New-Object Windows.Forms.ListViewItem($it.name)
        [void]$row.SubItems.Add($(if ($it.source -eq 'nexus') { 'Nexus' } else { 'mod.io' }))
        $st = ''; $dt = ''; $done = $false
        if ($state.ContainsKey($it.key)) { $st = $state[$it.key].status; $dt = $state[$it.key].detail; $done = $state[$it.key].done }
        [void]$row.SubItems.Add($st); [void]$row.SubItems.Add($dt)
        $row.Tag = $it.key
        $row.Group = $list.Groups["b$($it.batch)"]
        $row.Checked = (-not $it.optional) -and (-not $done)
        if ($it.note -and -not $dt) { $row.SubItems[3].Text = $it.note }
        [void]$list.Items.Add($row)
        $rows[$it.key] = @{ row = $row; statusCol = 2; detailCol = 3 }
    }
    foreach ($it in $manifest.items) { & $addRow $it }
    $bottom = New-Object Windows.Forms.FlowLayoutPanel
    $bottom.Dock = 'Bottom'; $bottom.Height = 44; $bottom.Padding = New-Object Windows.Forms.Padding(4, 6, 4, 6)
    $btnStart = New-Object Windows.Forms.Button; $btnStart.Text = 'Start'; $btnStart.Width = 110; $btnStart.Height = 30; $btnStart.Font = $bold
    $btnPause = New-Object Windows.Forms.Button; $btnPause.Text = 'Pause'; $btnPause.Width = 90; $btnPause.Height = 30; $btnPause.Enabled = $false
    $btnAll = New-Object Windows.Forms.Button; $btnAll.Text = 'Tick all'; $btnAll.Width = 90; $btnAll.Height = 30
    $btnNone = New-Object Windows.Forms.Button; $btnNone.Text = 'Untick all'; $btnNone.Width = 90; $btnNone.Height = 30
    $btnReset = New-Object Windows.Forms.Button; $btnReset.Text = 'Reset progress'; $btnReset.Width = 120; $btnReset.Height = 30
    $chkPause = New-Object Windows.Forms.CheckBox; $chkPause.Text = 'Pause after each batch so I can test the game'; $chkPause.AutoSize = $true
    $chkPause.Margin = New-Object Windows.Forms.Padding(16, 8, 0, 0); $chkPause.Checked = [bool]$config.pauseBetweenBatches
    $bottom.Controls.AddRange(@($btnStart, $btnPause, $btnAll, $btnNone, $btnReset, $chkPause))
    $summary = New-Object Windows.Forms.Panel; $summary.Dock = 'Top'; $summary.Height = 58; $summary.Padding = New-Object Windows.Forms.Padding(8, 6, 8, 4)
    $sumText = New-Object Windows.Forms.Label; $sumText.Dock = 'Top'; $sumText.Height = 26; $sumText.Font = New-Object Drawing.Font('Segoe UI Semibold', 12)
    $sumLegend = New-Object Windows.Forms.Label; $sumLegend.Dock = 'Top'; $sumLegend.Height = 22; $sumLegend.ForeColor = [Drawing.Color]::DimGray
    $sumLegend.Text = "Green rows with $($script:Glyph.ok) are installed and locked (nothing to do).  Orange rows with $($script:Glyph.up) have an update and can be ticked.  Yellow rows are waiting.  White rows will be installed."
    $summary.Controls.Add($sumLegend); $summary.Controls.Add($sumText)
    $btnRefresh = New-Object Windows.Forms.Button; $btnRefresh.Text = 'Refresh installed'; $btnRefresh.Width = 130; $btnRefresh.Height = 30
    $bottom.Controls.Add($btnRefresh); $bottom.Controls.SetChildIndex($btnRefresh, 5)
    $tabInstall.Controls.Add($list); $tabInstall.Controls.Add($summary); $tabInstall.Controls.Add($bottom)

    # Updates tab
    $updHeader = New-Object Windows.Forms.Label; $updHeader.Dock = 'Top'; $updHeader.Height = 50; $updHeader.Padding = New-Object Windows.Forms.Padding(6, 6, 6, 0)
    $updList = New-Object Windows.Forms.ListView
    $updList.View = 'Details'; $updList.CheckBoxes = $true; $updList.FullRowSelect = $true; $updList.Dock = 'Fill'; $updList.HideSelection = $false
    [void]$updList.Columns.Add('Mod', 330); [void]$updList.Columns.Add('Source', 70); [void]$updList.Columns.Add('Installed', 110); [void]$updList.Columns.Add('Latest', 110); [void]$updList.Columns.Add('Status', 400)
    $gFw = New-Object Windows.Forms.ListViewGroup('fw', 'Frameworks (update these first)')
    $gNx = New-Object Windows.Forms.ListViewGroup('nx', 'Nexus mods (installed through Vortex)')
    $gMo = New-Object Windows.Forms.ListViewGroup('mo', 'mod.io mods (the game updates these by itself)')
    [void]$updList.Groups.AddRange(@($gFw, $gNx, $gMo))
    $updBottom = New-Object Windows.Forms.FlowLayoutPanel
    $updBottom.Dock = 'Bottom'; $updBottom.Height = 44; $updBottom.Padding = New-Object Windows.Forms.Padding(4, 6, 4, 6)
    $btnCheck = New-Object Windows.Forms.Button; $btnCheck.Text = 'Check for updates'; $btnCheck.Width = 150; $btnCheck.Height = 30; $btnCheck.Font = $bold
    $btnUpdate = New-Object Windows.Forms.Button; $btnUpdate.Text = 'Update ticked'; $btnUpdate.Width = 130; $btnUpdate.Height = 30; $btnUpdate.Enabled = $false
    $btnAppUpd = New-Object Windows.Forms.Button; $btnAppUpd.Text = 'Update app'; $btnAppUpd.AutoSize = $true; $btnAppUpd.Height = 30; $btnAppUpd.Visible = $false
    $chkAuto = New-Object Windows.Forms.CheckBox; $chkAuto.Text = 'Check for updates when the app opens'; $chkAuto.AutoSize = $true
    $chkAuto.Margin = New-Object Windows.Forms.Padding(16, 8, 0, 0); $chkAuto.Checked = [bool]$config.checkOnStart
    $chkDisc = New-Object Windows.Forms.CheckBox; $chkDisc.Text = 'Look for new compatible mods when the app opens'; $chkDisc.AutoSize = $true
    $chkDisc.Margin = New-Object Windows.Forms.Padding(16, 8, 0, 0); $chkDisc.Checked = [bool]$config.discoverOnStart
    $updBottom.Controls.AddRange(@($btnCheck, $btnUpdate, $btnAppUpd, $chkAuto, $chkDisc))
    $tabUpdates.Controls.Add($updList); $tabUpdates.Controls.Add($updHeader); $tabUpdates.Controls.Add($updBottom)

    # ---- log
    $log = New-Object Windows.Forms.TextBox
    $log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Vertical'; $log.Dock = 'Bottom'; $log.Height = 130
    $log.Font = New-Object Drawing.Font('Consolas', 9)

    $form.Controls.Add($tabs); $form.Controls.Add($banner); $form.Controls.Add($top); $form.Controls.Add($log)

    $engineRef = @{ E = $null; C = $null; D = $null; AppUpdate = $null }

    $looks = @{
        ok     = @{ back = [Drawing.Color]::FromArgb(222, 244, 226); fore = [Drawing.Color]::FromArgb(22, 101, 52) }
        update = @{ back = [Drawing.Color]::FromArgb(255, 232, 204); fore = [Drawing.Color]::FromArgb(154, 52, 18) }
        wait   = @{ back = [Drawing.Color]::FromArgb(254, 249, 214); fore = [Drawing.Color]::FromArgb(113, 63, 18) }
        fail   = @{ back = [Drawing.Color]::FromArgb(254, 226, 226); fore = [Drawing.Color]::FromArgb(153, 27, 27) }
        busy   = @{ back = [Drawing.Color]::FromArgb(224, 236, 255); fore = [Drawing.Color]::FromArgb(30, 64, 175) }
        none   = @{ back = [Drawing.Color]::White; fore = [Drawing.Color]::Black }
    }
    $setLook = {
        param($r, [string]$kind)
        $r.UseItemStyleForSubItems = $true
        $r.BackColor = $looks[$kind].back; $r.ForeColor = $looks[$kind].fore
        $r.Font = if ($kind -eq 'ok') { $font } elseif ($kind -eq 'update') { $bold } else { $font }
    }
    $lookFor = {
        param([string]$status)
        if ($status -match '^(Installed|Updated|Subscribed|Already|Up to date)') { return 'ok' }
        if ($status -match '^(Waiting for 2\.5|Needs)') { return 'wait' }
        if ($status -match '^(Failed|Not found)') { return 'fail' }
        if ($status -match '^Update available') { return 'update' }
        if ($status -match '^(Waiting for your click|Working)') { return 'busy' }
        if ($status -eq 'Skipped') { return 'none' }
        return 'none'
    }
    $decorate = {
        param([string]$status)
        $k = & $lookFor $status
        if ($k -eq 'ok' -and -not $status.StartsWith($script:Glyph.ok)) { return "$($script:Glyph.ok) $status" }
        if ($k -eq 'update' -and -not $status.StartsWith($script:Glyph.up)) { return "$($script:Glyph.up) $status" }
        return $status
    }
    $updateSummary = {
        $inst = 0; $wait = 0; $todo = 0
        foreach ($it in $manifest.items) {
            $t = $rows[$it.key].row.SubItems[2].Text
            $k = & $lookFor ($t -replace "^[^A-Za-z]+", '')
            if ($k -eq 'ok') { $inst++ } elseif ($k -eq 'wait') { $wait++ } elseif ($rows[$it.key].row.Checked) { $todo++ }
        }
        $sumText.Text = "$($script:Glyph.ok) $inst installed      $($script:Glyph.dot) $todo ticked to install      $($script:Glyph.dot) $wait waiting      (of $($manifest.items.Count) in the list)"
        $sumText.ForeColor = $looks.ok.fore
    }

    # ---- UI adapter used by the engine and the update checker
    $ui = [pscustomobject]@{}
    $ui | Add-Member ScriptMethod Log {
        param($m)
        $line = (Get-Date -Format 'HH:mm:ss') + '  ' + $m
        $log.AppendText($line + [Environment]::NewLine)
        try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch {}
    }
    $ui | Add-Member ScriptMethod SetStatus {
        param($key, $status, $detail)
        $entry = $rows[$key]; if (-not $entry) { return }
        $r = $entry.row
        $r.SubItems[$entry.statusCol].Text = (& $decorate $status)
        if ($entry.detailCol -ge 0) { $r.SubItems[$entry.detailCol].Text = $detail }
        $k = & $lookFor $status
        & $setLook $r $k
        if ($k -eq 'ok') {
            $r.Checked = $false
            if ($entry.statusCol -eq 2) {
                [void]$locked.Add([string]$key)
                if ($key -like 'nexus:*') { $updatesById.Remove([int]($key -replace '^nexus:', '')) }
            }
        }
        $r.EnsureVisible()
        if ($entry.statusCol -eq 2) { & $updateSummary }
    }
    $ui | Add-Member ScriptMethod Banner {
        param($text, $buttons)
        $bannerText.Text = $text
        $bannerBtns.Controls.Clear()
        foreach ($b in @($buttons)) {
            $btn = New-Object Windows.Forms.Button; $btn.Text = $b; $btn.AutoSize = $true; $btn.Height = 28
            $btn.Add_Click({ param($s, $a) if ($s.Text -eq 'Update app') { & $doAppUpdate } elseif ($engineRef.E) { Invoke-EngineAction $engineRef.E $s.Text } })
            $bannerBtns.Controls.Add($btn)
        }
        $banner.Visible = -not [string]::IsNullOrEmpty($text)
    }
    $ui | Add-Member ScriptMethod OpenUrl { param($u) Start-Process $u }
    $ui | Add-Member ScriptMethod UpdateRow {
        param($res)
        $entry = $rows[$res.key]
        if (-not $entry) {
            $r = New-Object Windows.Forms.ListViewItem([string]$res.name)
            [void]$r.SubItems.Add([string]$res.source); [void]$r.SubItems.Add(''); [void]$r.SubItems.Add(''); [void]$r.SubItems.Add('')
            if ($res.source -eq 'mod.io') { $r.Group = $gMo } elseif ($res.framework) { $r.Group = $gFw } else { $r.Group = $gNx }
            [void]$updList.Items.Add($r)
            $entry = @{ row = $r; statusCol = 4; detailCol = -1 }
            $rows[$res.key] = $entry
            if ($res.source -eq 'Nexus') { $rows["update:$($res.id)"] = $entry }
        }
        $r = $entry.row
        $r.Tag = $res
        $r.SubItems[2].Text = [string]$res.installed; $r.SubItems[3].Text = [string]$res.latest; $r.SubItems[4].Text = (& $decorate ([string]$res.status))
        $r.Checked = [bool]$res.update
        if ($res.update) { & $setLook $r 'update' }
        elseif ($res.status -like 'Updated*') { & $setLook $r 'busy' }
        elseif ($res.status -like 'Up to date*') { & $setLook $r 'ok' }
        elseif ($res.status -like 'Add a Nexus key*') { & $setLook $r 'wait' }
        else { & $setLook $r 'fail' }
    }
    $ui | Add-Member ScriptMethod CheckFinished {
        param($n)
        $updatesById.Clear()
        foreach ($res in @($engineRef.C.results | Where-Object { $_.update -and $_.source -eq 'Nexus' })) { $updatesById[[int]$res.id] = $res }
        $unlocked = 0
        foreach ($id in @($updatesById.Keys)) {
            $entry = $rows["nexus:$id"]
            if ($entry) {
                $u = $updatesById[$id]; $r = $entry.row
                [void]$locked.Remove("nexus:$id")
                $r.SubItems[2].Text = (& $decorate 'Update available'); $r.SubItems[3].Text = "v$($u.installed) -> v$($u.latest)"
                & $setLook $r 'update'; $r.Checked = $true; $unlocked++
            }
        }
        if ($unlocked -gt 0) { & $updateSummary }
        $btnCheck.Enabled = $true
        $btnUpdate.Enabled = ($n -gt 0)
        Update-UpdHeader
        if ($n -gt 0) {
            $ui.Log("Update check: $n Nexus mods have updates.")
            if (-not $engineRef.E -or $engineRef.E.mode -in @('idle', 'done')) {
                $ui.Banner("$n of your Nexus mods have updates. Open the Updates tab and click 'Update ticked'. Frameworks go first.", @())
            }
        } else { $ui.Log('Update check: everything is up to date.') }
    }

    $ui | Add-Member ScriptMethod DiscoveryFinished {
        param($keys)
        $added = 0
        foreach ($k in @($keys)) {
            if ($rows.ContainsKey($k)) { continue }
            $it = $manifest.items | Where-Object { $_.key -eq $k } | Select-Object -First 1
            if ($it) { & $addRow $it; $added++ }
        }
        & $updateSummary
        $nx = @($keys | Where-Object { $_ -like 'nexus:*' }).Count; $mo = $added - $nx
        if ($added -gt 0) {
            $ui.Log("Discovery: added $added new mods for this game version ($mo from mod.io, ticked; $nx from Nexus, unticked).")
            if (-not (Test-EngineBusy)) { $ui.Banner("Found $added more mods that work with this game version. They're at the bottom of the list under 'Discovered'. mod.io finds are ticked; Nexus finds are unticked, so check their pages for requirements before ticking.", @()) }
        } else { $ui.Log('Discovery: no new compatible mods since last time.') }
    }

    $refreshInstalled = {
        if (-not $config.gameDir -or -not (Test-Path -LiteralPath $config.gameDir)) { return }
        $subs = $null
        if ($config.modioToken) {
            try {
                if (-not $config.modioGameId) { $config.modioGameId = Resolve-ModioGameId $config.modioToken; Save-Config $config }
                $subs = @(Get-ModioSubscribedDetails $config.modioGameId $config.modioToken)
            } catch { $ui.Log('Could not read your mod.io subscriptions: ' + $_.Exception.Message) }
        }
        $snap = Get-InstallSnapshot $manifest $config.gameDir $subs
        $n = 0
        foreach ($it in $manifest.items) {
            $entry = $rows[$it.key]; $r = $entry.row
            if (-not $snap.ContainsKey($it.key)) {
                $saved = if ($state.ContainsKey($it.key)) { $state[$it.key].status } else { '' }
                $r.SubItems[2].Text = (& $decorate $saved); & $setLook $r (& $lookFor $saved)
                continue
            }
            $s = $snap[$it.key]
            if ($s.installed -and $it.source -eq 'nexus' -and $updatesById.ContainsKey([int]$it.id)) {
                $n++
                $u = $updatesById[[int]$it.id]
                [void]$locked.Remove($it.key)
                $r.SubItems[2].Text = (& $decorate 'Update available'); $r.SubItems[3].Text = "$($s.detail) -> v$($u.latest)"
                & $setLook $r 'update'; $r.Checked = $true
            } elseif ($s.installed) {
                $n++
                $r.SubItems[2].Text = (& $decorate $(if ($it.source -eq 'nexus') { 'Installed' } else { 'Subscribed' }))
                $r.SubItems[3].Text = $s.detail + $(if ($it.source -eq 'nexus') { '  (locked: no update)' } else { '  (locked: the game keeps it updated)' })
                & $setLook $r 'ok'; $r.Checked = $false
                [void]$locked.Add($it.key)
            } else {
                [void]$locked.Remove($it.key)
                $saved = if ($state.ContainsKey($it.key)) { $state[$it.key].status } else { '' }
                if ((& $lookFor $saved) -eq 'ok') {
                    # was installed earlier but is gone now (removed in Vortex or unsubscribed)
                    $state.Remove($it.key); $saved = ''
                    $r.SubItems[3].Text = 'Not installed any more'; $r.Checked = -not $it.optional
                }
                $r.SubItems[2].Text = (& $decorate $saved); & $setLook $r (& $lookFor $saved)
            }
        }
        Save-State $state
        & $updateSummary
        $ui.Log("Installed check: $n of $($manifest.items.Count) list mods are already in place.")
    }

    function Update-AccountLabel {
        $n = if ($config.nexusKey) { 'Nexus key saved' } else { 'No Nexus key (optional, needed for mod update checks)' }
        $m = if ($config.modioToken) { 'mod.io token saved' } else { 'No mod.io token (needed for mod.io mods)' }
        $g = if ($config.githubToken) { 'GitHub token saved' } else { 'App updates: public repo, no token needed' }
        $lblAcct.Text = "$n  |  $m  |  $g"
    }
    function Update-UpdHeader {
        $gv = Get-GameVersion $config.gameDir
        $last = if ($state.ContainsKey('__lastCheck')) { $state['__lastCheck'].detail } else { 'never' }
        $app = if ($engineRef.AppUpdate) { "App $($script:AppVersion), update to $($engineRef.AppUpdate.version) available" } else { "App $($script:AppVersion)" }
        $updHeader.Text = "Game version: $(if ($gv) { $gv } else { 'unknown' })    |    $app    |    Last checked: $last" + [Environment]::NewLine + 'Ticked rows have a newer file on Nexus. Updating opens each file page in order; click "Slow download" and Vortex replaces the old version.'
    }
    function Show-Preflight {
        $config.gameDir = $txtGame.Text.Trim()
        $w = Get-PreflightWarnings $config
        if ($w.Count -gt 0) { $ui.Banner(($w -join ' '), @()); return $false }
        return $true
    }
    function Test-EngineBusy { return ($engineRef.E -and $engineRef.E.mode -notin @('idle', 'done', 'paused')) }

    $doAppUpdate = {
        if (-not $engineRef.AppUpdate) { return }
        if (Test-EngineBusy) { $ui.Banner('Finish or pause the current install before updating the app.', @()); return }
        try {
            $ui.Log("Downloading app update $($engineRef.AppUpdate.version)...")
            $backup = Install-AppUpdate $engineRef.AppUpdate $config.githubToken
            $ui.Log("App updated. The previous version is saved in $backup. Restarting...")
            Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"' + (Join-Path $script:Root 'NightCityInstaller.ps1') + '"'))
            $form.Close()
        } catch { $ui.Banner('App update failed: ' + $_.Exception.Message, @()); $ui.Log('App update failed: ' + $_.Exception.Message) }
    }
    $checkApp = {
        param([bool]$Quiet)
        try {
            $info = Test-AppUpdate $config.githubToken
            $engineRef.AppUpdate = $info
            if ($info) {
                $btnAppUpd.Text = "Update app to $($info.version)"; $btnAppUpd.Visible = $true
                $ui.Log("App update $($info.version) available: $($info.notes)")
                if (-not (Test-EngineBusy)) { $ui.Banner("Night City Installer $($info.version) is available. $($info.notes)", @('Update app')) }
            } elseif (-not $Quiet) { $ui.Log("The app is up to date ($($script:AppVersion)).") }
        } catch { if (-not $Quiet) { $ui.Log('App update check: ' + $_.Exception.Message) } else { $ui.Log('App update check skipped: ' + $_.Exception.Message) } }
        Update-UpdHeader
    }
    $startCheck = {
        if (-not (Show-Preflight)) { return }
        if ($engineRef.C -and -not $engineRef.C.done) { return }
        $updList.Items.Clear()
        foreach ($k in @($rows.Keys | Where-Object { $_ -like 'upd*' -or $_ -like 'update:*' })) { $rows.Remove($k) }
        $btnCheck.Enabled = $false; $btnUpdate.Enabled = $false
        $engineRef.C = New-UpdateChecker $config $state $ui
        Start-UpdateCheck $engineRef.C
        $ui.Log('Checking for mod updates...')
        $chkTimer.Start()
        & $checkApp $true
    }

    # ---- events
    $chkPause.Add_CheckedChanged({ $config.pauseBetweenBatches = $chkPause.Checked; Save-Config $config })
    $chkAuto.Add_CheckedChanged({ $config.checkOnStart = $chkAuto.Checked; Save-Config $config })
    $chkDisc.Add_CheckedChanged({ $config.discoverOnStart = $chkDisc.Checked; Save-Config $config })

    $btnBrowse.Add_Click({
        $fb = New-Object Windows.Forms.FolderBrowserDialog
        $fb.Description = 'Select your Cyberpunk 2077 folder'
        if ($txtGame.Text -and (Test-Path -LiteralPath $txtGame.Text)) { $fb.SelectedPath = $txtGame.Text }
        if ($fb.ShowDialog($form) -eq 'OK') { $txtGame.Text = $fb.SelectedPath; $config.gameDir = $fb.SelectedPath; Save-Config $config; [void](Show-Preflight); Update-UpdHeader }
    })

    $btnAccounts.Add_Click({
        $dlg = New-Object Windows.Forms.Form
        $dlg.Text = 'Accounts'; $dlg.Size = New-Object Drawing.Size(660, 520); $dlg.StartPosition = 'CenterParent'; $dlg.Font = $font; $dlg.FormBorderStyle = 'FixedDialog'
        $t = New-Object Windows.Forms.TableLayoutPanel; $t.Dock = 'Fill'; $t.ColumnCount = 1; $t.Padding = New-Object Windows.Forms.Padding(12)
        $mk = {
            param($text, $linkText, $url)
            $l = New-Object Windows.Forms.LinkLabel; $l.AutoSize = $true; $l.MaximumSize = New-Object Drawing.Size(610, 0); $l.Text = $text
            $l.Links.Add($text.IndexOf($linkText), $linkText.Length, $url) | Out-Null
            $l.Add_LinkClicked({ param($s, $a) Start-Process $a.Link.LinkData })
            return $l
        }
        $l1 = & $mk 'Nexus personal API key (optional; needed to check Nexus mods for updates). Get it at next.nexusmods.com/settings/api-keys, under "Personal API Key".' 'next.nexusmods.com/settings/api-keys' 'https://next.nexusmods.com/settings/api-keys'
        $k1 = New-Object Windows.Forms.TextBox; $k1.UseSystemPasswordChar = $true; $k1.Width = 610; $k1.Text = $config.nexusKey
        $l2 = & $mk 'mod.io token: a Personal Access Token (preferred) or an older OAuth 2 access token, with read and write access. Sign in at mod.io/me/access with the SAME account you linked in the game and create it there.' 'mod.io/me/access' 'https://mod.io/me/access'
        $k2 = New-Object Windows.Forms.TextBox; $k2.UseSystemPasswordChar = $true; $k2.Width = 610; $k2.Text = $config.modioToken
        $l4 = New-Object Windows.Forms.Label; $l4.AutoSize = $true; $l4.MaximumSize = New-Object Drawing.Size(610, 0)
        $l4.Text = 'mod.io API path (optional). Leave empty unless mod.io/me/access shows a personal API path such as https://u-12345.modapi.io/v1.'
        $k4 = New-Object Windows.Forms.TextBox; $k4.Width = 610; $k4.Text = $config.modioApiPath
        $l3 = & $mk 'GitHub token (optional). App updates come from the public repo github.com/Sirtacoburrito/NightCityInstaller and need no token. Only fill this in if that repo is ever made private.' 'github.com/Sirtacoburrito/NightCityInstaller' 'https://github.com/Sirtacoburrito/NightCityInstaller'
        $k3 = New-Object Windows.Forms.TextBox; $k3.UseSystemPasswordChar = $true; $k3.Width = 610; $k3.Text = $config.githubToken
        $res = New-Object Windows.Forms.Label; $res.AutoSize = $true; $res.MaximumSize = New-Object Drawing.Size(610, 0); $res.ForeColor = [Drawing.Color]::DimGray
        $p = New-Object Windows.Forms.FlowLayoutPanel; $p.AutoSize = $true
        $test = New-Object Windows.Forms.Button; $test.Text = 'Test'; $test.AutoSize = $true
        $save = New-Object Windows.Forms.Button; $save.Text = 'Save'; $save.AutoSize = $true; $save.DialogResult = 'OK'
        $p.Controls.AddRange(@($test, $save))
        $t.Controls.AddRange(@($l1, $k1, $l2, $k2, $l4, $k4, $l3, $k3, $p, $res)); $dlg.Controls.Add($t)
        $dlg.Size = New-Object Drawing.Size(660, 600)
        $test.Add_Click({
            $out = @()
            if ($k1.Text.Trim()) {
                try { $v = Invoke-Nexus 'users/validate.json' $k1.Text.Trim(); $out += "Nexus: signed in as $($v.name)" + $(if ($v.is_premium) { ' (Premium)' } else { ' (free)' }) }
                catch { $out += 'Nexus: key rejected (' + $_.Exception.Message + ')' }
            }
            if ($k2.Text.Trim()) {
                Set-ModioBase $k4.Text
                $kind = Get-ModioTokenKind $k2.Text
                try {
                    $me = Invoke-Modio Get 'me' $k2.Text.Trim()
                    $out += "mod.io: signed in as $($me.username). Make sure this is the account linked in the game."
                    if ($kind -eq 'oauth2') { $out += 'mod.io: this is an OAuth 2 token, which mod.io is phasing out. When you can, create a Personal Access Token on mod.io/me/access and paste it here instead.' }
                } catch {
                    $code = Get-HttpStatus $_
                    $out += if ($code -eq 401) { 'mod.io: token rejected. It may have expired or been revoked; create a new Personal Access Token on mod.io/me/access.' } else { 'mod.io: could not connect (' + $_.Exception.Message + '). If mod.io/me/access shows an API path, paste it in the field above.' }
                }
                Set-ModioBase $config.modioApiPath
            }
            try {
                $info = Test-AppUpdate $k3.Text.Trim()
                $out += if ($info) { "GitHub: connected, app update $($info.version) available" } else { 'GitHub: connected, the app is up to date' }
            } catch { $out += 'GitHub: ' + $_.Exception.Message }
            $res.Text = ($out -join [Environment]::NewLine)
        })
        if ($dlg.ShowDialog($form) -eq 'OK') {
            $config.nexusKey = $k1.Text.Trim(); $config.modioToken = $k2.Text.Trim(); $config.githubToken = $k3.Text.Trim(); $config.modioApiPath = $k4.Text.Trim()
            if ((Get-ModioTokenKind $config.modioToken) -eq 'oauth2') { $ui.Log('mod.io: you are using an OAuth 2 token. It works for now, but mod.io is moving to Personal Access Tokens; swap it when you can.') }
            if ($engineRef.E) { $engineRef.E.subscribed = $null }
            Save-Config $config; Update-AccountLabel
            $ui.Log('Accounts saved.')
        }
    })

    $btnRefresh.Add_Click({ if (Show-Preflight) { & $refreshInstalled } })
    $btnAll.Add_Click({ foreach ($r in $list.Items) { if ((& $lookFor ($r.SubItems[2].Text -replace '^[^A-Za-z]+', '')) -ne 'ok') { $r.Checked = $true } }; & $updateSummary })
    $btnNone.Add_Click({ foreach ($r in $list.Items) { $r.Checked = $false }; & $updateSummary })
    $list.Add_ItemChecked({ if ($sumText) { & $updateSummary } })
    $list.Add_ItemCheck({
        param($s, $e)
        $k = [string]$list.Items[$e.Index].Tag
        if ($e.NewValue -eq [Windows.Forms.CheckState]::Checked -and $locked.Contains($k)) { $e.NewValue = [Windows.Forms.CheckState]::Unchecked }
    })
    $btnReset.Add_Click({
        $a = [Windows.Forms.MessageBox]::Show('Clear all saved install progress? Mods already installed stay installed and are detected again.', $script:AppName, 'YesNo', 'Question')
        if ($a -eq 'Yes') {
            foreach ($k in @($state.Keys | Where-Object { $_ -notlike '__*' })) { $state.Remove($k) }
            Save-State $state
            foreach ($it in $manifest.items) { $r = $rows[$it.key].row; $r.SubItems[2].Text = ''; $r.SubItems[3].Text = ''; & $setLook $r 'none'; $r.Checked = -not $it.optional }
            $ui.Log('Install progress cleared.')
            & $refreshInstalled
        }
    })

    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 1500
    $script:Busy = $false
    $timer.Add_Tick({
        if ($script:Busy -or -not $engineRef.E) { return }
        $script:Busy = $true
        try {
            Step-Engine $engineRef.E
            if ($engineRef.E.mode -in @('done', 'paused')) {
                $btnStart.Enabled = $true; $btnPause.Enabled = $false; $btnStart.Text = 'Start'; $btnUpdate.Enabled = $true
                if ($engineRef.E.mode -eq 'done') { $timer.Stop(); & $refreshInstalled }
            }
        } catch { $ui.Log('Error: ' + $_.Exception.Message) }
        finally { $script:Busy = $false }
    })

    $discTimer = New-Object Windows.Forms.Timer
    $discTimer.Interval = 300
    $script:DiscBusy = $false
    $discTimer.Add_Tick({
        if ($script:DiscBusy -or -not $engineRef.D) { return }
        $script:DiscBusy = $true
        try { Step-Discovery $engineRef.D; if ($engineRef.D.done) { $discTimer.Stop() } }
        catch { $ui.Log('Discovery error: ' + $_.Exception.Message); $discTimer.Stop() }
        finally { $script:DiscBusy = $false }
    })
    $startDiscovery = {
        if (-not $config.gameDir -or -not (Test-Path -LiteralPath $config.gameDir)) { return }
        if (-not $config.nexusKey -and -not $config.modioToken) { $ui.Log('Discovery skipped: add a Nexus key or mod.io token under Accounts.'); return }
        $engineRef.D = New-Discovery $manifest $config (Read-DiscoveryStore) (Get-InstalledNexusIds $config.gameDir) $ui
        $ui.Log('Looking for more mods that work with this game version...')
        $discTimer.Start()
    }

    $chkTimer = New-Object Windows.Forms.Timer
    $chkTimer.Interval = 250
    $script:CheckBusy = $false
    $chkTimer.Add_Tick({
        if ($script:CheckBusy -or -not $engineRef.C) { return }
        $script:CheckBusy = $true
        try { Step-UpdateCheck $engineRef.C; if ($engineRef.C.done) { $chkTimer.Stop() } }
        catch { $ui.Log('Update check error: ' + $_.Exception.Message); $chkTimer.Stop(); $btnCheck.Enabled = $true }
        finally { $script:CheckBusy = $false }
    })

    $btnStart.Add_Click({
        if (-not (Show-Preflight)) { return }
        Save-Config $config
        $checked = @($list.Items | Where-Object { $_.Checked } | ForEach-Object { [string]$_.Tag })
        if ($engineRef.E -and $engineRef.E.mode -eq 'paused' -and $engineRef.E.pos -lt $engineRef.E.queue.Count) {
            $engineRef.E.mode = 'running'; $engineRef.E.current = $null
        } else {
            $engineRef.E = New-Engine $manifest $config $state $ui
            $engineRef.E.updates = $updatesById
            Start-Engine $engineRef.E $checked
        }
        if ($engineRef.E.mode -eq 'done') { return }
        $ui.Banner('Working...', @())
        $btnStart.Enabled = $false; $btnPause.Enabled = $true; $btnUpdate.Enabled = $false
        $timer.Start()
    })
    $btnPause.Add_Click({
        if ($engineRef.E) {
            if ($engineRef.E.current -and $engineRef.E.mode -eq 'waitNexus') { $engineRef.E.current = $null }
            $engineRef.E.mode = 'paused'
        }
        $ui.Banner('Paused. Click Start to carry on from where you stopped.', @())
        $btnStart.Text = 'Continue'; $btnStart.Enabled = $true; $btnPause.Enabled = $false
    })

    $btnCheck.Add_Click({ & $startCheck })
    $btnAppUpd.Add_Click({ & $doAppUpdate })
    $btnUpdate.Add_Click({
        if (Test-EngineBusy) { $ui.Banner('Finish or pause the current install first.', @()); return }
        if (-not (Show-Preflight)) { return }
        $picked = @($updList.Items | Where-Object { $_.Checked -and $_.Tag -and $_.Tag.update } | ForEach-Object { $_.Tag } | Sort-Object { Get-UpdateSortKey $_.id $_.name })
        if ($picked.Count -eq 0) { $ui.Banner('Tick the mods you want to update first.', @()); return }
        $engineRef.E = New-Engine $manifest $config $state $ui
        Start-UpdateEngine $engineRef.E $picked
        $btnUpdate.Enabled = $false; $btnStart.Enabled = $false; $btnPause.Enabled = $true
        $tabs.SelectedTab = $tabUpdates
        $timer.Start()
    })

    # ---- startup
    Update-AccountLabel
    Update-UpdHeader
    $ui.Banner('First run: click Accounts... and add your mod.io token (and, ideally, your Nexus key). Then click Start. mod.io mods install with no further input. For each Nexus mod, click "Slow download" in the page that opens; Vortex does the rest and the app moves on by itself.', @())
    $ui.Log("$($script:AppName) $($script:AppVersion). $($manifest.items.Count) mods in the list. Progress is saved in $($script:DataDir).")
    if (Show-Preflight) {
        $gv = Get-GameVersion $config.gameDir
        $prev = if ($state.ContainsKey('__gameVersion')) { $state['__gameVersion'].detail } else { '' }
        if ($gv -and $prev -and $gv -ne $prev) {
            $ui.Banner("Cyberpunk 2077 was updated from $prev to $gv. Script mods often stop working after a game patch until their frameworks are updated. Open the Updates tab, check for updates and install the framework updates first. If the game won't start, disable mods in Vortex until they catch up.", @())
            $ui.Log("Game version changed: $prev -> $gv")
        }
        if ($gv) { $state['__gameVersion'] = @{ status = ''; detail = $gv; done = $false }; Save-State $state }
        $form.Add_Shown({ & $refreshInstalled; if ($config.checkOnStart) { & $startCheck }; if ($config.discoverOnStart) { & $startDiscovery } })
    }
    [void]$form.ShowDialog()
    $timer.Stop(); $chkTimer.Stop(); $discTimer.Stop()
}

if (-not $TestMode) {
    try { Start-App }
    catch {
        try { Ensure-DataDir; Add-Content -LiteralPath (Join-Path $script:DataDir 'log.txt') -Value ('Startup error: ' + $_.Exception.Message) } catch {}
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show("Night City Installer couldn't start: $($_.Exception.Message)", 'Night City Installer', 'OK', 'Error')
    }
}
