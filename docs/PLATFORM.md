# Platform status

The macOS/Xcode version Sound Control was last fully tested against (`scripts/check.sh` green, deployed,
live tap test with the real permission granted). `scripts/status.sh` compares the last `tested:` line
with the running system. Append new lines at the bottom and keep the format exactly.

tested: macOS=27.0.1 (26A434) Xcode=27.0 SDK=27.0 date=2026-10-16

## Dependencies on the system (what an update may break)
- **Core Audio process taps** (`AudioHardwareCreateProcessTap`, `CATapDescription`, private aggregate device) –
  the core of per-app volume, available since macOS 14.2. Verified by the live tap test in the self-test (ratio 0.50 at 50 %).
- **System audio recording permission** (TCC `kTCCServiceAudioCapture`, private query in `CapturePermission.swift`).
  If the query breaks, the app shows "Allow" although the permission is granted – the self-test reports `permission`.
- **Process → app** via "responsible PID" (`AudioApps.swift`, private function) – if it breaks, helper processes appear instead of apps.
  Fallback for root-owned helpers without a responsible PID (e.g. the VM process of a virtualization app): the executable path inside a running app's bundle (`proc_pidpath`, `AppOwnership`).
- **Device properties** (volume, mute, sample rate, transport) – public HAL API, stable.
- **MenuBarExtra (.window)**, `NSWindow.didResignKey/didBecomeKey` for collapsing and freezing the order.
  A closed menu = window hidden (`isVisible` false, CGWindowList `onscreen` false).
  A context menu/tooltip takes focus without closing → reset happens only once the window is no longer visible.
  SwiftUI does not build its accessibility tree in-process (only the root `AXGroup`) → the self-test checks logic instead of clicks.
- **AirPlay rooms** via Bonjour `_airplay._tcp` (`Network.NWBrowser`, `Audio/AirPlayBrowser.swift`): TXT `gid` = group,
  `gpn` = room name (an Apple TV + HomePod in the same room share a `gid`), `model` for the symbol (`AudioAccessory5,*` = HomePod mini).
  Needs `NSBonjourServices` + `NSLocalNetworkUsageDescription` (Local Network privacy prompt, shown only when the output list is expanded).
  Bonjour only provides the name; rooms that are not connected are not shown.
  Core Audio creates an AirPlay target only after it has been connected through Apple: HAL device named "AirPlay", transport `airp`, plug-in
  `com.apple.AirPlayXPCHelper`, UID unrelated to Bonjour IDs, `kAudioPlugInPropertyTranslateUIDToDevice` → `'nope'`
  (cannot be created by the app). After deselecting (default/system output moved to another
  device) the HAL device disappears immediately; reconnecting works only through Apple. A custom AirPlay sender was rejected.
  `AVOutputDeviceDiscoverySession`/`AVOutputContext`/MediaRemote return nothing without an Apple entitlement; `AVRoutePickerView`
  only applies to the app's own audio (removed).
  If rooms are missing, check the Bonjour TXT records (`dns-sd -B _airplay._tcp`) and the Local Network permission.
- **System Settings → Sound** (footer button) via the URL `x-apple.systempreferences:com.apple.Sound-Settings.extension`.
- **SMAppService** (login item) – `scripts/status.sh` checks via `sfltool dumpbtm`.
- **Code signing:** ad-hoc by default. With your own certificate (`Config/Local.xcconfig`) the TCC permission survives reinstalls;
  with ad-hoc signing it may have to be granted again after each local rebuild. Release zips (`scripts/release.sh`) carry a
  fixed designated requirement, so the permission survives updates.
- **GitHub releases API** (`App/UpdateCheck.swift`), only while Check for Updates is on: `GET api.github.com/repos/ape97/SoundControl/releases/latest`,
  reads `tag_name` and `html_url`, ignores drafts and pre-releases. If GitHub changes this, only the update notice stops working.
