# Clipboard Manager

[中文文档](README_CN.md)

A **local-first, high-performance, minimal** macOS clipboard manager. Keyboard-first design: summon the panel, pick with arrow keys, paste with Enter — no mouse required.

## Features

- Menu bar resident, global hotkeys to summon the panel (default `⌥⌘V`, customizable by recording)
- Auto-captures: text, links, images, files, and rich text (RTF preserved)
- **Snapshot bar**: horizontal cards at the bottom of the screen, adaptive width, category filters (All / Text / Link / Image / File)
- Instant search with keyword highlighting
- Pin/favorite items (protected from history cleanup)
- Deduplication: identical content refreshes timestamp instead of stacking
- **Sequential paste**: enqueue with `⌥⌘E` (simulates ⌘C + auto-queue), dequeue with `⌥⌘D` (paste one by one), with a persistent side queue list
- Queue side panel: shows all queued items, scrollable, follows the screen where you started copying
- Settings: launch at login, history limit (100–3000), auto-paste, ignore specific apps, clear history
- **Privacy: zero network permissions, all data stays local** (SQLite + cached images/RTF)
- About window with version info and project link

## Installation

Download the latest DMG from [Releases](https://github.com/BaaKoo9/clipboard-manager/releases), drag to Applications.

First launch will ask for **Accessibility** permission (global hotkeys & auto-paste). After granting, everything works; permissions persist across reinstalls thanks to stable code signing.

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
./scripts/build-app.sh          # builds dist/Clipboard Manager.app
./scripts/make-dmg.sh           # builds dist/Clipboard-Manager.dmg
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
- CGEventTap for global hotkeys (Accessibility permission)
- PNG canonical storage + JPEG thumbnails; RTF preserved for rich text

## Roadmap

- [x] Clipboard monitoring & local storage
- [x] Snapshot bar, search, paste-back
- [x] Customizable global hotkeys (summon / enqueue / dequeue)
- [x] Sequential paste, pin, ignore apps, launch at login
- [x] App icon, DMG packaging, about window
- [x] Queue side panel with screen following
- [ ] Cloud sync (iCloud private database), more type detection (colors, code blocks)

## License

Source-available for personal use. All rights reserved.
