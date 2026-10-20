# Contributing to Tatakan

Thanks for helping. Issues and pull requests can be written in English or Bahasa Indonesia.

## Ways to help

- **Report a bug**: open an issue with the *Bug report* template. Include your macOS version, Mac model (Apple Silicon or Intel, notch or not) and what you were doing.
- **Suggest a feature**: use the *Feature request* template. A sketch or screenshot helps a lot.
- **Fix or build**: pick an issue labelled `good first issue` or `help wanted`, comment that you're on it, then open a PR.
- **Design**: UI, icon and copy improvements are welcome too. Keep the visual system below.

## Dev setup

1. Install the Command Line Tools: `xcode-select --install`.
2. Fork and clone the repo.
3. `./Tatakan/build.sh && open Tatakan/build/Tatakan.app`
4. Quit the running copy (menu-bar icon → Quit) before each rebuild.

Tip: ad-hoc builds get a new signature every time, so macOS may ask for Calendar/Camera permission again. If you create a self-signed code-signing certificate named **"Puteran Local Signing"** in Keychain Access, `build.sh` uses it automatically and permissions stick between builds.

## How the code is organised

| Path | Role |
|---|---|
| `Sources/AppDelegate.swift`, `main.swift` | App start, menu-bar item |
| `Sources/Shelf*.swift`, `Shake.swift`, `DragSource.swift` | Floating shelf and shake detection |
| `Sources/Notch.swift`, `NookModels.swift` | The Nook panel and its tabs |
| `Sources/Actions.swift`, `ItemMenu.swift`, `ShareRelay.swift` | Item actions, share, AirDrop |
| `Sources/Theme.swift` | Design tokens, fonts, shared UI pieces |
| `Resources/MediaAdapter.m` | Now Playing adapter (private API, see README) |

## Visual system

- Fonts: Doto (dot-matrix numbers), Space Grotesk (UI), Space Mono (labels). All OFL.
- The Nook is black like the hardware notch. One accent: `#F07A42`, only for active states.
- Labels are small uppercase mono. Buttons are round icons or pills.

## Before a PR

- `./Tatakan/build.sh` must finish with `BUILD OK`. Also try `UNIVERSAL=1 ./Tatakan/build.sh` if you touched build settings.
- Don't add new compiler warnings.
- Try your change in light and dark mode, and on a screen without a notch if it touches the Nook.

## Pull requests

- One topic per PR. Small is better.
- Branch name like `fix/shelf-drop` or `feat/clipboard-tab`.
- Commit messages short and imperative, e.g. `fix: keep shelf above full-screen apps`.
- Add a screenshot or GIF for any UI change.
- By submitting a PR you agree your contribution is released under the MIT license of this project.

## Code of Conduct

Be kind. Read [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
