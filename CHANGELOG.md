# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow [SemVer](https://semver.org/).

## [Unreleased]

### Ideas / help wanted
- Notarized builds so macOS stops warning on first launch.
- A public replacement for the private MediaRemote "Now Playing" workaround.
- Replace deprecated APIs that cause compiler warnings.
- Testing on Intel Macs and on external displays without a notch.

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
