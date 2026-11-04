NIGHT CITY INSTALLER 1.1
Installs the "Night City Load Order" mod list for Cyberpunk 2077 patch 2.5, in order.

START
  Double-click "Start Night City Installer.bat".

FIRST RUN (one time, about 3 minutes)
  1. Click "Accounts...".
  2. mod.io token (needed for the 41 mod.io mods):
     Sign in at mod.io with the SAME account you linked in the game's Mods menu.
     Open https://mod.io/me/access, create an OAuth 2 client, then create a token with
     Read and Write access. Paste it into the app.
  3. Nexus API key (optional, recommended):
     https://next.nexusmods.com/settings/api-keys  ->  "Personal API Key".
     With it, the app opens the exact 2.5 file for each mod and skips any mod whose newest
     file is older than the patch. Without it, it opens the mod's Files tab and you pick
     the newest main file yourself.
  4. Click Test, then Save.

IN VORTEX (check once)
  Settings > Downloads: "Handle Nexus links" on.
  Settings > Interface/Downloads: install and enable mods automatically after download (default).
  Settings > Mods: "Deploy mods when enabled" on (default).

INSTALLING
  Click Start.
  - mod.io mods: fully automatic. The app subscribes your account to each mod and anything it
    requires. The game downloads them the next time you open the main menu (Mods tab).
  - Nexus mods: your browser opens each mod's download page. Click "Slow download".
    Vortex downloads and installs it; the app notices and opens the next one by itself.
    Nexus requires this one click per file on free accounts. It can't be skipped.
  When it finishes, start the game once so it downloads the mod.io mods.

UPDATES (Updates tab)
  Mods:
  - "Check for updates" looks at every Nexus mod Vortex has installed (including the ones you
    had before this app) and compares your version with the newest main file on Nexus.
    Needs your Nexus key. Frameworks (RED4ext, CET, redscript, ArchiveXL, TweakXL, Codeware,
    Input Loader, Mod Settings, Native Settings UI) are listed and updated first.
  - "Update ticked" opens each new file's page in order. Click "Slow download"; Vortex installs
    the new version (it may ask whether to replace the old one: choose Replace). The app
    waits until the newer version is in Vortex, then moves on.
  - mod.io mods are updated by the game itself. The list shows which ones changed since your
    last check.
  - Mods you installed by hand (not through Vortex) can't be checked.
  - When the game itself updates (e.g. 2.5 to 2.51), the app warns you on start-up: script mods
    often break until their frameworks are updated, so update frameworks first.
  App:
  - The app checks the public repo github.com/Sirtacoburrito/NightCityInstaller for new versions
    (which can also bring an updated mod list). No token needed.
  - "Update app" downloads the new files, checks each file's SHA-256 fingerprint, keeps a backup
    of the old version in %LOCALAPPDATA%\NightCityInstaller\backup-<version>, then restarts.
  - "Check for updates when the app opens" runs both checks on start-up (on by default).

OPTIONS
  - Untick any mod you don't want before clicking Start. The character-looks mods
    (House of Vesna hair and makeup, E3 textures) are unticked by default.
  - "Pause after each batch so I can test the game" stops after each group so you can launch the
    game and check it before carrying on. Off by default; turn it on for the safest install.
  - Pause / Continue at any time. Progress is saved; closing the app and reopening it resumes.
  - Already-installed mods are detected and skipped.

WHAT IT DOES AND DOESN'T TOUCH
  - It never writes to your game folder. Vortex installs every Nexus mod, so you can disable or
    remove any of them in Vortex as usual. It only reads vortex.deployment.json and Vortex's
    staging folder to see what's installed.
  - Keys are stored encrypted for your Windows user (DPAPI) in
    %LOCALAPPDATA%\NightCityInstaller, and are sent only to api.nexusmods.com and api.mod.io.
  - Log file: %LOCALAPPDATA%\NightCityInstaller\log.txt

IF SOMETHING GOES WRONG
  - "Still waiting" for a Nexus mod: click "Open page again", or "It's installed" if Vortex
    already has it.
  - A mod.io mod shows "Not found": it was removed from the catalog. Nothing to do.
  - Game won't start: disable the most recently installed batch in Vortex and check
    red4ext\logs and r6\logs\redscript_rCURRENT.log in the game folder.
