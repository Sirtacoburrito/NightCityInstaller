NIGHT CITY INSTALLER 1.5
Installs the "Night City Load Order" mod list for Cyberpunk 2077 patch 2.5, in order.

START
  Double-click "Start Night City Installer.bat" (or the "Night City Installer" desktop shortcut
  the app creates on first run).

THE WINDOW (laid out like Vortex)
  Left sidebar: Mods, Load Order, Updates, Health check, Settings, Log, and a big Play button.
  The window opens straight away. Checking what's installed, the health check, update checks,
  looking for new mods and loading mod pages and photos all run in the background; the status
  bar shows what is still working.
  Mods: every mod in the list with a status pill, version, category and source. Click any row
  to see its description, photos from the mod page, its requirements (marked [installed] or
  [MISSING]) and the author's install notes. "All photos" and "Open mod page" open the page.
  Filter by name, category or status above the list.
  Play: fixes known crash causes first (see Health check), then starts the game through Steam.

FIRST RUN (one time, about 3 minutes)
  1. Open Settings in the sidebar.
  2. mod.io: nothing to do if you have opened Mods in the game once. The game signs in to
     mod.io through your CD PROJEKT RED account, and that is its OWN mod.io account (it may show
     your CDPR name, e.g. Name#1234, but it is not the account you use on the mod.io website).
     The game only downloads mods subscribed on that account, so the app uses the game's own
     sign-in from this PC ("Use the game's own mod.io sign-in" in Settings, on by default).
     A token is only a fallback for when the game hasn't signed in yet:
     mod.io is replacing OAuth 2 access tokens with Personal Access Tokens. The app accepts
     either in the same box, and tells you when you're still on an OAuth 2 token.
     Sign in at https://mod.io/me/access with the SAME account you linked in the game's Mods
     menu, create a Personal Access Token with read and write access, and paste it in.
     If that page shows a personal API path (like https://u-12345.modapi.io/v1), paste it in
     the "mod.io API path" box too; otherwise leave that box empty.
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

NEW MODS FOUND AUTOMATICALLY
  Each time the app opens it looks for more mods that work with your game version and adds them
  at the bottom of the list (turn this off in Settings):
  - mod.io: every mod in the official catalog that isn't in the list yet. CD PROJEKT RED approves
    these for the current patch, so they are ticked (mature ones unticked).
  - Nexus (needs your Nexus key): mods with a file uploaded since the patch, at least 10
    endorsements or 1,000 downloads, and nothing that clashes with your setup (HUD, dismemberment,
    dual-wield, wardrobe, flashlight, translations, AMM add-ons, older-version builds, modder
    resources). They are unticked: open each one's page and check its requirements first. Adult
    finds go in their own group.
  Finds are remembered in %LOCALAPPDATA%\NightCityInstaller\discovered.json.

WHAT'S ALREADY INSTALLED
  Every time the app opens (and after each install run) it checks Vortex and your mod.io
  subscriptions. Rows that are already in place turn GREEN with a check mark and are LOCKED:
  they can't be ticked, so nothing is downloaded twice. When the update check finds a newer
  file for one of them, the row turns ORANGE with an arrow, unlocks and is ticked; Start then
  installs the update. (mod.io rows stay locked because the game updates those itself.) The bar above the list counts installed, ticked and waiting
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
  - Updates are silent: a new version is downloaded in the background and each file's SHA-256
    fingerprint is checked, then it is swapped in when you close the app (the old version is
    kept in %LOCALAPPDATA%\NightCityInstaller\backup-<version>). "Restart to finish updating"
    on the Updates page applies it right away.
  - Mod update checks also run in the background; the Updates page and the orange rows on the
    Mods page show what has an update. Nexus still needs your "Slow download" click per file.
  - "Check for updates when the app opens" runs both checks on start-up (on by default).

OPTIONS
  - Untick any mod you don't want before clicking Start. The character-looks mods
    (House of Vesna hair and makeup, E3 textures) are unticked by default.
  - "Pause after each batch so I can test the game" stops after each group so you can launch the
    game and check it before carrying on. Off by default; turn it on for the safest install.
  - Pause / Continue at any time. Progress is saved; closing the app and reopening it resumes.
  - Already-installed mods are detected and skipped.

WHAT IT DOES AND DOESN'T TOUCH
  - Vortex installs every Nexus mod, so you can disable or remove them in Vortex as usual.
    The app only writes to the game folder for manual installs (new files only, all recorded)
    and to rename an empty r6\cache\modded folder. It never deletes your files.
  - Keys are stored encrypted for your Windows user (DPAPI) in
    %LOCALAPPDATA%\NightCityInstaller, and are sent only to api.nexusmods.com and api.mod.io.
  - Log file: %LOCALAPPDATA%\NightCityInstaller\log.txt

HEALTH CHECK (sidebar)
  Runs in the background on start-up (Play does a quick local check first). It looks for:
  - Missing requirements, the same way Vortex's Health Check does: for every mod Vortex has
    deployed it asks Nexus for that mod's listed requirements and reports any that aren't
    installed ("Download" opens its page), installed but disabled in Vortex, or DLC it needs.
    Frameworks installed by hand (CET, RED4ext, redscript, ArchiveXL, TweakXL, Codeware...) count.
    Results are cached for 12 hours.
  - Load order problems: a modlist.txt that is missing new archives, archives that overwrite
    each other, and damaged archive files.
  - An empty r6\cache\modded folder. This makes the game crash on start ("Failed to load the
    original script cache"). Fix renames it to _modded_empty_<time>; nothing is deleted.
  - A replaced or missing r6\cache\final.redscripts (the game's own script cache, about 20 MB).
    If something overwrites it, every launch fails with "Failed to load the original script
    cache". Fix asks Steam to verify the game files, which restores it and keeps your mods.
  - Script compile errors from the last launch (redscript / RED4ext logs).
  - Files Vortex couldn't place (V2077\mod-extra-files). Fix installs them by hand, see below.
  - Mods that need the REDmod DLC.
  - mod.io account link: the game signs in to mod.io through its own account link (Mods menu on
    the main menu). It only downloads mods subscribed on THAT mod.io account. The check compares
    the game's mod.io sign-in on this PC with the account of your token, and tells you if they
    differ or if the game hasn't downloaded anything yet. Details are written to modio-check.txt
    in the app folder (user names only, never tokens).

LOAD ORDER (sidebar)
  Cyberpunk loads archive mods (archive\pc\mod\*.archive) top to bottom, alphabetically unless
  archive\pc\mod\modlist.txt lists them, and the FIRST archive that contains a game file wins.
  The Load Order page lists your archive mods per mod (grouped the way Vortex installed them),
  reads each archive's file list to show which mods really overwrite each other and who wins,
  and lets you drag mods or use Up/Down/To top/To bottom.
  - Auto-sort only moves mods that overlap: a patch or fix for another mod goes above it, and a
    small, specific mod goes above a big overhaul it overlaps. Everything else keeps its place.
  - Apply load order writes modlist.txt (like Mod Organizer 2). Vortex doesn't touch that file.
    A modlist.txt the app didn't write is kept as modlist.txt.backup-<time>.
  - Keep it up to date automatically: new mods you install later are placed by the same rules
    and the file is rewritten silently.
  - Game default renames modlist.txt (never deletes it) to go back to alphabetical order.
  - REDmods (folders in \mods) always load after archive mods. Like Vortex, the page orders
    them and deploys them with redMod.exe (needs the free REDmod DLC).

REQUIREMENTS AND MANUAL INSTALLS
  - Before each Nexus mod, the app reads its "Requirements" section and queues any missing
    requirement first. If a requirement can't be installed, the mod waits ("Needs ...").
  - After each install it checks whether Vortex left files it couldn't place. If so it copies them
    into the standard Cyberpunk folders (archive\pc\mod, r6\scripts, r6\tweaks, bin\x64\plugins
    \cyber_engine_tweaks\mods, red4ext\plugins), never overwriting anything, and records each file in
    %LOCALAPPDATA%\NightCityInstaller\manual-installs.json so it can be removed later.

IF SOMETHING GOES WRONG
  - "Still waiting" for a Nexus mod: click "Open page again", or "It's installed" if Vortex
    already has it.
  - A mod.io mod shows "Not found": it was removed from the catalog. Nothing to do.
  - Game won't start: disable the most recently installed batch in Vortex and check
    red4ext\logs and r6\logs\redscript_rCURRENT.log in the game folder.
