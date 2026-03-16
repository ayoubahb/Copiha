# ClipStack — Claude Code Build Prompt

> **How to use this file:** Paste the full contents into Claude Code (or run `claude < CLIPSTACK_PROMPT.md`) and it will follow every step below to build the complete macOS clipboard manager app.

---

## PROJECT OVERVIEW

Build a native macOS clipboard manager application called **ClipStack** that lives in the menu bar and pops up via a global keyboard shortcut (default: `Cmd+Shift+V`) **AND** by clicking the menu bar icon — just like [Maccy](https://maccy.app/). This is a **$9.99 premium app**, so it must feel polished, fast, and professional.

---

## TECH STACK

| Layer | Choice |
|---|---|
| Language | Swift (latest) |
| UI Framework | SwiftUI + AppKit where needed |
| Target | macOS 13 Ventura and above |
| Architecture | MVVM |
| Storage | Core Data (persistence) + UserDefaults (settings) |
| Global Hotkey | Carbon framework (`RegisterEventHotKey`) — no third-party deps |
| Distribution | Standalone `.app` bundle |

---

## STEP 1 — Project Setup

1. Create a new Xcode project:
   - Template: **macOS › App**
   - Name: `ClipStack`
   - Bundle ID: `com.yourname.clipstack`
   - Interface: SwiftUI
   - Life Cycle: AppKit App Delegate

2. Configure `Info.plist`:
   - `LSUIElement = true` — hides from Dock, runs as menu bar-only app
   - `NSAppleEventsUsageDescription = "ClipStack needs access to monitor your clipboard."`

3. Entitlements:
   - `com.apple.security.automation.apple-events = true`
   - Disable App Sandbox **OR** configure sandbox for clipboard + input monitoring

4. Link the **Carbon** framework:
   - Xcode › Target › Build Phases › Link Binary With Libraries › Add `Carbon.framework`

5. Set deployment target: **macOS 13.0**

---

## STEP 2 — File Structure

```
ClipStack/
├── App/
│   ├── ClipStackApp.swift
│   └── AppDelegate.swift
├── Models/
│   ├── ClipItem.swift
│   └── ClipItemType.swift
├── ViewModels/
│   ├── ClipboardViewModel.swift
│   └── SettingsViewModel.swift
├── Services/
│   ├── ClipboardMonitor.swift
│   ├── PersistenceController.swift
│   └── HotkeyManager.swift          ← CRITICAL: global hotkey service
├── Views/
│   ├── PopupView.swift
│   ├── ClipRowView.swift
│   ├── SearchBarView.swift
│   └── SettingsView.swift
└── Resources/
    └── ClipStack.xcdatamodeld
```

---

## STEP 3 — Global Hotkey Implementation (`HotkeyManager.swift`)

This is the most critical service. Use the **Carbon Event Manager** so the hotkey works system-wide, even when ClipStack is not the focused app.

```swift
import Carbon

class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    var onHotkeyPressed: (() -> Void)?

    // Default: Cmd+Shift+V
    private var keyCode: UInt32 = UInt32(kVK_ANSI_V)
    private var modifiers: UInt32 = UInt32(cmdKey | shiftKey)

    func register(keyCode: UInt32? = nil, modifiers: UInt32? = nil) {
        unregister()

        if let k = keyCode { self.keyCode = k }
        if let m = modifiers { self.modifiers = m }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { manager.onHotkeyPressed?() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        var hotKeyID = EventHotKeyID(signature: OSType(0x434C5053), id: 1) // 'CLPS'
        RegisterEventHotKey(
            self.keyCode,
            self.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    func updateHotkey(keyCode: UInt32, modifiers: UInt32) {
        register(keyCode: keyCode, modifiers: modifiers)
        UserDefaults.standard.set(keyCode, forKey: "hotkeyKeyCode")
        UserDefaults.standard.set(modifiers, forKey: "hotkeyModifiers")
    }

    func loadSavedHotkey() {
        let savedKey = UserDefaults.standard.object(forKey: "hotkeyKeyCode") as? UInt32
        let savedMod = UserDefaults.standard.object(forKey: "hotkeyModifiers") as? UInt32
        register(
            keyCode: savedKey ?? UInt32(kVK_ANSI_V),
            modifiers: savedMod ?? UInt32(cmdKey | shiftKey)
        )
    }
}
```

Wire it up in `AppDelegate`:

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    setupMenuBar()
    HotkeyManager.shared.loadSavedHotkey()
    HotkeyManager.shared.onHotkeyPressed = { [weak self] in
        self?.togglePopup()
    }
}
```

`togglePopup()` must:
- If popup is **hidden** → show it (positioned under menu bar icon, or centered-top of screen if triggered by hotkey)
- If popup is **visible** → dismiss it
- Always auto-focus the search field when showing

---

## STEP 4 — Menu Bar Integration (`AppDelegate.swift`)

- Create `NSStatusItem` with variable length
- Icon: SF Symbol `"doc.on.clipboard.fill"`, template rendering (auto dark/light)
- **Left-click** on icon → `togglePopup()`
- **Right-click** on icon → minimal `NSMenu`:
  - "Open ClipStack" `(Cmd+Shift+V)`
  - "Settings…" `(Cmd+,)`
  - Separator
  - "Quit ClipStack" `(Cmd+Q)`

### Popup `NSPanel` Spec

| Property | Value |
|---|---|
| Style | `.borderless` + `.nonactivating` |
| Level | `.popUpMenu` |
| Title bar | None |
| Corner radius | `12pt` on `contentView.layer` |
| `isOpaque` | `false` |
| `backgroundColor` | `.clear` |
| `hasShadow` | `true` |

### Positioning Logic

- Get `statusItem` button frame in screen coordinates
- Position popup so its **top-right** aligns below the icon
- If triggered by hotkey (no click position) → center at **top of main screen**
- Clamp popup fully within screen bounds

### Show / Hide Animation

```swift
func showPopup() {
    panel.alphaValue = 0
    panel.makeKeyAndOrderFront(nil)
    NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.15
        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().alphaValue = 1
    }
    searchHostingView.rootView.focusSearch()
}

