# ClipBar

[中文文档](README_CN.md)

A **local-first, high-performance, minimal** macOS clipboard manager. Keyboard-first design: summon the panel, pick with arrow keys, paste with Enter — no mouse required.

## System Requirements

- **macOS 14 Sonoma** or later (including macOS 15 Sequoia)
- **Apple Silicon** and **Intel** Macs
- First launch requires **Accessibility** and **Input Monitoring** permissions (global hotkeys & auto-paste)

## Features

- Menu bar resident, global hotkeys to summon the panel (default `⌥⌘V`, customizable by recording)
- Auto-captures: text, links, images, files, and rich text (RTF preserved)
- **Snapshot bar**: horizontal cards with type filters (All / Text / Link / Image / File) and custom labels
- Instant search with keyword highlighting (supports `#tag`)
- Pin/favorite items (protected from history cleanup); optional bump-on-paste
- Deduplication: identical content refreshes timestamp instead of stacking
- **Sequential paste**: enqueue with `⌥⌘E` (simulates ⌘C + auto-queue), dequeue with `⌥⌘D`, with a persistent side queue list
- Labels: create / drag-reorder / context-menu edit-delete in the panel; manage in Settings
- Settings: launch at login, history limit & retention, auto-paste, ignore apps, silent update checks, clear history
- **Privacy: zero network permissions, all data stays local** (SQLite + cached images/RTF)
- About window with version info and project link

## Installation

Download the latest **`.pkg` installer** from [Releases](https://github.com/BaaKoo9/ClipBar/releases), then double-click to install into Applications.

### First launch (not notarized)

This build is self-signed and **not Apple-notarized**. macOS may block the first open after download. Use either:

1. **Recommended**: in Finder, **Control-click** (or right-click) `ClipBar` → **Open** → confirm **Open** again
2. Or go to **System Settings → Privacy & Security**, scroll to the security prompt, and click **Open Anyway** (wording may vary by macOS version)

After that, grant in **System Settings → Privacy & Security**:

- **Accessibility**
- **Input Monitoring**

Both are required for global hotkeys and auto-paste.

## Usage

| Action | Shortcut |
|---|---|
| Summon / dismiss panel | `⌥⌘V` |
| Enqueue copy (copy selection + queue) | `⌥⌘E` |
| Dequeue paste | `⌥⌘D` |
| In panel: select | `←` `→` |
| In panel: paste selected | `Enter` or single click |
| In panel: enqueue | `⌘+Click` or hover `⊕` button |

All shortcuts are customizable in Settings.

## Build

Requires macOS 14+ and only Xcode CommandLineTools (no full Xcode needed):

```bash
./scripts/build-app.sh          # builds dist/ClipBar.app
./scripts/make-pkg.sh           # builds dist/ClipBar-x.y.z.pkg
./scripts/run-tests.sh          # runs core unit tests
```

## Tests

```bash
swift run CoreTests
```

Covers: insert/fetch, dedup, search, pin protection, clear, text/image/file/RTF paste-back, hotkey registration, legacy DB migration, 10k-item performance (fetch <10ms, search <5ms).

## Tech Stack

- Swift + SwiftUI + AppKit, zero third-party dependencies
- SQLite (system library): serialized writes, lazy capacity cleanup
- Carbon global hotkeys + CGEventTap (Accessibility / Input Monitoring)
- PNG canonical storage + JPEG thumbnails; RTF preserved for rich text

## Roadmap

- [x] Clipboard monitoring & local storage
- [x] Snapshot bar, search, paste-back
- [x] Customizable global hotkeys (summon / enqueue / dequeue)
- [x] Sequential paste, pin, ignore apps, launch at login
- [x] App icon, pkg installer, about window
- [x] Queue side panel with screen following
- [x] Custom labels, silent update checks
- [ ] Cloud sync (iCloud private database), more type detection (colors, code blocks)

## License

Source-available for personal use. All rights reserved.
