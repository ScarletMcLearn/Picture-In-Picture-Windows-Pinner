# PiP Window Pinner (Windows 11)

Small AutoHotkey v2 utility. Detects high-confidence browser PiP windows, then calls only VirtualDesktopAccessor's per-window `IsPinnedWindow` / `PinWindow` APIs. It never calls `PinApp`; normal browser windows cannot be app-pinned.

## Compatibility and safety

- Requires 64-bit AutoHotkey v2, Windows 11, x64, and Ciantic's MIT-licensed `VirtualDesktopAccessor.dll`.
- Project uses official VDA release `2024-12-16-windows11`: upstream says minimum Windows 11 24H2 build `26100.2605`; upstream reports testing through build `26200.8117`.
- This machine is `26300.9711`. That build has no upstream compatibility statement. Installer and utility refuse it by default. There is no supported public Windows API for pinning one arbitrary window on every virtual desktop, so no safe alternative is substituted.
- Installer retrieves only the named official GitHub release asset and verifies its pinned SHA-256 (`8740C572A1C000E3B87FFEB1E4C397EAE9AF3BD4A2ABDC3BCFFACAB4493F8FF5`) before loading it. It can install AutoHotkey only with explicit `-InstallAutoHotkey`.

## Install

1. Install 64-bit [AutoHotkey v2](https://www.autohotkey.com/), or let setup install its official winget package with `-InstallAutoHotkey`.
2. Open PowerShell in this folder.
3. On documented/tested builds:

   ```powershell
   .\Install.ps1
   ```

4. On build 26300 only after you have manually validated the upstream DLL in a disposable session:

   ```powershell
   .\Install.ps1 -AllowUnverifiedOsBuild
   ```

Installation copies `PiPWindowPinner.ahk` and `config.ini` to `%LOCALAPPDATA%\PiPWindowPinner`, downloads the verified DLL to its `lib` directory, starts it, and registers a per-user Task Scheduler logon task named `PiPWindowPinner`. It runs 10 seconds after every sign-in. No admin rights required.

When `-AllowUnverifiedOsBuild` is supplied, setup persists `AllowUnverifiedOsBuild=1` in installed config so background startup has same explicit compatibility approval.

To install AutoHotkey through winget and set up this utility in one command (build 26300 requires the explicit compatibility override):

```powershell
.\Install.ps1 -InstallAutoHotkey -AllowUnverifiedOsBuild
```

## Detection

Every 750 ms (configurable), utility enumerates top-level visible windows. A window is accepted only if all conditions hold:

- process is `chrome.exe`, `msedge.exe`, `brave.exe`, or `firefox.exe`;
- title matches configured PiP title pattern;
- class is browser-PiP class (`Chrome_WidgetWin_1` or Firefox `MozillaDialogClass`);
- size is within configured PiP bounds;
- it is within PiP dimensions. Owner/style are recorded only as diagnostics: current Chromium PiP windows can have no tool-window, owner, or popup flags.

This intentionally favors no false pins over detecting unknown/localized browser PiP variants. Add your localized title to `config.ini` (`TitlePatterns`, pipe-separated), then reload from tray. A detected HWND is revalidated with process ID, process creation time, path, and class before reuse; stale/reused HWNDs are never reused from cache.

## Verify manually

1. Start utility and open browser PiP.
2. Switch to another desktop (`Win`+`Ctrl`+Arrow): PiP remains.
3. Close/reopen PiP; repeat with two PiP windows.
4. Open normal browser tabs/windows: they must remain unpinned.
5. Check `%LOCALAPPDATA%\PiPWindowPinner\PiPWindowPinner.log`.
6. Sign out/in; task should relaunch it. Use Task Scheduler to inspect `PiPWindowPinner`.

Not executed here: browser GUI scenarios, desktop switching, sleep/resume, Explorer restart, and startup task. No AutoHotkey v2 executable is installed in this environment. Polling survives those events because it re-enumerates live windows; a VDA incompatibility is logged and process exits rather than pinning a wrong window.

## Diagnostics

Log rotates at 256 KiB to `.log.1`. Set `VerboseLogging=1` for accepted-candidate traits. Set `PollIntervalMs` from 250 to 5000. DLL load/export/API failures log then exit or skip the affected window.

## Uninstall

From this source folder:

```powershell
.\Uninstall.ps1
```

This stops utility, removes per-user scheduled task, and deletes `%LOCALAPPDATA%\PiPWindowPinner`. Add `-KeepLogs` to copy log back to source folder first.
