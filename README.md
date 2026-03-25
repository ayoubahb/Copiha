# Copiha

A fast, native macOS clipboard manager that lives in your menu bar.

![macOS](https://img.shields.io/badge/macOS-13.0%2B-blue)
![Universal](https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-Universal-brightgreen)
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
2. Download `Copiha.dmg` — universal build, works on both Apple Silicon and Intel Macs
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

### Keyboard Shortcuts

| Action | Shortcut |
|---|---|
| Open Copiha | ⌘⇧V *(customizable in Preferences)* |
| Paste selected item | Click or ↩ Enter |
| Quick paste (first 9 items) | ⌘1 – ⌘9 |
| Navigate list | ↑ / ↓ arrow keys |
| Search | Just start typing |
| Delete hovered item | ⌥⌫ |
| Clear all history | ⌥⇧⌘⌫ |
| Reset panel size | ⌘0 |
| Preferences | ⌘, |
| About | ⌘I |
| Close panel | Escape |
| Quit | ⌘Q |

---

## Preferences

### General
| Option | Description |
|---|---|
| Launch at login | Start Copiha automatically when you log in |
| Open hotkey | Customize the global shortcut (default ⌘⇧V) |
| Search mode | Fuzzy or exact match |
| Paste automatically | Simulate ⌘V to paste directly after selecting |
| Paste without formatting | Strip rich text and paste plain text only |

### Storage
| Option | Description |
|---|---|
| Save — Text | Record text copies (enabled by default) |
| Save — Images | Record image copies |
| Save — Files | Record file copies |
| History size | Max number of items to keep (10–5000, default 100) |
| Sort by | Last copy · Copy count · Alphabetical |
| Auto-clear after | Never · 1 day · 1 week · 1 month |

### Appearance
| Option | Description |
|---|---|
| Popup at | Open at menu bar icon or at the mouse cursor |
| Item preview | Show full content preview on hover |
| Preview delay | How long before the preview appears |
| Show search field | Toggle the search bar visibility |
| Show footer | Toggle the footer bar (Clear, Preferences, Quit…) |

### Ignore
Add apps whose clipboard activity you want Copiha to ignore (e.g. password managers). Copies made in those apps will not be recorded.

### Advanced
| Option | Description |
|---|---|
| Pause monitoring | Stop recording clipboard changes temporarily |
| Clear history on quit | Wipe history when Copiha exits |
| Clear clipboard on quit | Clear the system clipboard when Copiha exits |
| Check for updates | Manually check for a new release on GitHub |
| Show log in Finder | Open `copiha.log` for bug reporting |

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
