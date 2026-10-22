# Sound Control

[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?logo=apple)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-SwiftUI-orange?logo=swift)](docs/DEVELOPMENT.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)
[![AI-assisted](https://img.shields.io/badge/built%20with-AI%20assistance-8A2BE2)](#ai-assisted-development)

A lightweight menu bar mixer for macOS in the style of Control Center: per-app volume, output boost and device switching.

<p align="center">
  <img src="docs/images/main-dark.png" alt="Sound Control menu (dark)" width="400">
  <img src="docs/images/main-light.png" alt="Sound Control menu (light)" width="400">
</p>

> [!NOTE]
> This app was developed with AI assistance. See [AI-assisted development](#ai-assisted-development).

## Features

- **Per-app volume** from 0 to 200 % with a limiter against clipping when boosting; double-click a slider to reset to 100 %.
- **Output and input devices**: switch with one click, hide devices you never use, set the microphone volume and mute it.
- **Output boost** up to 200 %: the device regulates itself up to 100 %, above that Sound Control amplifies (shown in orange).
- **AirPlay rooms** appear by their room name once macOS has connected them.
- **Advanced mode**: per-app sound profiles, balance, mono and a custom output device, plus a fixed sample rate per device.
- **Remembers** your settings per app across restarts; quiet apps collapse under "More Apps", nothing jumps while you drag.

## Screenshots

<table>
<tr>
<td align="center"><img src="docs/images/apps-dark.png" width="360"><br>All apps, including the quiet ones under "More Apps"</td>
<td align="center"><img src="docs/images/advanced-dark.png" width="360"><br>Advanced mode: sound profiles, balance, mono and output per app</td>
</tr>
<tr>
<td align="center"><img src="docs/images/output-dark.png" width="360"><br>Choosing the output device</td>
<td align="center"><img src="docs/images/airplay-dark.png" width="360"><br>AirPlay rooms shown by name</td>
</tr>
<tr>
<td align="center"><img src="docs/images/hidden-dark.png" width="360"><br>Hiding devices you never use</td>
<td align="center"><img src="docs/images/input-dark.png" width="360"><br>Choosing the microphone</td>
</tr>
<tr>
<td align="center"><img src="docs/images/sample-rate-dark.png" width="360"><br>Fixed sample rate per device (advanced mode)</td>
<td align="center"><img src="docs/images/settings-dark.png" width="360"><br>Settings and saved per-app values</td>
</tr>
<tr>
<td align="center"><img src="docs/images/confirm-dark.png" width="360"><br>Two-step reset</td>
</tr>
</table>

## Requirements

- macOS 26 or later on Apple silicon

## Installation

1. Download `SoundControl-<version>.zip` from the [latest release](../../releases/latest) and unzip it.
2. Move **SoundControl.app** to `/Applications`.
3. Open it. The app is free and ad-hoc signed, not notarized by Apple, so macOS blocks the first launch:
   open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
   Alternatively, in Terminal: `xattr -dr com.apple.quarantine /Applications/SoundControl.app`
4. The first time you change an app's volume, allow **System Audio Recording** when asked
   (see [Permissions and privacy](#permissions-and-privacy)).

The app starts at login by default; switch this off under Settings (gear icon) → **Open at Login**.
To uninstall, quit it from the menu and move it to the Trash.
Because the app is ad-hoc signed, macOS may ask for the permissions again after an update.

## Usage

- Click the menu bar item. The top section sets the output device and volume (up to 200 %), then the microphone.
- Drag an app's slider to change only that app; double-click to reset it to 100 %.
- Open the output or input list to switch or hide devices; hidden ones sit under "Hidden".
- The small button at the bottom left turns on **advanced mode** (sound profiles, balance, mono, output per app, sample rate).
- The gear icon opens settings: stored values, a two-step reset and **Open at Login**.

## Build from source

```sh
brew install xcodegen
git clone https://github.com/ape97/SoundControl.git && cd SoundControl
./scripts/check.sh    # build + snapshots + self-test -> RESULT: GREEN
./scripts/deploy.sh   # check, install to /Applications, restart
```

No Apple developer account is needed. Project layout, scripts, signing, screenshots and releases are described in
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Permissions and privacy

- **System Audio Recording** (System Settings → Privacy & Security → Screen & System Audio Recording, audio only): required
  for per-app volume, boost and sound profiles. To change an app's volume, Sound Control taps that app's audio output with
  Core Audio process taps, processes it in memory and plays it back. Only apps whose sound you actually change are tapped;
  all other apps run untouched. The audio is never recorded to disk or sent anywhere. Without the permission the device
  volume, device switching and microphone controls still work.
- **Local Network**: used only to find AirPlay speakers on your network via Bonjour (`_airplay._tcp`), so they can be
  shown by room name. macOS asks the first time you expand the output list. If you decline, the name stays "AirPlay".
- **Microphone**: declared because the app shows and adjusts the volume and mute state of your input device. It does not
  record or listen to your microphone.

Everything stays on your Mac. The only stored data are your settings per app in the app's user defaults. Apart from the
local Bonjour search there is no network access and no telemetry.

## AI-assisted development

Sound Control was built with the help of an AI coding assistant: code, comments, documentation and the screenshot
pipeline were written in collaboration with AI. Every change is built and checked with `scripts/check.sh`
(warning-free build, snapshots, self-test) and the app is in daily use on the maintainer's Mac.
Issues and pull requests are welcome.

## License

MIT, see [LICENSE](LICENSE).
