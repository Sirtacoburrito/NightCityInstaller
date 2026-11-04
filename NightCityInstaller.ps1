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
$script:TraceOn = ($env:NCI_DEBUG -eq '1') -or (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'trace.on'))
function Write-Trace([string]$m) { if ($script:TraceOn) { try { Add-Content -LiteralPath (Join-Path $PSScriptRoot 'trace.txt') -Value ((Get-Date -Format 'HH:mm:ss.fff') + '  ' + $m) } catch {} } }
Write-Trace 'script loaded'
$script:AppName    = 'Night City Installer'
$script:AppVersion = '1.5.1'
$script:Root       = $PSScriptRoot
$script:ScriptPath = $PSCommandPath
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

# The game keeps its own mod.io sign-in (made through the CD PROJEKT RED account link) in
# %LOCALAPPDATA%\mod.io\<gameId>\<user>\user.json. That sign-in is a separate mod.io account from
# one made on the mod.io website, even when both show the same name. The game only downloads mods
# subscribed on its own account, so by default the app subscribes with that sign-in. The token is
# read from the file each time the app starts and is never copied anywhere.
function Get-GameModioLogin([int]$GameId) {
    if (-not $GameId) { return $null }
    $root = Join-Path $env:LOCALAPPDATA "mod.io\$GameId"
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    $best = $null
    foreach ($f in (Get-ChildItem -LiteralPath $root -Filter 'user.json' -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        try {
            $j = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json
            $tok = $null; $exp = 0
            if ($j.PSObject.Properties['OAuth'] -and $j.OAuth) {
                foreach ($k in 'token', 'Token', 'access_token') { if ($j.OAuth.PSObject.Properties[$k] -and $j.OAuth.$k) { $tok = [string]$j.OAuth.$k; break } }
                foreach ($k in 'expiry', 'Expiry', 'ExpiryDate', 'date_expires') { if ($j.OAuth.PSObject.Properties[$k]) { try { $exp = [long]$j.OAuth.$k } catch {} ; break } }
            }
            if (-not $tok) { continue }
            if ($exp -gt 100000000000) { $exp = [long]($exp / 1000) }
            $now = [long]([datetimeoffset][datetime]::UtcNow).ToUnixTimeSeconds()
            $pr = if ($j.PSObject.Properties['Profile']) { $j.Profile } else { $null }
            $best = [pscustomobject]@{ token = $tok; expiry = $exp; expired = ($exp -gt 0 -and $exp -lt $now); path = $f.FullName
                username = $(if ($pr -and $pr.PSObject.Properties['username']) { [string]$pr.username } else { '' })
                id = $(if ($pr -and $pr.PSObject.Properties['id']) { [string]$pr.id } else { '' })
                portal = $(if ($pr -and $pr.PSObject.Properties['display_name_portal']) { [string]$pr.display_name_portal } else { '' }) }
            if (-not $best.expired) { return $best }
        } catch {}
    }
    return $best
}

# Picks the token the app uses: the game's own mod.io sign-in when "use the game's sign-in" is on
# and one exists, otherwise the Personal Access Token from Settings.
function Update-ModioSource($cfg) {
    if (-not $cfg.ContainsKey('modioPat')) { $cfg.modioPat = $cfg.modioToken }
    $cfg.modioSource = 'pat'; $cfg.modioToken = $cfg.modioPat; $cfg.modioGameLogin = $null
    if ($cfg.ContainsKey('modioUseGame') -and -not $cfg.modioUseGame) { return }
    $l = $null; try { $l = Get-GameModioLogin ([int]$cfg.modioGameId) } catch {}
    if ($l -and $l.token -and -not $l.expired) { $cfg.modioToken = $l.token; $cfg.modioSource = 'game'; $cfg.modioGameLogin = $l }
}

function Load-Config {
    $c = Read-JsonFile (Join-Path $script:DataDir 'config.json')
    $cfg = @{ gameDir = ''; nexusKey = ''; modioToken = ''; githubToken = ''; modioGameId = 0; pauseBetweenBatches = $false; checkOnStart = $true; modioApiPath = ''; discoverOnStart = $true; autoFix = $true; shortcutDone = $false
        modioUseGame = $true; modioPat = ''; modioSource = 'pat'; modioGameLogin = $null }
    if ($c) {
        if ($c.PSObject.Properties['pauseBetweenBatches']) { $cfg.pauseBetweenBatches = [bool]$c.pauseBetweenBatches }
        if ($c.PSObject.Properties['checkOnStart']) { $cfg.checkOnStart = [bool]$c.checkOnStart }
        if ($c.PSObject.Properties['discoverOnStart']) { $cfg.discoverOnStart = [bool]$c.discoverOnStart }
        if ($c.PSObject.Properties['autoFix']) { $cfg.autoFix = [bool]$c.autoFix }
        if ($c.PSObject.Properties['shortcutDone']) { $cfg.shortcutDone = [bool]$c.shortcutDone }
        if ($c.PSObject.Properties['modioUseGame']) { $cfg.modioUseGame = [bool]$c.modioUseGame }
        if ($c.PSObject.Properties['modioApiPath'] -and $c.modioApiPath) { $cfg.modioApiPath = [string]$c.modioApiPath }
        if ($c.PSObject.Properties['githubToken'] -and $c.githubToken) { $cfg.githubToken = Unprotect-Text ([string]$c.githubToken) }
        if ($c.gameDir)     { $cfg.gameDir = [string]$c.gameDir }
        if ($c.nexusKey)    { $cfg.nexusKey = Unprotect-Text ([string]$c.nexusKey) }
        if ($c.modioToken)  { $cfg.modioToken = Unprotect-Text ([string]$c.modioToken) }
        if ($c.modioGameId) { $cfg.modioGameId = [int]$c.modioGameId }
    }
    if (-not $cfg.gameDir -and (Test-Path -LiteralPath $script:DefaultGameDir)) { $cfg.gameDir = $script:DefaultGameDir }
    $cfg.modioPat = $cfg.modioToken
    Set-ModioBase $cfg.modioApiPath
    Update-ModioSource $cfg
    return $cfg
}

function Save-Config($cfg) {
    Write-JsonFile (Join-Path $script:DataDir 'config.json') ([ordered]@{
        gameDir = $cfg.gameDir; nexusKey = (Protect-Text $cfg.nexusKey); modioToken = (Protect-Text $(if ($cfg.ContainsKey('modioPat')) { $cfg.modioPat } else { $cfg.modioToken })); modioGameId = $cfg.modioGameId
        modioUseGame = $(if ($cfg.ContainsKey('modioUseGame')) { [bool]$cfg.modioUseGame } else { $true })
        pauseBetweenBatches = [bool]$cfg.pauseBetweenBatches; checkOnStart = [bool]$cfg.checkOnStart; githubToken = (Protect-Text $cfg.githubToken)
        modioApiPath = [string]$cfg.modioApiPath; discoverOnStart = [bool]$cfg.discoverOnStart; autoFix = [bool]$cfg.autoFix; shortcutDone = [bool]$cfg.shortcutDone })
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
            optional = [bool]$x.optional; verify = [bool]$x.verify; note = [string]$x.note; modioId = 0; discovered = $false; desc = [string]$x.desc })
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

function Invoke-Modio([string]$Method, [string]$Path, [string]$Token, [switch]$AnyPlatform) {
    $h = @{ Authorization = "Bearer $(([string]$Token).Trim())"; Accept = 'application/json' }
    if (-not $AnyPlatform) { $h['X-Modio-Platform'] = 'windows' }
    if ($Method -eq 'Post') {
        return Invoke-RestMethod -Method Post -Uri "$($script:ModioBase)/$Path" -Headers $h -ContentType 'application/x-www-form-urlencoded' -Body '' -TimeoutSec 30
    }
    return Invoke-RestMethod -Method Get -Uri "$($script:ModioBase)/$Path" -Headers $h -TimeoutSec 30
}

function UrlEnc([string]$s) { return [Uri]::EscapeDataString($s) }

# Windows PowerShell 5.1 returns a JSON array from Invoke-RestMethod as ONE object (the array
# itself) instead of its items. Wrapping that in @() gives an array inside an array. This helper
# always returns the plain list of items, on 5.1 and 7 alike.
function ConvertTo-FlatList($x) {
    $out = New-Object System.Collections.ArrayList
    foreach ($i in @($x)) {
        if ($i -is [System.Array]) { foreach ($j in $i) { if ($null -ne $j) { [void]$out.Add($j) } } }
        elseif ($null -ne $i) { [void]$out.Add($i) }
    }
    return ,$out.ToArray()
}

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

function Search-Modio([int]$GameId, [string]$Query, [string]$Token, [switch]$AnyPlatform) {
    $r = Invoke-Modio Get "games/$GameId/mods?_q=$(UrlEnc $Query)&_limit=30" $Token -AnyPlatform:$AnyPlatform
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
    $null = Save-AppUpdate $Info $Token
    $null = Install-StagedAppUpdate
    return (Join-Path $script:DataDir ('backup-' + $script:AppVersion))
}

# ---------------------------------------------------------------- engine (UI-independent)
# The UI object supplies: Log(msg) SetStatus(key,status,detail) Banner(text, [string[]]buttons) OpenUrl(url) Choose(title, items) -> index or -1

function New-Engine($Manifest, $Config, $State, $UI) {
    return [pscustomobject]@{
        manifest = $Manifest; config = $Config; state = $State; ui = $UI
        queue = @(); pos = 0; mode = 'idle'; current = $null; purpose = 'install'; modioNoted = $false; updates = @{}
        reqQueued = (New-Object 'System.Collections.Generic.HashSet[int]')
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
                try { $doneItem = $E.current; $E.pos++; Invoke-PostInstallCheck $E $doneItem; $E.pos-- } catch { $E.ui.Log("Post-install check for $($E.current.name) failed: " + $_.Exception.Message) }
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
        try { if (Repair-EmptyModdedCache $E.config.gameDir) { $E.ui.Log('Health: renamed an empty r6\cache\modded folder that would crash the game on start-up.') } } catch {}
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
        # Install whatever this mod needs first.
        $info = $null
        try { $info = Get-NexusModInfo $item.id $E.config.nexusKey } catch {}
        if ($info) {
            $missing = @(Get-RequirementsFromText ([string]$info.description) $item.id | Where-Object { -not $ids.Contains([int]$_.id) })
            if ($missing.Count -gt 0) {
                $tried = @($missing | Where-Object { $E.reqQueued.Contains([int]$_.id) })
                if ($tried.Count -gt 0) {
                    $names = ($tried | ForEach-Object { $_.name }) -join ', '
                    Set-ItemState $E $item "Needs $names" "Waiting for its requirement $names (no 2.5 file yet, skipped, or not installed)" $false
                    $E.ui.Log("Held back $($item.name): it needs $names, which isn't installed.")
                    Complete-Item $E 'skipped'
                    return
                }
                foreach ($req in $missing) {
                    $E.ui.Log("$($item.name) needs $($req.name). Installing that first.")
                    Add-RequirementToQueue $E $req $item
                }
                $E.current = $null
                return
            }
        }
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
        Set-ItemState $E $item 'Needs mod.io sign-in' 'Start the game once and open Mods on the main menu (or add a token in Settings), then click Start again' $false
        Complete-Item $E 'skipped'
        return
    }
    if (-not $E.config.modioGameId) { $E.config.modioGameId = Resolve-ModioGameId $tok; Save-Config $E.config }
    $gid = $E.config.modioGameId
    if (-not $E.subscribed) {
        try { $me = Invoke-Modio Get 'me' $tok; $E.ui.Log("mod.io: subscribing for account '$($me.username)'" + $(if ($E.config.modioSource -eq 'game') { " (the game's own mod.io sign-in)" } else { " (your token; it must be the account the game uses)" }) + '.') } catch {}
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
    if (-not $mod -and -not $item.modioId) {
        # Not offered for PC? Look again without the platform filter.
        $any = Select-ModioMatch (Search-Modio $gid $item.query $tok -AnyPlatform) $item.query $item.exclude
        if ($any.match -or $any.choices.Count -gt 0) {
            Set-ItemState $E $item 'Console only' 'mod.io offers this mod for consoles only, so PC skips it' $true
            $E.ui.Log("Console only (skipped on PC): $($item.name)")
            Complete-Item $E 'skipped'; return
        }
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

# ---------------------------------------------------------------- health checks
# Problems that stop the game from starting, found in the game folder. Each has an id, a level
# (error / warning / info), a title, a detail line and, when the app can fix it, a fix id.

function Get-HealthIssues([string]$GameDir) {
    $issues = New-Object System.Collections.ArrayList
    $sccMsg = $null
    if (-not $GameDir -or -not (Test-Path -LiteralPath $GameDir)) { return $issues }
    $modded = Join-Path $GameDir 'r6\cache\modded'
    if ((Test-Path -LiteralPath $modded) -and -not (Get-ChildItem -LiteralPath $modded -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        [void]$issues.Add([pscustomobject]@{ id = 'empty-modded-cache'; level = 'error'; title = 'Empty REDmod script cache folder'
            detail = 'r6\cache\modded exists but is empty. The script compiler then fails ("Failed to load the original script cache") and the game crashes on start-up.'; fix = 'rename-modded' })
    }
    # The game's own script cache is about 20 MB. A much smaller file means it was overwritten
    # (e.g. by a mod or tool that wrote its compiled scripts there) and every launch fails with
    # "Failed to load the original script cache". Only Steam can restore the original.
    $orig = Join-Path $GameDir 'r6\cache\final.redscripts'
    if (Test-Path -LiteralPath $orig) {
        $len = (Get-Item -LiteralPath $orig).Length
        if ($len -lt 2MB) {
            [void]$issues.Add([pscustomobject]@{ id = 'script-cache-damaged'; level = 'error'; title = "The game's script cache has been replaced"
                detail = ("r6\cache\final.redscripts is only {0:N0} KB (the game's own file is about 20 MB), so mod scripts can't compile and the game crashes. Fix asks Steam to verify the game files, which restores it and leaves your mods alone. Wait for Steam to finish, then press Play." -f [Math]::Ceiling($len / 1KB)); fix = 'steam-verify' })
        }
    } else {
        [void]$issues.Add([pscustomobject]@{ id = 'script-cache-missing'; level = 'error'; title = "The game's script cache is missing"
            detail = 'r6\cache\final.redscripts is missing. Fix asks Steam to verify the game files, which restores it.'; fix = 'steam-verify' })
    }
    $logDir = Join-Path $GameDir 'red4ext\logs'
    $last = Get-ChildItem -LiteralPath $logDir -Filter 'red4ext-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($last) {
        $m = Select-String -LiteralPath $last.FullName -Pattern 'scc invocation failed with an error: (.+)$' | Select-Object -Last 1
        if ($m) {
            $sccMsg = $m.Matches[0].Groups[1].Value.Trim()
            [void]$issues.Add([pscustomobject]@{ id = 'scc-failed'; level = 'error'; title = 'Mod scripts failed to compile on the last launch'
                detail = "Last launch $($last.LastWriteTime.ToString('MMM d, h:mm tt')): $sccMsg. The game usually crashes after this. Fix anything else listed here, then press Play; this clears once a launch compiles cleanly."; fix = '' })
        }
    }
    $rs = Join-Path $GameDir 'r6\logs\redscript_rCURRENT.log'
    if ((Test-Path -LiteralPath $rs) -and -not ($sccMsg -and (Select-String -LiteralPath $rs -SimpleMatch $sccMsg -Quiet))) {
        $errs = @(Select-String -LiteralPath $rs -Pattern '^\[ERROR' | Select-Object -First 3)
        if ($errs.Count -gt 0) {
            [void]$issues.Add([pscustomobject]@{ id = 'redscript-errors'; level = 'error'; title = 'Script errors in the last compile'
                detail = (($errs | ForEach-Object { ($_.Line -replace '^\[ERROR - [^\]]*\]\s*', '') }) -join ' | '); fix = '' })
        }
    }
    $extra = Join-Path $GameDir 'V2077\mod-extra-files'
    if (Test-Path -LiteralPath $extra) {
        foreach ($d in (Get-ChildItem -LiteralPath $extra -Directory -ErrorAction SilentlyContinue)) {
            $plan = Get-ManualInstallPlan $d.FullName $d.Name
            if ($plan.copy.Count -gt 0) {
                [void]$issues.Add([pscustomobject]@{ id = "extra:$($d.Name)"; level = 'warning'; title = "Vortex couldn't place some files of $($d.Name)"
                    detail = "$($plan.copy.Count) game files are parked in V2077\mod-extra-files. The app can put them where they belong."; fix = "manual:$($d.Name)" })
            }
            if ($plan.redmod) {
                [void]$issues.Add([pscustomobject]@{ id = "redmod:$($d.Name)"; level = 'warning'; title = "$($d.Name) is a REDmod mod"
                    detail = 'It needs the free REDmod DLC (Steam > Cyberpunk 2077 > DLC) and Vortex REDmod deployment.'; fix = '' })
            }
        }
    }
    return $issues
}

# ---------------------------------------------------------------- mod.io account check
# The game signs in to mod.io through its own account link (CD PROJEKT RED / GOG). The mod.io
# SDK keeps that session in %LOCALAPPDATA%\mod.io\<gameId>\<user>\ and downloaded mods in
# C:\Users\Public\mod.io\<gameId>\mods. If that session belongs to a different mod.io account
# than the app's token, the app's subscriptions never reach the game. This reads those folders
# (names, JSON keys and user names only; token values are never read out or written anywhere).

function Get-JsonUserInfo($Node, $Found, [int]$Depth = 0) {
    if ($null -eq $Node -or $Depth -gt 8) { return }
    if ($Node -is [System.Array]) { foreach ($n in $Node) { Get-JsonUserInfo $n $Found ($Depth + 1) }; return }
    if ($Node -isnot [System.Management.Automation.PSCustomObject]) { return }
    $props = @($Node.PSObject.Properties)
    $names = @($props | ForEach-Object { $_.Name })
    foreach ($pr in $props) {
        $k = [string]$pr.Name
        [void]$Found.keys.Add($k)
        if ($k -match '^(username|name_id|display_?name|user_?name)$' -and $pr.Value -is [string] -and $pr.Value) { [void]$Found.users.Add([string]$pr.Value) }
        if ($k -match '^(user_?id|id)$' -and ($names -match '^(username|name_id|user_?name)$') -and $pr.Value) { [void]$Found.ids.Add([string]$pr.Value) }
        if ($k -match 'token|oauth|auth' -and $pr.Value) { $Found.token = $true }
        if ($pr.Value -is [System.Management.Automation.PSCustomObject] -or $pr.Value -is [System.Array]) { Get-JsonUserInfo $pr.Value $Found ($Depth + 1) }
    }
}

function Get-GameModioSession([int]$GameId) {
    $r = [pscustomobject]@{ gameId = $GameId; userRoot = ''; userDirs = @(); users = @(); ids = @(); hasToken = $false; modsDir = ''; installed = -1; files = @(); otherGames = @() }
    $local = Join-Path $env:LOCALAPPDATA 'mod.io'
    $public = Join-Path $env:PUBLIC 'mod.io'
    foreach ($root in @($local, $public)) {
        if (Test-Path -LiteralPath $root) { $r.otherGames += @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) }
    }
    $r.otherGames = @($r.otherGames | Sort-Object -Unique)
    $found = @{ users = (New-Object System.Collections.Generic.HashSet[string]); ids = (New-Object System.Collections.Generic.HashSet[string]); keys = (New-Object System.Collections.Generic.HashSet[string]); token = $false }
    $ur = Join-Path $local "$GameId"
    if (Test-Path -LiteralPath $ur) {
        $r.userRoot = $ur
        $r.userDirs = @(Get-ChildItem -LiteralPath $ur -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        $files = New-Object System.Collections.ArrayList
        foreach ($f in (Get-ChildItem -LiteralPath $ur -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 200)) {
            $rel = $f.FullName.Substring($ur.Length).TrimStart('\')
            $note = "$rel ($($f.Length) bytes)"
            if ($f.Length -lt 2MB) {
                try {
                    $txt = [IO.File]::ReadAllText($f.FullName)
                    if ($txt.TrimStart().StartsWith('{') -or $txt.TrimStart().StartsWith('[')) {
                        $before = $found.keys.Count
                        Get-JsonUserInfo ($txt | ConvertFrom-Json) $found
                        $note += ' json'
                    } else { $note += ' not json' }
                } catch { $note += ' unreadable' }
            }
            [void]$files.Add($note)
        }
        $r.files = @($files)
    }
    $r.users = @($found.users); $r.ids = @($found.ids); $r.hasToken = $found.token
    $r | Add-Member NoteProperty keys (@($found.keys | Sort-Object))
    $md = Join-Path $public "$GameId\mods"
    $r.modsDir = $md
    if (Test-Path -LiteralPath $md) { $r.installed = @(Get-ChildItem -LiteralPath $md -Directory -ErrorAction SilentlyContinue).Count } else { $r.installed = 0 }
    return $r
}

function Get-ModioLinkIssues($Session, [string]$TokenUser, [int]$TokenUserId, [int]$Subscribed, [bool]$CanUseGame = $false) {
    $issues = New-Object System.Collections.ArrayList
    if (-not $Session) { return $issues }
    if ($Session.userDirs.Count -eq 0) {
        [void]$issues.Add([pscustomobject]@{ id = 'modio-not-linked'; level = 'error'; title = 'Cyberpunk is not signed in to mod.io on this PC'
            detail = "The game has no mod.io sign-in yet, so it can't download your subscriptions. Start the game, open Mods on the main menu and link your account" + $(if ($TokenUser) { " as '$TokenUser'" } else { '' }) + '. Then return to the main menu so it downloads them.'; fix = '' })
        return $issues
    }
    $known = @($Session.users) + @($Session.ids)
    $match = ($TokenUser -and ($known -contains $TokenUser)) -or ($TokenUserId -and ($known -contains "$TokenUserId"))
    if ($TokenUser -and $Session.users.Count -gt 0 -and -not $match) {
        [void]$issues.Add([pscustomobject]@{ id = 'modio-account-mismatch'; level = 'error'; title = 'The game uses a different mod.io account'
            detail = "The game is signed in to mod.io as '$(($Session.users) -join "', '")', but the app subscribes as '$TokenUser'. The game only downloads mods subscribed on its own account. Fix switches the app to the game's own mod.io sign-in, then click Start install to subscribe the mods there."; fix = $(if ($CanUseGame) { 'modio-use-game' } else { '' }) })
    }
    if ($Subscribed -gt 0 -and $Session.installed -eq 0) {
        [void]$issues.Add([pscustomobject]@{ id = 'modio-nothing-downloaded'; level = 'warning'; title = "The game hasn't downloaded any mod.io mods yet"
            detail = "$Subscribed mods are subscribed on '$TokenUser', but the game's mod.io folder has none. Start the game and open Mods on the main menu: it downloads subscriptions there. If 'My Collection' stays empty, the game is linked to another mod.io account (sign out there and link '$TokenUser')."; fix = '' })
    }
    return $issues
}

function Write-ModioReport($Session, [string]$TokenUser, [int]$TokenUserId, [int]$Subscribed, $Issues) {
    $l = New-Object System.Collections.ArrayList
    [void]$l.Add("Night City Installer $($script:AppVersion) - mod.io check $((Get-Date).ToString('yyyy-MM-dd HH:mm'))")
    [void]$l.Add("App mod.io account: '$TokenUser' (id $TokenUserId), $Subscribed Cyberpunk mods subscribed")
    $gl = $null; try { $gl = Get-GameModioLogin ([int]$Session.gameId) } catch {}
    if ($gl) { [void]$l.Add("Game's own sign-in: '$($gl.username)' (id $($gl.id)), shown in game as '$($gl.portal)', expired: $($gl.expired)") }
    [void]$l.Add("Cyberpunk mod.io game id: $($Session.gameId); mod.io game folders on this PC: $($Session.otherGames -join ', ')")
    [void]$l.Add("Game session folder: $($Session.userRoot)  users: $($Session.userDirs -join ', ')")
    [void]$l.Add("Names found in the session: $($Session.users -join ', ')  ids: $($Session.ids -join ', ')  sign-in stored: $($Session.hasToken)")
    [void]$l.Add("JSON keys: $($Session.keys -join ', ')")
    [void]$l.Add("Downloaded mods folder: $($Session.modsDir)  count: $($Session.installed)")
    [void]$l.Add('Files:'); foreach ($f in $Session.files) { [void]$l.Add("  $f") }
    [void]$l.Add('Result:'); if (@($Issues).Count -eq 0) { [void]$l.Add('  no problem found') } else { foreach ($i in $Issues) { [void]$l.Add("  $($i.level): $($i.title) - $($i.detail)") } }
    try { Set-Content -LiteralPath (Join-Path $script:Root 'modio-check.txt') -Value $l -Encoding UTF8 } catch {}
}

# Safe, reversible fix for the crash: rename the empty folder (never delete anything).
function Repair-EmptyModdedCache([string]$GameDir) {
    $modded = Join-Path $GameDir 'r6\cache\modded'
    if (-not (Test-Path -LiteralPath $modded)) { return $false }
    if (Get-ChildItem -LiteralPath $modded -Force -ErrorAction SilentlyContinue | Select-Object -First 1) { return $false }
    $target = Join-Path $GameDir ('r6\cache\_modded_empty_' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Rename-Item -LiteralPath $modded -NewName (Split-Path $target -Leaf)
    return $true
}

# ---------------------------------------------------------------- requirements
# Mods name what they need in their description (usually under a "Requirements" heading) or readme.
# The app knows these frameworks and libraries by name and Nexus id.

$script:KnownRequirements = @(
    @{ id = 107;   name = 'Cyber Engine Tweaks';            re = 'cyber ?engine ?tweaks|\bCET\b' },
    @{ id = 2380;  name = 'RED4ext';                        re = 'red4ext' },
    @{ id = 1511;  name = 'redscript';                      re = '\bredscript\b' },
    @{ id = 4198;  name = 'ArchiveXL';                      re = 'archive ?xl' },
    @{ id = 4197;  name = 'TweakXL';                        re = 'tweak ?xl' },
    @{ id = 7780;  name = 'Codeware';                       re = 'codeware' },
    @{ id = 4575;  name = 'Input Loader';                   re = 'input ?loader' },
    @{ id = 4885;  name = 'Mod Settings';                   re = '\bmod settings\b' },
    @{ id = 3518;  name = 'Native Settings UI';             re = 'native ?settings' },
    @{ id = 21422; name = 'Native Interactions Framework';  re = 'native interactions' },
    @{ id = 12001; name = 'Audioware';                      re = 'audioware' },
    @{ id = 13077; name = 'Trigger Mode Control';           re = 'trigger mode control' },
    @{ id = 26764; name = 'Radial Menu Upgrade';            re = 'radial menu upgrade' },
    @{ id = 14139; name = 'RedData';                        re = '\bred ?data\b' },
    @{ id = 13378; name = 'RedFileSystem';                  re = 'red ?file ?system' },
    @{ id = 14192; name = 'RedHttpClient';                  re = 'red ?http ?client' },
    @{ id = 9429;  name = 'Cyberware-EX';                   re = 'cyberware-?ex\b' },
    @{ id = 6945;  name = 'Equipment-EX';                   re = 'equipment-?ex\b' },
    @{ id = 2987;  name = 'Virtual Atelier';                re = 'virtual atelier' },
    @{ id = 4591;  name = 'RadioExt';                       re = 'radio ?ext\b' },
    @{ id = 790;   name = 'Appearance Menu Mod';            re = 'appearance menu mod|\bAMM\b' }
)

function ConvertTo-PlainText([string]$Text) {
    $t = [string]$Text
    $t = $t -replace '(?i)<br\s*/?>', "`n" -replace '(?i)\[/?(b|i|u|s|center|right|left|size|color|font|quote|spoiler|url|img|youtube|heading|line|list|\*)[^\]]*\]', ' '
    $t = $t -replace '<[^>]+>', ' ' -replace '&nbsp;', ' ' -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>' -replace '&quot;', '"' -replace '&#39;', "'"
    return ($t -replace '[ \t]+', ' ')
}

# Finds required mods in a description or readme. Looks inside a "Requirements" section when
# there is one; lines that say "optional", "not required" or "compatible" are ignored.
# Nexus mod links inside a page's Requirements section (raw description, before tags are removed).
function Get-RequirementLinksFromText([string]$Text, [int]$SelfId = 0) {
    $t = [string]$Text
    $m = [regex]::Match($t, '(?i)\b(requirements?|required|dependenc(y|ies)|prerequisites?)\b')
    if (-not $m.Success) { return @() }
    $seg = $t.Substring($m.Index, [Math]::Min(1500, $t.Length - $m.Index))
    $stop = [regex]::Match($seg.Substring([Math]::Min(20, $seg.Length)), '(?i)\b(optional|recommended|installation|compatib|features|changelog|credits|known issues)\b')
    if ($stop.Success) { $seg = $seg.Substring(0, $stop.Index + [Math]::Min(20, $seg.Length)) }
    $ids = New-Object System.Collections.ArrayList
    foreach ($x in [regex]::Matches($seg, '(?i)nexusmods\.com/cyberpunk2077/mods/(\d{1,6})')) { $id = [int]$x.Groups[1].Value; if ($id -ne $SelfId -and -not $ids.Contains($id)) { [void]$ids.Add($id) } }
    return $ids.ToArray()
}

function Get-RequirementsFromText([string]$Text, [int]$SelfId = 0) {
    $plain = ConvertTo-PlainText $Text
    $lines = $plain -split "`r?`n"
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '(?i)\b(requirements?|required|dependenc(y|ies)|prerequisites?|needs?)\b|\u524d\u7f6e|\u4f9d\u8d56') { $start = $i; break } }
    if ($start -lt 0) { return @() }
    $section = New-Object System.Collections.ArrayList
    for ($i = $start; $i -lt [Math]::Min($lines.Count, $start + 25); $i++) {
        $l = $lines[$i]
        if ($i -gt $start + 1 -and $l -match '(?i)^\s*(installation|install|features?|description|changelog|compatib|credits|known issues|how to|uninstall|\u529f\u80fd|\u5378\u8f7d|\u70ed\u952e)\b') { break }
        if ($l -match '(?i)optional|not required|not needed|compatible with|works with|no longer|\u4e0d\u9700\u8981') { continue }
        [void]$section.Add($l)
    }
    $text2 = $section -join "`n"
    $found = New-Object System.Collections.ArrayList
    foreach ($r in $script:KnownRequirements) {
        if ($r.id -ne $SelfId -and $text2 -imatch $r.re) { [void]$found.Add([pscustomobject]@{ id = $r.id; name = $r.name }) }
    }
    return $found.ToArray()   # items go down the pipeline one by one; callers wrap in @()
}

# ---------------------------------------------------------------- mod details (description, photos)
$script:ModInfoCache = $null
function Get-ModInfoCache {
    if ($null -eq $script:ModInfoCache) {
        $script:ModInfoCache = @{}
        $d = Read-JsonFile (Join-Path $script:DataDir 'modinfo.json')
        if ($d) { foreach ($p in $d.PSObject.Properties) { $script:ModInfoCache[$p.Name] = $p.Value } }
    }
    return $script:ModInfoCache
}
function Save-ModInfoCache { Write-JsonFile (Join-Path $script:DataDir 'modinfo.json') (Get-ModInfoCache) }

function Get-NexusModInfo([int]$Id, [string]$Key, [switch]$Refresh) {
    $c = Get-ModInfoCache; $k = "nexus:$Id"
    $now = [long]([datetimeoffset][datetime]::UtcNow).ToUnixTimeSeconds()
    if (-not $Refresh -and $c.ContainsKey($k) -and ($now - [long]$c[$k].fetched) -lt 259200) { return $c[$k] }
    if (-not $Key) { if ($c.ContainsKey($k)) { return $c[$k] } else { return $null } }
    $o = Invoke-Nexus "games/cyberpunk2077/mods/$Id.json" $Key
    $desc = [string]$o.description; if ($desc.Length -gt 20000) { $desc = $desc.Substring(0, 20000) }
    $info = [pscustomobject]@{ source = 'nexus'; id = $Id; name = [string]$o.name; summary = (ConvertTo-PlainText ([string]$o.summary)).Trim(); description = $desc
        author = [string]$o.author; version = [string]$o.version; endorsements = [int]$o.endorsement_count; downloads = [int]$o.mod_downloads
        images = @([string]$o.picture_url | Where-Object { $_ }); adult = [bool]$o.contains_adult_content
        url = "https://www.nexusmods.com/cyberpunk2077/mods/$Id"; gallery = "https://www.nexusmods.com/cyberpunk2077/mods/$Id`?tab=images"; fetched = $now }
    $c[$k] = $info; Save-ModInfoCache
    return $info
}

function Get-ModioModInfo([int]$GameId, [int]$ModId, [string]$Token, [switch]$Refresh) {
    $c = Get-ModInfoCache; $k = "modio:$ModId"
    $now = [long]([datetimeoffset][datetime]::UtcNow).ToUnixTimeSeconds()
    if (-not $Refresh -and $c.ContainsKey($k) -and ($now - [long]$c[$k].fetched) -lt 259200) { return $c[$k] }
    if (-not $Token) { if ($c.ContainsKey($k)) { return $c[$k] } else { return $null } }
    $o = Invoke-Modio Get "games/$GameId/mods/$ModId" $Token -AnyPlatform
    $imgs = New-Object System.Collections.ArrayList
    try { if ($o.logo.thumb_640x360) { [void]$imgs.Add([string]$o.logo.thumb_640x360) } } catch {}
    try { foreach ($im in @($o.media.images)) { $u = if ($im.thumb_1280x720) { $im.thumb_1280x720 } elseif ($im.original) { $im.original } else { $im.thumb_320x180 }; if ($u -and $imgs.Count -lt 6) { [void]$imgs.Add([string]$u) } } } catch {}
    $desc = [string]$o.description_plaintext; if (-not $desc) { $desc = [string]$o.description }
    $info = [pscustomobject]@{ source = 'modio'; id = $ModId; name = [string]$o.name; summary = [string]$o.summary; description = $desc
        author = [string]$o.submitted_by.username; version = $(try { [string]$o.modfile.version } catch { '' }); endorsements = $(try { [int]$o.stats.ratings_positive } catch { 0 }); downloads = $(try { [int]$o.stats.downloads_total } catch { 0 })
        images = @($imgs); adult = $(try { [int]$o.maturity_option -gt 0 } catch { $false }); url = [string]$o.profile_url; gallery = [string]$o.profile_url; fetched = $now }
    $c[$k] = $info; Save-ModInfoCache
    return $info
}

# Downloads an image once into the app's cache folder and returns the local path.
function Get-CachedImage([string]$Url) {
    if (-not $Url) { return $null }
    $dir = Join-Path $script:DataDir 'img'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $sha = [Security.Cryptography.SHA1]::Create()
    $name = (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Url)) | ForEach-Object { $_.ToString('x2') }) -join '') + '.img'
    $path = Join-Path $dir $name
    if (-not (Test-Path -LiteralPath $path)) {
        # Windows Forms can't show WebP, so ask the CDN for JPEG/PNG first.
        Invoke-WebRequest -Uri $Url -OutFile $path -UseBasicParsing -TimeoutSec 30 -Headers @{ 'User-Agent' = 'NightCityInstaller'; 'Accept' = 'image/jpeg,image/png,image/gif;q=0.9,*/*;q=0.1' } | Out-Null
    }
    return $path
}

