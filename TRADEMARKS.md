# Name and logo policy

The **code** in this repository is MIT licensed. You can use it, change it, ship it and sell it.

The **brand** is not part of that license. "Tatakan" and its logo and icons (`Tatakan - Logo.ai`, `Tatakan_Icon.svg`, `Tatakan_Icon_2.svg`, `Tatakan/Resources/AppIcon.icns`, `Tatakan/Resources/Icons/`, the `.ico`/`.png`/`.bmp` files in `windows/Tatakan/Assets/` and `windows/installer/`) belong to Reihan Al Kautsar.

## Fine without asking

- Saying your project is "based on Tatakan" or "a fork of Tatakan".
- Using the name and icon when you write about, review or teach the original app.
- Sending pull requests back to this repo, using the name and icon as they are.
- Running the app unchanged, for any work, personal or commercial.

## Please don't

- Release a modified build under the name "Tatakan" or with the Tatakan icon.
- Imply that the author made, endorses or supports your fork.
- Use the logo in your own product, merch or branding.

## If you fork and redistribute

1. Pick a new name.
2. Replace `Tatakan_Icon.svg` and `Tatakan_Icon_2.svg` and rebuild (the icons are generated from them).
3. Change `CFBundleIdentifier` in `Tatakan/Info.plist` (e.g. `com.yourname.yourapp`) and the `--identifier` in `scripts/make-release.sh`. For Windows, change `AppId` in `windows/installer/Tatakan.iss` and the instance name in `windows/Tatakan/App.xaml.cs`. That way your fork never clashes with ours.
4. Keep the MIT copyright notice in `LICENSE`.

Not sure? Open an issue.
