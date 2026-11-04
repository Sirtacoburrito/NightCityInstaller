# Builds version.json for a release: version, notes and the SHA-256 of every app file.
# Usage: pwsh tools/make-version.ps1 -Version 1.2.0 -Notes "What changed"
param([Parameter(Mandatory)][string]$Version, [string]$Notes = '')
$root = Split-Path -Parent $PSScriptRoot
$files = 'NightCityInstaller.ps1', 'manifest.json', 'README.txt', 'Start Night City Installer.bat', 'NightCityInstaller.ico', 'NightCityInstaller.png'
$ps1 = Get-Content (Join-Path $root 'NightCityInstaller.ps1') -Raw
if ($ps1 -notmatch "AppVersion = '$([regex]::Escape($Version))'") { throw "Set `$script:AppVersion = '$Version' in NightCityInstaller.ps1 first." }
$list = foreach ($f in $files) { [ordered]@{ path = $f; sha256 = (Get-FileHash (Join-Path $root $f) -Algorithm SHA256).Hash } }
[ordered]@{ version = $Version; notes = $Notes; files = @($list) } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $root 'version.json') -Encoding ascii
Write-Host "version.json written for $Version"
