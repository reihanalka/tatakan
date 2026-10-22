# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow [SemVer](https://semver.org/).

## [Unreleased]

### Ideas / help wanted
- Notarized Mac builds and a code-signed Windows installer, so first launch doesn't warn.
- A public replacement for the private MediaRemote "Now Playing" workaround (Mac).
- Quick Look–style preview on Windows (Space).
- Replace deprecated Mac APIs that cause compiler warnings.
- Testing on Intel Macs, real Windows PCs, multi-monitor and high-DPI setups.

## [0.5.0] — 2026-10-22

Mac only. The Windows app stays at 0.4.0.

### Added
- **Tab Groups** (beta, off by default). Drag any window onto the middle of another and hold for half a second: they share one frame under a tab strip, whatever their apps.
  - Click a tab or press `⌃⌥⇥` / `⌃⌥⇧⇥` to switch; drag a tab sideways to reorder or off the strip to take it out.
  - Right-click a tab: Close Tab, Move Out of Group, Separate All Tabs.
  - Drag the visible window to move the whole group; drop a group on another window to merge them.
  - Groups are remembered when Tatakan restarts; hidden tabs come back on screen when Tatakan quits, even when it's force-quit.
  - Settings: on/off and a list of apps that are never grouped.
- Needs Accessibility, asked for only when Tab Groups is switched on.

### Changed
- The Settings window scrolls instead of growing past the screen.
- Release workflow: the Windows job is skipped when a tag is Mac only; the PowerShell installer picks the newest release that has a Windows installer.

## [0.4.0] — 2026-10-20

### Added
- **Windows version** (Windows 10 1809+ / 11, x64 and ARM64). A native C# / WPF port of the shelf:
  - shake-to-open while dragging, `Ctrl+Alt+Space`, tray icon (click = new shelf, right-click = menu)
  - drop files, folders, links, text, images and virtual files (e.g. Outlook attachments); drag out to Explorer and other apps
  - pile and list views, multi-select, rename, colours, Recent Shelves
  - Open, Show in File Explorer, Copy, Copy Path, Save/Move to Folder, Create ZIP
  - image resize/convert and offline OCR (Windows' built-in engine)
  - Windows share sheet (Nearby Share, Mail, apps)
  - same look as the Mac app: Doto / Space Grotesk / Space Mono, light and dark mode following Windows
  - settings: shake sensitivity, excluded apps, start at sign-in
- **Windows installer** `Tatakan-Setup-x.y.z.exe` (per-user, no admin; installs the .NET 8 Desktop Runtime if missing) and a one-line PowerShell installer.
- CI builds, installs and screenshots the Windows app on every push; releases attach Mac and Windows files together.

### Not on Windows
- The Nook (notch panel), Mirror and Bluetooth/battery notices. They depend on the MacBook notch and stay Mac only.

## [0.3.1] — 2026-10-20

First public release.

### Added
- Universal build: runs on Apple Silicon and Intel Macs.
- `.pkg` installer that installs to /Applications, clears the quarantine flag and opens the app.
- `.dmg` disk image and a one-line Terminal installer (`scripts/install.sh`).
- `scripts/make-release.sh` builds all release files.

### Included
- **Shelf**: shake-to-open floating shelf, drag in/out, item actions (copy, reveal, share, AirDrop).
- **Nook**: notch panel with Now Playing, Tray, Calendar, Timer and Notes. Pill fallback on screens without a notch.
- **Mirror** camera check and **Bluetooth** connect notices.
- Light and dark mode.