# Turns downloaded image bytes into a System.Drawing image. JPEG/PNG/GIF/BMP load directly. WebP
# (what the Nexus CDN often sends) goes through the Windows Imaging Component codec via WPF and is
# re-encoded as PNG; the PNG is cached next to the original so this only happens once per picture.
# WebP (what the Nexus CDN often sends) can't be shown by Windows Forms. This converts it once to a
# PNG next to the download, through the Windows Imaging Component codec (via WPF), and returns the
# path of a file Windows Forms can show. Runs in the background so the window never waits.
function Get-DisplayImagePath([string]$Path) {
    $png = $Path + '.png'
    if (Test-Path -LiteralPath $png) { return $png }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $isWebp = $bytes.Length -gt 12 -and [Text.Encoding]::ASCII.GetString($bytes, 8, 4) -eq 'WEBP'
    if (-not $isWebp) { return $Path }
    Add-Type -AssemblyName PresentationCore, WindowsBase
    $in = New-Object IO.MemoryStream (, $bytes)
    $dec = [Windows.Media.Imaging.BitmapDecoder]::Create($in, [Windows.Media.Imaging.BitmapCreateOptions]::None, [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($dec.Frames[0]))
    $out = New-Object IO.MemoryStream; $enc.Save($out)
    [IO.File]::WriteAllBytes($png, $out.ToArray())
    return $png
}

function ConvertTo-DrawingImage([string]$Path) {
    $p = Get-DisplayImagePath $Path
    return [Drawing.Image]::FromStream((New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($p))))
}

# ---------------------------------------------------------------- manual installs
# Vortex parks files it can't place in V2077\mod-extra-files\<mod>. The app puts them where the
# standard Cyberpunk layout says they go and records every file it adds so it can remove them.

$script:GameRoots = @('archive/pc/mod', 'bin/x64', 'r6/scripts', 'r6/tweaks', 'r6/config', 'red4ext/plugins', 'engine/config', 'engine/tools', 'mods')
$script:DocExt = @('.txt', '.md', '.pdf', '.png', '.jpg', '.jpeg', '.gif', '.webp', '.url', '.html', '.htm', '.rtf', '.docx')

function Get-ManualInstallPlan([string]$Dir, [string]$ModName) {
    $safe = ($ModName -replace '[^A-Za-z0-9 ._-]', '').Trim(); if (-not $safe) { $safe = 'ManualMod' }
    $copy = New-Object System.Collections.ArrayList; $docs = New-Object System.Collections.ArrayList; $unknown = New-Object System.Collections.ArrayList
    $redmod = $false
    $files = @(Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '__folder_managed_by_vortex' })
    $cetRoots = @($files | Where-Object { $_.Name -eq 'init.lua' } | ForEach-Object { $_.DirectoryName })
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($Dir.Length).TrimStart('\', '/') -replace '\\', '/'
        $low = $rel.ToLowerInvariant()
        $ext = $f.Extension.ToLowerInvariant()
        $dest = $null
        foreach ($root in $script:GameRoots) {
            $ix = $low.IndexOf($root + '/')
            if ($low.StartsWith($root + '/')) { $ix = 0 }
            elseif ($ix -gt 0 -and $low[$ix - 1] -ne '/') { $ix = -1 }
            if ($ix -ge 0) { $dest = $rel.Substring($ix); if ($root -eq 'mods') { $redmod = $true }; break }
        }
        if (-not $dest) {
            if ($f.Name -eq 'info.json' -and (Test-Path -LiteralPath (Join-Path $f.DirectoryName 'archives'))) { $redmod = $true; continue }
            $cet = $cetRoots | Where-Object { $f.DirectoryName.StartsWith($_) } | Select-Object -First 1
            if ($cet) { $dest = 'bin/x64/plugins/cyber_engine_tweaks/mods/' + (Split-Path $cet -Leaf) + ($f.FullName.Substring($cet.Length) -replace '\\', '/') }
            elseif ($ext -in @('.archive', '.xl')) { $dest = 'archive/pc/mod/' + $f.Name }
            elseif ($ext -eq '.reds') { $dest = "r6/scripts/$safe/" + $f.Name }
            elseif ($ext -in @('.yaml', '.yml', '.tweak')) { $dest = "r6/tweaks/$safe/" + $f.Name }
            elseif ($ext -in $script:DocExt) { [void]$docs.Add($f.FullName); continue }
            else { [void]$unknown.Add($rel); continue }
        }
        [void]$copy.Add([pscustomobject]@{ src = $f.FullName; dest = $dest })
    }
    return [pscustomobject]@{ copy = @($copy); docs = @($docs); unknown = @($unknown); redmod = $redmod }
}

