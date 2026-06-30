# IconKeeper

**Keep your custom macOS app icons through updates.** IconKeeper lets you drop in a `.app` and a custom icon, applies it, and then quietly watches for the day an update wipes it — automatically putting your icon back.

[![CI](https://github.com/developer180527/IconKeeper/actions/workflows/ci.yml/badge.svg)](https://github.com/developer180527/IconKeeper/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/developer180527/IconKeeper?display_name=tag)](https://github.com/developer180527/IconKeeper/releases)
![Platform](https://img.shields.io/badge/macOS-26%2B-blue)

Native SwiftUI + AppKit. A polished dashboard, a personal icon library, a menu bar companion, and an optional background agent that protects your icons even when the app isn't running.

## Screenshots

### Dashboard
Drag in an app to start protecting its icon. Each row shows live status and health.

![IconKeeper dashboard](Assets/App%20Screenshots/Screenshot%202.png)

---

### Protect an app
Drop the app and the icon you want it to keep, preview the before → after, then apply.

![Protect an app](Assets/App%20Screenshots/Screenshot%203.png)

---

### App detail & health
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

- **Drag-and-drop** an app + icon, with a live before/after preview.
- **Automatic reapply** — detects when an update (or anything else) resets the icon and restores *your* choice.
- **Original always recoverable** — restore reveals the app's genuine current icon natively; the backup tracks official redesigns automatically.
- **Personal icon library** — import once, reuse across apps, batch-apply.
- **Automatic icon conversion** — any PNG/JPEG/TIFF/HEIC is normalized into a proper multi-size `.icns` (downscale-only, no blurry upscaling).
- **Transparent health checks** — applied/matching, resolution, backup, writability, stability.
- **Menu bar companion** — quick status and reapply, runs quietly in the background.
- **Background agent (optional)** — a lightweight launchd agent reapplies icons even when IconKeeper is closed, with no always-on process.
- **Export / import** your whole configuration (icons embedded), and an **Activity** history.

## How it works

- **Icon override, not destruction.** IconKeeper uses `NSWorkspace.setIcon`, which stores your icon as an `Icon\r` resource on the bundle — the app's real icon inside `Contents/Resources` is never touched. Restoring just removes the override, revealing the app's *current* genuine icon.
- **Drift detection.** Protection means *your specific* icon is applied — not merely that some custom icon exists. IconKeeper compares the on-disk icon to your asset, so a third-party or manual change is caught too.
- **Monitoring.** A single recursive FSEvents stream over the app folders reacts to bundle replacement and in-bundle edits (targeted to the affected app), backed by a periodic safety-net sweep.
- **Background protection.** An optional launchd LaunchAgent re-checks at login and on an interval; each run is a short-lived process that fixes drift and exits — there is no resident daemon.
- **System apps are respected.** Built-in apps on the read-only system volume (SIP) are detected by volume and never modified.

> **Note:** IconKeeper ships **outside the App Sandbox** because it must write icons into other apps' bundles and watch them for changes — the standard model for this category of utility (direct/notarized distribution).

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

## Releases

Prebuilt apps are published on the [Releases](https://github.com/developer180527/IconKeeper/releases) page.

> Release builds from CI are **not code-signed or notarized**. On first launch, right-click the app and choose **Open**, or clear the quarantine flag:
> ```bash
> xattr -dr com.apple.quarantine /Applications/IconKeeper.app
> ```

## License

To be determined by the project owner.
