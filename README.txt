NIGHT CITY INSTALLER 1.2
Installs the "Night City Load Order" mod list for Cyberpunk 2077 patch 2.5, in order.

START
  Double-click "Start Night City Installer.bat".

FIRST RUN (one time, about 3 minutes)
  1. Click "Accounts...".
  2. mod.io token (needed for the 41 mod.io mods in the list of 113):
     Sign in at mod.io with the SAME account you linked in the game's Mods menu.
     Open https://mod.io/me/access, create an OAuth 2 client, then create a token with
     Read and Write access. Paste it into the app.
  3. Nexus API key (strongly recommended; required for about 40 of the newer mods):
     https://next.nexusmods.com/settings/api-keys  ->  "Personal API Key".
     With it, the app opens the exact 2.5 file for each mod and skips any mod whose newest
     file is older than the patch. Without it, it opens the mod's Files tab and you pick
     the newest main file yourself.
  4. Click Test, then Save.

IN VORTEX (check once)
  Settings > Downloads: "Handle Nexus links" on.
  Settings > Interface/Downloads: install and enable mods automatically after download (default).
  Settings > Mods: "Deploy mods when enabled" on (default).

WHAT'S ALREADY INSTALLED
  Every time the app opens (and after each install run) it checks Vortex and your mod.io
  subscriptions. Rows that are already in place turn GREEN with a check mark and are unticked,
  so nothing is downloaded twice. The bar above the list counts installed, ticked and waiting
  mods. Click "Refresh installed" after changing mods in Vortex.
    Green  + check mark : installed / subscribed / up to date, nothing to do
    Yellow              : waiting for a 2.5 file from the author, or needs your Nexus key
    Blue                : waiting for your "Slow download" click
    Red                 : failed or not found
    White               : will be installed when ticked
  On the Updates tab, green rows are up to date and orange rows (with an arrow) have an update.

HOW THE LIST STAYS 2.5-SAFE
  - Mods confirmed for 2.5 by their authors install normally.
  - Newer mods without a published 2.5 note are checked on Nexus first: the app installs them
    only if their newest main file was uploaded after the 2.5 patch (22 Oct 2026). This needs
    your Nexus key; without it they show "Needs Nexus key" and are left alone.
  - Any mod whose newest file is older than the patch shows "Waiting for 2.5 update" and is
    retried on every run, so it installs by itself once the author updates it. The last
    group, "Waiting for 2.5 updates", holds popular mods like Appearance Menu Mod for this.
  - Mods that clash with your setup are not in the list: HUD replacements (you use a custom HUD
    layout), "no dismemberment" (you use Relentless Live Dismember), other dual-wield mods
    (you use Expanded Dual Wielding) and wardrobe UI replacements (Equipment-EX).

OPTIONAL GROUPS (unticked by default)
  Big overhauls, character looks and voice, romance, and Adult 18+ (spawn0 body mod and its
  2.5 fix). Tick what you want. Adult mods on Nexus only show for accounts with adult content
  turned on (nexusmods.com > Settings > Content blocking).

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