function Invoke-ManualInstall([string]$GameDir, $Plan, [string]$Key) {
    $done = New-Object System.Collections.ArrayList; $skipped = New-Object System.Collections.ArrayList
    foreach ($c in $Plan.copy) {
        if ($c.dest -match '\.\.') { continue }
        $target = Join-Path $GameDir ($c.dest -replace '/', '\')
        if (Test-Path -LiteralPath $target) { [void]$skipped.Add($c.dest); continue }   # never overwrite what Vortex placed
        $dir = Split-Path $target -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Copy-Item -LiteralPath $c.src -Destination $target
        [void]$done.Add($c.dest)
    }
    $recPath = Join-Path $script:DataDir 'manual-installs.json'
    $rec = @{}; $r = Read-JsonFile $recPath
    if ($r) { foreach ($p in $r.PSObject.Properties) { $rec[$p.Name] = @($p.Value) } }
    $rec[$Key] = @(@($rec[$Key]) + @($done) | Where-Object { $_ } | Select-Object -Unique)
    Write-JsonFile $recPath $rec
    return [pscustomobject]@{ copied = @($done); skipped = @($skipped) }
}

function Get-ExtraFilesFolder([string]$GameDir, [string]$ModName, [int]$NexusId) {
    $extra = Join-Path $GameDir 'V2077\mod-extra-files'
    if (-not (Test-Path -LiteralPath $extra)) { return $null }
    $want = Normalize-Name $ModName
    foreach ($d in (Get-ChildItem -LiteralPath $extra -Directory -ErrorAction SilentlyContinue)) {
        $n = Normalize-Name $d.Name
        if ($n -and ($n -eq $want -or ($want -and ($n.StartsWith($want) -or $want.StartsWith($n))) -or ($NexusId -and $d.Name -match "(^|\D)$NexusId(\D|$)"))) { return $d.FullName }
    }
    return $null
}

# After Vortex installs a mod: place any files it parked, read the readme for requirements.
function Invoke-PostInstallCheck($E, $Item) {
    $mods = Get-InstalledNexusMods $E.config.gameDir
    $vname = if ($mods.ContainsKey([int]$Item.id)) { $mods[[int]$Item.id].name } else { $Item.name }
    $dir = Get-ExtraFilesFolder $E.config.gameDir $vname $Item.id
    if (-not $dir) { $dir = Get-ExtraFilesFolder $E.config.gameDir $Item.name $Item.id }
    if (-not $dir) { return }
    $plan = Get-ManualInstallPlan $dir (Split-Path $dir -Leaf)
    if ($plan.copy.Count -gt 0) {
        $res = Invoke-ManualInstall $E.config.gameDir $plan $Item.key
        $E.ui.Log("Manual install for $($Item.name): placed $($res.copied.Count) files Vortex couldn't" + $(if ($res.skipped.Count) { ", left $($res.skipped.Count) that already existed" } else { '' }) + '.')
    }
    if ($plan.redmod) { $E.ui.Log("$($Item.name) is a REDmod mod: it needs the free REDmod DLC from Steam to work.") }
    foreach ($doc in @($plan.docs | Where-Object { $_ -match '\.(txt|md)$' })) {
        $txt = Get-Content -LiteralPath $doc -Raw -ErrorAction SilentlyContinue
        $c = Get-ModInfoCache
        if ($c.ContainsKey($Item.key)) { $c[$Item.key] | Add-Member -NotePropertyName readme -NotePropertyValue $txt -Force }
        else { $c["readme:$($Item.key)"] = [pscustomobject]@{ readme = $txt } }
        Save-ModInfoCache
        foreach ($req in (Get-RequirementsFromText $txt $Item.id)) {
            if (-not $mods.ContainsKey([int]$req.id) -and -not $E.reqQueued.Contains([int]$req.id)) {
                $E.ui.Log("$($Item.name)'s readme says it needs $($req.name). Adding it next.")
                Add-RequirementToQueue $E $req $Item
            }
        }
    }
}

# Puts a required mod into the queue right after the current position.
# Puts a required Nexus mod in the list (group "Requirements added automatically") and returns it.
# It is a "verify" item: the installer only installs it if its newest file is from after the patch.
function Add-RequirementItem($Manifest, [int]$Id, [string]$Name, [string]$Note) {
    $key = "nexus:$Id"
    $existing = $Manifest.items | Where-Object { $_.key -eq $key } | Select-Object -First 1
    if ($existing) { return $existing }
    if (-not $Manifest.batches.ContainsKey(94)) { $Manifest.batches[94] = [pscustomobject]@{ id = 94; name = 'Requirements added automatically'; source = 'nexus' } }
    $it = [pscustomobject]@{ key = $key; kind = 'install'; order = @($Manifest.items).Count; batch = 94; source = 'nexus'; name = $Name; id = $Id
        query = ''; exclude = ''; optional = $false; verify = $true; note = $Note; modioId = 0; discovered = $false }
    [void]$Manifest.items.Add($it)
    return $it
}

function Add-RequirementToQueue($E, $Req, $ForItem) {
    [void]$E.reqQueued.Add([int]$Req.id)
    $key = "nexus:$($Req.id)"
    $existing = $E.manifest.items | Where-Object { $_.key -eq $key } | Select-Object -First 1
    if (-not $existing) {
        if (-not $E.manifest.batches.ContainsKey(94)) { $E.manifest.batches[94] = [pscustomobject]@{ id = 94; name = 'Requirements added automatically'; source = 'nexus' } }
        $existing = [pscustomobject]@{ key = $key; kind = 'install'; order = @($E.manifest.items).Count; batch = 94; source = 'nexus'; name = $Req.name; id = [int]$Req.id
            query = ''; exclude = ''; optional = $false; verify = $true; note = "Required by $($ForItem.name)"; modioId = 0; discovered = $false }
        [void]$E.manifest.items.Add($existing)
        if ($E.ui.PSObject.Methods['AddItem']) { $E.ui.AddItem($existing) }
    }
    $head = @($E.queue | Select-Object -First $E.pos)
    $tail = @($E.queue | Select-Object -Skip $E.pos)
    $E.queue = @($head) + @($existing) + @($tail)
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
                foreach ($u in (ConvertTo-FlatList (Invoke-Nexus "games/$game/mods/updated.json?period=1m" $key))) {
                    if ([long]$u.latest_file_update -ge $D.patchTs) { $cands[[int]$u.mod_id] = [long]$u.latest_file_update }
                }
            } catch { $D.ui.Log('Discovery: Nexus update feed failed: ' + $_.Exception.Message) }
            foreach ($feed in 'trending', 'latest_added', 'latest_updated') {
                try {
                    foreach ($o in (ConvertTo-FlatList (Invoke-Nexus "games/$game/mods/$feed.json" $key))) {
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
# Dark, Vortex-style layout: sidebar navigation with a Play button, a mods table with status
# badges and filters, and a details pane with the mod's description, photos and requirements.

# ---------------------------------------------------------------- background work
# Network and disk-heavy work runs on a small pool of background threads so the window never
# freezes. Each job gets its own copy of this script's functions (the script is dot-sourced once
# per pool thread) and talks to the window only through a queue: the window drains that queue on
# a timer and does all drawing itself.

$script:BgBootstrap = @'
param($ScriptPath, $Queue, $Code, $ArgList, $Box, $ModioBase)
$ErrorActionPreference = 'Stop'
try {
    if (-not (Get-Command New-BgUi -ErrorAction SilentlyContinue)) { . $ScriptPath -TestMode }
    if ($ModioBase) { $script:ModioBase = $ModioBase }
    $BgUi = New-BgUi $Queue
    $Box.result = & ([scriptblock]::Create($Code)) @ArgList
} catch {
    $Box.error = $_.Exception.Message
    $Box.errorAt = [string]$_.InvocationInfo.PositionMessage
}
'@

# A stand-in for the window's UI object that queues every call for the window thread.
function New-BgUi($Queue) {
    $o = [pscustomobject]@{ q = $Queue }
    foreach ($m in 'Log', 'SetStatus', 'Banner', 'OpenUrl', 'AddItem', 'UpdateRow', 'CheckFinished', 'DiscoveryFinished', 'Post') {
        $o | Add-Member ScriptMethod $m ([scriptblock]::Create("`$this.q.Enqueue([object[]]@('$m', `$args[0], `$args[1], `$args[2]))"))
    }
    return $o
}

function New-BgRunner([int]$Max = 3) {
    $pool = [runspacefactory]::CreateRunspacePool(1, $Max)
    if ($script:IsWin) { try { $pool.ApartmentState = [Threading.ApartmentState]::STA } catch {} }
    $pool.Open()
    return [pscustomobject]@{ pool = $pool; jobs = (New-Object System.Collections.ArrayList); queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]') }
}

function Start-BgJob($Runner, [string]$Name, [scriptblock]$Work, [object[]]$ArgList, $OnDone) {
    $box = [hashtable]::Synchronized(@{ name = $Name; result = $null; error = $null; errorAt = '' })
    $ps = [powershell]::Create(); $ps.RunspacePool = $Runner.pool
    [void]$ps.AddScript($script:BgBootstrap).AddArgument($script:ScriptPath).AddArgument($Runner.queue).AddArgument($Work.ToString()).AddArgument(@($ArgList)).AddArgument($box).AddArgument($script:ModioBase)
    $job = [pscustomobject]@{ name = $Name; ps = $ps; handle = $ps.BeginInvoke(); box = $box; onDone = $OnDone; started = (Get-Date) }
    [void]$Runner.jobs.Add($job)
    return $job
}

function Test-BgJobRunning($Runner, [string]$Name) {
    if (-not $Runner) { return $false }
    return [bool](@($Runner.jobs) | Where-Object { $_.name -eq $Name } | Select-Object -First 1)
}

# Returns the jobs that have finished (their PowerShell instances already cleaned up).
function Receive-BgJobs($Runner) {
    $done = New-Object System.Collections.ArrayList
    foreach ($j in @($Runner.jobs)) {
        if (-not $j.handle.IsCompleted) { continue }
        try { [void]$j.ps.EndInvoke($j.handle) } catch { if (-not $j.box.error) { $j.box.error = $_.Exception.Message } }
        try { $j.ps.Dispose() } catch {}
        [void]$Runner.jobs.Remove($j)
        [void]$done.Add($j)
    }
    return $done.ToArray()
}

function Stop-BgRunner($Runner) {
    if (-not $Runner) { return }
    foreach ($j in @($Runner.jobs)) { try { $j.ps.Stop(); $j.ps.Dispose() } catch {} }
    try { $Runner.pool.Close(); $Runner.pool.Dispose() } catch {}
}

# The mod.io account check (see Get-ModioLinkIssues), callable from a background thread.
# $Ref is a shared table that remembers the account and subscription count for 10 minutes.
function Get-ModioCheckIssues($Cfg, $Ref, $Log) {
    if (-not $Cfg.modioToken -or -not $Cfg.modioGameId) { return @() }
    try {
        if (-not $Ref.when -or ((Get-Date) - [datetime]$Ref.when).TotalMinutes -gt 10) {
            try { $me = Invoke-Modio Get 'me' $Cfg.modioToken }
            catch {
                if ($Cfg.modioSource -ne 'game' -or -not $Cfg.modioPat) { throw }
                if ($Log) { $Log.Log("mod.io refused the game's own sign-in from outside the game ($($_.Exception.Message)). Using your token from Settings instead.") }
                $Cfg.modioToken = $Cfg.modioPat; $Cfg.modioSource = 'pat'; $Cfg.modioGameLogin = $null
                $me = Invoke-Modio Get 'me' $Cfg.modioToken
            }
            $Ref.user = [string]$me.username; $Ref.uid = [int]$me.id
            $Ref.subs = (Get-ModioSubscribed $Cfg.modioGameId $Cfg.modioToken).Count
            $Ref.when = Get-Date
        }
        $sess = Get-GameModioSession ([int]$Cfg.modioGameId)
        $iss = @(Get-ModioLinkIssues $sess $Ref.user $Ref.uid $Ref.subs ([bool](Get-GameModioLogin ([int]$Cfg.modioGameId))))
        Write-ModioReport $sess $Ref.user $Ref.uid $Ref.subs $iss
        return $iss
    } catch { if ($Log) { $Log.Log('mod.io check failed: ' + $_.Exception.Message) }; return @() }
}

# ---------------------------------------------------------------- silent app updates
# A new version is downloaded and checked in the background, then swapped in when the app closes
# (or, if the app was closed some other way, the next time it starts). No prompts, no restart.

function Get-PendingUpdatePath { return (Join-Path $script:DataDir 'pending-update.json') }

function Save-AppUpdate($Info, [string]$Token) {
    Ensure-DataDir
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
    Write-JsonFile (Get-PendingUpdatePath) ([ordered]@{ version = [string]$Info.version; notes = [string]$Info.notes; stage = $stage
        files = @($files | ForEach-Object { [ordered]@{ path = [string]$_.path; sha256 = [string]$_.sha256 } }) })
    return $stage
}

function Get-PendingAppUpdate {
    $p = Read-JsonFile (Get-PendingUpdatePath)
    if (-not $p -or -not $p.version -or -not $p.stage) { return $null }
    try { if ([version]$p.version -le [version]$script:AppVersion) { return $null } } catch { return $null }
    if (-not (Test-Path -LiteralPath ([string]$p.stage))) { return $null }
    return $p
}

# Swaps a downloaded update in. Re-checks every file's fingerprint first; keeps a backup.
function Install-StagedAppUpdate {
    $p = Get-PendingAppUpdate
    if (-not $p) {
        $pp = Get-PendingUpdatePath
        if (Test-Path -LiteralPath $pp) { Remove-Item -LiteralPath $pp -Force -ErrorAction SilentlyContinue }
        return $null
    }
    $files = @($p.files)
    foreach ($f in $files) {
        if (-not (Test-SafeFileName ([string]$f.path))) { throw "Unsafe file name in the staged update: $($f.path)" }
        $src = Join-Path ([string]$p.stage) ([string]$f.path)
        if (-not (Test-Path -LiteralPath $src) -or ((Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash -ine [string]$f.sha256)) { throw "The staged update is incomplete ($($f.path)); it will be downloaded again." }
    }
    $backup = Join-Path $script:DataDir ('backup-' + $script:AppVersion)
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach ($f in $files) {
        $cur = Join-Path $script:Root ([string]$f.path)
        if (Test-Path -LiteralPath $cur) { Copy-Item -LiteralPath $cur -Destination (Join-Path $backup ([string]$f.path)) -Force }
    }
    foreach ($f in $files) { Copy-Item -LiteralPath (Join-Path ([string]$p.stage) ([string]$f.path)) -Destination (Join-Path $script:Root ([string]$f.path)) -Force }
    Remove-Item -LiteralPath ([string]$p.stage) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Get-PendingUpdatePath) -Force -ErrorAction SilentlyContinue
    return [string]$p.version
}

# ---------------------------------------------------------------- Vortex-style requirement check
# Same check as Vortex's Health Check: for every Nexus mod you have installed, ask Nexus for the
# mod's listed requirements (the "modRequirements" GraphQL query Vortex uses) and report the ones
# that are not installed, installed but not enabled (not deployed), and DLC requirements.

$script:NexusGraphUrl = 'https://api.nexusmods.com/v2/graphql'
$script:NexusReqFields = 'modRequirements { nexusRequirements { nodes { modId modName gameId externalRequirement notes } totalCount } dlcRequirements { gameExpansion { name } notes } }'
# Ways to ask Nexus for requirements, newest first. The first that works is remembered.
$script:NexusReqVariants = @(
    @{ name = 'modsByUid';          batch = $true;  query = 'query Reqs($uids: [ID!]!) { modsByUid(uids: $uids) { nodes { modId FIELDS } } }' },
    @{ name = 'legacyModsByDomain'; batch = $true;  query = 'query Reqs($ids: [CompositeDomainWithIdInput!]!) { legacyModsByDomain(ids: $ids) { nodes { modId FIELDS } } }' },
    @{ name = 'mod';                batch = $false; query = 'query Req($modId: ID!, $gameId: ID!) { mod(modId: $modId, gameId: $gameId) { modId FIELDS } }' }
)
$script:CyberpunkNexusGameId = 3333
$script:RequirementCacheHours = 12

# Frameworks people often install by hand instead of through Vortex: a file that proves each one.
$script:FrameworkFiles = @{
    107  = 'bin\x64\plugins\cyber_engine_tweaks.asi'
    2380 = 'red4ext\RED4ext.dll'
    1511 = 'engine\tools\scc_lib.dll'
    4198 = 'red4ext\plugins\ArchiveXL\ArchiveXL.dll'
    4197 = 'red4ext\plugins\TweakXL\TweakXL.dll'
    7780 = 'red4ext\plugins\Codeware\Codeware.dll'
    4575 = 'red4ext\plugins\input_loader\input_loader.dll'
    4885 = 'red4ext\plugins\mod_settings\mod_settings.dll'
    3518 = 'bin\x64\plugins\cyber_engine_tweaks\mods\nativeSettings\init.lua'
}

function Invoke-NexusGraph([string]$Query, $Variables, [string]$Key) {
    $h = @{ apikey = $Key; Accept = 'application/json'; 'Application-Name' = 'NightCityInstaller'; 'Application-Version' = $script:AppVersion }
    $body = [ordered]@{ query = $Query; variables = $Variables } | ConvertTo-Json -Depth 6 -Compress
    $r = Invoke-RestMethod -Method Post -Uri $script:NexusGraphUrl -Headers $h -ContentType 'application/json' -Body $body -TimeoutSec 30
    if ($r.PSObject.Properties['errors'] -and $r.errors) { throw ('Nexus: ' + ((@($r.errors) | ForEach-Object { $_.message }) -join '; ')) }
    return $r.data
}

function Get-RequirementCache {
    if (-not $script:ReqCache) {
        $script:ReqCache = @{}
        $d = Read-JsonFile (Join-Path $script:DataDir 'requirements-v3.json')
        if ($d) { foreach ($p in $d.PSObject.Properties) { $script:ReqCache[$p.Name] = $p.Value } }
    }
    return $script:ReqCache
}
function Save-RequirementCache { try { Write-JsonFile (Join-Path $script:DataDir 'requirements-v3.json') (Get-RequirementCache) } catch {} }

function ConvertTo-RequirementRecord($ModNode, [long]$Now) {
    $mr = $ModNode.modRequirements
    $nodes = @(); $dlc = @()
    if ($mr -and $mr.nexusRequirements) {
        $nodes = @(@($mr.nexusRequirements.nodes) | Where-Object { $_ } | ForEach-Object {
            [pscustomobject]@{ modId = [string]$_.modId; modName = [string]$_.modName; gameId = [string]$_.gameId; external = [bool]$_.externalRequirement; notes = [string]$_.notes } })
    }
    if ($mr -and $mr.dlcRequirements) { $dlc = @(@($mr.dlcRequirements) | Where-Object { $_ -and $_.gameExpansion } | ForEach-Object { [string]$_.gameExpansion.name }) }
    return [pscustomobject]@{ fetched = $Now; source = 'nexus'; nodes = $nodes; dlc = $dlc }
}

# Fetches requirements for many mods at once (like Vortex) and fills the cache.
function Update-NexusRequirements([int[]]$ModIds, [string]$Key) {
    $cache = Get-RequirementCache
    $now = [long]([datetimeoffset][datetime]::UtcNow).ToUnixTimeSeconds()
    $todo = @($ModIds | Where-Object {
        $c = $cache["$_"]
        $ttl = if ($c -and [string]$c.source -eq 'nexus') { $script:RequirementCacheHours * 3600 } else { 3600 }
        -not ($c -and ($now - [long]$c.fetched) -lt $ttl) })
    if ($todo.Count -eq 0) { return }
    $errors = New-Object System.Collections.ArrayList
    $variants = @($script:NexusReqVariants)
    if ($script:NexusReqVariant) { $variants = @($variants | Where-Object { $_.name -eq $script:NexusReqVariant }) + @($variants | Where-Object { $_.name -ne $script:NexusReqVariant }) }
    foreach ($v in $variants) {
        $q = $v.query -replace 'FIELDS', $script:NexusReqFields
        try {
            if ($v.batch) {
                for ($i = 0; $i -lt $todo.Count; $i += 40) {
                    $chunk = @($todo[$i..([Math]::Min($i + 39, $todo.Count - 1))])
                    $vars = if ($v.name -eq 'legacyModsByDomain') { @{ ids = @($chunk | ForEach-Object { @{ gameDomain = 'cyberpunk2077'; modId = [string]$_ } }) } }
                            else { @{ uids = @($chunk | ForEach-Object { [string](([long]$script:CyberpunkNexusGameId -shl 32) + [long]$_) }) } }
                    $data = Invoke-NexusGraph $q $vars $Key
                    $root = $data.($v.name)
                    foreach ($n in @($root.nodes)) { if ($n -and $n.modId) { $cache["$([int]$n.modId)"] = ConvertTo-RequirementRecord $n $now } }
                    foreach ($id in $chunk) { if (-not $cache["$id"] -or [long]$cache["$id"].fetched -ne $now) { $cache["$id"] = [pscustomobject]@{ fetched = $now; source = 'nexus'; nodes = @(); dlc = @() } } }
                }
            } else {
                foreach ($id in $todo) {
                    $data = Invoke-NexusGraph $q @{ modId = [string]$id; gameId = [string]$script:CyberpunkNexusGameId } $Key
                    $cache["$id"] = if ($data.mod) { ConvertTo-RequirementRecord $data.mod $now } else { [pscustomobject]@{ fetched = $now; source = 'nexus'; nodes = @(); dlc = @() } }
                }
            }
            $script:NexusReqVariant = $v.name
            $script:ReqGraphError = ''
            return
        } catch { [void]$errors.Add("$($v.name): $($_.Exception.Message)") }
    }
    $script:ReqGraphError = $errors -join ' || '
    try {
        $sch = Invoke-NexusGraph '{ __schema { queryType { fields { name args { name } } } } }' @{} $Key
        Write-Trace ('nexus query fields: ' + ((@($sch.__schema.queryType.fields) | Where-Object { $_.name -match 'mod|Mod' } | ForEach-Object { "$($_.name)(" + ((@($_.args) | ForEach-Object { $_.name }) -join ',') + ')' }) -join ' '))
    } catch { Write-Trace "nexus schema read failed: $($_.Exception.Message)" }
    # Nexus didn't answer: fall back to the "Requirements" section of each mod page (v1 API).
    foreach ($id in $todo) {
        try {
            $info = Get-NexusModInfo $id $Key
            $nodes = @(@(Get-RequirementsFromText ([string]$info.description) $id) | ForEach-Object { [pscustomobject]@{ modId = [string]$_.id; modName = [string]$_.name; gameId = ''; external = $false; notes = '' } })
            $cache["$id"] = [pscustomobject]@{ fetched = $now; source = 'page'; nodes = $nodes; dlc = @() }
        } catch {}
    }
}

# Requirements of one Nexus mod: { nodes = @({ modId, modName, gameId, external, notes }) ; dlc = @(names) ; source }
function Get-NexusRequirements([int]$ModId, [string]$Key) {
    Update-NexusRequirements @($ModId) $Key
    $c = (Get-RequirementCache)["$ModId"]
    if (-not $c) { throw "No requirement data for $ModId" }
    return $c
}

$script:ModioSubNames = $null
function Test-ModioHas([string]$Name) {
    if (-not $script:ModioSubNames -or -not $Name) { return $false }
    return $script:ModioSubNames.Contains((Normalize-Name $Name))
}

function Test-SameGameRequirement([string]$GameId) {
    return (-not $GameId -or $GameId -eq "$($script:CyberpunkNexusGameId)" -or $GameId -eq 'cyberpunk2077')
}

function Get-RequirementIssues([string]$GameDir, [string]$Key, $Log, $Report) {
    $issues = New-Object System.Collections.ArrayList
    if (-not $Key -or -not $GameDir) { return $issues.ToArray() }
    $installed = Get-InstalledNexusMods $GameDir
    $deployed = (Get-VortexInfo $GameDir).ids
    if ($installed.Count -eq 0) { return $issues.ToArray() }
    $missing = @{}; $disabled = @{}; $maybe = @{}; $dlcNeed = @{}; $failed = 0
    Update-NexusRequirements @($installed.Values | Where-Object { $deployed.Contains([int]$_.id) } | ForEach-Object { [int]$_.id }) $Key
    foreach ($m in ($installed.Values | Sort-Object name)) {
        if (-not $deployed.Contains([int]$m.id)) { continue }   # Vortex only checks enabled mods
        try { $req = Get-NexusRequirements ([int]$m.id) $Key } catch { $failed++; continue }
        # the description's "Requirements" section too (frameworks named there, and linked mods)
        $pageNodes = @()
        try {
            $info = Get-NexusModInfo ([int]$m.id) $Key
            if ($info -and $info.description) {
                $pageNodes += @(@(Get-RequirementsFromText ([string]$info.description) ([int]$m.id)) | ForEach-Object { [pscustomobject]@{ modId = [string]$_.id; modName = [string]$_.name; gameId = ''; external = $false; notes = 'named in the description'; origin = 'page' } })
                $pageNodes += @(@(Get-RequirementLinksFromText ([string]$info.description) ([int]$m.id)) | ForEach-Object { [pscustomobject]@{ modId = [string]$_; modName = ''; gameId = ''; external = $false; notes = 'linked in the description'; origin = 'page' } })
            }
        } catch {}
        $listed = @(@($req.nodes) | Where-Object { $_ -and ([string]$_.notes) -notmatch '(?i)\boptional\b|not required|not needed|recommended|soft ?req|^\s*add-?on\b|\badd-?on\s*:|suggest|whatever you want|only (if|for|needed)|if you (want|use|have)|for compatibility|compatib(le|ility) (with|patch)' })
        $listedIds = @($listed | ForEach-Object { [string]$_.modId })
        $allNodes = @(@($listed | ForEach-Object { $_ | Add-Member NoteProperty origin 'nexus' -Force -PassThru }) + @($pageNodes | Where-Object { $listedIds -notcontains [string]$_.modId }))
        if ($null -ne $Report) {
            $names = @($allNodes | Where-Object { -not $_.external -and (Test-SameGameRequirement $_.gameId) } | ForEach-Object {
                $rid = 0; [void][int]::TryParse([string]$_.modId, [ref]$rid)
                $nm = [string]$_.modName
                if (-not $nm -and $rid -gt 0) { $ci = (Get-ModInfoCache)["nexus:$rid"]; if ($ci) { $nm = [string]$ci.name } }
                $st = if ($rid -le 0) { '?' } elseif ($deployed.Contains($rid) -or (Test-FrameworkInstalled $GameDir $rid $deployed)) { 'ok' } elseif ($nm -and (Test-ModioHas $nm)) { 'ok via mod.io' } elseif ($installed.ContainsKey($rid)) { 'DISABLED' } elseif ($_.origin -eq 'page') { 'maybe missing' } else { 'MISSING' }
                "$(if ($nm) { $nm } else { "Nexus mod $rid" }) [$st]" } | Sort-Object -Unique)
            [void]$Report.Add("  Nexus   $($m.name) ($($m.id)): " + $(if ($names.Count) { $names -join ', ' } else { 'no requirements listed' }))
        }
        foreach ($n in $allNodes) {
            if ($n.external -or -not (Test-SameGameRequirement $n.gameId)) { continue }
            $rid = 0; if (-not [int]::TryParse([string]$n.modId, [ref]$rid) -or $rid -le 0 -or $rid -eq [int]$m.id) { continue }
            $fw = $script:FrameworkFiles[$rid]
            if ($deployed.Contains($rid)) { continue }
            if ($fw -and (Test-Path -LiteralPath (Join-Path $GameDir $fw))) { continue }
            if (Test-FrameworkInstalled $GameDir $rid $deployed) { continue }
            if ($n.modName -and (Test-ModioHas ([string]$n.modName))) { continue }
            $bucket = if ($installed.ContainsKey($rid)) { $disabled } elseif ($n.origin -eq 'page') { $maybe } else { $missing }
            if (-not $bucket.ContainsKey($rid)) {
                $rn = [string]$n.modName
                if (-not $rn) { try { $rn = [string](Get-NexusModInfo $rid $Key).name } catch {} }
                if (-not $rn) { $rn = "Nexus mod $rid" }
                $bucket[$rid] = [pscustomobject]@{ id = $rid; name = $rn; by = (New-Object System.Collections.ArrayList); notes = [string]$n.notes }
            }
            if (-not $bucket[$rid].by.Contains($m.name)) { [void]$bucket[$rid].by.Add($m.name) }
        }
        foreach ($d in @($req.dlc)) { if ($d) { if (-not $dlcNeed.ContainsKey($d)) { $dlcNeed[$d] = New-Object System.Collections.ArrayList }; [void]$dlcNeed[$d].Add($m.name) } }
    }
    Save-RequirementCache
    $srcs = @($installed.Values | ForEach-Object { $c2 = (Get-RequirementCache)["$($_.id)"]; if ($c2) { [string]$c2.source } }) | Group-Object | ForEach-Object { "$($_.Name)=$($_.Count)" }
    Write-Trace ("requirements: " + ($srcs -join ' ') + "; via $($script:NexusReqVariant); missing $($missing.Count), disabled $($disabled.Count); graph error: $($script:ReqGraphError)")
    foreach ($r in ($missing.Values | Sort-Object name)) {
        [void]$issues.Add([pscustomobject]@{ id = "req:$($r.id)"; level = 'error'; title = "Missing requirement: $($r.name)"
            detail = "Needed by $(@($r.by) -join ', '). Nexus lists it as a requirement and it isn't installed." + $(if ($r.notes) { " Author's note: $($r.notes)" } else { '' }) + ' Fix opens its download page; Vortex installs it.'; fix = "nexus-page:$($r.id)" })
    }
    foreach ($r in ($maybe.Values | Sort-Object name)) {
        if ($r.name -and (Test-ModioHas $r.name)) { continue }
        [void]$issues.Add([pscustomobject]@{ id = "reqhint:$($r.id)"; level = 'warning'; title = "Possibly missing: $($r.name)"
            detail = "Mentioned near the Requirements part of the description of $(@($r.by) -join ', '), but not in their official requirement list, so it may be optional. Check the mod page; Download opens it."; fix = "nexus-page:$($r.id)" })
    }
    foreach ($r in ($disabled.Values | Sort-Object name)) {
        [void]$issues.Add([pscustomobject]@{ id = "reqoff:$($r.id)"; level = 'error'; title = "Requirement is disabled in Vortex: $($r.name)"
            detail = "Needed by $(@($r.by) -join ', '). It is installed in Vortex but not enabled/deployed. Enable it on Vortex's Mods page."; fix = '' })
    }
    $hasEp1 = Test-Path -LiteralPath (Join-Path $GameDir 'archive\pc\ep1')
    foreach ($d in ($dlcNeed.Keys | Sort-Object)) {
        if ($d -match 'Phantom Liberty' -and $hasEp1) { continue }
        [void]$issues.Add([pscustomobject]@{ id = "dlc:$d"; level = 'warning'; title = "Needs DLC: $d"
            detail = "Needed by $(@($dlcNeed[$d]) -join ', '). Make sure the DLC is installed and enabled in Steam."; fix = '' })
    }
    if ($failed -gt 0 -and $Log) { $Log.Log("Requirement check: couldn't read $failed mods from Nexus this time.") }
    return $issues.ToArray()
}

# ---------------------------------------------------------------- full requirement audit
# Covers every mod no matter where it came from:
#  - Nexus mods (Vortex): the structured requirement list on each mod page (as Vortex reads it)
#    plus the "Requirements" section of each page's description, including links to other mods.
#  - mod.io mods: every subscribed mod's dependencies through the mod.io API.
#  - Mods from anywhere else (installed by hand, other sites): what the files themselves use,
#    e.g. scripts that call Codeware, .xl files (ArchiveXL), tweaks (TweakXL), CET Lua mods,
#    RED4ext plugins, input files (Input Loader), REDmods (REDmod DLC).
# Results are written to requirements-report.txt next to the app.

$script:FrameworkNames = @{ 107 = 'Cyber Engine Tweaks'; 2380 = 'RED4ext'; 1511 = 'redscript'; 4198 = 'ArchiveXL'; 4197 = 'TweakXL'; 7780 = 'Codeware'
    4575 = 'Input Loader'; 4885 = 'Mod Settings'; 3518 = 'Native Settings UI'; 12001 = 'Audioware'; 14139 = 'RedData'; 13378 = 'RedFileSystem'; 14192 = 'RedHttpClient'; 21422 = 'Native Interactions Framework' }

# Script/file signatures: what a mod's files use, and the framework that provides it.
$script:ContentRules = @(
    @{ id = 1511;  kind = 'reds';  re = '' ;                                              why = 'redscript scripts (.reds)' },
    @{ id = 7780;  kind = 'reds';  re = '\bimport\s+Codeware\b|\bCodeware\.' ;           why = 'its scripts use Codeware' },
    @{ id = 4885;  kind = 'reds';  re = '@runtimeProperty\("ModSettings\.' ;              why = 'its settings use Mod Settings' },
    @{ id = 13378; kind = 'reds';  re = '\bimport\s+RedFileSystem\b|\bFileSystemStorage\b' ; why = 'its scripts use RedFileSystem' },
    @{ id = 14192; kind = 'reds';  re = '\bimport\s+RedHttpClient\b|\bAsyncHttpClient\b' ;   why = 'its scripts use RedHttpClient' },
    @{ id = 14139; kind = 'reds';  re = '\bimport\s+RedData\.' ;                           why = 'its scripts use RedData' },
    @{ id = 12001; kind = 'reds';  re = '\bimport\s+Audioware\b|\bAudioware\.' ;           why = 'its scripts use Audioware' },
    @{ id = 4198;  kind = 'xl';    re = '' ;                                              why = 'it has ArchiveXL files (.xl)' },
    @{ id = 4197;  kind = 'tweak'; re = '' ;                                              why = 'it has TweakXL tweaks (r6\tweaks)' },
    @{ id = 107;   kind = 'cet';   re = '' ;                                              why = 'it is a Cyber Engine Tweaks (Lua) mod' },
    @{ id = 3518;  kind = 'lua';   re = 'GetMod\(\s*["'']nativeSettings["'']\s*\)' ;    why = 'its menu uses Native Settings UI' },
    @{ id = 2380;  kind = 'r4e';   re = '' ;                                              why = 'it is a RED4ext plugin' },
    @{ id = 4575;  kind = 'input'; re = '' ;                                              why = 'it adds key bindings (r6\input)' }
)

function Test-FrameworkInstalled([string]$GameDir, [int]$Id, $DeployedIds) {
    if ($DeployedIds -and $DeployedIds.Contains($Id)) { return $true }
    $f = $script:FrameworkFiles[$Id]
    if ($f -and (Test-Path -LiteralPath (Join-Path $GameDir $f))) { return $true }
    if ($Id -eq 12001 -and (Test-Path -LiteralPath (Join-Path $GameDir 'red4ext\plugins\audioware'))) { return $true }
    if ($Id -eq 14139 -and (Test-Path -LiteralPath (Join-Path $GameDir 'red4ext\plugins\RedData'))) { return $true }
    if ($Id -eq 13378 -and (Test-Path -LiteralPath (Join-Path $GameDir 'red4ext\plugins\RedFileSystem'))) { return $true }
    if ($Id -eq 14192 -and (Test-Path -LiteralPath (Join-Path $GameDir 'red4ext\plugins\RedHttpClient'))) { return $true }
    return $false
}

# Which mod owns each mod file in the game folder: the Vortex mod, or (for files Vortex doesn't
# know) the top-level folder/file it sits in, labelled "not in Vortex".
function Get-ModFileOwners([string]$GameDir) {
    $own = @{}
    $d = Read-JsonFile (Join-Path $GameDir 'vortex.deployment.json')
    if ($d -and $d.files) {
        foreach ($f in $d.files) {
            $src = [string]$f.source; $name = $src
            $m = [regex]::Match($src, '^(?<name>.*?)\s(?<id>\d{2,6})\s\S+\s\d{4}-\d{2}-\d{2}T')
            if ($m.Success) { $name = $m.Groups['name'].Value }
            $own[(([string]$f.relPath) -replace '/', '\').ToLowerInvariant()] = $name
        }
    }
    return $own
}

function Get-ContentRequirementIssues([string]$GameDir, $DeployedIds, $Report) {
    $issues = New-Object System.Collections.ArrayList
    if (-not $GameDir -or -not (Test-Path -LiteralPath $GameDir)) { return $issues.ToArray() }
    $owners = Get-ModFileOwners $GameDir
    $needs = @{}   # framework id -> mod name -> reason
    $mods = @{}    # mod name -> source label
    $add = {
        param([int]$fid, [string]$mod, [string]$why)
        if (-not $needs.ContainsKey($fid)) { $needs[$fid] = @{} }
        if (-not $needs[$fid].ContainsKey($mod)) { $needs[$fid][$mod] = $why }
    }
    $ownerOf = {
        param([string]$full, [string]$fallback)
        $rel = $full.Substring($GameDir.TrimEnd('\', '/').Length).TrimStart('\', '/') -replace '/', '\'
        $o = $owners[$rel.ToLowerInvariant()]
        if ($o) { $mods[$o] = 'Vortex'; return $o }
        $mods[$fallback] = 'not in Vortex'; return $fallback
    }
    $gd = $GameDir
    # redscript
    $rs = Join-Path $gd 'r6\scripts'
    if (Test-Path -LiteralPath $rs) {
        foreach ($f in (Get-ChildItem -LiteralPath $rs -Filter '*.reds' -File -Recurse -ErrorAction SilentlyContinue)) {
            $top = ($f.FullName.Substring($rs.Length).TrimStart('\', '/') -split '[\\/]')[0]
            $mod = & $ownerOf $f.FullName ("$top (r6\scripts)")
            & $add 1511 $mod 'redscript scripts (.reds)'
            $txt = ''; try { $txt = [IO.File]::ReadAllText($f.FullName) } catch {}
            foreach ($r in ($script:ContentRules | Where-Object { $_.kind -eq 'reds' -and $_.re })) { if ($txt -match $r.re) { & $add $r.id $mod $r.why } }
        }
    }
    # ArchiveXL files
    $am = Join-Path $gd 'archive\pc\mod'
    if (Test-Path -LiteralPath $am) {
        foreach ($f in (Get-ChildItem -LiteralPath $am -Filter '*.xl' -File -Recurse -ErrorAction SilentlyContinue)) { & $add 4198 (& $ownerOf $f.FullName "$($f.Name) (archive\pc\mod)") 'it has ArchiveXL files (.xl)' }
    }
    # TweakXL
    $tw = Join-Path $gd 'r6\tweaks'
    if (Test-Path -LiteralPath $tw) {
        foreach ($f in (Get-ChildItem -LiteralPath $tw -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.yaml', '.yml', '.tweak') })) {
            $top = ($f.FullName.Substring($tw.Length).TrimStart('\', '/') -split '[\\/]')[0]
            & $add 4197 (& $ownerOf $f.FullName "$top (r6\tweaks)") 'it has TweakXL tweaks (r6\tweaks)'
        }
    }
    # CET mods
    $cm = Join-Path $gd 'bin\x64\plugins\cyber_engine_tweaks\mods'
    if (Test-Path -LiteralPath $cm) {
        foreach ($dir in (Get-ChildItem -LiteralPath $cm -Directory -ErrorAction SilentlyContinue)) {
            $init = Join-Path $dir.FullName 'init.lua'
            if (-not (Test-Path -LiteralPath $init)) { continue }
            $mod = & $ownerOf $init "$($dir.Name) (CET mod)"
            & $add 107 $mod 'it is a Cyber Engine Tweaks (Lua) mod'
            if ($dir.Name -ieq 'nativeSettings') { continue }
            foreach ($lf in (Get-ChildItem -LiteralPath $dir.FullName -Filter '*.lua' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 60)) {
                $txt = ''; try { $txt = [IO.File]::ReadAllText($lf.FullName) } catch {}
                if ($txt -match (@($script:ContentRules | Where-Object { $_.kind -eq 'lua' })[0].re)) { & $add 3518 $mod 'its menu uses Native Settings UI'; break }
            }
        }
    }
    # RED4ext plugins
    $rp = Join-Path $gd 'red4ext\plugins'
    if (Test-Path -LiteralPath $rp) {
        foreach ($f in (Get-ChildItem -LiteralPath $rp -Filter '*.dll' -File -Recurse -ErrorAction SilentlyContinue)) {
            $top = ($f.FullName.Substring($rp.Length).TrimStart('\', '/') -split '[\\/]')[0]
            & $add 2380 (& $ownerOf $f.FullName "$top (RED4ext plugin)") 'it is a RED4ext plugin'
        }
    }
    # Input Loader
    $ri = Join-Path $gd 'r6\input'
    if (Test-Path -LiteralPath $ri) {
        foreach ($f in (Get-ChildItem -LiteralPath $ri -Filter '*.xml' -File -Recurse -ErrorAction SilentlyContinue)) { & $add 4575 (& $ownerOf $f.FullName "$($f.Name) (r6\input)") 'it adds key bindings (r6\input)' }
    }
    foreach ($fid in ($needs.Keys | Sort-Object)) {
        $ok = Test-FrameworkInstalled $GameDir ([int]$fid) $DeployedIds
        $users = @($needs[$fid].Keys | Sort-Object)
        if ($null -ne $Report) { [void]$Report.Add("  $(if ($ok) { 'OK     ' } else { 'MISSING' })  $($script:FrameworkNames[[int]$fid]) - used by $($users.Count) mod(s): $($users -join ', ')") }
        if (-not $ok) {
            [void]$issues.Add([pscustomobject]@{ id = "req:$fid"; level = 'error'; title = "Missing requirement: $($script:FrameworkNames[[int]$fid])"
                detail = "Needed by $($users -join ', ') ($(@($needs[$fid].Values | Sort-Object -Unique) -join '; ')). It isn't installed. Fix opens its download page; Vortex installs it."; fix = "nexus-page:$fid" })
        }
    }
    # REDmods need the REDmod DLC
    $redmods = @(Get-ChildItem -LiteralPath (Join-Path $gd 'mods') -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'info.json') })
    if ($redmods.Count -gt 0) {
        $have = Test-Path -LiteralPath (Join-Path $gd 'tools\redmod\bin\redMod.exe')
        if ($null -ne $Report) { [void]$Report.Add("  $(if ($have) { 'OK     ' } else { 'MISSING' })  REDmod DLC - used by $($redmods.Count) REDmod(s): $((@($redmods | ForEach-Object { $_.Name })) -join ', ')") }
        if (-not $have) {
            [void]$issues.Add([pscustomobject]@{ id = 'req:redmod'; level = 'error'; title = 'Missing requirement: REDmod DLC'
                detail = "These REDmods need it: $((@($redmods | ForEach-Object { $_.Name })) -join ', '). Install the free REDmod DLC in Steam, or use each mod's archive version instead."; fix = '' })
        }
    }
    return $issues.ToArray()
}

# Every subscribed mod.io mod's dependencies must be subscribed too (the game only downloads
# what the account subscribes to). Missing ones can be subscribed automatically.
function Get-ModioDependencyIssues($Cfg, $Report, $Log) {
    $issues = New-Object System.Collections.ArrayList
    if (-not $Cfg.modioToken -or -not $Cfg.modioGameId) { return $issues.ToArray() }
    try {
        $subs = @(Get-ModioSubscribedDetails $Cfg.modioGameId $Cfg.modioToken)
        $script:ModioSubNames = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($s in $subs) { [void]$script:ModioSubNames.Add((Normalize-Name ([string]$s.name))) }
        $ids = New-Object 'System.Collections.Generic.HashSet[int]'
        foreach ($s in $subs) { [void]$ids.Add([int]$s.id) }
        $cache = Get-RequirementCache
        $now = [long]([datetimeoffset][datetime]::UtcNow).ToUnixTimeSeconds()
        $missing = @{}
        foreach ($s in $subs) {
            $key = "modio:$($s.id)"; $c = $cache[$key]
            if (-not $c -or ($now - [long]$c.fetched) -gt ($script:RequirementCacheHours * 3600)) {
                $deps = @(Get-ModioDependencies ([int]$Cfg.modioGameId) ([int]$s.id) $Cfg.modioToken | ForEach-Object { [pscustomobject]@{ id = [int]$_.mod_id; name = [string]$_.name } })
                $c = [pscustomobject]@{ fetched = $now; source = 'modio'; deps = $deps }
                $cache[$key] = $c
            }
            $miss = @(@($c.deps) | Where-Object { $_ -and -not $ids.Contains([int]$_.id) })
            if ($null -ne $Report) { [void]$Report.Add("  mod.io  $($s.name): " + $(if (@($c.deps).Count -eq 0) { 'no dependencies' } else { (@($c.deps | ForEach-Object { "$($_.name) [$(if ($ids.Contains([int]$_.id)) { 'subscribed' } else { 'MISSING' })]" })) -join ', ' })) }
            foreach ($m in $miss) {
                if (-not $missing.ContainsKey([int]$m.id)) { $missing[[int]$m.id] = [pscustomobject]@{ id = [int]$m.id; name = $(if ($m.name) { $m.name } else { "mod.io mod $($m.id)" }); by = (New-Object System.Collections.ArrayList) } }
                [void]$missing[[int]$m.id].by.Add([string]$s.name)
            }
        }
        Save-RequirementCache
        foreach ($m in ($missing.Values | Sort-Object name)) {
            [void]$issues.Add([pscustomobject]@{ id = "modiodep:$($m.id)"; level = 'error'; title = "Missing mod.io requirement: $($m.name)"
                detail = "Needed by $(@($m.by) -join ', '). Fix subscribes it (no clicks needed); the game downloads it from its Mods menu."; fix = "modio-sub:$($m.id)" })
        }
    } catch { if ($Log) { $Log.Log('mod.io requirement check skipped: ' + $_.Exception.Message) } }
    return $issues.ToArray()
}

function Write-RequirementsReport($Lines) {
    try { Set-Content -LiteralPath (Join-Path $script:Root 'requirements-report.txt') -Value $Lines -Encoding UTF8 } catch {}
}

# ---------------------------------------------------------------- load order
# Cyberpunk loads every .archive in archive\pc\mod in ASCII order of the file name, unless
# archive\pc\mod\modlist.txt lists them; the FIRST archive to contain a game file wins. REDmods
# (folders in \mods) load after all archives. Vortex's Cyberpunk load order orders REDmods and
# deploys them with redMod.exe; Mod Organizer 2 orders archive mods by writing modlist.txt.
# This does both, per mod (not per file), and can sort automatically using the archives' own
# file lists so mods that really overwrite each other are put in the right order.

function Read-ArchiveHashes([string]$Path) {
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        if ($fs.Length -lt 40) { return $null }
        $br = New-Object IO.BinaryReader($fs)
        if ($br.ReadUInt32() -ne 0x52414452) { return $null }      # "RDAR"
        $null = $br.ReadUInt32()
        $ipos = [long]$br.ReadUInt64()
        if ($ipos -lt 40 -or ($ipos + 28) -gt $fs.Length) { return $null }
        $fs.Position = $ipos
        $null = $br.ReadUInt32(); $null = $br.ReadUInt32(); $null = $br.ReadUInt64()
        $count = [long]$br.ReadUInt32()
        $null = $br.ReadUInt32(); $null = $br.ReadUInt32()
        $need = $count * 56
        if ($count -lt 0 -or ($fs.Position + $need) -gt $fs.Length -or $need -gt 400MB) { return $null }
        $bytes = $br.ReadBytes([int]$need)
        $arr = New-Object 'UInt64[]' ([int]$count)
        for ($i = 0; $i -lt $count; $i++) { $arr[$i] = [BitConverter]::ToUInt64($bytes, $i * 56) }
        return ,$arr
    } finally { $fs.Dispose() }
}

function Get-LoadOrderConfig {
    $c = Read-JsonFile (Join-Path $script:DataDir 'loadorder.json')
    $o = [pscustomobject]@{ order = @(); keepUpdated = $true; lastHash = ''; redmodOrder = @(); applied = $false }
    if ($c) {
        if ($c.PSObject.Properties['order']) { $o.order = @($c.order | ForEach-Object { [string]$_ }) }
        if ($c.PSObject.Properties['keepUpdated']) { $o.keepUpdated = [bool]$c.keepUpdated }
        if ($c.PSObject.Properties['lastHash']) { $o.lastHash = [string]$c.lastHash }
        if ($c.PSObject.Properties['redmodOrder']) { $o.redmodOrder = @($c.redmodOrder | ForEach-Object { [string]$_ }) }
        if ($c.PSObject.Properties['applied']) { $o.applied = [bool]$c.applied }
    }
    return $o
}
function Save-LoadOrderConfig($Cfg) { Write-JsonFile (Join-Path $script:DataDir 'loadorder.json') $Cfg }

function Get-StringHash([string]$Text) {
    $sha = [Security.Cryptography.SHA1]::Create()
    return (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) -join '')
}

# Which Vortex mod each archive belongs to (from vortex.deployment.json).
function Get-ArchiveOwners([string]$GameDir) {
    $map = @{}
    $d = Read-JsonFile (Join-Path $GameDir 'vortex.deployment.json')
    if ($d -and $d.files) {
        foreach ($f in $d.files) {
            $rel = ([string]$f.relPath) -replace '/', '\'
            $mm = [regex]::Match($rel, '^archive\\pc\\mod\\([^\\]+\.archive)$', 'IgnoreCase')
            if (-not $mm.Success) { continue }
            $src = [string]$f.source
            $name = $src; $id = 0
            $m = [regex]::Match($src, '^(?<name>.*?)\s(?<id>\d{2,6})\s\S+\s\d{4}-\d{2}-\d{2}T')
            if ($m.Success) { $name = $m.Groups['name'].Value; $id = [int]$m.Groups['id'].Value }
            $map[$mm.Groups[1].Value.ToLowerInvariant()] = [pscustomobject]@{ key = "vortex:$src"; name = $name; nexusId = $id }
        }
    }
    return $map
}

function Get-LoadOrderModel([string]$GameDir) {
    $dir = Join-Path $GameDir 'archive\pc\mod'
    $model = [pscustomobject]@{ gameDir = $GameDir; mods = [ordered]@{}; conflicts = @(); defaultOrder = @(); currentOrder = @(); hasModlist = $false
        modlistLines = @(); unlisted = @(); stale = @(); archiveCount = 0; unreadable = @(); redmods = @(); redmodDeploy = '' }
    if (-not (Test-Path -LiteralPath $dir)) { return $model }
    $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.archive' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    [Array]::Sort($files, [StringComparer]::Ordinal)
    $model.archiveCount = $files.Count
    $owners = Get-ArchiveOwners $GameDir
    $owners2 = @{}
    foreach ($f in $files) {
        $o = $owners[$f.ToLowerInvariant()]
        if (-not $o) { $o = [pscustomobject]@{ key = "file:$f"; name = ($f -replace '\.archive$', ''); nexusId = 0 } }
        if (-not $model.mods.Contains($o.key)) {
            $model.mods[$o.key] = [pscustomobject]@{ key = $o.key; name = $o.name; nexusId = $o.nexusId; managed = ($o.key -like 'vortex:*'); archives = (New-Object System.Collections.ArrayList); resources = 0 }
        }
        [void]$model.mods[$o.key].archives.Add($f)
        $owners2[$f] = $o.key
    }
    # who contains which game file
    $where = New-Object 'System.Collections.Generic.Dictionary[UInt64,System.Collections.Generic.List[string]]'
    foreach ($f in $files) {
        $mk = $owners2[$f]
        $h = $null
        try { $h = Read-ArchiveHashes (Join-Path $dir $f) } catch { $h = $null }
        if ($null -eq $h) { $model.unreadable += $f; continue }
        $model.mods[$mk].resources += $h.Length
        foreach ($x in $h) {
            $l = $null
            if (-not $where.TryGetValue($x, [ref]$l)) { $l = New-Object 'System.Collections.Generic.List[string]'; $where[$x] = $l }
            if (-not $l.Contains($mk)) { $l.Add($mk) }
        }
    }
    $pairs = @{}
    foreach ($l in $where.Values) {
        if ($l.Count -lt 2) { continue }
        for ($i = 0; $i -lt $l.Count; $i++) { for ($j = $i + 1; $j -lt $l.Count; $j++) {
            $a = $l[$i]; $b = $l[$j]; if ([string]::CompareOrdinal($a, $b) -gt 0) { $t = $a; $a = $b; $b = $t }
            $k = "$a`n$b"; if ($pairs.ContainsKey($k)) { $pairs[$k]++ } else { $pairs[$k] = 1 }
        } }
    }
    $model.conflicts = @($pairs.Keys | ForEach-Object { $p = $_ -split "`n"; [pscustomobject]@{ a = $p[0]; b = $p[1]; count = $pairs[$_] } } | Sort-Object count -Descending)
    # the game's own order (no modlist.txt) and the order in effect now
    $model.defaultOrder = @(Get-ModOrderFromArchives $model $files)
    $ml = Join-Path $dir 'modlist.txt'
    $effective = $files
    if (Test-Path -LiteralPath $ml) {
        $model.hasModlist = $true
        $lines = @(Get-Content -LiteralPath $ml -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $model.modlistLines = $lines
        $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($f in $files) { [void]$set.Add($f) }
        $listed = @($lines | Where-Object { $set.Contains($_) })
        $model.stale = @($lines | Where-Object { -not $set.Contains($_) })
        $lset = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($f in $listed) { [void]$lset.Add($f) }
        $model.unlisted = @($files | Where-Object { -not $lset.Contains($_) })
        $effective = @($listed) + @($model.unlisted)
    }
    $model.currentOrder = @(Get-ModOrderFromArchives $model $effective)
    # REDmods
    $rm = Join-Path $GameDir 'mods'
    if (Test-Path -LiteralPath $rm) {
        $model.redmods = @(Get-ChildItem -LiteralPath $rm -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'info.json') } | ForEach-Object {
            $nm = $_.Name; $ver = ''
            try { $ij = Get-Content -LiteralPath (Join-Path $_.FullName 'info.json') -Raw | ConvertFrom-Json; if ($ij.name) { $nm = [string]$ij.name }; if ($ij.version) { $ver = [string]$ij.version } } catch {}
            [pscustomobject]@{ folder = $_.Name; name = $nm; version = $ver } })
    }
    $exe = Join-Path $GameDir 'tools\redmod\bin\redMod.exe'
    if (Test-Path -LiteralPath $exe) { $model.redmodDeploy = $exe }
    return $model
}

function Get-ModOrderFromArchives($Model, [string[]]$Archives) {
    $owner = @{}
    foreach ($m in $Model.mods.Values) { foreach ($a in $m.archives) { $owner[$a.ToLowerInvariant()] = $m.key } }
    $seen = New-Object System.Collections.ArrayList
    foreach ($a in $Archives) {
        $k = $owner[([string]$a).ToLowerInvariant()]
        if ($k -and -not $seen.Contains($k)) { [void]$seen.Add($k) }
    }
    return $seen.ToArray()
}

# Which of two conflicting mods should load first (and win). Returns @(winner, loser, rank) or $null.
function Get-ConflictWinner($A, $B, [int]$Count) {
    $norm = { param($s) (([string]$s).ToLowerInvariant() -replace '[^a-z0-9]+', ' ').Trim() }
    $na = & $norm $A.name; $nb = & $norm $B.name
    $core = { param($s) (($s -split ' ') | Where-Object { $_.Length -ge 3 -and $_ -notin @('the', 'and', 'mod', 'for', 'with', 'patch', 'fix', 'fixes', 'compat', 'compatibility', 'addon', 'version', 'edition', 'archive', 'cyberpunk', '2077') }) -join ' ' }
    $cb = & $core $nb; $ca = & $core $na
    # 1. a patch/add-on that names the other mod goes first
    if ($cb -and $na.Contains($cb) -and -not ($ca -and $nb.Contains($ca))) { return @($A.key, $B.key, 1) }
    if ($ca -and $nb.Contains($ca) -and -not ($cb -and $na.Contains($cb))) { return @($B.key, $A.key, 1) }
    # 2. patches, fixes and compatibility files go before the mods they adjust
    $kw = '\b(patch|patched|fix|fixes|fixed|compat|compatibility|hotfix|override|addon|add on|tweak|tweaks)\b'
    $ka = $na -match $kw; $kb = $nb -match $kw
    if ($ka -and -not $kb) { return @($A.key, $B.key, 2) }
    if ($kb -and -not $ka) { return @($B.key, $A.key, 2) }
    # 3. the smaller, more specific mod goes before a big overhaul it overlaps with
    if ($A.resources -gt 0 -and $B.resources -gt 0) {
        if ($A.resources * 2 -le $B.resources) { return @($A.key, $B.key, 3) }
        if ($B.resources * 2 -le $A.resources) { return @($B.key, $A.key, 3) }
    }
    return $null
}

# Stable sort: keep the base order, except where a conflict rule says otherwise.
# $OnlyFor (optional) limits the rules to conflicts that involve those mods (used for new mods).
function Get-AutoLoadOrder($Model, [string[]]$BaseOrder, [string[]]$OnlyFor) {
    $keys = New-Object System.Collections.ArrayList
    foreach ($k in @($BaseOrder)) { if ($Model.mods.Contains($k) -and -not $keys.Contains($k)) { [void]$keys.Add($k) } }
    foreach ($k in $Model.defaultOrder) { if (-not $keys.Contains($k)) { [void]$keys.Add($k) } }
    $pos = @{}; for ($i = 0; $i -lt $keys.Count; $i++) { $pos[$keys[$i]] = $i }
    $succ = @{}; foreach ($k in $keys) { $succ[$k] = New-Object System.Collections.ArrayList }
    $reach = {
        param($from, $to)
        $stack = New-Object System.Collections.Stack; $stack.Push($from); $seen = @{}
        while ($stack.Count -gt 0) { $n = $stack.Pop(); if ($n -eq $to) { return $true }; if ($seen[$n]) { continue }; $seen[$n] = $true; foreach ($s in $succ[$n]) { $stack.Push($s) } }
        return $false
    }
    $edges = @()
    foreach ($c in $Model.conflicts) {
        if (-not $pos.ContainsKey($c.a) -or -not $pos.ContainsKey($c.b)) { continue }
        if ($OnlyFor -and -not ($OnlyFor -contains $c.a -or $OnlyFor -contains $c.b)) { continue }
        $w = Get-ConflictWinner $Model.mods[$c.a] $Model.mods[$c.b] $c.count
        if ($w) { $edges += , $w }
    }
    foreach ($e in @($edges | Sort-Object { $_[2] })) {
        $w = $e[0]; $l = $e[1]
        if (& $reach $l $w) { continue }          # would contradict a stronger rule
        if (-not $succ[$w].Contains($l)) { [void]$succ[$w].Add($l) }
    }
    $indeg = @{}; foreach ($k in $keys) { $indeg[$k] = 0 }
    foreach ($k in $keys) { foreach ($s in $succ[$k]) { $indeg[$s]++ } }
    $out = New-Object System.Collections.ArrayList
    $ready = New-Object System.Collections.ArrayList
    foreach ($k in $keys) { if ($indeg[$k] -eq 0) { [void]$ready.Add($k) } }
    while ($ready.Count -gt 0) {
        $best = $ready[0]; foreach ($r in $ready) { if ($pos[$r] -lt $pos[$best]) { $best = $r } }
        [void]$ready.Remove($best); [void]$out.Add($best)
        foreach ($s in $succ[$best]) { $indeg[$s]--; if ($indeg[$s] -eq 0) { [void]$ready.Add($s) } }
    }
    return $out.ToArray()
}

# For each conflict: who wins under the given order.
function Get-ConflictReport($Model, [string[]]$Order) {
    $pos = @{}; for ($i = 0; $i -lt $Order.Count; $i++) { $pos[$Order[$i]] = $i }
    return @($Model.conflicts | ForEach-Object {
        $aw = ($pos.ContainsKey($_.a) -and $pos.ContainsKey($_.b) -and $pos[$_.a] -lt $pos[$_.b])
        [pscustomobject]@{ winner = $(if ($aw) { $_.a } else { $_.b }); loser = $(if ($aw) { $_.b } else { $_.a }); count = $_.count } })
}

function Get-ModlistLines($Model, [string[]]$Order) {
    $lines = New-Object System.Collections.ArrayList
    foreach ($k in $Order) {
        if (-not $Model.mods.Contains($k)) { continue }
        $arc = @($Model.mods[$k].archives); [Array]::Sort($arc, [StringComparer]::Ordinal)
        foreach ($a in $arc) { [void]$lines.Add($a) }
    }
    foreach ($m in $Model.mods.Values) { foreach ($a in $m.archives) { if (-not $lines.Contains($a)) { [void]$lines.Add($a) } } }
    return $lines.ToArray()
}

# Writes archive\pc\mod\modlist.txt. A modlist.txt the app didn't write is kept as a backup first.
function Write-ArchiveLoadOrder([string]$GameDir, [string[]]$Lines, $Cfg) {
    $p = Join-Path $GameDir 'archive\pc\mod\modlist.txt'
    $text = ($Lines -join "`r`n") + "`r`n"
    if (Test-Path -LiteralPath $p) {
        $cur = [IO.File]::ReadAllText($p)
        if ($cur -eq $text) { return $false }
        if ((Get-StringHash $cur) -ne $Cfg.lastHash) {
            Rename-Item -LiteralPath $p -NewName ('modlist.txt.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        }
    }
    [IO.File]::WriteAllText($p, $text, (New-Object Text.UTF8Encoding $false))
    $Cfg.lastHash = Get-StringHash $text
    return $true
}

# Back to the game's own alphabetical order: the app's modlist.txt is renamed, never deleted.
function Reset-ArchiveLoadOrder([string]$GameDir) {
    $p = Join-Path $GameDir 'archive\pc\mod\modlist.txt'
    if (-not (Test-Path -LiteralPath $p)) { return $false }
    Rename-Item -LiteralPath $p -NewName ('modlist.txt.off-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    return $true
}

# Keeps an applied load order current when mods are added or removed: new mods are placed by
# the same conflict rules (only against the mods they overlap with); everything else stays put.
function Update-LoadOrderAuto($Model, $Cfg) {
    if (-not $Cfg.applied -or -not $Cfg.keepUpdated) { return $null }
    $known = @($Cfg.order | Where-Object { $Model.mods.Contains($_) })
    $new = @($Model.defaultOrder | Where-Object { $known -notcontains $_ })
    $base = @($known) + @($new)
    $order = @(if ($new.Count -gt 0) { Get-AutoLoadOrder $Model $base $new } else { $base })
    $lines = Get-ModlistLines $Model $order
    $Cfg.order = @($order)
    $changed = Write-ArchiveLoadOrder $Model.gameDir $lines $Cfg
    Save-LoadOrderConfig $Cfg
    return [pscustomobject]@{ changed = $changed; added = $new.Count; order = $order }
}

function Get-LoadOrderIssues($Model, $Cfg) {
    $issues = New-Object System.Collections.ArrayList
    if ($Model.hasModlist -and ($Model.unlisted.Count -gt 0 -or $Model.stale.Count -gt 0)) {
        [void]$issues.Add([pscustomobject]@{ id = 'loadorder-outdated'; level = 'warning'; title = 'Load order file is out of date'
            detail = "archive\pc\mod\modlist.txt is missing $($Model.unlisted.Count) archive(s) and lists $($Model.stale.Count) that no longer exist, so new mods load in the wrong place. Fix rewrites it with your saved order."; fix = 'loadorder-apply' })
    }
    $rep = @(Get-ConflictReport $Model $Model.currentOrder)
    if ($rep.Count -gt 0) {
        $txt = @($rep | Select-Object -First 4 | ForEach-Object { "$($Model.mods[$_.winner].name) overrides $($Model.mods[$_.loser].name) ($($_.count) files)" }) -join '; '
        [void]$issues.Add([pscustomobject]@{ id = 'archive-conflicts'; level = 'info'; title = "$($rep.Count) pair(s) of mods change the same game files"
            detail = "The mod higher in the load order wins: $txt. Review or auto-sort them on the Load Order page."; fix = 'open-loadorder' })
    }
    if ($Model.unreadable.Count -gt 0) {
        [void]$issues.Add([pscustomobject]@{ id = 'archive-unreadable'; level = 'warning'; title = "$($Model.unreadable.Count) archive file(s) look damaged"
            detail = "These aren't valid Cyberpunk archives and may crash the game: $(@($Model.unreadable) -join ', '). Reinstall the mod they came from in Vortex."; fix = '' })
    }
    return $issues.ToArray()
}

# REDmod deployment, the way Vortex runs it.
function Invoke-RedmodDeploy([string]$GameDir, [string[]]$Folders) {
    $exe = Join-Path $GameDir 'tools\redmod\bin\redMod.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw 'REDmod is not installed (free REDmod DLC in Steam).' }
    $list = Join-Path $script:DataDir 'redmod-modlist.txt'
    [IO.File]::WriteAllText($list, (($Folders -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding $false))
    $args2 = @('deploy', '-force', '-root=', "`"$GameDir`"", '-rttiSchemaFile=', "`"$(Join-Path $GameDir 'tools\redmod\metadata.json')`"", '-modlist=', "`"$list`"")
    $p = Start-Process -FilePath $exe -ArgumentList $args2 -WorkingDirectory (Split-Path $exe) -WindowStyle Hidden -PassThru -Wait
    return $p.ExitCode
}

# ---------------------------------------------------------------- UI

function New-Rgb([int]$r, [int]$g, [int]$b) { return [Drawing.Color]::FromArgb($r, $g, $b) }

function Get-Theme {
    return @{
        bg = (New-Rgb 24 25 29); panel = (New-Rgb 32 33 38); panel2 = (New-Rgb 41 42 48); sidebar = (New-Rgb 16 17 20)
        border = (New-Rgb 54 55 62); text = (New-Rgb 232 232 236); muted = (New-Rgb 150 152 162); hover = (New-Rgb 52 53 60)
        accent = (New-Rgb 217 143 64); accentText = (New-Rgb 20 20 22); select = (New-Rgb 56 58 70)
        yellow = (New-Rgb 242 230 0); cyan = (New-Rgb 0 232 255)
        banner = (New-Rgb 58 50 22); bannerText = (New-Rgb 255 236 170)
    }
}

# Restarts the app the same way the desktop shortcut does (through the launcher .bat and
# cmd's "start"), so the new window opens normally even when this process was started hidden.
function Start-AppFresh {
    $bat = Join-Path $script:Root 'Start Night City Installer.bat'
    if (Test-Path -LiteralPath $bat) { Start-Process -FilePath $env:ComSpec -ArgumentList @('/c', '"' + $bat + '"') -WindowStyle Hidden -WorkingDirectory $script:Root }
    else { Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"' + (Join-Path $script:Root 'NightCityInstaller.ps1') + '"')) }
}

function Show-Splash($T, [string]$Logo) {
    $f = New-Object Windows.Forms.Form
    $f.FormBorderStyle = 'None'; $f.StartPosition = 'CenterScreen'; $f.Size = New-Object Drawing.Size(520, 300)
    $f.BackColor = $T.sidebar; $f.ShowInTaskbar = $true; $f.TopMost = $true; $f.Text = 'Night City Installer'
    if (Test-Path -LiteralPath $Logo) {
        $pb = New-Object Windows.Forms.PictureBox; $pb.Size = New-Object Drawing.Size(96, 96); $pb.Location = New-Object Drawing.Point(212, 34)
        $pb.SizeMode = 'Zoom'; $pb.Image = [Drawing.Image]::FromStream((New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($Logo))))
        $f.Controls.Add($pb)
    }
    $t1 = New-Object Windows.Forms.Label; $t1.Text = 'NIGHT CITY INSTALLER'; $t1.ForeColor = $T.yellow; $t1.Font = New-Object Drawing.Font('Segoe UI Semibold', 18)
    $t1.AutoSize = $false; $t1.TextAlign = 'MiddleCenter'; $t1.Bounds = New-Object Drawing.Rectangle(0, 140, 520, 36)
    $t2 = New-Object Windows.Forms.Label; $t2.Text = "Cyberpunk 2077 mod manager  |  version $($script:AppVersion)"; $t2.ForeColor = $T.muted; $t2.Font = New-Object Drawing.Font('Segoe UI', 9.5)
    $t2.AutoSize = $false; $t2.TextAlign = 'MiddleCenter'; $t2.Bounds = New-Object Drawing.Rectangle(0, 176, 520, 22)
    $st = New-Object Windows.Forms.Label; $st.Text = 'Starting...'; $st.ForeColor = $T.text; $st.Font = New-Object Drawing.Font('Segoe UI', 9)
    $st.AutoSize = $false; $st.TextAlign = 'MiddleCenter'; $st.Bounds = New-Object Drawing.Rectangle(0, 222, 520, 22)
    $track = New-Object Windows.Forms.Panel; $track.Bounds = New-Object Drawing.Rectangle(60, 256, 400, 4); $track.BackColor = $T.panel2
    $bar = New-Object Windows.Forms.Panel; $bar.Bounds = New-Object Drawing.Rectangle(0, 0, 90, 4); $bar.BackColor = $T.cyan
    $track.Controls.Add($bar)
    $f.Controls.AddRange(@($t1, $t2, $st, $track))
    $f.Show(); [Windows.Forms.Application]::DoEvents()
    return [pscustomobject]@{ form = $f; status = $st; bar = $bar }
}

function Set-SplashStatus($S, [string]$Text) {
    if (-not $S) { return }
    $S.status.Text = $Text
    $x = $S.bar.Left + 70; if ($x -gt 310) { $x = 0 }
    $S.bar.Left = $x
    [Windows.Forms.Application]::DoEvents()
}

function New-DarkButton($T, [string]$Text, [string]$Kind = 'normal', [int]$Width = 0) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $Text; $b.FlatStyle = 'Flat'; $b.Height = 32; $b.Cursor = 'Hand'
    $b.Font = New-Object Drawing.Font('Segoe UI Semibold', 9.5)
    if ($Width -gt 0) { $b.Width = $Width } else { $b.AutoSize = $true; $b.AutoSizeMode = 'GrowAndShrink'; $b.Padding = New-Object Windows.Forms.Padding(10, 0, 10, 0) }
    switch ($Kind) {
        'primary' { $b.BackColor = $T.accent; $b.ForeColor = $T.accentText; $b.FlatAppearance.BorderSize = 0; $b.FlatAppearance.MouseOverBackColor = (New-Rgb 236 163 84) }
        'play'    { $b.BackColor = (New-Rgb 245 245 245); $b.ForeColor = (New-Rgb 20 20 22); $b.FlatAppearance.BorderSize = 0; $b.FlatAppearance.MouseOverBackColor = (New-Rgb 255 255 255); $b.Font = New-Object Drawing.Font('Segoe UI Semibold', 12) }
        'nav'     { $b.BackColor = $T.sidebar; $b.ForeColor = $T.text; $b.FlatAppearance.BorderSize = 0; $b.FlatAppearance.MouseOverBackColor = $T.hover; $b.TextAlign = 'MiddleLeft'; $b.Height = 38; $b.Padding = New-Object Windows.Forms.Padding(14, 0, 0, 0); $b.Font = New-Object Drawing.Font('Segoe UI', 10) }
        default   { $b.BackColor = $T.panel2; $b.ForeColor = $T.text; $b.FlatAppearance.BorderColor = $T.border; $b.FlatAppearance.BorderSize = 1; $b.FlatAppearance.MouseOverBackColor = $T.hover }
    }
    return $b
}

function New-DarkGrid($T) {
    $g = New-Object Windows.Forms.DataGridView
    $g.Dock = 'Fill'; $g.BackgroundColor = $T.bg; $g.BorderStyle = 'None'; $g.GridColor = $T.border
    $g.RowHeadersVisible = $false; $g.AllowUserToAddRows = $false; $g.AllowUserToDeleteRows = $false; $g.AllowUserToResizeRows = $false
    $g.SelectionMode = 'FullRowSelect'; $g.MultiSelect = $false; $g.AutoGenerateColumns = $false; $g.EnableHeadersVisualStyles = $false
    $g.CellBorderStyle = 'SingleHorizontal'; $g.ColumnHeadersBorderStyle = 'None'; $g.ColumnHeadersHeight = 34; $g.ColumnHeadersHeightSizeMode = 'DisableResizing'
    $g.ColumnHeadersDefaultCellStyle.BackColor = $T.panel; $g.ColumnHeadersDefaultCellStyle.ForeColor = $T.muted
    $g.ColumnHeadersDefaultCellStyle.Font = New-Object Drawing.Font('Segoe UI Semibold', 9.5); $g.ColumnHeadersDefaultCellStyle.SelectionBackColor = $T.panel
    $g.DefaultCellStyle.BackColor = $T.bg; $g.DefaultCellStyle.ForeColor = $T.text; $g.DefaultCellStyle.Font = New-Object Drawing.Font('Segoe UI', 9.75)
    $g.DefaultCellStyle.SelectionBackColor = $T.select; $g.DefaultCellStyle.SelectionForeColor = [Drawing.Color]::White
    $g.DefaultCellStyle.Padding = New-Object Windows.Forms.Padding(4, 0, 4, 0)
    $g.RowTemplate.Height = 32; $g.ReadOnly = $false
    # double buffering stops flicker on big lists
    $prop = $g.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic'); if ($prop) { $prop.SetValue($g, $true, $null) }
    return $g
}

function Add-GridColumn($Grid, [string]$Name, [string]$Header, [int]$Width, [string]$Type = 'text', [int]$Fill = 0) {
    $c = if ($Type -eq 'check') { New-Object Windows.Forms.DataGridViewCheckBoxColumn } else { New-Object Windows.Forms.DataGridViewTextBoxColumn }
    $c.Name = $Name; $c.HeaderText = $Header; $c.SortMode = 'Automatic'
    if ($Fill -gt 0) { $c.AutoSizeMode = 'Fill'; $c.FillWeight = $Fill; $c.MinimumWidth = $Width } else { $c.Width = $Width }
    if ($Type -ne 'check') { $c.ReadOnly = $true }
    [void]$Grid.Columns.Add($c)
    return $c
}

function New-DesktopShortcut([string]$Root) {
    $ps1 = Join-Path $Root 'NightCityInstaller.ps1'; $ico = Join-Path $Root 'NightCityInstaller.ico'
    $desk = [Environment]::GetFolderPath('Desktop')
    $path = Join-Path $desk 'Night City Installer.lnk'
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($path)
    $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$ps1`""
    $lnk.WorkingDirectory = $Root; $lnk.Description = 'Night City Installer - Cyberpunk 2077 mods'
    if (Test-Path -LiteralPath $ico) { $lnk.IconLocation = "$ico,0" }
    $lnk.Save()
    return $path
}

function Start-App {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $T = Get-Theme
    $logoPath = Join-Path $script:Root 'NightCityInstaller.png'
    $icoPath = Join-Path $script:Root 'NightCityInstaller.ico'
    $splash = Show-Splash $T $logoPath
    Write-Trace 'splash shown'

    Ensure-DataDir
    $script:LogFile = Join-Path $script:DataDir 'log.txt'
    Set-SplashStatus $splash 'Reading your mod list...'
    $manifest = Load-Manifest
    $config = Load-Config
    $state = Load-State
    $startupNotes = New-Object System.Collections.ArrayList
    $startIds = $null
    if ($config.gameDir -and (Test-Path -LiteralPath $config.gameDir)) {
        Set-SplashStatus $splash 'Checking the game folder...'
        try { if ($config.autoFix -and (Repair-EmptyModdedCache $config.gameDir)) { [void]$startupNotes.Add('Health: renamed an empty r6\cache\modded folder that makes the game crash on start-up.') } } catch {}
        Set-SplashStatus $splash 'Reading what Vortex has installed...'
        $startIds = Get-InstalledNexusIds $config.gameDir
    }
    $null = Add-DiscoveredToManifest $manifest (Read-DiscoveryStore) $startIds
    Set-SplashStatus $splash 'Building the window...'
    Write-Trace 'building window'

    $font = New-Object Drawing.Font('Segoe UI', 9.75)
    $bold = New-Object Drawing.Font('Segoe UI Semibold', 10)
    $pillFont = New-Object Drawing.Font('Segoe UI Semibold', 8.75)
    $titleFont = New-Object Drawing.Font('Segoe UI Semibold', 17)

    $form = New-Object Windows.Forms.Form
    $form.Text = "Night City Installer $($script:AppVersion)"
    $form.Size = New-Object Drawing.Size(1440, 900); $form.MinimumSize = New-Object Drawing.Size(1100, 680)
    $form.StartPosition = 'CenterScreen'; $form.Font = $font; $form.BackColor = $T.bg; $form.ForeColor = $T.text; $form.WindowState = 'Maximized'
    if (Test-Path -LiteralPath $icoPath) { try { $form.Icon = New-Object Drawing.Icon($icoPath) } catch {} }

    # ================= sidebar =================
    $side = New-Object Windows.Forms.Panel; $side.Dock = 'Left'; $side.Width = 220; $side.BackColor = $T.sidebar
    $brand = New-Object Windows.Forms.Panel; $brand.Dock = 'Top'; $brand.Height = 72; $brand.BackColor = $T.sidebar
    if (Test-Path -LiteralPath $logoPath) {
        $lg = New-Object Windows.Forms.PictureBox; $lg.Bounds = New-Object Drawing.Rectangle(16, 16, 40, 40); $lg.SizeMode = 'Zoom'
        $lg.Image = [Drawing.Image]::FromStream((New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($logoPath)))); $brand.Controls.Add($lg)
    }
    $bt = New-Object Windows.Forms.Label; $bt.Text = 'Night City'; $bt.Font = New-Object Drawing.Font('Segoe UI Semibold', 12); $bt.ForeColor = $T.yellow; $bt.Bounds = New-Object Drawing.Rectangle(64, 14, 150, 24)
    $bs = New-Object Windows.Forms.Label; $bs.Text = 'Installer for Cyberpunk 2077'; $bs.Font = New-Object Drawing.Font('Segoe UI', 8.5); $bs.ForeColor = $T.muted; $bs.Bounds = New-Object Drawing.Rectangle(64, 38, 156, 20)
    $brand.Controls.AddRange(@($bt, $bs))
    $nav = New-Object Windows.Forms.FlowLayoutPanel; $nav.Dock = 'Fill'; $nav.FlowDirection = 'TopDown'; $nav.WrapContents = $false; $nav.BackColor = $T.sidebar; $nav.Padding = New-Object Windows.Forms.Padding(0, 8, 0, 0)
    $navButtons = [ordered]@{}
    foreach ($n in @('Mods', 'Load Order', 'Updates', 'Health check', 'Settings', 'Log')) {
        $b = New-DarkButton $T $n 'nav' 220; $b.Margin = New-Object Windows.Forms.Padding(0); $b.Tag = $n
        $nav.Controls.Add($b); $navButtons[$n] = $b
    }
    $sideBottom = New-Object Windows.Forms.Panel; $sideBottom.Dock = 'Bottom'; $sideBottom.Height = 96; $sideBottom.BackColor = $T.sidebar
    $btnPlay = New-DarkButton $T ([string][char]0x25B6 + '  Play') 'play' 188; $btnPlay.Height = 44; $btnPlay.Location = New-Object Drawing.Point(16, 14)
    $verLbl = New-Object Windows.Forms.Label; $verLbl.Text = "v$($script:AppVersion)"; $verLbl.ForeColor = $T.muted; $verLbl.Font = New-Object Drawing.Font('Segoe UI', 8); $verLbl.Bounds = New-Object Drawing.Rectangle(16, 66, 188, 18)
    $sideBottom.Controls.AddRange(@($btnPlay, $verLbl))
    $side.Controls.Add($nav); $side.Controls.Add($sideBottom); $side.Controls.Add($brand)

    # ================= main area =================
    $main = New-Object Windows.Forms.Panel; $main.Dock = 'Fill'; $main.BackColor = $T.bg
    $header = New-Object Windows.Forms.Panel; $header.Dock = 'Top'; $header.Height = 70; $header.BackColor = $T.bg; $header.Padding = New-Object Windows.Forms.Padding(24, 12, 24, 0)
    $hTitle = New-Object Windows.Forms.Label; $hTitle.Font = $titleFont; $hTitle.ForeColor = $T.text; $hTitle.Bounds = New-Object Drawing.Rectangle(24, 10, 600, 32)
    $hSub = New-Object Windows.Forms.Label; $hSub.Font = $font; $hSub.ForeColor = $T.muted; $hSub.Bounds = New-Object Drawing.Rectangle(24, 42, 900, 20)
    $header.Controls.AddRange(@($hTitle, $hSub))
    $banner = New-Object Windows.Forms.Panel; $banner.Dock = 'Top'; $banner.Height = 64; $banner.BackColor = $T.banner; $banner.Padding = New-Object Windows.Forms.Padding(24, 8, 24, 6); $banner.Visible = $false
    $bannerText = New-Object Windows.Forms.Label; $bannerText.Dock = 'Fill'; $bannerText.ForeColor = $T.bannerText; $bannerText.Font = $bold
    $bannerBtns = New-Object Windows.Forms.FlowLayoutPanel; $bannerBtns.Dock = 'Right'; $bannerBtns.AutoSize = $true; $bannerBtns.WrapContents = $false; $bannerBtns.BackColor = $T.banner
    $banner.Controls.Add($bannerText); $banner.Controls.Add($bannerBtns)
    $statusBar = New-Object Windows.Forms.Label; $statusBar.Dock = 'Bottom'; $statusBar.Height = 28; $statusBar.BackColor = $T.sidebar; $statusBar.ForeColor = $T.muted; $statusBar.Padding = New-Object Windows.Forms.Padding(24, 6, 0, 0)
    $bgLbl = New-Object Windows.Forms.Label; $bgLbl.Dock = 'Right'; $bgLbl.AutoSize = $true; $bgLbl.ForeColor = $T.muted; $bgLbl.BackColor = $T.sidebar; $bgLbl.Padding = New-Object Windows.Forms.Padding(0, 0, 24, 0)
    $statusBar.Controls.Add($bgLbl)
    $pages = New-Object Windows.Forms.Panel; $pages.Dock = 'Fill'; $pages.BackColor = $T.bg; $pages.Padding = New-Object Windows.Forms.Padding(24, 8, 24, 12)
    $main.Controls.Add($pages); $main.Controls.Add($statusBar); $main.Controls.Add($banner); $main.Controls.Add($header)

    $pageMods = New-Object Windows.Forms.Panel; $pageMods.Dock = 'Fill'
    $pageUpd = New-Object Windows.Forms.Panel; $pageUpd.Dock = 'Fill'; $pageUpd.Visible = $false
    $pageHealth = New-Object Windows.Forms.Panel; $pageHealth.Dock = 'Fill'; $pageHealth.Visible = $false
    $pageSet = New-Object Windows.Forms.Panel; $pageSet.Dock = 'Fill'; $pageSet.Visible = $false; $pageSet.AutoScroll = $true
    $pageLog = New-Object Windows.Forms.Panel; $pageLog.Dock = 'Fill'; $pageLog.Visible = $false
    $pageLO = New-Object Windows.Forms.Panel; $pageLO.Dock = 'Fill'; $pageLO.Visible = $false
    $pages.Controls.AddRange(@($pageMods, $pageLO, $pageUpd, $pageHealth, $pageSet, $pageLog))
    $pageInfo = @{
        'Mods'         = @{ panel = $pageMods; title = 'Mods'; sub = 'Install and manage the Night City Load Order for Cyberpunk 2077 patch 2.5.' }
        'Load Order'   = @{ panel = $pageLO; title = 'Load Order'; sub = 'Which mod wins when two mods change the same game file. Top of the list loads first and wins.' }
        'Updates'      = @{ panel = $pageUpd; title = 'Updates'; sub = 'Newer files for the mods Vortex has installed, plus updates to this app.' }
        'Health check' = @{ panel = $pageHealth; title = 'Health check'; sub = 'Problems that can stop the game from starting, and fixes for them.' }
        'Settings'     = @{ panel = $pageSet; title = 'Settings'; sub = 'Game folder, accounts and options.' }
        'Log'          = @{ panel = $pageLog; title = 'Log'; sub = "Everything the app has done. Also saved to $($script:DataDir)\log.txt" }
    }

    # ---------- Mods page ----------
    $toolbar = New-Object Windows.Forms.FlowLayoutPanel; $toolbar.Dock = 'Top'; $toolbar.Height = 44; $toolbar.WrapContents = $false; $toolbar.BackColor = $T.bg
    $btnStart = New-DarkButton $T ([string][char]0x25B6 + '  Start install') 'primary'
    $btnPause = New-DarkButton $T 'Pause'; $btnPause.Enabled = $false
    $btnRefresh = New-DarkButton $T ([string][char]0x21BB + '  Refresh')
    $btnAll = New-DarkButton $T 'Tick all'; $btnNone = New-DarkButton $T 'Untick all'; $btnReset = New-DarkButton $T 'Reset progress'
    $chkPause = New-Object Windows.Forms.CheckBox; $chkPause.Text = 'Pause after each batch to test'; $chkPause.AutoSize = $true; $chkPause.ForeColor = $T.muted; $chkPause.Margin = New-Object Windows.Forms.Padding(14, 9, 0, 0); $chkPause.Checked = [bool]$config.pauseBetweenBatches
    foreach ($c in @($btnStart, $btnPause, $btnRefresh, $btnAll, $btnNone, $btnReset)) { $c.Margin = New-Object Windows.Forms.Padding(0, 4, 8, 4) }
    $toolbar.Controls.AddRange(@($btnStart, $btnPause, $btnRefresh, $btnAll, $btnNone, $btnReset, $chkPause))
    $filters = New-Object Windows.Forms.FlowLayoutPanel; $filters.Dock = 'Top'; $filters.Height = 40; $filters.WrapContents = $false; $filters.BackColor = $T.bg
    $lblSearch = New-Object Windows.Forms.Label; $lblSearch.Text = 'Search'; $lblSearch.ForeColor = $T.muted; $lblSearch.AutoSize = $true; $lblSearch.Margin = New-Object Windows.Forms.Padding(0, 10, 6, 0)
    $txtSearch = New-Object Windows.Forms.TextBox; $txtSearch.Width = 260; $txtSearch.BackColor = $T.panel2; $txtSearch.ForeColor = $T.text; $txtSearch.BorderStyle = 'FixedSingle'; $txtSearch.Margin = New-Object Windows.Forms.Padding(0, 7, 18, 0)
    $lblCat = New-Object Windows.Forms.Label; $lblCat.Text = 'Category'; $lblCat.ForeColor = $T.muted; $lblCat.AutoSize = $true; $lblCat.Margin = New-Object Windows.Forms.Padding(0, 10, 6, 0)
    $cmbCat = New-Object Windows.Forms.ComboBox; $cmbCat.DropDownStyle = 'DropDownList'; $cmbCat.Width = 280; $cmbCat.BackColor = $T.panel2; $cmbCat.ForeColor = $T.text; $cmbCat.FlatStyle = 'Flat'; $cmbCat.Margin = New-Object Windows.Forms.Padding(0, 7, 18, 0)
    $lblSt = New-Object Windows.Forms.Label; $lblSt.Text = 'Status'; $lblSt.ForeColor = $T.muted; $lblSt.AutoSize = $true; $lblSt.Margin = New-Object Windows.Forms.Padding(0, 10, 6, 0)
    $cmbSt = New-Object Windows.Forms.ComboBox; $cmbSt.DropDownStyle = 'DropDownList'; $cmbSt.Width = 170; $cmbSt.BackColor = $T.panel2; $cmbSt.ForeColor = $T.text; $cmbSt.FlatStyle = 'Flat'; $cmbSt.Margin = New-Object Windows.Forms.Padding(0, 7, 18, 0)
    [void]$cmbSt.Items.AddRange(@('All', 'Installed', 'Not installed', 'Ticked', 'Update available', 'Waiting / needs something', 'Problems'))
    $cmbSt.SelectedIndex = 0
    $filters.Controls.AddRange(@($lblSearch, $txtSearch, $lblCat, $cmbCat, $lblSt, $cmbSt))

    $split = New-Object Windows.Forms.SplitContainer; $split.Dock = 'Fill'; $split.BackColor = $T.border; $split.SplitterWidth = 4; $split.Panel1.BackColor = $T.bg; $split.Panel2.BackColor = $T.panel
    $grid = New-DarkGrid $T
    $null = Add-GridColumn $grid 'Q' '' 36 'check'
    $colStatus = Add-GridColumn $grid 'Status' 'Status' 150
    $null = Add-GridColumn $grid 'ModName' 'Mod Name' 260 'text' 46
    $null = Add-GridColumn $grid 'Version' 'Version' 90
    $null = Add-GridColumn $grid 'Category' 'Category' 220
    $null = Add-GridColumn $grid 'Source' 'Source' 70
    $null = Add-GridColumn $grid 'Info' 'Info' 160 'text' 30
    $grid.Columns['Q'].HeaderText = [string][char]0x2713
    $split.Panel1.Controls.Add($grid)

    # details pane
    $det = New-Object Windows.Forms.Panel; $det.Dock = 'Fill'; $det.BackColor = $T.panel; $det.Padding = New-Object Windows.Forms.Padding(16, 14, 16, 14); $det.AutoScroll = $true
    $detPic = New-Object Windows.Forms.PictureBox; $detPic.Dock = 'Top'; $detPic.Height = 230; $detPic.SizeMode = 'Zoom'; $detPic.BackColor = $T.sidebar; $detPic.Cursor = 'Hand'
    $detThumbs = New-Object Windows.Forms.FlowLayoutPanel; $detThumbs.Dock = 'Top'; $detThumbs.Height = 70; $detThumbs.WrapContents = $false; $detThumbs.AutoScroll = $true; $detThumbs.BackColor = $T.panel; $detThumbs.Padding = New-Object Windows.Forms.Padding(0, 6, 0, 0)
    $detName = New-Object Windows.Forms.Label; $detName.Dock = 'Top'; $detName.Height = 54; $detName.Font = New-Object Drawing.Font('Segoe UI Semibold', 14); $detName.ForeColor = $T.text; $detName.Padding = New-Object Windows.Forms.Padding(0, 10, 0, 0)
    $detMeta = New-Object Windows.Forms.Label; $detMeta.Dock = 'Top'; $detMeta.Height = 40; $detMeta.ForeColor = $T.muted
    $detLinks = New-Object Windows.Forms.FlowLayoutPanel; $detLinks.Dock = 'Top'; $detLinks.Height = 40; $detLinks.BackColor = $T.panel
    $btnOpenPage = New-DarkButton $T 'Open mod page'; $btnOpenGallery = New-DarkButton $T 'All photos'
    $detLinks.Controls.AddRange(@($btnOpenPage, $btnOpenGallery))
    $detText = New-Object Windows.Forms.RichTextBox; $detText.Dock = 'Fill'; $detText.ReadOnly = $true; $detText.BorderStyle = 'None'; $detText.BackColor = $T.panel; $detText.ForeColor = $T.text; $detText.Font = $font; $detText.DetectUrls = $true
    $det.Controls.Add($detText); $det.Controls.Add($detLinks); $det.Controls.Add($detMeta); $det.Controls.Add($detName); $det.Controls.Add($detThumbs); $det.Controls.Add($detPic)
    $split.Panel2.Controls.Add($det)
    $pageMods.Controls.Add($split); $pageMods.Controls.Add($filters); $pageMods.Controls.Add($toolbar)

    # ---------- Updates page ----------
    $updTool = New-Object Windows.Forms.FlowLayoutPanel; $updTool.Dock = 'Top'; $updTool.Height = 44; $updTool.WrapContents = $false
    $btnCheck = New-DarkButton $T ([string][char]0x21BB + '  Check for updates') 'primary'
    $btnUpdate = New-DarkButton $T ([string][char]0x2191 + '  Update ticked'); $btnUpdate.Enabled = $false
    $btnAppUpd = New-DarkButton $T 'Update app'; $btnAppUpd.Visible = $false
    $chkAuto = New-Object Windows.Forms.CheckBox; $chkAuto.Text = 'Check when the app opens'; $chkAuto.AutoSize = $true; $chkAuto.ForeColor = $T.muted; $chkAuto.Margin = New-Object Windows.Forms.Padding(14, 9, 0, 0); $chkAuto.Checked = [bool]$config.checkOnStart
    $chkDisc = New-Object Windows.Forms.CheckBox; $chkDisc.Text = 'Look for new compatible mods when the app opens'; $chkDisc.AutoSize = $true; $chkDisc.ForeColor = $T.muted; $chkDisc.Margin = New-Object Windows.Forms.Padding(14, 9, 0, 0); $chkDisc.Checked = [bool]$config.discoverOnStart
    foreach ($c in @($btnCheck, $btnUpdate, $btnAppUpd)) { $c.Margin = New-Object Windows.Forms.Padding(0, 4, 8, 4) }
    $updTool.Controls.AddRange(@($btnCheck, $btnUpdate, $btnAppUpd, $chkAuto, $chkDisc))
    $updHeader = New-Object Windows.Forms.Label; $updHeader.Dock = 'Top'; $updHeader.Height = 30; $updHeader.ForeColor = $T.muted; $updHeader.Padding = New-Object Windows.Forms.Padding(0, 6, 0, 0)
    $updGrid = New-DarkGrid $T
    $null = Add-GridColumn $updGrid 'Q' ([string][char]0x2713) 36 'check'
    $colUStatus = Add-GridColumn $updGrid 'Status' 'Status' 170
    $null = Add-GridColumn $updGrid 'ModName' 'Mod Name' 260 'text' 50
    $null = Add-GridColumn $updGrid 'Installed' 'Installed' 110
    $null = Add-GridColumn $updGrid 'Latest' 'Latest' 110
    $null = Add-GridColumn $updGrid 'Category' 'Category' 200
    $null = Add-GridColumn $updGrid 'Source' 'Source' 70
    $pageUpd.Controls.Add($updGrid); $pageUpd.Controls.Add($updHeader); $pageUpd.Controls.Add($updTool)

    # ---------- Health page ----------
    $hTool = New-Object Windows.Forms.FlowLayoutPanel; $hTool.Dock = 'Top'; $hTool.Height = 44; $hTool.WrapContents = $false
    $btnHealth = New-DarkButton $T ([string][char]0x21BB + '  Run health check') 'primary'
    $btnFixAll = New-DarkButton $T 'Fix everything I can'
    $btnReqInstall = New-DarkButton $T 'Install missing requirements'
    $chkAutoFix = New-Object Windows.Forms.CheckBox; $chkAutoFix.Text = 'Fix the start-up crash folder automatically'; $chkAutoFix.AutoSize = $true; $chkAutoFix.ForeColor = $T.muted; $chkAutoFix.Margin = New-Object Windows.Forms.Padding(14, 9, 0, 0); $chkAutoFix.Checked = [bool]$config.autoFix
    foreach ($c in @($btnHealth, $btnFixAll, $btnReqInstall)) { $c.Margin = New-Object Windows.Forms.Padding(0, 4, 8, 4) }
    $hTool.Controls.AddRange(@($btnHealth, $btnFixAll, $btnReqInstall, $chkAutoFix))
    $hGrid = New-DarkGrid $T
    $colHLevel = Add-GridColumn $hGrid 'Level' 'Level' 100
    $null = Add-GridColumn $hGrid 'Problem' 'Problem' 300 'text' 35
    $null = Add-GridColumn $hGrid 'Detail' 'Details' 300 'text' 65
    $fixCol = New-Object Windows.Forms.DataGridViewButtonColumn; $fixCol.Name = 'Fix'; $fixCol.HeaderText = ''; $fixCol.Width = 110; $fixCol.FlatStyle = 'Flat'
    $fixCol.DefaultCellStyle.BackColor = $T.accent; $fixCol.DefaultCellStyle.ForeColor = $T.accentText; [void]$hGrid.Columns.Add($fixCol)
    $hGrid.RowTemplate.Height = 44; $hGrid.DefaultCellStyle.WrapMode = 'True'
    $pageHealth.Controls.Add($hGrid); $pageHealth.Controls.Add($hTool)

    # ---------- Load Order page ----------
    $loTool = New-Object Windows.Forms.FlowLayoutPanel; $loTool.Dock = 'Top'; $loTool.Height = 44; $loTool.WrapContents = $false
    $btnLoAuto = New-DarkButton $T 'Auto-sort' 'primary'
    $btnLoApply = New-DarkButton $T 'Apply load order'
    $btnLoUp = New-DarkButton $T ([string][char]0x25B2 + ' Up'); $btnLoDown = New-DarkButton $T ([string][char]0x25BC + ' Down')
    $btnLoTop = New-DarkButton $T 'To top'; $btnLoBottom = New-DarkButton $T 'To bottom'
    $btnLoReset = New-DarkButton $T 'Game default'
    $btnLoReload = New-DarkButton $T ([string][char]0x21BB + '  Refresh')
    $chkLoKeep = New-Object Windows.Forms.CheckBox; $chkLoKeep.Text = 'Keep it up to date automatically'; $chkLoKeep.AutoSize = $true; $chkLoKeep.ForeColor = $T.muted; $chkLoKeep.Margin = New-Object Windows.Forms.Padding(14, 9, 0, 0)
    foreach ($c in @($btnLoAuto, $btnLoApply, $btnLoUp, $btnLoDown, $btnLoTop, $btnLoBottom, $btnLoReset, $btnLoReload)) { $c.Margin = New-Object Windows.Forms.Padding(0, 4, 8, 4) }
    $loTool.Controls.AddRange(@($btnLoAuto, $btnLoApply, $btnLoUp, $btnLoDown, $btnLoTop, $btnLoBottom, $btnLoReset, $btnLoReload, $chkLoKeep))
    $loHint = New-Object Windows.Forms.Label; $loHint.Dock = 'Top'; $loHint.Height = 40; $loHint.ForeColor = $T.muted
    $loHint.Text = "Cyberpunk loads archive mods top to bottom and the FIRST one to change a game file wins. Drag mods (or use the buttons), or let Auto-sort place the ones that really overlap, then Apply. The order is saved to archive\pc\mod\modlist.txt; Vortex doesn't touch that file. REDmods always load after archive mods."
    $loSplit = New-Object Windows.Forms.SplitContainer; $loSplit.Dock = 'Fill'; $loSplit.Orientation = 'Horizontal'; $loSplit.BackColor = $T.bg; $loSplit.SplitterWidth = 6
    $loGrid = New-DarkGrid $T
    $loGrid.AllowDrop = $true; $loGrid.MultiSelect = $false
    $null = Add-GridColumn $loGrid 'Pos' '#' 50
    $null = Add-GridColumn $loGrid 'LoMod' 'Mod' 300 'text' 45
    $null = Add-GridColumn $loGrid 'LoArch' 'Archives' 80
    $null = Add-GridColumn $loGrid 'LoFiles' 'Game files' 90
    $null = Add-GridColumn $loGrid 'LoConf' 'Conflicts' 300 'text' 55
    $null = Add-GridColumn $loGrid 'LoSrc' 'Source' 110
    foreach ($col in $loGrid.Columns) { $col.ReadOnly = $true; $col.SortMode = 'NotSortable' }
    $loSplit.Panel1.Controls.Add($loGrid)
    $loBottom = New-Object Windows.Forms.SplitContainer; $loBottom.Dock = 'Fill'; $loBottom.BackColor = $T.bg; $loBottom.SplitterWidth = 6
    $loInfo = New-Object Windows.Forms.RichTextBox; $loInfo.Dock = 'Fill'; $loInfo.ReadOnly = $true; $loInfo.BorderStyle = 'None'; $loInfo.BackColor = $T.panel; $loInfo.ForeColor = $T.text; $loInfo.Font = $font
    $loBottom.Panel1.Controls.Add($loInfo)
    $rmTool = New-Object Windows.Forms.FlowLayoutPanel; $rmTool.Dock = 'Top'; $rmTool.Height = 40; $rmTool.WrapContents = $false; $rmTool.BackColor = $T.bg
    $rmTitle = New-Object Windows.Forms.Label; $rmTitle.Text = 'REDmods'; $rmTitle.Font = $bold; $rmTitle.ForeColor = $T.text; $rmTitle.AutoSize = $true; $rmTitle.Margin = New-Object Windows.Forms.Padding(0, 10, 12, 0)
    $btnRmUp = New-DarkButton $T ([string][char]0x25B2); $btnRmDown = New-DarkButton $T ([string][char]0x25BC); $btnRmDeploy = New-DarkButton $T 'Deploy REDmods' 'primary'
    foreach ($c in @($btnRmUp, $btnRmDown, $btnRmDeploy)) { $c.Margin = New-Object Windows.Forms.Padding(0, 4, 6, 4) }
    $rmTool.Controls.AddRange(@($rmTitle, $btnRmUp, $btnRmDown, $btnRmDeploy))
    $rmGrid = New-DarkGrid $T
    $null = Add-GridColumn $rmGrid 'RmPos' '#' 40
    $null = Add-GridColumn $rmGrid 'RmName' 'REDmod' 200 'text' 70
    $null = Add-GridColumn $rmGrid 'RmVer' 'Version' 80
    foreach ($col in $rmGrid.Columns) { $col.ReadOnly = $true; $col.SortMode = 'NotSortable' }
    $rmEmpty = New-Object Windows.Forms.Label; $rmEmpty.Dock = 'Fill'; $rmEmpty.ForeColor = $T.muted; $rmEmpty.Padding = New-Object Windows.Forms.Padding(4, 8, 4, 0)
    $rmEmpty.Text = "No REDmods installed. REDmods are mods in the game's \mods folder; they load after every archive mod and need the free REDmod DLC. Vortex orders them on its own Load Order page; this list works the same way and deploys them with redMod.exe."
    $loBottom.Panel2.Controls.Add($rmGrid); $loBottom.Panel2.Controls.Add($rmEmpty); $loBottom.Panel2.Controls.Add($rmTool)
    $loSplit.Panel2.Controls.Add($loBottom)
    $loStatus = New-Object Windows.Forms.Label; $loStatus.Dock = 'Bottom'; $loStatus.Height = 26; $loStatus.ForeColor = $T.muted; $loStatus.Text = 'Reading your archive mods...'
    $pageLO.Controls.Add($loSplit); $pageLO.Controls.Add($loStatus); $pageLO.Controls.Add($loHint); $pageLO.Controls.Add($loTool)

    # ---------- Settings page ----------
    $setT = New-Object Windows.Forms.TableLayoutPanel; $setT.Dock = 'Top'; $setT.AutoSize = $true; $setT.ColumnCount = 3; $setT.BackColor = $T.bg
    [void]$setT.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', 230)))
    [void]$setT.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', 620)))
    [void]$setT.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize')))
    $mkLabel = { param($txt) $l = New-Object Windows.Forms.Label; $l.Text = $txt; $l.ForeColor = $T.text; $l.AutoSize = $true; $l.Margin = New-Object Windows.Forms.Padding(0, 12, 8, 4); return $l }
    $mkHint = { param($txt) $l = New-Object Windows.Forms.Label; $l.Text = $txt; $l.ForeColor = $T.muted; $l.AutoSize = $true; $l.MaximumSize = New-Object Drawing.Size(600, 0); $l.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 10); return $l }
    $mkBox = { param($v, [bool]$secret) $b = New-Object Windows.Forms.TextBox; $b.Width = 600; $b.Text = $v; $b.BackColor = $T.panel2; $b.ForeColor = $T.text; $b.BorderStyle = 'FixedSingle'; $b.UseSystemPasswordChar = $secret; $b.Margin = New-Object Windows.Forms.Padding(0, 9, 8, 2); return $b }
    $txtGame = & $mkBox $config.gameDir $false; $btnBrowse = New-DarkButton $T 'Browse...'
    $chkUseGame = New-Object Windows.Forms.CheckBox; $chkUseGame.Text = "Use the game's own mod.io sign-in"; $chkUseGame.AutoSize = $true; $chkUseGame.ForeColor = $T.text; $chkUseGame.Checked = [bool]$config.modioUseGame; $chkUseGame.Margin = New-Object Windows.Forms.Padding(0, 10, 0, 2)
    $k1 = & $mkBox $config.nexusKey $true; $k2 = & $mkBox $config.modioPat $true; $k4 = & $mkBox $config.modioApiPath $false; $k3 = & $mkBox $config.githubToken $true
    $rows0 = @(
        @('Game folder', $txtGame, $btnBrowse, 'The folder that contains bin\x64\Cyberpunk2077.exe.'),
        @('Nexus API key', $k1, $null, 'Optional but recommended. next.nexusmods.com/settings/api-keys > Personal API Key. Needed for update checks, requirements and the newer mods.'),
        @('mod.io token', $k2, $null, 'Only needed when the box below is off or the game has never signed in to mod.io on this PC. A Personal Access Token from mod.io/me/access.'),
        @('', $chkUseGame, $null, "Recommended. The game signs in to mod.io through your CD PROJEKT RED account, which is its own mod.io account (it can show your CDPR name but is not the account you use on the mod.io website). The game only downloads mods subscribed on that account, so the app uses the game's sign-in from this PC."),
        @('mod.io API path', $k4, $null, 'Leave empty unless mod.io/me/access shows a personal API path such as https://u-12345.modapi.io/v1.'),
        @('GitHub token', $k3, $null, 'Optional. App updates come from the public repo github.com/Sirtacoburrito/NightCityInstaller.')
    )
    $r = 0
    foreach ($row in $rows0) {
        $setT.Controls.Add((& $mkLabel $row[0]), 0, $r); $setT.Controls.Add($row[1], 1, $r); if ($row[2]) { $setT.Controls.Add($row[2], 2, $r) }; $r++
        $setT.Controls.Add((& $mkHint $row[3]), 1, $r); $r++
    }
    $setBtns = New-Object Windows.Forms.FlowLayoutPanel; $setBtns.AutoSize = $true
    $btnTest = New-DarkButton $T 'Test connections'; $btnSave = New-DarkButton $T 'Save' 'primary'; $btnShortcut = New-DarkButton $T 'Create desktop shortcut'
    $setBtns.Controls.AddRange(@($btnSave, $btnTest, $btnShortcut))
    $setT.Controls.Add($setBtns, 1, $r); $r++
    $setRes = New-Object Windows.Forms.Label; $setRes.AutoSize = $true; $setRes.MaximumSize = New-Object Drawing.Size(600, 0); $setRes.ForeColor = $T.muted; $setRes.Margin = New-Object Windows.Forms.Padding(0, 10, 0, 0)
    $setT.Controls.Add($setRes, 1, $r); $r++
    $about = & $mkHint "Night City Installer $($script:AppVersion). Source and updates: github.com/Sirtacoburrito/NightCityInstaller. Keys are encrypted for your Windows user and sent only to Nexus, mod.io and GitHub."
    $setT.Controls.Add($about, 1, $r)
    $pageSet.Controls.Add($setT)

    # ---------- Log page ----------
    $log = New-Object Windows.Forms.TextBox; $log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Vertical'; $log.Dock = 'Fill'
    $log.BackColor = $T.sidebar; $log.ForeColor = (New-Rgb 200 205 210); $log.BorderStyle = 'None'; $log.Font = New-Object Drawing.Font('Consolas', 9.5)
    $pageLog.Controls.Add($log)

    $form.Controls.Add($main); $form.Controls.Add($side)

    # ================= state shared by the handlers =================
    $rows = @{}
    $locked = New-Object 'System.Collections.Generic.HashSet[string]'
    $updatesById = @{}
    $engineRef = @{ E = $null; C = $null; D = $null; AppUpdate = $null; CShared = $null; appQuiet = $true; restartAfterClose = $false }
    $bgRef = @{ runner = $null; refreshAgain = $false; detailsPending = $null }
    $postHandlers = @{}
    $detailState = @{ key = ''; images = (New-Object System.Collections.ArrayList); pending = (New-Object System.Collections.ArrayList) }
    $pill = @{
        ok     = @{ back = (New-Rgb 46 96 52);  fore = (New-Rgb 205 245 200) }
        update = @{ back = (New-Rgb 168 98 32); fore = (New-Rgb 255 245 230) }
        wait   = @{ back = (New-Rgb 96 84 28);  fore = (New-Rgb 255 236 160) }
        fail   = @{ back = (New-Rgb 120 44 44); fore = (New-Rgb 255 210 210) }
        busy   = @{ back = (New-Rgb 40 74 130); fore = (New-Rgb 210 228 255) }
        none   = @{ back = (New-Rgb 48 49 56);  fore = (New-Rgb 175 177 186) }
        muted  = @{ back = (New-Rgb 40 41 46);  fore = (New-Rgb 130 132 140) }
    }
    $lookFor = {
        param([string]$status)
        $s0 = $status -replace '^[^A-Za-z]+', ''
        if ($s0 -match '^(Installed|Updated|Subscribed|Already|Up to date)') { return 'ok' }
        if ($s0 -match '^(Waiting for 2\.5|Needs)') { return 'wait' }
        if ($s0 -match '^(Failed|Not found)') { return 'fail' }
        if ($s0 -match '^Update') { return 'update' }
        if ($s0 -match '^(Waiting for your click|Working)') { return 'busy' }
        if ($s0 -match '^Console only') { return 'muted' }
        return 'none'
    }
    $decorate = {
        param([string]$status)
        $k = & $lookFor $status
        if (-not $status) { return 'Not installed' }
        if ($k -eq 'ok' -and -not $status.StartsWith($script:Glyph.ok)) { return "$($script:Glyph.ok) $status" }
        if ($k -eq 'update' -and -not $status.StartsWith($script:Glyph.up)) { return "$($script:Glyph.up) $status" }
        return $status
    }
    $setStatusCell = {
        param($row, [string]$status)
        $txt = & $decorate $status
        $row.Cells['Status'].Value = $txt
        $row.Cells['Status'].Tag = (& $lookFor $txt)
    }
    $setLock = {
        param($row, [bool]$on)
        $k = [string]$row.Tag
        if ($on) { [void]$locked.Add($k); $row.Cells['Q'].Value = $false; $row.Cells['Q'].ReadOnly = $true }
        else { [void]$locked.Remove($k); $row.Cells['Q'].ReadOnly = $false }
    }
    $batchName = { param($it) $b = $manifest.batches[[int]$it.batch]; if ($b) { [string]$b.name } else { '' } }

    $addRow = {
        param($it)
        $st = ''; $dt = ''; $done = $false
        if ($state.ContainsKey($it.key)) { $st = $state[$it.key].status; $dt = $state[$it.key].detail; $done = $state[$it.key].done }
        if (-not $dt -and $it.note) { $dt = $it.note }
        $i = $grid.Rows.Add(((-not $it.optional) -and (-not $done)), '', $it.name, '', (& $batchName $it), $(if ($it.source -eq 'nexus') { 'Nexus' } else { 'mod.io' }), $dt)
        $row = $grid.Rows[$i]; $row.Tag = $it.key
        & $setStatusCell $row $st
        $rows[$it.key] = @{ grid = 'mods'; row = $row }
        $cat = & $batchName $it
        if ($cat -and -not $cmbCat.Items.Contains($cat)) { [void]$cmbCat.Items.Add($cat) }
    }
    [void]$cmbCat.Items.Add('All categories')
    foreach ($it in $manifest.items) { & $addRow $it }
    $cmbCat.SelectedIndex = 0

    $updateSummary = {
        $inst = 0; $wait = 0; $todo = 0; $upd = 0
        foreach ($row in $grid.Rows) {
            $k = [string]$row.Cells['Status'].Tag
            if ($k -eq 'ok') { $inst++ } elseif ($k -eq 'wait') { $wait++ } elseif ($k -eq 'update') { $upd++ }
            if ($row.Cells['Q'].Value -eq $true) { $todo++ }
        }
        $statusBar.Text = "$($script:Glyph.ok) $inst installed     $($script:Glyph.up) $upd updates     $($script:Glyph.dot) $todo ticked to install     $($script:Glyph.dot) $wait waiting     ($($grid.Rows.Count) mods in the list)"
        $navButtons['Updates'].Text = if ($upd -gt 0 -or $updatesById.Count -gt 0) { "Updates  ($([Math]::Max($upd, $updatesById.Count)))" } else { 'Updates' }
    }

    $applyFilter = {
        $q = $txtSearch.Text.Trim().ToLowerInvariant()
        $cat = [string]$cmbCat.SelectedItem; $stf = [string]$cmbSt.SelectedItem
        $grid.CurrentCell = $null
        foreach ($row in $grid.Rows) {
            $show = $true
            if ($q -and -not ([string]$row.Cells['ModName'].Value).ToLowerInvariant().Contains($q)) { $show = $false }
            if ($show -and $cat -and $cat -ne 'All categories' -and [string]$row.Cells['Category'].Value -ne $cat) { $show = $false }
            if ($show -and $stf -and $stf -ne 'All') {
                $k = [string]$row.Cells['Status'].Tag
                switch ($stf) {
                    'Installed'                 { $show = ($k -eq 'ok') }
                    'Not installed'             { $show = ($k -in @('none', 'busy')) }
                    'Ticked'                    { $show = ($row.Cells['Q'].Value -eq $true) }
                    'Update available'          { $show = ($k -eq 'update') }
                    'Waiting / needs something' { $show = ($k -eq 'wait') }
                    'Problems'                  { $show = ($k -eq 'fail') }
                }
            }
            $row.Visible = $show
        }
    }

    # ---------------- UI adapter used by the engine, checker and discovery ----------------
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
        $row = $entry.row
        if ($entry.grid -eq 'mods') {
            & $setStatusCell $row $status
            if ($detail) { $row.Cells['Info'].Value = $detail }
            $k = [string]$row.Cells['Status'].Tag
            if ($k -eq 'ok' -or $k -eq 'muted') {
                & $setLock $row $true
                if ($key -like 'nexus:*') { $updatesById.Remove([int]($key -replace '^nexus:', '')) }
            }
            try { if ($row.Visible) { $grid.FirstDisplayedScrollingRowIndex = [Math]::Max(0, $row.Index - 5) } } catch {}
            & $updateSummary
        } else {
            $row.Cells['Status'].Value = (& $decorate $status); $row.Cells['Status'].Tag = (& $lookFor $status)
            if ((& $lookFor $status) -eq 'ok') { $row.Cells['Q'].Value = $false }
        }
        $grid.InvalidateColumn($colStatus.Index); $updGrid.InvalidateColumn($colUStatus.Index)
    }
    $ui | Add-Member ScriptMethod Banner {
        param($text, $buttons)
        $bannerText.Text = $text
        $bannerBtns.Controls.Clear()
        foreach ($b in @($buttons)) {
            $btn = New-DarkButton $T $b 'primary'; $btn.Margin = New-Object Windows.Forms.Padding(8, 6, 0, 0)
            $btn.Add_Click({ param($s, $a) if ($s.Text -eq 'Update app') { & $doAppUpdate } elseif ($s.Text -eq 'Open Health check') { & $showPage 'Health check' } elseif ($engineRef.E) { Invoke-EngineAction $engineRef.E $s.Text } })
            $bannerBtns.Controls.Add($btn)
        }
        $banner.Visible = -not [string]::IsNullOrEmpty($text)
    }
    $ui | Add-Member ScriptMethod OpenUrl { param($u) Start-Process $u }
    $ui | Add-Member ScriptMethod AddItem { param($it) if (-not $rows.ContainsKey($it.key)) { & $addRow $it; & $updateSummary } }
    $ui | Add-Member ScriptMethod UpdateRow {
        param($res)
        $entry = $rows[$res.key]
        if (-not $entry) {
            $cat = if ($res.source -eq 'mod.io') { 'mod.io (the game updates these)' } elseif ($res.framework) { 'Frameworks (update first)' } else { 'Nexus mods' }
            $i = $updGrid.Rows.Add($false, '', [string]$res.name, '', '', $cat, [string]$res.source)
            $entry = @{ grid = 'updates'; row = $updGrid.Rows[$i] }
            $rows[$res.key] = $entry
            if ($res.source -eq 'Nexus') { $rows["update:$($res.id)"] = $entry }
        }
        $row = $entry.row; $row.Tag = $res
        $row.Cells['Installed'].Value = [string]$res.installed; $row.Cells['Latest'].Value = [string]$res.latest
        $st = [string]$res.status
        $row.Cells['Status'].Value = (& $decorate $st)
        $row.Cells['Status'].Tag = $(if ($res.update) { 'update' } elseif ($st -like 'Up to date*') { 'ok' } elseif ($st -like 'Updated*') { 'busy' } elseif ($st -like 'Add a Nexus key*') { 'wait' } else { 'fail' })
        $row.Cells['Q'].Value = [bool]$res.update; $row.Cells['Q'].ReadOnly = -not $res.update
    }
    $ui | Add-Member ScriptMethod CheckFinished {
        param($n)
        $updatesById.Clear()
        $resList = if ($engineRef.CShared -and $engineRef.CShared.C) { $engineRef.CShared.C.results } else { @() }
        foreach ($res in @($resList | Where-Object { $_.update -and $_.source -eq 'Nexus' })) { $updatesById[[int]$res.id] = $res }
        foreach ($id in @($updatesById.Keys)) {
            $entry = $rows["nexus:$id"]
            if ($entry -and $entry.grid -eq 'mods') {
                $u = $updatesById[$id]; $row = $entry.row
                & $setLock $row $false
                & $setStatusCell $row 'Update available'
                $row.Cells['Info'].Value = "v$($u.installed) -> v$($u.latest)"; $row.Cells['Q'].Value = $true
            }
        }
        $btnCheck.Enabled = $true; $btnUpdate.Enabled = ($n -gt 0)
        & $updateUpdHeader; & $updateSummary
        if ($n -gt 0) {
            $ui.Log("Update check: $n Nexus mods have updates. They're ticked on the Mods page (orange) and listed on the Updates page.")
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
            $ui.Log("Discovery: added $added new mods for this game version ($mo from mod.io, ticked; $nx from Nexus, unticked). Filter the Category list by 'Discovered' to see them.")
        } else { $ui.Log('Discovery: no new compatible mods since last time.') }
    }

    $engineBusy = { return ($engineRef.E -and $engineRef.E.mode -notin @('idle', 'done', 'paused')) }

    # ---------------- background jobs ----------------
    $bgNames = @{ installed = 'checking what is installed'; health = 'health check'; updates = 'checking mod updates'; discovery = 'looking for new mods'; appupdate = 'checking for app updates'; details = 'loading mod details'; loadorder = 'reading load order'; loapply = 'saving load order'; redmod = 'deploying REDmods' }
    $dispatch = {
        param($ev)
        switch ([string]$ev[0]) {
            'Log' { $ui.Log([string]$ev[1]) }
            'SetStatus' { $ui.SetStatus($ev[1], $ev[2], $ev[3]) }
            'Banner' { $ui.Banner($ev[1], $ev[2]) }
            'OpenUrl' { Start-Process ([string]$ev[1]) }
            'AddItem' { $ui.AddItem($ev[1]) }
            'UpdateRow' { $ui.UpdateRow($ev[1]) }
            'CheckFinished' { $ui.CheckFinished($ev[1]) }
            'DiscoveryFinished' { $ui.DiscoveryFinished($ev[1]) }
            'Post' { $h = $postHandlers[[string]$ev[1]]; if ($h) { & $h $ev[2] $ev[3] } }
        }
    }
    $bgTimer = New-Object Windows.Forms.Timer; $bgTimer.Interval = 100
    $bgTimer.Add_Tick({
        $r = $bgRef.runner; if (-not $r) { return }
        $ev = $null; $n = 0
        while ($n -lt 150 -and $r.queue.TryDequeue([ref]$ev)) { $n++; try { & $dispatch $ev } catch { try { $ui.Log('UI update failed: ' + $_.Exception.Message) } catch {} } }
        foreach ($j in @(Receive-BgJobs $r)) {
            if ($j.box.error) { $ui.Log("Background task '$($j.name)' failed: $($j.box.error)"); Write-Trace "bg error $($j.name): $($j.box.error) $($j.box.errorAt)" }
            Write-Trace ("bg done {0} in {1:N1}s" -f $j.name, ((Get-Date) - $j.started).TotalSeconds)
            if ($j.onDone) { try { & $j.onDone $j.box } catch { $ui.Log("Background task '$($j.name)' result couldn't be shown: " + $_.Exception.Message) } }
        }
        $busy = @(@($r.jobs) | ForEach-Object { $bgNames[$_.name] } | Where-Object { $_ } | Sort-Object -Unique)
        $bgLbl.Text = if ($busy.Count) { 'Working in the background: ' + ($busy -join ', ') + '...' } else { '' }
    })
    $runBg = {
        param([string]$name, [scriptblock]$work, [object[]]$argList, [scriptblock]$onDone)
        if (-not $bgRef.runner) { $bgRef.runner = New-BgRunner 4; $bgTimer.Start() }
        return (Start-BgJob $bgRef.runner $name $work $argList $onDone)
    }
    $bgRunning = { param([string]$name) return (Test-BgJobRunning $bgRef.runner $name) }

    # ---------------- details pane ----------------
    $setImage = {
        param($pb, [string]$path)
        try { $pb.Image = ConvertTo-DrawingImage $path }
        catch { $bytes = $null; $head = ''; try { $bytes = [IO.File]::ReadAllBytes($path); $head = [Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min(48, $bytes.Length)) -replace '[^\x20-\x7e]', '.' } catch {}; Write-Trace "image decode failed for $path ($($bytes.Length) bytes, starts '$head'): $($_.Exception.Message)" }
    }
    $showDetails = {
        param([string]$key)
        $it = $manifest.items | Where-Object { $_.key -eq $key } | Select-Object -First 1
        if (-not $it) { return }
        $detailState.key = $key; $detailState.images.Clear(); $detailState.pending.Clear()
        $detPic.Image = $null; $detThumbs.Controls.Clear()
        $detName.Text = $it.name
        $entry = $rows[$key]
        $stTxt = if ($entry) { [string]$entry.row.Cells['Status'].Value } else { '' }
        $detMeta.Text = "$(if ($it.source -eq 'nexus') { 'Nexus Mods' } else { 'mod.io' })   |   $(& $batchName $it)   |   $stTxt"
        $parts = New-Object System.Collections.ArrayList
        if ($it.desc) { [void]$parts.Add($it.desc) }
        if ($it.note) { [void]$parts.Add("Note: $($it.note)") }
        $detText.Text = ($parts -join "`n`n") + "`n`nLoading details from the mod page..."
        $detailState.info = $null
        $detailTimer.Stop(); $detailTimer.Start()
    }
    $detailTimer = New-Object Windows.Forms.Timer; $detailTimer.Interval = 120
    $detailTimer.Add_Tick({
        $detailTimer.Stop()
        $key = $detailState.key
        $it = $manifest.items | Where-Object { $_.key -eq $key } | Select-Object -First 1
        if (-not $it) { return }
        if (& $bgRunning 'details') { $bgRef.detailsPending = $key; return }
        $null = & $runBg 'details' {
            param($it, $cfg, $key)
            $info = $null
            if ($it.source -eq 'nexus') { $info = Get-NexusModInfo $it.id $cfg.nexusKey }
            elseif ($cfg.modioToken) {
                if (-not $cfg.modioGameId) { $cfg.modioGameId = Resolve-ModioGameId $cfg.modioToken }
                $mid = [int]$it.modioId
                $cache = Get-ModInfoCache
                if (-not $mid -and $cache.ContainsKey("modioq:$($it.query)")) { $mid = [int]$cache["modioq:$($it.query)"].id }
                if (-not $mid) {
                    $sel = Select-ModioMatch (Search-Modio $cfg.modioGameId $it.query $cfg.modioToken -AnyPlatform) $it.query $it.exclude
                    $hit = if ($sel.match) { $sel.match } elseif ($sel.choices.Count) { Select-MostPopular $sel.choices } else { $null }
                    if ($hit) { $mid = [int]$hit.id; $cache["modioq:$($it.query)"] = [pscustomobject]@{ id = $mid; fetched = 0 }; Save-ModInfoCache }
                }
                if ($mid) { $info = Get-ModioModInfo $cfg.modioGameId $mid $cfg.modioToken }
            }
            $reqLines = @()
            if ($info) {
                $reqs = @(Get-RequirementsFromText ([string]$info.description) ([int]$it.id))
                if ($reqs.Count -gt 0) {
                    $have = if ($cfg.gameDir) { Get-InstalledNexusIds $cfg.gameDir } else { $null }
                    $reqLines = @(foreach ($q in $reqs) { $mark = if ($have -and $have.Contains([int]$q.id)) { 'installed' } else { 'MISSING' }; "  [$mark]  $($q.name)" })
                }
            }
            $BgUi.Post('details', $key, @{ info = $info; reqLines = $reqLines })
            if ($info) {
                $n = 0
                foreach ($u in @($info.images)) {
                    if (-not $u -or $n -ge 8) { continue }
                    try { $p = Get-CachedImage ([string]$u); if ($p) { $BgUi.Post('image', $key, (Get-DisplayImagePath $p)); $n++ } } catch {}
                }
            }
            return $true
        } @($it, $config, $key) {
            param($box)
            if ($box.error) { $postHandlers['details'].Invoke($detailState.key, @{ info = $null; reqLines = @(); error = $box.error }) }
            if ($bgRef.detailsPending) { $bgRef.detailsPending = $null; $detailTimer.Stop(); $detailTimer.Start() }
        }
    })
    $postHandlers['details'] = {
        param($key, $d)
        if ($key -ne $detailState.key) { return }
        $it = $manifest.items | Where-Object { $_.key -eq $key } | Select-Object -First 1
        if (-not $it) { return }
        $info = $d.info
        $detailState.info = $info
        $parts = New-Object System.Collections.ArrayList
        if ($it.desc) { [void]$parts.Add($it.desc) }
        if ($info -and $info.summary -and $info.summary -ne $it.desc) { [void]$parts.Add($info.summary) }
        if ($info) {
            if (@($d.reqLines).Count -gt 0) { [void]$parts.Add("Requirements:`n" + (@($d.reqLines) -join "`n")) }
            $meta = @()
            if ($info.author) { $meta += "by $($info.author)" }
            if ($info.version) { $meta += "v$($info.version)" }
            if ($info.endorsements) { $meta += "$($info.endorsements) endorsements" }
            if ($info.downloads) { $meta += ('{0:N0} downloads' -f [int]$info.downloads) }
            if ($meta.Count) { $detMeta.Text = $detMeta.Text + "`n" + ($meta -join '   |   ') }
            $long = ConvertTo-PlainText ([string]$info.description)
            if ($long) { $long = $long.Trim(); if ($long.Length -gt 3000) { $long = $long.Substring(0, 3000) + '...' }; [void]$parts.Add("From the mod page:`n" + $long) }
        } elseif ($d.error) { [void]$parts.Add("Couldn't load the mod page right now ($($d.error)).") }
        elseif (-not $config.nexusKey -and $it.source -eq 'nexus') { [void]$parts.Add('Add your Nexus key in Settings to see photos, requirements and the full description here.') }
        $rd = (Get-ModInfoCache)["readme:$key"]; if ($rd -and $rd.readme) { [void]$parts.Add("Readme:`n" + [string]$rd.readme) }
        if ($it.note) { [void]$parts.Add("Note: $($it.note)") }
        $detText.Text = $parts -join "`n`n"
    }
    $postHandlers['image'] = {
        param($key, $p)
        if ($key -ne $detailState.key -or -not $p) { return }
        [void]$detailState.images.Add($p)
        if (-not $detPic.Image) { & $setImage $detPic $p }
        $tb = New-Object Windows.Forms.PictureBox; $tb.Size = New-Object Drawing.Size(100, 56); $tb.SizeMode = 'Zoom'; $tb.BackColor = $T.sidebar; $tb.Cursor = 'Hand'; $tb.Tag = $p; $tb.Margin = New-Object Windows.Forms.Padding(0, 0, 6, 0)
        & $setImage $tb $p
        $tb.Add_Click({ param($s, $a) & $setImage $detPic ([string]$s.Tag) })
        $detThumbs.Controls.Add($tb)
    }
    $imgTimer = New-Object Windows.Forms.Timer
    $btnOpenPage.Add_Click({ $i = $detailState.info; $it = $manifest.items | Where-Object { $_.key -eq $detailState.key } | Select-Object -First 1
        if ($i -and $i.url) { Start-Process $i.url } elseif ($it -and $it.source -eq 'nexus') { Start-Process "https://www.nexusmods.com/cyberpunk2077/mods/$($it.id)" } elseif ($it) { Start-Process ('https://mod.io/g/cyberpunk2077?_q=' + (UrlEnc $it.query)) } })
    $btnOpenGallery.Add_Click({ $i = $detailState.info; if ($i -and $i.gallery) { Start-Process $i.gallery } })
    $detPic.Add_Click({ $i = $detailState.info; if ($i -and $i.gallery) { Start-Process $i.gallery } })

    # ---------------- page switching ----------------
    $showPage = {
        param([string]$name)
        foreach ($k in $pageInfo.Keys) { $pageInfo[$k].panel.Visible = ($k -eq $name) }
        foreach ($k in $navButtons.Keys) {
            $b = $navButtons[$k]
            if ($k -eq $name) { $b.BackColor = $T.hover; $b.ForeColor = $T.yellow } else { $b.BackColor = $T.sidebar; $b.ForeColor = $T.text }
        }
        $hTitle.Text = $pageInfo[$name].title; $hSub.Text = $pageInfo[$name].sub
        if ($name -eq 'Health check' -and -not (& $bgRunning 'health')) { & $runHealth }
        if ($name -eq 'Load Order' -and -not $loRef.model) { & $loLoad }
    }
    foreach ($k in $navButtons.Keys) { $navButtons[$k].Add_Click({ param($s, $a) & $showPage ([string]$s.Tag) }) }

    # ---------------- installed snapshot ----------------
    $applySnapshot = {
        param($snap)
        $n = 0
        foreach ($it in $manifest.items) {
            $entry = $rows[$it.key]; if (-not $entry) { continue }
            $row = $entry.row
            $saved = if ($state.ContainsKey($it.key)) { $state[$it.key].status } else { '' }
            if (-not $snap.ContainsKey($it.key)) { & $setStatusCell $row $saved; if ((& $lookFor $saved) -in @('ok', 'muted')) { & $setLock $row $true }; continue }
            $s = $snap[$it.key]
            if ($s.installed -and $it.source -eq 'nexus' -and $updatesById.ContainsKey([int]$it.id)) {
                $n++; $u = $updatesById[[int]$it.id]
                & $setLock $row $false; & $setStatusCell $row 'Update available'
                $row.Cells['Version'].Value = [string]$u.installed; $row.Cells['Info'].Value = "v$($u.installed) -> v$($u.latest)"; $row.Cells['Q'].Value = $true
            } elseif ($s.installed) {
                $n++
                & $setStatusCell $row $(if ($it.source -eq 'nexus') { 'Installed' } else { 'Subscribed' })
                if ($s.detail -match '^v(.+) in Vortex$') { $row.Cells['Version'].Value = $Matches[1] }
                $row.Cells['Info'].Value = $(if ($it.source -eq 'nexus') { 'Locked: installed, no update' } else { 'Locked: the game keeps it updated' })
                & $setLock $row $true
            } else {
                if ((& $lookFor $saved) -eq 'ok') { $state.Remove($it.key); $saved = ''; $row.Cells['Info'].Value = 'Not installed any more'; $row.Cells['Q'].Value = -not $it.optional }
                if ((& $lookFor $saved) -eq 'muted') { & $setLock $row $true } else { & $setLock $row $false }
                & $setStatusCell $row $saved
            }
        }
        Save-State $state
        $grid.Invalidate(); & $updateSummary; & $applyFilter
        $ui.Log("Installed check: $n of $($manifest.items.Count) list mods are already in place.")
    }
    $refreshInstalled = {
        if (-not $config.gameDir -or -not (Test-Path -LiteralPath $config.gameDir)) { return }
        if (& $bgRunning 'installed') { $bgRef.refreshAgain = $true; return }
        $mcopy = [pscustomobject]@{ items = @($manifest.items) }
        $null = & $runBg 'installed' {
            param($m, $cfg)
            $subs = $null
            if ($cfg.modioToken) {
                try {
                    if (-not $cfg.modioGameId) { $cfg.modioGameId = Resolve-ModioGameId $cfg.modioToken; Save-Config $cfg }
                    $subs = @(Get-ModioSubscribedDetails $cfg.modioGameId $cfg.modioToken)
                } catch { $BgUi.Log('Could not read your mod.io subscriptions: ' + $_.Exception.Message) }
            }
            return (Get-InstallSnapshot $m $cfg.gameDir $subs)
        } @($mcopy, $config) {
            param($box)
            if ($box.result) { & $applySnapshot $box.result }
            if ($bgRef.refreshAgain) { $bgRef.refreshAgain = $false; & $refreshInstalled }
        }
    }

    # ---------------- health ----------------
    $modioRef = [hashtable]::Synchronized(@{ user = ''; uid = 0; subs = -1; when = $null })
    $healthRef = @{ last = @(); again = $false; after = $null }
    $renderHealth = {
        param($issues)
        $hGrid.Rows.Clear()
        if ($issues.Count -eq 0) { $i = $hGrid.Rows.Add('OK', 'No problems found', 'The game folder, your mods and their requirements look healthy.', ''); $c0 = New-Object Windows.Forms.DataGridViewTextBoxCell; $c0.Value = ''; $hGrid.Rows[$i].Cells['Fix'] = $c0 }
        $order = @{ error = 0; warning = 1; info = 2 }
        foreach ($is in @($issues | Sort-Object { $order[[string]$_.level] })) {
            $label = switch ([string]$is.fix) { { $_ -like 'nexus-page:*' } { 'Download' } 'open-loadorder' { 'Open' } 'steam-verify' { 'Verify' } default { 'Fix' } }
            $i = $hGrid.Rows.Add($is.level.ToUpper(), $is.title, $is.detail, $(if ($is.fix) { $label } else { '' }))
            $hGrid.Rows[$i].Tag = $is
            if (-not $is.fix) { $c0 = New-Object Windows.Forms.DataGridViewTextBoxCell; $c0.Value = ''; $c0.Style.BackColor = $T.panel; $hGrid.Rows[$i].Cells['Fix'] = $c0 }
        }
        $err = @($issues | Where-Object { $_.level -eq 'error' }).Count
        $navButtons['Health check'].Text = if ($err -gt 0) { "Health check  ($err)" } else { 'Health check' }
    }
    $runHealth = {
        param([scriptblock]$after)
        if ($after) { $healthRef.after = $after }
        if (& $bgRunning 'health') { $healthRef.again = $true; return }
        $btnHealth.Enabled = $false; $btnHealth.Text = 'Checking...'
        $null = & $runBg 'health' {
            param($cfg, $mref)
            $all = New-Object System.Collections.ArrayList
            foreach ($x in @(Get-HealthIssues $cfg.gameDir)) { [void]$all.Add($x) }
            foreach ($x in @(Get-ModioCheckIssues $cfg $mref $BgUi)) { [void]$all.Add($x) }
            $rep = New-Object System.Collections.ArrayList
            [void]$rep.Add("Requirement check $((Get-Date).ToString('yyyy-MM-dd HH:mm')) - every installed mod and what it needs")
            [void]$rep.Add(''); [void]$rep.Add('Nexus mods (Vortex): requirement list on each mod page + the Requirements section of its description')
            $seen = New-Object 'System.Collections.Generic.HashSet[string]'
            $mrep = New-Object System.Collections.ArrayList
            $mio = @(Get-ModioDependencyIssues $cfg $mrep $BgUi)
            if ($cfg.nexusKey) {
                try { foreach ($x in @(Get-RequirementIssues $cfg.gameDir $cfg.nexusKey $BgUi $rep)) { if ($seen.Add($x.id)) { [void]$all.Add($x) } } }
                catch { $BgUi.Log('Nexus requirement check skipped: ' + $_.Exception.Message); [void]$rep.Add('  (skipped: ' + $_.Exception.Message + ')') }
            } else { [void]$rep.Add('  (skipped: add your Nexus key in Settings)') }
            [void]$rep.Add('  [MISSING] = in the mod page''s official requirement list; [maybe missing] = only mentioned in the description')
            [void]$rep.Add(''); [void]$rep.Add('mod.io mods: dependencies of every subscribed mod')
            foreach ($l in $mrep) { [void]$rep.Add($l) }
            foreach ($x in $mio) { if ($seen.Add($x.id)) { [void]$all.Add($x) } }
            [void]$rep.Add(''); [void]$rep.Add('All mods, wherever they came from: frameworks their files use')
            try { foreach ($x in @(Get-ContentRequirementIssues $cfg.gameDir (Get-VortexInfo $cfg.gameDir).ids $rep)) { if ($seen.Add($x.id)) { [void]$all.Add($x) } } }
            catch { [void]$rep.Add('  (skipped: ' + $_.Exception.Message + ')') }
            $nmiss = @($all | Where-Object { $_.id -like 'req:*' -or $_.id -like 'reqoff:*' -or $_.id -like 'modiodep:*' }).Count
            $nmaybe = @($all | Where-Object { $_.id -like 'reqhint:*' }).Count
            [void]$rep.Add(''); [void]$rep.Add($(if ($nmiss) { "$nmiss missing requirement(s)" } else { 'No missing requirements' }) + $(if ($nmaybe) { ", $nmaybe possibly missing (only mentioned in descriptions)" } else { '' }) + ' - see the Health check page.')
            Write-RequirementsReport $rep.ToArray()
            $model = $null
            try {
                $model = Get-LoadOrderModel $cfg.gameDir
                $lcfg = Get-LoadOrderConfig
                $u = Update-LoadOrderAuto $model $lcfg
                if ($u -and $u.changed) { $BgUi.Log("Load order: kept up to date ($($u.added) new mod(s) placed by their conflicts)."); $model = Get-LoadOrderModel $cfg.gameDir }
                foreach ($x in @(Get-LoadOrderIssues $model $lcfg)) { [void]$all.Add($x) }
            } catch { $BgUi.Log('Load order check skipped: ' + $_.Exception.Message) }
            return @{ issues = $all.ToArray(); model = $model }
        } @($config, $modioRef) {
            param($box)
            $btnHealth.Enabled = $true; $btnHealth.Text = [string][char]0x21BB + '  Run health check'
            if (-not $box.result) { return }
            $issues = @($box.result.issues)
            $healthRef.last = $issues
            & $renderHealth $issues
            if ($box.result.model -and -not $loRef.dirty) { & $loSetModel $box.result.model }
            $a = $healthRef.after; $healthRef.after = $null
            if ($a) { & $a $issues }
            if ($healthRef.again) { $healthRef.again = $false; & $runHealth }
        }
    }
    $applyFix = {
        param($is)
        try {
            if ($is.fix -eq 'modio-use-game') {
                $config.modioUseGame = $true; $chkUseGame.Checked = $true; Update-ModioSource $config; Save-Config $config
                $modioRef.when = $null
                if ($config.modioSource -eq 'game') {
                    $ui.Log("mod.io: now using the game's own sign-in ('$($config.modioGameLogin.username)').")
                    & $refreshInstalled
                    $modioRef.when = $null
                    $ui.Banner("The app now uses the game's own mod.io account. Click Start install to subscribe your mod.io mods there; the game downloads them from its Mods menu.", @())
                } else { $ui.Log("mod.io: couldn't use the game's sign-in (it may have expired). Start the game, open Mods on the main menu, then try again.") }
            }
            elseif ($is.fix -like 'nexus-page:*') { Start-Process ("https://www.nexusmods.com/cyberpunk2077/mods/$($is.fix.Substring(11))?tab=files"); $ui.Log("Opened the download page for $($is.title -replace '^Missing requirement: ', ''). Click 'Slow download' (or 'Mod manager download'); Vortex installs it.") }
            elseif ($is.fix -eq 'open-loadorder') { & $showPage 'Load Order' }
            elseif ($is.fix -like 'modio-sub:*') {
                $mid = [int]$is.fix.Substring(10)
                Add-ModioSubscription ([int]$config.modioGameId) $mid $config.modioToken
                $ui.Log("mod.io: subscribed to $($is.title -replace '^Missing mod.io requirement: ', ''). The game downloads it from its Mods menu.")
                & $refreshInstalled
            }
            elseif ($is.fix -eq 'loadorder-apply') { & $loApply $true }
            elseif ($is.fix -eq 'steam-verify') { Start-Process 'steam://validate/1091500'; $ui.Log('Health: asked Steam to verify the Cyberpunk 2077 game files. Wait for it to finish (Steam > Downloads), then press Play.'); $ui.Banner('Steam is verifying the game files. When it finishes, press Play.', @()) }
            elseif ($is.fix -eq 'rename-modded') { if (Repair-EmptyModdedCache $config.gameDir) { $ui.Log('Health: renamed the empty r6\cache\modded folder.') } }
            elseif ($is.fix -like 'manual:*') {
                $name = $is.fix.Substring(7); $dir = Join-Path $config.gameDir "V2077\mod-extra-files\$name"
                $res = Invoke-ManualInstall $config.gameDir (Get-ManualInstallPlan $dir $name) "extra:$name"
                $ui.Log("Health: placed $($res.copied.Count) parked files for $name" + $(if ($res.skipped.Count) { " (kept $($res.skipped.Count) that already existed)" } else { '' }) + '.')
            }
        } catch { $ui.Log('Fix failed: ' + $_.Exception.Message) }
    }
    $hGrid.Add_CellContentClick({ param($s, $e) if ($e.RowIndex -ge 0 -and $hGrid.Columns[$e.ColumnIndex].Name -eq 'Fix') { $is = $hGrid.Rows[$e.RowIndex].Tag; if ($is -and $is.fix) { & $applyFix $is; if ($is.fix -notlike 'nexus-page:*' -and $is.fix -ne 'open-loadorder') { & $runHealth } } } })
    $btnHealth.Add_Click({ & $runHealth })
    # Queues every missing requirement from the mod pages' official lists (and missing frameworks)
    # in the installer: mod.io ones are subscribed, Nexus ones open one by one for your
    # "Slow download" click, and anything without a file for this game version waits.
    $btnReqInstall.Add_Click({
        if (& $engineBusy) { $ui.Banner('Finish or pause the current install first.', @()); return }
        if (-not (& $preflight)) { & $showPage 'Settings'; return }
        $keys = New-Object System.Collections.ArrayList
        foreach ($is in @($healthRef.last)) {
            if ($is.id -match '^modiodep:(\d+)$') { try { & $applyFix $is } catch {}; continue }
            if ($is.id -notmatch '^req:(\d+)$') { continue }
            $rid = [int]$Matches[1]
            $nm = ([string]$is.title) -replace '^Missing requirement: ', ''
            $note = ([string]$is.detail -split '\. ')[0]
            $it = Add-RequirementItem $manifest $rid $nm $note
            if (-not $rows.ContainsKey($it.key)) { & $addRow $it }
            $rows[$it.key].row.Cells['Q'].Value = $true
            [void]$keys.Add($it.key)
        }
        & $updateSummary
        if ($keys.Count -eq 0) { $ui.Log('No missing requirements to install.'); return }
        $ui.Log("Installing $($keys.Count) missing requirement(s). Each is checked for a file made for this game version first.")
        Save-Config $config
        $engineRef.E = New-Engine $manifest $config $state $ui
        $engineRef.E.updates = $updatesById
        Start-Engine $engineRef.E @($keys)
        if ($engineRef.E.mode -eq 'done') { return }
        & $showPage 'Mods'
        $ui.Banner('Working...', @())
        $btnStart.Enabled = $false; $btnPause.Enabled = $true; $btnUpdate.Enabled = $false
        $timer.Start()
    })
    # "Fix everything" only runs the fixes that need no decision from you (no browser pages, no Steam verify).
    $btnFixAll.Add_Click({ foreach ($is in @($healthRef.last)) { if ($is.fix -and $is.fix -notlike 'nexus-page:*' -and $is.fix -notin @('open-loadorder', 'steam-verify')) { & $applyFix $is } }; & $runHealth })
    $hGrid.Add_CellFormatting({ param($s, $e)
        if ($e.RowIndex -ge 0 -and $e.ColumnIndex -eq $colHLevel.Index) {
            switch ([string]$e.Value) { 'ERROR' { $e.CellStyle.ForeColor = (New-Rgb 255 140 140) } 'WARNING' { $e.CellStyle.ForeColor = (New-Rgb 255 210 120) } 'OK' { $e.CellStyle.ForeColor = (New-Rgb 150 220 140) } default { $e.CellStyle.ForeColor = $T.muted } }
        } })

    # ---------------- load order ----------------
    $loRef = @{ model = $null; order = (New-Object System.Collections.ArrayList); dirty = $false; cfg = (Get-LoadOrderConfig); rm = (New-Object System.Collections.ArrayList); dragFrom = -1 }
    $chkLoKeep.Checked = [bool]$loRef.cfg.keepUpdated
    $loRender = {
        $m = $loRef.model; if (-not $m) { return }
        $sel = if ($loGrid.CurrentRow) { $loGrid.CurrentRow.Index } else { 0 }
        $rep = @(Get-ConflictReport $m @($loRef.order))
        $loGrid.SuspendLayout(); $loGrid.Rows.Clear()
        $i = 0
        foreach ($k in $loRef.order) {
            $mod = $m.mods[$k]; if (-not $mod) { continue }
            $i++
            $wins = @($rep | Where-Object { $_.winner -eq $k }); $loses = @($rep | Where-Object { $_.loser -eq $k })
            $ctxt = @()
            if ($wins.Count) { $ctxt += 'overrides ' + (($wins | ForEach-Object { $m.mods[$_.loser].name }) -join ', ') }
            if ($loses.Count) { $ctxt += 'overridden by ' + (($loses | ForEach-Object { $m.mods[$_.winner].name }) -join ', ') }
            $r = $loGrid.Rows.Add($i, $mod.name, $mod.archives.Count, $mod.resources, ($ctxt -join '; '), $(if ($mod.managed) { 'Vortex' } else { 'Not in Vortex' }))
            $loGrid.Rows[$r].Tag = $k
            if ($loses.Count) { $loGrid.Rows[$r].DefaultCellStyle.ForeColor = (New-Rgb 255 200 120) } elseif ($wins.Count) { $loGrid.Rows[$r].DefaultCellStyle.ForeColor = (New-Rgb 150 220 140) }
        }
        $loGrid.ResumeLayout()
        if ($loGrid.Rows.Count -gt 0) { $sel = [Math]::Min([Math]::Max(0, $sel), $loGrid.Rows.Count - 1); $loGrid.CurrentCell = $loGrid.Rows[$sel].Cells[1] }
        $file = if ($m.hasModlist) { 'archive\pc\mod\modlist.txt is in use' } else { "no modlist.txt (the game's alphabetical order)" }
        $loStatus.Text = "$($loRef.order.Count) archive mods, $($m.archiveCount) archives, $($m.conflicts.Count) overlapping pair(s); $file." + $(if ($loRef.dirty) { '   Not applied yet: click Apply load order.' } else { '' })
        $btnLoApply.BackColor = if ($loRef.dirty) { $T.accent } else { $T.panel2 }; $btnLoApply.ForeColor = if ($loRef.dirty) { $T.accentText } else { $T.text }
        # REDmods
        $rmGrid.Rows.Clear()
        $j = 0; foreach ($f in $loRef.rm) { $rd = @($m.redmods | Where-Object { $_.folder -eq $f })[0]; if (-not $rd) { continue }; $j++; $x = $rmGrid.Rows.Add($j, $rd.name, $rd.version); $rmGrid.Rows[$x].Tag = $f }
        $rmGrid.Visible = ($j -gt 0); $rmEmpty.Visible = ($j -eq 0)
        foreach ($b in @($btnRmUp, $btnRmDown, $btnRmDeploy)) { $b.Visible = ($j -gt 0) }
        $btnRmUp.Enabled = ($j -gt 1); $btnRmDown.Enabled = ($j -gt 1); $btnRmDeploy.Enabled = ($j -gt 0 -and $m.redmodDeploy)
        & $loShowInfo
    }
    $loShowInfo = {
        $m = $loRef.model; if (-not $m -or -not $loGrid.CurrentRow) { $loInfo.Text = ''; return }
        $k = [string]$loGrid.CurrentRow.Tag; $mod = $m.mods[$k]; if (-not $mod) { return }
        $rep = @(Get-ConflictReport $m @($loRef.order))
        $lines = New-Object System.Collections.ArrayList
        [void]$lines.Add("$($mod.name)   (position $($loRef.order.IndexOf($k) + 1) of $($loRef.order.Count))")
        [void]$lines.Add("Archives: " + (@($mod.archives) -join ', '))
        [void]$lines.Add("Game files changed: $($mod.resources)")
        foreach ($c in $rep) {
            if ($c.winner -eq $k) { [void]$lines.Add("  WINS over $($m.mods[$c.loser].name): $($c.count) shared file(s) come from this mod.") }
            elseif ($c.loser -eq $k) { [void]$lines.Add("  LOSES to $($m.mods[$c.winner].name): $($c.count) shared file(s) come from that mod instead. Move this one above it if you want its version.") }
        }
        if (@($rep | Where-Object { $_.winner -eq $k -or $_.loser -eq $k }).Count -eq 0) { [void]$lines.Add('No overlap with other archive mods: its position makes no difference.') }
        $loInfo.Text = $lines -join "`n"
    }
    $loSetModel = {
        param($model)
        $loRef.model = $model; $loRef.cfg = Get-LoadOrderConfig
        $loRef.order.Clear()
        $base = if ($loRef.cfg.applied -and $loRef.cfg.order.Count) { @($loRef.cfg.order | Where-Object { $model.mods.Contains($_) }) } else { @($model.currentOrder) }
        foreach ($k in $base) { [void]$loRef.order.Add($k) }
        foreach ($k in $model.currentOrder) { if (-not $loRef.order.Contains($k)) { [void]$loRef.order.Add($k) } }
        $loRef.rm.Clear()
        foreach ($f in $loRef.cfg.redmodOrder) { if (@($model.redmods | Where-Object { $_.folder -eq $f }).Count) { [void]$loRef.rm.Add($f) } }
        foreach ($rd in @($model.redmods)) { if (-not $loRef.rm.Contains($rd.folder)) { [void]$loRef.rm.Add($rd.folder) } }
        $loRef.dirty = $false
        & $loRender
    }
    $loLoad = {
        if (-not $config.gameDir -or (& $bgRunning 'loadorder')) { return }
        $loStatus.Text = 'Reading your archive mods...'
        $null = & $runBg 'loadorder' { param($gameDir) return (Get-LoadOrderModel $gameDir) } @($config.gameDir) { param($box) if ($box.result) { & $loSetModel $box.result } }
    }
    $loMove = {
        param([int]$to)
        if (-not $loGrid.CurrentRow) { return }
        $from = $loGrid.CurrentRow.Index
        $to = [Math]::Max(0, [Math]::Min($loRef.order.Count - 1, $to))
        if ($to -eq $from) { return }
        $k = $loRef.order[$from]; $loRef.order.RemoveAt($from); $loRef.order.Insert($to, $k)
        $loRef.dirty = $true
        & $loRender
        $loGrid.CurrentCell = $loGrid.Rows[$to].Cells[1]
    }
    $loApply = {
        param([bool]$keepSaved)
        if (& $bgRunning 'loapply') { return }
        $order = if ($keepSaved -or -not $loRef.model) { $null } else { @($loRef.order) }
        $null = & $runBg 'loapply' {
            param($gameDir, $order, $keep)
            $model = Get-LoadOrderModel $gameDir
            $cfg = Get-LoadOrderConfig; $cfg.keepUpdated = $keep
            if (-not $order) {
                $saved = if ($cfg.applied -and $cfg.order.Count) { @($cfg.order | Where-Object { $model.mods.Contains($_) }) } else { @($model.currentOrder) }
                $new = @($model.defaultOrder | Where-Object { $saved -notcontains $_ })
                $order = @(if ($new.Count) { Get-AutoLoadOrder $model (@($saved) + @($new)) $new } else { $saved })
            }
            $changed = Write-ArchiveLoadOrder $gameDir (Get-ModlistLines $model $order) $cfg
            $cfg.order = @($order); $cfg.applied = $true
            Save-LoadOrderConfig $cfg
            $BgUi.Log("Load order saved to archive\pc\mod\modlist.txt ($(@($order).Count) archive mods)." + $(if (-not $changed) { ' It was already up to date.' } else { '' }))
            return (Get-LoadOrderModel $gameDir)
        } @($config.gameDir, $order, $chkLoKeep.Checked) { param($box) if ($box.result) { & $loSetModel $box.result; & $runHealth } }
    }
    $btnLoAuto.Add_Click({
        if (-not $loRef.model) { return }
        $new = @(Get-AutoLoadOrder $loRef.model @($loRef.order))
        $changed = (($new -join "`n") -ne (@($loRef.order) -join "`n"))
        $loRef.order.Clear(); foreach ($k in $new) { [void]$loRef.order.Add($k) }
        if ($changed) { $loRef.dirty = $true; $ui.Log('Load order: auto-sorted the mods that overlap (patches and smaller, more specific mods go above what they change). Click Apply load order to save it.') }
        else { $ui.Log('Load order: already sorted; nothing to change.') }
        & $loRender
    })
    $btnLoApply.Add_Click({ & $loApply $false })
    $btnLoUp.Add_Click({ if ($loGrid.CurrentRow) { & $loMove ($loGrid.CurrentRow.Index - 1) } })
    $btnLoDown.Add_Click({ if ($loGrid.CurrentRow) { & $loMove ($loGrid.CurrentRow.Index + 1) } })
    $btnLoTop.Add_Click({ & $loMove 0 })
    $btnLoBottom.Add_Click({ & $loMove ($loRef.order.Count - 1) })
    $btnLoReload.Add_Click({ $loRef.dirty = $false; & $loLoad })
    $btnLoReset.Add_Click({
        try {
            $renamed = Reset-ArchiveLoadOrder $config.gameDir
            $c = Get-LoadOrderConfig; $c.applied = $false; $c.order = @(); Save-LoadOrderConfig $c
            $ui.Log($(if ($renamed) { "Load order: back to the game's alphabetical order (your modlist.txt was renamed, not deleted)." } else { "Load order: already using the game's alphabetical order." }))
        } catch { $ui.Log('Load order reset failed: ' + $_.Exception.Message) }
        $loRef.dirty = $false; & $loLoad
    })
    $chkLoKeep.Add_CheckedChanged({ $c = Get-LoadOrderConfig; $c.keepUpdated = $chkLoKeep.Checked; Save-LoadOrderConfig $c })
    $loGrid.Add_SelectionChanged({ & $loShowInfo })
    $loGrid.Add_MouseDown({ param($s, $e) $h = $loGrid.HitTest($e.X, $e.Y); $loRef.dragFrom = $h.RowIndex })
    $loGrid.Add_MouseMove({ param($s, $e)
        if ($e.Button -eq [Windows.Forms.MouseButtons]::Left -and $loRef.dragFrom -ge 0) { [void]$loGrid.DoDragDrop([string]$loRef.dragFrom, [Windows.Forms.DragDropEffects]::Move); $loRef.dragFrom = -1 } })
    $loGrid.Add_DragOver({ param($s, $e) $e.Effect = [Windows.Forms.DragDropEffects]::Move })
    $loGrid.Add_DragDrop({ param($s, $e)
        $from = [int]$e.Data.GetData([string]); $pt = $loGrid.PointToClient((New-Object Drawing.Point($e.X, $e.Y)))
        $to = $loGrid.HitTest($pt.X, $pt.Y).RowIndex; if ($to -lt 0) { $to = $loRef.order.Count - 1 }
        if ($from -ge 0 -and $from -lt $loRef.order.Count -and $to -ne $from) { $loGrid.CurrentCell = $loGrid.Rows[$from].Cells[1]; & $loMove $to } })
    $rmMove = { param([int]$d) if (-not $rmGrid.CurrentRow) { return }; $a = $rmGrid.CurrentRow.Index; $b = $a + $d; if ($b -lt 0 -or $b -ge $loRef.rm.Count) { return }
        $k = $loRef.rm[$a]; $loRef.rm.RemoveAt($a); $loRef.rm.Insert($b, $k)
        $c = Get-LoadOrderConfig; $c.redmodOrder = @($loRef.rm); Save-LoadOrderConfig $c
        & $loRender; $rmGrid.CurrentCell = $rmGrid.Rows[$b].Cells[1] }
    $btnRmUp.Add_Click({ & $rmMove -1 }); $btnRmDown.Add_Click({ & $rmMove 1 })
    $btnRmDeploy.Add_Click({
        if (& $bgRunning 'redmod') { return }
        $ui.Log('REDmod: deploying in the background (this recompiles the game scripts and can take a few minutes)...')
        $null = & $runBg 'redmod' { param($gameDir, $folders) return (Invoke-RedmodDeploy $gameDir $folders) } @($config.gameDir, @($loRef.rm)) {
            param($box) if ($box.error) { return }; $ui.Log($(if ($box.result -eq 0) { 'REDmod: deployed. You can start the game.' } else { "REDmod: redMod.exe finished with code $($box.result); check tools\redmod\bin\..\logs." })) }
    })

    # ---------------- status badges ----------------
    $paintPill = {
        param($s, $e, [int]$col)
        if ($e.RowIndex -lt 0 -or $e.ColumnIndex -ne $col) { return }
        $e.PaintBackground($e.ClipBounds, $true)
        $k = [string]$s.Rows[$e.RowIndex].Cells[$col].Tag; if (-not $pill.ContainsKey($k)) { $k = 'none' }
        $r = $e.CellBounds
        $rect = New-Object Drawing.Rectangle(($r.X + 6), ($r.Y + 6), ($r.Width - 12), ($r.Height - 12))
        $br = New-Object Drawing.SolidBrush($pill[$k].back); $e.Graphics.FillRectangle($br, $rect); $br.Dispose()
        [Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$e.Value, $pillFont, $rect, $pill[$k].fore, [Windows.Forms.TextFormatFlags]'HorizontalCenter, VerticalCenter, EndEllipsis, SingleLine')
        $e.Handled = $true
    }
    $grid.Add_CellPainting({ param($s, $e) & $paintPill $s $e $colStatus.Index })
    $updGrid.Add_CellPainting({ param($s, $e) & $paintPill $s $e $colUStatus.Index })
    $grid.Add_CellFormatting({ param($s, $e)
        if ($e.RowIndex -ge 0) {
            $k = [string]$s.Rows[$e.RowIndex].Cells['Status'].Tag
            if ($e.ColumnIndex -ne $colStatus.Index -and ($k -eq 'ok' -or $k -eq 'muted')) { $e.CellStyle.ForeColor = $T.muted }
        } })

    # ---------------- grid events ----------------
    $grid.Add_CurrentCellDirtyStateChanged({ if ($grid.IsCurrentCellDirty) { $grid.CommitEdit([Windows.Forms.DataGridViewDataErrorContexts]::Commit) | Out-Null } })
    $grid.Add_CellValueChanged({ param($s, $e) if ($e.RowIndex -ge 0 -and $e.ColumnIndex -eq 0) { & $updateSummary } })
    $grid.Add_SelectionChanged({ $r0 = $grid.CurrentRow; if ($r0 -and $r0.Tag -and [string]$r0.Tag -ne $detailState.key) { & $showDetails ([string]$r0.Tag) } })
    $grid.Add_DataError({ param($s, $e) $e.ThrowException = $false })
    $updGrid.Add_CurrentCellDirtyStateChanged({ if ($updGrid.IsCurrentCellDirty) { $updGrid.CommitEdit([Windows.Forms.DataGridViewDataErrorContexts]::Commit) | Out-Null } })
    $updGrid.Add_DataError({ param($s, $e) $e.ThrowException = $false })
    $txtSearch.Add_TextChanged({ & $applyFilter })
    $cmbCat.Add_SelectedIndexChanged({ & $applyFilter })
    $cmbSt.Add_SelectedIndexChanged({ & $applyFilter })

    # ---------------- updates header ----------------
    $updateUpdHeader = {
        $gv = Get-GameVersion $config.gameDir
        $last = if ($state.ContainsKey('__lastCheck')) { $state['__lastCheck'].detail } else { 'never' }
        $app = if ($engineRef.AppUpdate) { "App $($script:AppVersion), update to $($engineRef.AppUpdate.version) available" } else { "App $($script:AppVersion) (latest)" }
        $updHeader.Text = "Game version: $(if ($gv) { $gv } else { 'unknown' })      $app      Last checked: $last"
    }

    # ---------------- settings ----------------
    $readSettings = {
        $config.gameDir = $txtGame.Text.Trim(); $config.nexusKey = $k1.Text.Trim(); $config.modioPat = $k2.Text.Trim(); $config.modioApiPath = $k4.Text.Trim(); $config.githubToken = $k3.Text.Trim()
        $config.modioUseGame = $chkUseGame.Checked
        Update-ModioSource $config
    }
    $preflight = {
        & $readSettings
        $w = Get-PreflightWarnings $config
        if ($w.Count -gt 0) { $ui.Banner(($w -join ' '), @()); return $false }
        return $true
    }
    $btnSave.Add_Click({
        & $readSettings; Save-Config $config
        if ($engineRef.E) { $engineRef.E.subscribed = $null }
        if ((Get-ModioTokenKind $config.modioToken) -eq 'oauth2') { $ui.Log('mod.io: you are using an OAuth 2 token. It works for now, but mod.io is moving to Personal Access Tokens; swap it when you can.') }
        $setRes.Text = 'Saved.'; $ui.Log('Settings saved.')
    })
    $btnTest.Add_Click({
        & $readSettings
        $out = @()
        if ($config.nexusKey) {
            try { $v = Invoke-Nexus 'users/validate.json' $config.nexusKey; $out += "Nexus: signed in as $($v.name)" + $(if ($v.is_premium) { ' (Premium)' } else { ' (free account)' }) }
            catch { $out += 'Nexus: key rejected (' + $_.Exception.Message + ')' }
        } else { $out += 'Nexus: no key (optional).' }
        if ($config.modioToken) {
            Set-ModioBase $config.modioApiPath
            try {
                $me = Invoke-Modio Get 'me' $config.modioToken
                $out += $(if ($config.modioSource -eq 'game') { "mod.io: using the game's own sign-in, account '$($me.username)'" + $(if ($config.modioGameLogin.portal) { " (shown in the game as $($config.modioGameLogin.portal))" } else { '' }) + '. Mods subscribed here are the ones the game downloads.' } else { "mod.io: signed in as $($me.username) with your token. This must be the same mod.io account the game uses (see Health check)." })
                if ((Get-ModioTokenKind $config.modioToken) -eq 'oauth2') { $out += 'mod.io: this is an OAuth 2 token, which mod.io is phasing out. Create a Personal Access Token on mod.io/me/access when you can.' }
            } catch {
                $code = Get-HttpStatus $_
                $out += if ($code -eq 401) { 'mod.io: token rejected. It may have expired or been revoked; create a new Personal Access Token on mod.io/me/access.' } else { 'mod.io: could not connect (' + $_.Exception.Message + ').' }
            }
        } else { $out += "mod.io: no sign-in. Start the game once and open Mods on the main menu so it signs in to mod.io, or add a token." }
        try { $info = Test-AppUpdate $config.githubToken; $out += if ($info) { "GitHub: connected, app update $($info.version) available" } else { 'GitHub: connected, the app is up to date' } } catch { $out += 'GitHub: ' + $_.Exception.Message }
        $setRes.Text = ($out -join [Environment]::NewLine)
    })
    $btnBrowse.Add_Click({
        $fb = New-Object Windows.Forms.FolderBrowserDialog; $fb.Description = 'Select your Cyberpunk 2077 folder'
        if ($txtGame.Text -and (Test-Path -LiteralPath $txtGame.Text)) { $fb.SelectedPath = $txtGame.Text }
        if ($fb.ShowDialog($form) -eq 'OK') { $txtGame.Text = $fb.SelectedPath; & $readSettings; Save-Config $config; [void](& $preflight) }
    })
    $btnShortcut.Add_Click({ try { $p = New-DesktopShortcut $script:Root; $setRes.Text = "Shortcut created: $p"; $ui.Log("Desktop shortcut created: $p") } catch { $setRes.Text = 'Could not create the shortcut: ' + $_.Exception.Message } })
    $chkPause.Add_CheckedChanged({ $config.pauseBetweenBatches = $chkPause.Checked; Save-Config $config })
    $chkAuto.Add_CheckedChanged({ $config.checkOnStart = $chkAuto.Checked; Save-Config $config })
    $chkDisc.Add_CheckedChanged({ $config.discoverOnStart = $chkDisc.Checked; Save-Config $config })
    $chkAutoFix.Add_CheckedChanged({ $config.autoFix = $chkAutoFix.Checked; Save-Config $config })

    # ---------------- app update ----------------
    $doAppUpdate = {
        # The update is already downloaded and checked; closing swaps it in, then the app reopens.
        if (& $engineBusy) { $ui.Banner('Finish or pause the current install first; the update installs itself when the app closes.', @()); return }
        if (Get-PendingAppUpdate) { $engineRef.restartAfterClose = $true; $form.Close() }
        else { & $checkApp $false }
    }
    $checkApp = {
        param([bool]$Quiet)
        if (& $bgRunning 'appupdate') { return }
        $engineRef.appQuiet = $Quiet
        $null = & $runBg 'appupdate' {
            param($token)
            $info = Test-AppUpdate $token
            if (-not $info) { return $null }
            $p = Get-PendingAppUpdate
            if (-not $p -or [string]$p.version -ne [string]$info.version) { $null = Save-AppUpdate $info $token }
            return $info
        } @($config.githubToken) {
            param($box)
            if ($box.error) { $ui.Log('App update check skipped: ' + $box.error) }
            elseif ($box.result) {
                $info = $box.result; $engineRef.AppUpdate = $info
                $btnAppUpd.Text = "Restart to finish updating to $($info.version)"; $btnAppUpd.Visible = $true
                $ui.Log("App update $($info.version) downloaded and checked in the background. It installs itself when you close the app. ($($info.notes))")
            } elseif (-not $engineRef.appQuiet) { $ui.Log("The app is up to date ($($script:AppVersion)).") }
            & $updateUpdHeader
        }
    }

    # ---------------- timers ----------------
    $timer = New-Object Windows.Forms.Timer; $timer.Interval = 1500
    $script:Busy = $false
    $timer.Add_Tick({
        if ($script:Busy -or -not $engineRef.E) { return }
        $script:Busy = $true
        try {
            Step-Engine $engineRef.E
            if ($engineRef.E.mode -in @('done', 'paused')) {
                $btnStart.Enabled = $true; $btnPause.Enabled = $false; $btnStart.Text = [string][char]0x25B6 + '  Start install'; $btnUpdate.Enabled = $true
                if ($engineRef.E.mode -eq 'done') { $timer.Stop(); & $refreshInstalled; & $runHealth }
            }
        } catch { $ui.Log('Error: ' + $_.Exception.Message) }
        finally { $script:Busy = $false }
    })
    $chkTimer = New-Object Windows.Forms.Timer; $chkTimer.Interval = 250
    $script:CheckBusy = $false
    $chkTimer.Add_Tick({
        if ($script:CheckBusy -or -not $engineRef.C) { return }
        $script:CheckBusy = $true
        try { Step-UpdateCheck $engineRef.C; if ($engineRef.C.done) { $chkTimer.Stop() } }
        catch { $ui.Log('Update check error: ' + $_.Exception.Message); $chkTimer.Stop(); $btnCheck.Enabled = $true }
        finally { $script:CheckBusy = $false }
    })
    $discTimer = New-Object Windows.Forms.Timer; $discTimer.Interval = 300
    $script:DiscBusy = $false
    $discTimer.Add_Tick({
        if ($script:DiscBusy -or -not $engineRef.D) { return }
        $script:DiscBusy = $true
        try { Step-Discovery $engineRef.D; if ($engineRef.D.done) { $discTimer.Stop() } }
        catch { $ui.Log('Discovery error: ' + $_.Exception.Message); $discTimer.Stop() }
        finally { $script:DiscBusy = $false }
    })
    $startCheck = {
        if (-not (& $preflight)) { return }
        if (& $bgRunning 'updates') { return }
        $updGrid.Rows.Clear()
        foreach ($k in @($rows.Keys | Where-Object { $_ -like 'upd*' -or $_ -like 'update:*' })) { $rows.Remove($k) }
        $btnCheck.Enabled = $false; $btnUpdate.Enabled = $false
        $engineRef.CShared = [hashtable]::Synchronized(@{ C = $null })
        $ui.Log('Checking for mod updates in the background...')
        $null = & $runBg 'updates' {
            param($cfg, $st, $shared)
            $C = New-UpdateChecker $cfg $st $BgUi
            $shared.C = $C
            Start-UpdateCheck $C
            $g = 0; while (-not $C.done -and $g -lt 5000) { $g++; Step-UpdateCheck $C }
            return $true
        } @($config, $state, $engineRef.CShared) { param($box) $btnCheck.Enabled = $true }
        & $checkApp $true
    }
    $startDiscovery = {
        if (-not $config.gameDir -or -not (Test-Path -LiteralPath $config.gameDir)) { return }
        if (-not $config.nexusKey -and -not $config.modioToken) { $ui.Log('Discovery skipped: add a Nexus key or mod.io token in Settings.'); return }
        if (& $bgRunning 'discovery') { return }
        $mcopy = [pscustomobject]@{ game = $manifest.game; patchDate = $manifest.patchDate; items = [System.Collections.ArrayList]@($manifest.items) }
        $ui.Log('Looking for more mods that work with this game version (in the background)...')
        $null = & $runBg 'discovery' {
            param($m, $cfg)
            $D = New-Discovery $m $cfg (Read-DiscoveryStore) (Get-InstalledNexusIds $cfg.gameDir) $BgUi
            $g = 0; while (-not $D.done -and $D.phase -ne 'finish' -and $g -lt 5000) { $g++; Step-Discovery $D }
            return $D
        } @($mcopy, $config) {
            param($box)
            $D = $box.result
            if ($D -and -not $D.done) { $D.ui = $ui; $D.manifest = $manifest; $D.installed = Get-InstalledNexusIds $config.gameDir; Step-Discovery $D }
        }
    }

    # ---------------- buttons ----------------
    $btnStart.Add_Click({
        if (-not (& $preflight)) { & $showPage 'Settings'; return }
        Save-Config $config
        $checked = @($grid.Rows | Where-Object { $_.Cells['Q'].Value -eq $true } | ForEach-Object { [string]$_.Tag })
        if ($engineRef.E -and $engineRef.E.mode -eq 'paused' -and $engineRef.E.pos -lt $engineRef.E.queue.Count -and $engineRef.E.purpose -eq 'install') {
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
        if ($engineRef.E) { if ($engineRef.E.current -and $engineRef.E.mode -eq 'waitNexus') { $engineRef.E.current = $null }; $engineRef.E.mode = 'paused' }
        $ui.Banner('Paused. Click Start install to carry on from where you stopped.', @())
        $btnStart.Text = [string][char]0x25B6 + '  Continue'; $btnStart.Enabled = $true; $btnPause.Enabled = $false
    })
    $btnRefresh.Add_Click({ if (& $preflight) { & $refreshInstalled } })
    $btnAll.Add_Click({ foreach ($row in $grid.Rows) { if (-not $locked.Contains([string]$row.Tag) -and $row.Visible) { $row.Cells['Q'].Value = $true } }; & $updateSummary })
    $btnNone.Add_Click({ foreach ($row in $grid.Rows) { if ($row.Visible) { $row.Cells['Q'].Value = $false } }; & $updateSummary })
    $btnReset.Add_Click({
        $a = [Windows.Forms.MessageBox]::Show('Clear all saved install progress? Mods already installed stay installed and are detected again.', 'Night City Installer', 'YesNo', 'Question')
        if ($a -eq 'Yes') {
            foreach ($k in @($state.Keys | Where-Object { $_ -notlike '__*' })) { $state.Remove($k) }
            Save-State $state
            foreach ($it in $manifest.items) { $e0 = $rows[$it.key]; if ($e0) { & $setLock $e0.row $false; & $setStatusCell $e0.row ''; $e0.row.Cells['Info'].Value = [string]$it.note; $e0.row.Cells['Q'].Value = -not $it.optional } }
            $ui.Log('Install progress cleared.'); & $refreshInstalled
        }
    })
    $btnCheck.Add_Click({ & $startCheck })
    $btnAppUpd.Add_Click({ & $doAppUpdate })
    $btnUpdate.Add_Click({
        if (& $engineBusy) { $ui.Banner('Finish or pause the current install first.', @()); return }
        if (-not (& $preflight)) { return }
        $picked = @($updGrid.Rows | Where-Object { $_.Cells['Q'].Value -eq $true -and $_.Tag -and $_.Tag.update } | ForEach-Object { $_.Tag } | Sort-Object { Get-UpdateSortKey $_.id $_.name })
        if ($picked.Count -eq 0) { $ui.Banner('Tick the mods you want to update first.', @()); return }
        $engineRef.E = New-Engine $manifest $config $state $ui
        Start-UpdateEngine $engineRef.E $picked
        $btnUpdate.Enabled = $false; $btnStart.Enabled = $false; $btnPause.Enabled = $true
        $timer.Start()
    })
    $btnPlay.Add_Click({
        if (-not (& $preflight)) { & $showPage 'Settings'; return }
        try { if ($config.autoFix -and (Repair-EmptyModdedCache $config.gameDir)) { $ui.Log('Health: renamed an empty r6\cache\modded folder before launch (it would crash the game).') } } catch {}
        # Log-based errors describe the LAST launch; launching again is how they clear, so they don't block Play.
        $issues = @(Get-HealthIssues $config.gameDir | Where-Object { $_.level -eq 'error' -and $_.id -notin @('scc-failed', 'redscript-errors') })
        if ($issues.Count -gt 0) { $ui.Banner('The health check found a problem that can stop the game from starting.', @('Open Health check')); return }
        $ui.Log('Launching Cyberpunk 2077...')
        try { Start-Process 'steam://rungameid/1091500' } catch { Start-Process (Join-Path $config.gameDir 'bin\x64\Cyberpunk2077.exe') }
    })

    # ---------------- startup ----------------
    Write-Trace 'window built'
    & $showPage 'Mods'
    & $updateSummary
    & $updateUpdHeader
    foreach ($n in $startupNotes) { $ui.Log($n) }
    $ui.Log("Night City Installer $($script:AppVersion). $($manifest.items.Count) mods in the list. Progress is saved in $($script:DataDir).")
    $shownRef = @{ done = $false }
    $form.Add_Shown({
        Write-Trace 'shown'
        $shownRef.done = $true
        try { $splash.form.Close() } catch {}
        $split.SplitterDistance = [Math]::Max(500, $split.Width - 430)
        if (-not $config.shortcutDone) {
            try { $p = New-DesktopShortcut $script:Root; $ui.Log("Desktop shortcut created: $p") } catch {}
            $config.shortcutDone = $true; Save-Config $config
        }
        if (& $preflight) {
            $gv = Get-GameVersion $config.gameDir
            $prev = if ($state.ContainsKey('__gameVersion')) { $state['__gameVersion'].detail } else { '' }
            if ($gv -and $prev -and $gv -ne $prev) {
                $ui.Banner("Cyberpunk 2077 was updated from $prev to $gv. Script mods often stop working after a game patch until their frameworks are updated. Check the Updates page and install framework updates first.", @())
                $ui.Log("Game version changed: $prev -> $gv")
            } elseif (-not $config.modioToken -and -not $config.nexusKey) {
                $ui.Banner('First run: open Settings and add your mod.io token and Nexus key, then click Start install.', @())
            }
            if ($gv) { $state['__gameVersion'] = @{ status = ''; detail = $gv; done = $false }; Save-State $state }
            & $refreshInstalled
            & $runHealth {
                param($issues)
                if (@($issues | Where-Object { $_.level -eq 'error' -and $_.id -notin @('scc-failed', 'redscript-errors') -and $_.id -notlike 'modio-*' -and $_.id -notlike 'req*' }).Count -gt 0) { $ui.Banner('The health check found a problem that can stop the game from starting.', @('Open Health check')) }
                elseif (@($issues | Where-Object { $_.id -like 'modio-*' -and $_.level -eq 'error' }).Count -gt 0) { $ui.Banner('mod.io mods: ' + @($issues | Where-Object { $_.id -like 'modio-*' -and $_.level -eq 'error' })[0].title + '. See Health check.', @('Open Health check')) }
                elseif (@($issues | Where-Object { $_.id -like 'req:*' }).Count -gt 0) { $ui.Banner("Some of your mods are missing a requirement (Vortex-style check). See Health check.", @('Open Health check')) }
                elseif (@($issues | Where-Object { $_.id -eq 'scc-failed' }).Count -gt 0) { $ui.Banner('Your last game launch failed to compile mod scripts. If the Health check shows nothing else to fix, press Play to try again.', @('Open Health check')) }
                if ($config.modioSource -eq 'game' -and $modioRef.subs -eq 0) { $gl = $config.modioGameLogin; $ui.Banner("mod.io mods now go to the game's own mod.io account" + $(if ($gl.portal) { " ($($gl.portal))" } else { '' }) + '. Click Start install to subscribe them there (no clicks in the browser needed), then open Mods in the game.', @()) }
            }
            if ($config.modioSource -eq 'game') { $gl = $config.modioGameLogin; $ui.Log("mod.io: using the game's own sign-in '$($gl.username)'" + $(if ($gl.portal) { " (shown in the game as $($gl.portal))" } else { '' }) + '.') }
            if ($config.checkOnStart) { & $startCheck }
            if ($config.discoverOnStart) { & $startDiscovery }
            if ($grid.Rows.Count -gt 0) { $grid.Rows[0].Selected = $true; & $showDetails ([string]$grid.Rows[0].Tag) }
        }
    })
    # Safety net: if Windows started this process hidden and the main window never appears,
    # show it after a few seconds and drop the splash anyway.
    $showGuard = New-Object Windows.Forms.Timer; $showGuard.Interval = 4000
    $showGuard.Add_Tick({
        $showGuard.Stop()
        if (-not $shownRef.done -or -not $form.Visible) {
            Write-Trace 'show guard: forcing the main window visible'
            try { $splash.form.Close() } catch {}
            $form.Visible = $true; $form.WindowState = 'Maximized'; $form.Activate()
        }
    })
    $showGuard.Start()
    Write-Trace 'showing dialog'
    # Application.Run, not ShowDialog: a modal dialog would take the splash as its owner and
    # close together with it.
    [Windows.Forms.Application]::Run($form)
    Write-Trace 'main window closed'
    $timer.Stop(); $chkTimer.Stop(); $discTimer.Stop(); $detailTimer.Stop(); $bgTimer.Stop()
    Stop-BgRunner $bgRef.runner
    try {
        $v = Install-StagedAppUpdate
        if ($v) { try { Add-Content -LiteralPath $script:LogFile -Value ((Get-Date -Format 'HH:mm:ss') + "  App updated to $v.") } catch {} }
        if ($v -and $engineRef.restartAfterClose) { Start-AppFresh }
    } catch { try { Add-Content -LiteralPath $script:LogFile -Value ((Get-Date -Format 'HH:mm:ss') + '  App update not installed: ' + $_.Exception.Message) } catch {} }
}

if (-not $TestMode) {
    try { if (Get-PendingAppUpdate) { $v = Install-StagedAppUpdate; if ($v) { Start-AppFresh; return } } } catch {}
    Write-Trace 'calling Start-App'
    try { Start-App; Write-Trace 'Start-App returned' }
    catch {
        $where = "line $($_.InvocationInfo.ScriptLineNumber): $(([string]$_.InvocationInfo.Line).Trim())"
        Write-Trace ("STARTUP ERROR: " + $_.Exception.ToString() + " AT " + $where)
        try { Ensure-DataDir; Add-Content -LiteralPath (Join-Path $script:DataDir 'log.txt') -Value ('Startup error: ' + $_.Exception.Message + ' at ' + $where) } catch {}
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show("Night City Installer couldn't start: $($_.Exception.Message)`n`nAt $where", 'Night City Installer', 'OK', 'Error')
    }
}
