# Copiha

A fast, native macOS clipboard manager that lives in your menu bar.

![macOS](https://img.shields.io/badge/macOS-13.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.0-orange)
![License](https://img.shields.io/badge/license-MIT-green)
![GitHub](https://img.shields.io/badge/GitHub-ayoubahb-black)

---

## Features

- **Instant access** — Press ⌘⇧V (customizable) to open your clipboard history at the cursor
- **Smart search** — Fuzzy or exact search across your entire history
- **Keyboard navigation** — Arrow keys to browse, Enter to paste, ⌘1–9 for quick picks
- **Hover preview** — See full content, copy timestamps, and copy count on hover
- **Preferences** — History size, TTL, sort order, ignored apps, appearance options
- **Pause monitoring** — Temporarily stop recording with one click
- **Launch at login** — Runs silently in the background
- **Privacy first** — All data stays on your Mac. No cloud, no analytics, no telemetry

---

## Installation

### Option 1 — Download (recommended)

1. Go to [Releases](https://github.com/ayoubahb/Copiha/releases/latest)
2. Download `Copiha.dmg`
3. Open the DMG, drag Copiha to Applications
4. Launch Copiha — grant Accessibility permission when prompted

### Option 2 — Build from source

```bash
git clone https://github.com/ayoubahb/Copiha.git
cd Copiha
xcodebuild -scheme Copiha -configuration Release build
```

---

## Usage

| Action | Shortcut |
|---|---|
| Open Copiha | ⌘⇧V (customizable in Preferences) |
| Paste item | Click or Enter |
| Quick paste (first 9) | ⌘1 – ⌘9 |
| Navigate list | ↑ / ↓ arrow keys |
| Search | Just start typing |
| Delete item | Hover + ⌥⌫ |
| Clear all | ⌥⇧⌘⌫ |
| Preferences | ⌘, |
| Quit | ⌘Q |

---

## Permissions

Copiha requires **Accessibility** permission to simulate ⌘V after you select an item. Without it, the item is still copied to your clipboard but not pasted automatically.

Grant access in: **System Settings → Privacy & Security → Accessibility**

---

## Privacy

Copiha stores your clipboard history **locally on your Mac only** — in `~/Library/Application Support/Copiha/history.json`. No data is ever sent to any server. The only outbound request is an optional update check against the GitHub releases API.

---

## Reporting bugs

1. Open **Preferences → Advanced → Show Log in Finder**
2. Attach `copiha.log` to your [GitHub issue](https://github.com/ayoubahb/Copiha/issues/new)

---

## License

MIT — see [LICENSE](LICENSE)