func hidePopup() {
    NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = 0.1
        panel.animator().alphaValue = 0
    }, completionHandler: {
        self.panel.orderOut(nil)
    })
}
```

### Dismiss on Outside Click

```swift
NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
    self?.hidePopup()
}
```

---

## STEP 5 — Clipboard Monitor (`ClipboardMonitor.swift`)

- Poll `NSPasteboard.general` every **0.5s** on a background `DispatchQueue`
- Track `changeCount` — only process when it increases
- Supported types (**priority order**):
  1. `NSImage` — screenshots, images from browsers / Figma / etc.
  2. `NSURL` — web and file URLs
  3. `NSColor` — from design tools
  4. `NSFilenamesPboardType` — Finder file copies
  5. `NSString` — plain text fallback
- Compute **SHA-256 hash** of content to skip true duplicates
- Detect source app: `NSWorkspace.shared.frontmostApplication` at copy time
- Skip **ignored apps** (compare bundle IDs against user's ignore list in `UserDefaults`)
  - Pre-populate defaults: `com.1password.1password`, `com.agilebits.onepassword`, `com.apple.keychainaccess`, `com.bitwarden.desktop`
- For URL type: async-fetch page `<title>` tag and cache it
- For image type: generate **60×60pt thumbnail** synchronously before storing
- Publish new `ClipItem` via `Combine` `PassthroughSubject<ClipItem, Never>`

---

## STEP 6 — Core Data Schema

**Entity: `ClipItem`**

| Attribute | Type | Notes |
|---|---|---|
| `id` | UUID | default `UUID()` |
| `content` | String | |
| `contentType` | String | `"text"`, `"url"`, `"image"`, `"file"`, `"color"` |
| `imageData` | Binary | optional, transformable |
| `colorHex` | String | optional |
| `appBundleId` | String | |
| `appName` | String | |
| `appIconData` | Binary | optional, small `NSImage` |
| `createdAt` | Date | |
| `isPinned` | Bool | default `false` |
| `useCount` | Integer 32 | default `0` |
| `urlTitle` | String | optional, async-fetched |
| `expiresAt` | Date | optional — set from TTL at insert time |

**Fetch request:**
- Sort: `isPinned DESC`, `createdAt DESC`
- Predicate: `expiresAt == nil OR expiresAt > NOW`
- Limit: user's `maxItems` setting (default `200`)

On every app launch and every hour: run a cleanup fetch to **delete expired items**.

---

## STEP 7 — Main Popup UI (`PopupView.swift`)

**Dimensions:** width `380pt`, max-height `520pt` (scrollable content inside)

```
┌─────────────────────────────────────┐  ← NSVisualEffectView (.popover material)
│  🔍  Search clipboard history...   │  ← SearchBarView, 44pt, auto-focused
├─────────────────────────────────────┤
│  📌 Pinned  ────────────────────   │  ← Section header (only if pinned items exist)
│  [pinned item row]                  │
│  [pinned item row]                  │
├─────────────────────────────────────┤
│  Recent  ───────────────────────   │  ← Section header
│  [clip row]                         │  ← ClipRowView, ~52pt each
│  [clip row]                         │
│  [clip row]  (scrollable)           │
│  ...                                │
├─────────────────────────────────────┤
│  ⚙️ Settings    🗑️ Clear    ✕ Quit │  ← Footer, 36pt tall
└─────────────────────────────────────┘
```

### Design Tokens

| Token | Value |
|---|---|
| Background | `NSVisualEffectView` material `.popover` |
| Row height | `52pt` |
| Row hover | `Color.accentColor.opacity(0.08)` |
| Row selected | `Color.accentColor.opacity(0.18)` |
| Section header | `10pt` uppercase gray |
| Footer | `11pt` gray icons with hover highlight |
| Corner radius | `12pt` |
| Border | `0.5pt Color.gray.opacity(0.2)` stroke |

---

## STEP 8 — Clip Row View (`ClipRowView.swift`)

### Layout (left → right)

1. **App icon** — `16×16pt`, rounded `3pt`, from stored `appIconData`
2. **Content preview:**
   - **Text** — first 80 chars, 1 line, truncated
   - **URL** — domain + async favicon (`16×16pt`) + `urlTitle` if fetched
   - **Image** — `48×36pt` thumbnail, `cornerRadius 4pt`
   - **Color** — `14pt` circle swatch + `"#FF5733"` hex label
   - **File** — system file icon (`16pt`) + filename
3. **Timestamp** — relative: `"Just now"`, `"5m"`, `"2h"`, `"Yesterday"` — `10pt` gray
4. **Pin icon** — SF Symbol `"pin.fill"` — visible on hover only (smooth opacity transition)

### Interactions

| Trigger | Action |
|---|---|
| Single click | Paste to previous app |
| Right-click | Context menu (see below) |
| `↑` `↓` | Navigate rows |
| `Enter` | Paste selected |
| `Delete` | Delete selected |
| `Cmd+P` | Pin / Unpin selected |
| `Escape` | Close popup |

**Context menu items:**
- Paste
- Copy without pasting
- *(separator)*
- Pin / Unpin
- Add Tag…
- *(separator)*
- Preview (QuickLook for images, open in browser for URLs)
- Delete *(confirm alert for pinned items)*

---

## STEP 9 — Settings Window (`SettingsView.swift`)

Open as a standard resizable `NSWindow` (not a sheet, not modal). Use `TabView` with SF Symbol icons.

---

### Tab 1 — General ⚙️

- **[Toggle]** Launch at login — `SMAppService.mainApp.register()`
- **[Toggle]** Show icon in menu bar
- **[Picker]** Menu bar icon style: Filled / Outline / Text badge `"CS"`
- **[Keyboard Shortcut Recorder]** Open ClipStack
  - Display current combo: `⌘⇧V`
  - Click to record a new combo (capture next key event)
  - On change: call `HotkeyManager.shared.updateHotkey(keyCode:modifiers:)`
  - "Reset to default" button → restores `Cmd+Shift+V`
- **[Toggle]** Close popup after pasting *(default: on)*
- **[Toggle]** Paste automatically on click *(default: on)*

---

### Tab 2 — History 📋

- **[Stepper / Slider]** Max items to keep: `10 – 10,000` *(default: 200)*
  - When reduced: delete oldest non-pinned items immediately
- **[Picker]** Item TTL:

  | Option | Value |
  |---|---|
  | 1 hour | `3600s` |
  | 6 hours | `21600s` |
  | 1 day | `86400s` |
  | 3 days | `259200s` |
  | 1 week | `604800s` *(default)* |
  | 1 month | `2592000s` |
  | Forever | `nil` |

  On change: recompute `expiresAt` for all existing items.

- **[Toggle]** Keep pinned items forever — ignores TTL *(default: on)*
- **[Toggle]** Save images in history *(default: on)*
- **[Stepper]** Max image storage: `50 MB – 2 GB` *(default: 200 MB)* — show current usage
- **[Button]** Clear all history now *(with confirmation alert)*

---

### Tab 3 — Privacy & Security 🔒

- **[Toggle]** Ignore password managers *(default: on)*
- **[List]** Ignored Applications
  - Pre-filled: 1Password, Bitwarden, Keychain Access, LastPass, Dashlane
  - `[+]` Add app → `NSOpenPanel` filtered to `.app` bundles
  - `[−]` Remove selected
- **[Toggle]** Pause monitoring — show `"Paused"` badge on menu bar icon
- **[Toggle]** Exclude regex patterns — e.g., credit card numbers
  - Text field to add pattern + live match preview
- **[Toggle]** Encrypt stored data (AES-256 via CryptoKit) — premium feature

---

### Tab 4 — Appearance 🎨 *(AI-suggested)*

- **[Picker]** Theme: System / Light / Dark
- **[Picker]** Popup position: Below icon / Center-top of screen / Last position
- **[Toggle]** Show app icon per item *(default: on)*
- **[Toggle]** Show timestamps *(default: on)*
- **[Slider]** Popup width: `300pt – 500pt` *(default: 380pt)*
- **[Picker]** Font size: Small `12pt` / Medium `13pt` / Large `15pt`
- **[Toggle]** Compact mode — reduces row height to `36pt`, text only

---

### Tab 5 — Smart Features 🤖 *(AI-suggested premium features)*

- **[Toggle]** Smart deduplication — merge items with same content regardless of source app
- **[Toggle]** Auto-organize by type — group text / images / URLs / files
- **[Toggle]** Quick actions — detect content type and show inline buttons:
  - Text with email → "Compose email"
  - URL → "Open / Copy URL / Copy domain"
  - Color hex → "Open in color picker"
  - Phone number → "Call / Message"
- **[Toggle]** Snippet templates — type `:sig` to expand to saved text
  - Manage snippets: name + expansion text
- **[Toggle]** Sync via iCloud *(show "Coming soon" badge)*
- **[Toggle]** Statistics dashboard — weekly copy/paste stats

---

### Tab 6 — About ℹ️

- App icon (`64pt`) + version number
- "You're on the latest version" / update check button
- License key field
- Links: Documentation, Report a Bug, Twitter, Email support
- **[Button]** Export all data as JSON
- **[Button]** Import data from Maccy *(parse Maccy's plist export)*

---

## STEP 10 — Keyboard Shortcut Recorder Component

Build a reusable `KeyboardShortcutRecorderView: NSViewRepresentable`.

**Behavior:**
- Displays current shortcut as pill-shaped badge: `⌘ ⇧ V`
- Click → enter recording mode → shows `"Press keys…"` pulsing
- Captures next key event (must include ≥ 1 modifier: `Cmd` / `Ctrl` / `Option` / `Shift`)
- Reject invalid combos (modifiers-only, reserved system shortcuts)
- `Escape` → cancel recording without saving
- `Delete` / `Backspace` → clear shortcut (disables hotkey)
- On valid capture: call `HotkeyManager.shared.updateHotkey()` immediately

**Modifier symbols:**

| Key | Symbol |
|---|---|
| Command | `⌘` |
| Shift | `⇧` |
| Option | `⌥` |
| Control | `⌃` |

---

## STEP 11 — Paste Simulation

```swift
func pasteItem(_ item: ClipItem) {
    // 1. Write to pasteboard
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    switch item.contentType {
    case "text", "url":
        pasteboard.setString(item.content, forType: .string)
    case "image":
        if let data = item.imageData, let img = NSImage(data: data) {
            pasteboard.writeObjects([img])
        }
    default:
        pasteboard.setString(item.content, forType: .string)
    }

    // 2. Close popup first (avoids focus issues)
    AppDelegate.shared.hidePopup()

    // 3. Activate previous app + simulate Cmd+V after short delay
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        if let prevApp = NSWorkspace.shared.runningApplications
            .first(where: { $0.isActive == false && $0.activationPolicy == .regular }) {
            prevApp.activate(options: .activateIgnoringOtherApps)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let src = CGEventSource(stateID: .hidSystemState)
            let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
            let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
            keyDown?.flags = .maskCommand
            keyUp?.flags   = .maskCommand
            keyDown?.post(tap: .cgAnnotatedSessionEventTap)
            keyUp?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
```

> **Note:** `CGEvent` posting requires **Accessibility permissions**.  
> Use `AXIsProcessTrustedWithOptions` to check and request on first launch.  
> Guide user to: **System Settings › Privacy & Security › Accessibility**

---

## STEP 12 — First Launch Experience

On very first launch, show a **welcome onboarding window** (3 swipeable slides):

1. **Slide 1:** "Welcome to ClipStack" — icon + tagline
2. **Slide 2:** "Your clipboard, supercharged" — explain main features
3. **Slide 3:** Grant permissions walkthrough:
   - Accessibility access (for paste simulation) → button opens System Settings
   - Explain: no data ever leaves the device

After onboarding:
- Show the popup once so the user knows where it lives
- Register default hotkey `Cmd+Shift+V`

---

## STEP 13 — Performance Requirements

| Metric | Target |
|---|---|
| Popup open time | < 100ms from hotkey press |
| Search filter | < 50ms for up to 1,000 items |
| Clipboard polling | Never blocks main thread |
| Core Data writes | Background context, merge to main |
| Image thumbnails | Generated once at insert, never re-generated |
| RAM at rest | < 50 MB |
| Favicon / icon cache | `NSCache` |

---

## STEP 14 — Build & Distribution

1. Set code signing to **"Sign to Run Locally"** for development

2. Create `build.sh`:

```bash
#!/bin/bash
xcodebuild -scheme ClipStack -configuration Release \
  -archivePath build/ClipStack.xcarchive archive

xcodebuild -exportArchive \
  -archivePath build/ClipStack.xcarchive \
  -exportPath build/ \
  -exportOptionsPlist ExportOptions.plist
```

3. Create a **DMG installer**:
   - Background image with arrow pointing to Applications folder
   - `brew install create-dmg && create-dmg ClipStack.dmg build/`

4. Add **Sparkle** framework (`SUFeedURL` in `Info.plist`) for future OTA updates

---

## ACCEPTANCE CRITERIA

- [ ] `Cmd+Shift+V` (customizable) opens/closes popup **system-wide**
- [ ] Clicking menu bar icon opens/closes popup
- [ ] Popup is **non-activating** (never steals focus from current app)
- [ ] New copies appear in list within **1 second**
- [ ] Clicking an item pastes it into the previously focused app
- [ ] Search filters in **real time**
- [ ] Pinned items survive TTL and app restart
- [ ] Items auto-expire based on TTL setting
- [ ] History limit enforced — oldest deleted when exceeded
- [ ] Password manager apps are **ignored**
- [ ] Settings persist across app restarts
- [ ] Hotkey changes take effect **immediately** without restart
- [ ] App launches at login when enabled
- [ ] Works in both **light and dark mode**
- [ ] Accessibility permission requested gracefully on first launch

---

*ClipStack — Built with Claude Code*
