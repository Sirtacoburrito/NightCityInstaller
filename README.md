# Night City Installer

A Windows app that installs a stability-checked mod list for **Cyberpunk 2077 patch 2.5**, in order, and keeps it up to date.

- **Nexus mods** install through **Vortex**: the app opens each file's page, you click *Slow download* (Nexus requires that click on free accounts), Vortex installs it, and the app moves on by itself.
- **mod.io mods** (the official in-game mod catalog) are subscribed through the mod.io API with their requirements. The game downloads them from its Mods menu.
- **Updates tab**: checks every Vortex-installed Nexus mod and your mod.io subscriptions for newer versions (frameworks first), warns when the game itself is patched, and updates the app from this repo after verifying each file's SHA-256.

## Use

1. Download this repo (Code > Download ZIP) and extract it anywhere.
2. Double-click `Start Night City Installer.bat`.
3. Click **Accounts...** and add a mod.io access token (and, ideally, a Nexus personal API key). Then click **Start**.

See [README.txt](README.txt) for details. Requires Windows PowerShell 5.1 (built into Windows 10/11) and Vortex.

Keys are stored encrypted for your Windows user (DPAPI) in `%LOCALAPPDATA%\NightCityInstaller` and are sent only to api.nexusmods.com and api.mod.io.

## Releasing a new version

1. Bump `$script:AppVersion` in `NightCityInstaller.ps1`.
2. `pwsh tools/make-version.ps1 -Version X.Y.Z -Notes "What changed"`
3. Commit and push to `main`. Installed copies offer the update on their next start.
