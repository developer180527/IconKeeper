# IconKeeper

**Keep your custom macOS icons through updates.** IconKeeper lets you drop in an app or folder plus a custom icon, applies it, and then quietly watches for the day an update wipes it — automatically putting your icon back.

[![CI](https://github.com/developer180527/IconKeeper/actions/workflows/ci.yml/badge.svg)](https://github.com/developer180527/IconKeeper/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/developer180527/IconKeeper?display_name=tag)](https://github.com/developer180527/IconKeeper/releases)
![Platform](https://img.shields.io/badge/macOS-26%2B-blue)

Native SwiftUI + AppKit. A polished dashboard, a personal icon library, a menu bar companion, and an optional background agent that protects your icons even when the app isn't running.

## Screenshots

### Dashboard
Drag in apps or folders to start protecting their icons. Each row shows live status and health.

![IconKeeper dashboard](Assets/App%20Screenshots/Screenshot%202.png)

---

### Protect an app or folder
Drop the items and the icon you want them to keep, preview the before → after, then apply. Drop several at once to give them all the same icon.

![Protect an app](Assets/App%20Screenshots/Screenshot%203.png)

---

### Item detail & health
A transparent, per-criterion health report — each check shows its verdict *and* the rule behind it.

![App detail and health](Assets/App%20Screenshots/Screenshot%204.png)

---

### Activity
A running history of applies, automatic reapplies after updates, restores, and removals.

![Activity log](Assets/App%20Screenshots/Screenshot%20%201.png)

---

### Settings
Monitoring cadence, notifications, startup, background protection, and maintenance tools.

![Settings](Assets/App%20Screenshots/Screenshot%205.png)

## Features

- **Apps and folders** — protect `.app` bundles and ordinary folders alike.
- **Drag-and-drop** items + icon, with a live before/after preview.
- **Batch apply** — drop or select many items at once and give them all the same icon, or push a library icon to any set of tracked items.
- **Automatic reapply** — detects when an update (or anything else) resets the icon and restores *your* choice.
- **Original always recoverable** — restore reveals the item's genuine current icon natively; the backup tracks official redesigns automatically.
- **Personal icon library** — import once, reuse across items, batch-apply.
- **Automatic icon conversion** — any PNG/JPEG/TIFF/HEIC is normalized into a proper multi-size `.icns` (downscale-only, no blurry upscaling).
- **Transparent health checks** — applied/matching, resolution, backup, writability, stability.
- **Menu bar companion** — quick status and reapply, runs quietly in the background.
- **Background agent (optional)** — a lightweight launchd agent reapplies icons even when IconKeeper is closed, with no always-on process.
- **Export / import** your whole configuration (icons embedded), and an **Activity** history.

## How it works

- **Icon override, not destruction.** IconKeeper uses `NSWorkspace.setIcon`, which stores your icon as an `Icon\r` resource inside the directory — the app's real icon in `Contents/Resources` is never touched. Restoring just removes the override, revealing the item's *current* genuine icon.
- **Folders work the same way.** A folder stores its custom icon in exactly the same `Icon\r` file an app bundle does, so protection, drift detection, and restore behave identically. Folders rarely drift, since nothing replaces them the way an update replaces an app.
- **Individual files aren't supported — deliberately.** A regular file has nowhere to put an `Icon\r`, so macOS keeps its custom icon in the file's resource fork. That is destroyed every time an app saves the file atomically (which most apps do), taking IconKeeper's own tracking metadata with it. Supporting files would mean fighting every save, so IconKeeper declines them with a clear message instead.
- **Drift detection.** Protection means *your specific* icon is applied — not merely that some custom icon exists. IconKeeper records how macOS renders your icon when it applies it and compares against that, so a third-party or manual change is caught too — and IconKeeper asks before overwriting one. A removed icon (an update) is put back automatically; a *different* icon (someone's deliberate choice) is left alone until you choose Keep Mine or Adopt.
- **One policy, one write path.** The decision about what to do with a check's result is a single pure function shared by the app and the background agent, and every icon write goes through the same engine — backups, the recovery marker, and the drift reference are handled identically everywhere.
- **Your folders stay sorted.** Applying an icon to a folder writes inside it, which would change its Date Modified; IconKeeper puts the original date back.
- **Storage is deduplicated.** Library icons, original-icon backups, and render references are stored by content, so a thousand folders sharing the default folder icon share one backup.
- **Monitoring.** A single FSEvents stream over the parent directories of everything you protect reacts to bundle replacement and in-place edits (targeted to just the affected item), backed by a periodic safety-net sweep.
- **Background protection.** An optional launchd LaunchAgent re-checks at login and on an interval; each run is a short-lived process that fixes drift and exits — there is no resident daemon.
- **System apps are respected.** Built-in apps on the read-only system volume (SIP) are detected by volume and never modified.

> **Note:** IconKeeper ships **outside the App Sandbox** because it must write icons into other apps' bundles and folders and watch them for changes — the standard model for this category of utility (direct distribution).

## Requirements

- macOS 26 or later.
- To build: **Xcode 26.5+** (the project targets the macOS 26 SDK).

## Building

The repo uses Xcode's synchronized file groups, so any `.swift` file under `IconKeeper/` is compiled automatically.

```bash
# If xcode-select points at the Command Line Tools, point xcodebuild at Xcode:
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -scheme IconKeeper -configuration Debug -destination 'platform=macOS' build
```

Or just open `IconKeeper.xcodeproj` in Xcode and run.

### Tests

The engine — drift policy, apply/restore, import planning, storage — is covered by unit and integration tests (`IconKeeperTests`, Swift Testing). Integration tests work on throwaway folders and a scratch data directory; they never touch your configuration or icons.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -scheme IconKeeper -destination 'platform=macOS' test
```

Debug builds can also be run against throwaway data by setting `ICONKEEPER_DATA_DIR` to an empty folder; in that mode the app leaves the LaunchAgent and notification permission alone.

## Releases

Prebuilt apps are published on the [Releases](https://github.com/developer180527/IconKeeper/releases) page.

- The automated build from CI is a **zip, unsigned**.
- Some releases also include a **DMG that is code-signed** with an Apple Development certificate — this verifies the build hasn't been tampered with since it left this machine, but it is **not notarized** (notarization requires a paid Apple Developer Program membership). Gatekeeper still blocks first launch either way.

> On first launch, right-click the app and choose **Open**, or clear the quarantine flag:
> ```bash
> xattr -dr com.apple.quarantine /Applications/IconKeeper.app
> ```
>
> To confirm a signed build's identity yourself: `codesign -dv --verbose=4 /Applications/IconKeeper.app` (look for `TeamIdentifier=7PF6KT3R5Q`).


