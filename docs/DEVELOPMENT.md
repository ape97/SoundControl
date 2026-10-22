# Development

Everything you need to change, build, install and release Sound Control yourself.

## Prerequisites

- macOS 26 or later, Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

The Xcode project is generated from `project.yml` and not checked in. Run `xcodegen generate` and open
`SoundControl.xcodeproj` if you want to work in Xcode; the scripts below generate it themselves.

## Project layout

```
project.yml                 XcodeGen project (version in MARKETING_VERSION)
Config/Signing.xcconfig     ad-hoc signing by default, optional Config/Local.xcconfig
SoundControl/
  App/                      app entry, state and settings, SelfTest
  Audio/                    AppTap (process taps), AppMixer, DSP, DeviceManager, AudioApps, AirPlayBrowser, CapturePermission, CoreAudioHelpers
  UI/                       MenuView, SettingsPage, CapsuleSlider, SystemLinks
  Resources/                Info.plist, entitlements, asset catalog (app icon)
scripts/                    check, deploy, status, screenshots, release, icon
docs/                       PLATFORM.md (tested macOS/Xcode), images/ (README screenshots)
```

## Scripts

| Script | What it does |
|---|---|
| `./scripts/check.sh` | The gate. Warning-free Release build, invisible snapshots of every page into `build/check/`, self-test with and without advanced mode. Ends with `RESULT: GREEN` or `RED`. Changes nothing on the system. |
| `./scripts/deploy.sh` | Runs the check; only if green, installs to `/Applications` and restarts the app. |
| `./scripts/status.sh` | Shows the installed version, running state, login item and signature, and compares the system with the last tested one in `docs/PLATFORM.md`. |
| `./scripts/screenshots.sh` | Renders every page with demo data and composes the README images in `docs/images/`: every page in dark mode, the main page in light mode too. |
| `./scripts/release.sh` | Builds the downloadable, ad-hoc signed and stripped `build/release/SoundControl-<version>.zip`. |
| `swift scripts/icon.swift <out.png>` | Draws the app icon (used when the icon changes). |

Typical loop: edit, `./scripts/check.sh`, look at `build/check/*.png`, then `./scripts/deploy.sh` to use it.

## Command-line modes

The app binary (`SoundControl.app/Contents/MacOS/SoundControl`) understands a few arguments used by the scripts:

- `--snapshot <base>` renders the menu off-screen to `<base>-light.png`, `<base>-dark.png` and `<base>-symbol.png`
  and exits. No window is shown. Page and state flags: `--devices` (output list), `--inputs` (input list),
  `--others` (all apps including quiet ones), `--settings`, `--confirm` (two-step reset), `--advanced`,
  `--hidden <name>` (hidden-devices section with that device), `--airplay [room]` (AirPlay room in the list).
- `--demo` (with `--snapshot`) replaces your devices and apps with fixed, invented data, so screenshots never show your own system.
- `--selftest <file.json> [--advanced]` checks DSP, persistence, menu behavior and, if the permission is granted, a real
  silent tap; the result is written as JSON.

## Signing

Builds are ad-hoc signed (`Config/Signing.xcconfig`), so no developer account is needed. macOS ties the System Audio
Recording permission and the login item to the code signature, so with ad-hoc signing you may have to grant the permission
again and switch **Open at Login** on again after a rebuild. To sign with your own certificate, create the git-ignored
`Config/Local.xcconfig`:

```
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = YOURTEAMID
```

## Releasing

1. Raise `MARKETING_VERSION` in `project.yml`.
2. `./scripts/check.sh` must be green; refresh the README images with `./scripts/screenshots.sh` if the UI changed.
3. `./scripts/release.sh` builds the zip. It always signs ad hoc, even with `Local.xcconfig` present, because a personal
   certificate would put the developer's name into the signature, and it strips the binary so no build paths remain.
4. Commit, tag and publish, for example with the GitHub CLI:
   ```sh
   git tag v1.8.8 && git push --tags
   gh release create v1.8.8 build/release/SoundControl-1.8.8.zip --title "Sound Control 1.8.8" --notes "…"
   ```

## After a macOS or Xcode update

Run `./scripts/status.sh`. If the system differs from the last `tested:` line in `docs/PLATFORM.md`, run
`./scripts/check.sh`, fix what broke and append a new `tested:` line. `docs/PLATFORM.md` also lists the system
interfaces most likely to change (process taps, the permission query, AirPlay discovery).

## How it works

- Core Audio process taps (`AudioHardwareCreateProcessTap`) capture only apps whose sound is being changed; all other apps run untouched.
- The tapped audio goes through a real-time chain (gain, biquad filters, optional compressor, limiter) and is played via a private aggregate device.
- Device volume, mute, sample rate and hot-plugging use the Core Audio HAL property API. Devices without their own volume (HDMI etc.) are regulated entirely in software; lowering the volume with the keyboard ends the boost.
- The System Audio Recording permission (`kTCCServiceAudioCapture`) is queried through a private TCC function in `Audio/CapturePermission.swift`, because without it a tap would mute the app and deliver only silence.
- AirPlay rooms come from Bonjour (`_airplay._tcp`, `Network.NWBrowser`); only the name is used, since Core Audio reports a connected target just as "AirPlay". Rooms that macOS has not connected do not appear.
- The UI is SwiftUI in a `MenuBarExtra` window; opening and closing is tracked through window key/visibility notifications.

## Contributing

Keep changes small and focused, run `./scripts/check.sh` before opening a pull request, and describe what you tested.
Settings get a short explanation below them (`SettingNote` in `UI/`, if present in the view you change).
