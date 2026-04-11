import AppKit
import Carbon
import ServiceManagement

// MARK: - Logging

private let _logFileURL: URL = {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first!.appendingPathComponent("Copiha", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("copiha.log")
}()

/// Always written (Debug + Release). Use for real errors only.
func logError(_ message: String) { _writeLog("[ERROR] \(message)") }

/// Compiled away in Release builds — free in production.
func log(_ message: String) {
    #if DEBUG
    _writeLog("[DEBUG] \(message)")
    #endif
}

private func _writeLog(_ text: String) {
    let entry = "[\(Date())] \(text)\n"
    guard let data = entry.data(using: .utf8) else { return }
    // Rotate file when it exceeds 512 KB — keep last 256 KB
    if let attrs = try? FileManager.default.attributesOfItem(atPath: _logFileURL.path),
       let size = attrs[.size] as? Int, size > 512_000,
       let existing = try? String(contentsOf: _logFileURL, encoding: .utf8) {
        try? String(existing.suffix(256_000)).write(to: _logFileURL, atomically: true, encoding: .utf8)
    }
    if FileManager.default.fileExists(atPath: _logFileURL.path) {
        if let handle = FileHandle(forWritingAtPath: _logFileURL.path) {
            handle.seekToEndOfFile(); handle.write(data); handle.closeFile()
        }
    } else {
        try? data.write(to: _logFileURL)
    }
}

func copihaLogFileURL() -> URL { _logFileURL }

// GitHub release info
let kGitHubOwner = "ayoubahb"
let kGitHubRepo  = "Copiha"

// MARK: - KeyablePanel

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var panel: KeyablePanel!
    private enum TriggerSource { case hotkey, statusItem }
    private var isVisible = false
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hotkeyRef: EventHotKeyRef?
    private var previousApp: NSRunningApplication?

    // Clipboard
    private var clipboardItems: [ClipItem] = []
    private var lastChangeCount: Int = 0
    private var monitorTimer: Timer?

    // UI
    private var allHoverViews: [HoverView] = []   // all clickable rows for mouse hit detection
    private var itemsStack: NSStackView!
    private var scrollView: NSScrollView!
    private var emptyLabel: NSTextField!
    private var searchField: NSTextField!
    private var scrollTopConstraint: NSLayoutConstraint!
    private var scrollBottomConstraint: NSLayoutConstraint!
    private var searchIcon: NSImageView!
    private var footerViews: [NSView] = []
    private var previewPanel: NSPanel?
    private var hoveredItemIndex: Int?
    private var selectedIndex: Int? = nil
    private var preferencesWindow: PreferencesWindow?
    private var onboardingController: OnboardingWindowController?
    private var isPinned: Bool = false
    private weak var pinButton: NSButton?
    private weak var toastView: NSView?
    private var toastWorkItem: DispatchWorkItem?
    private weak var pauseFooterIcon: NSImageView?
    private weak var pauseFooterLabel: NSTextField?

    // Search
    private var searchText: String = ""
    private var filteredItems: [ClipItem] {
        var items = clipboardItems
        // Apply sort
        switch Prefs.shared.sortOrder {
        case .lastCopy:      break  // already sorted by lastCopied (insertion order)
        case .copyCount:     items.sort { $0.copyCount > $1.copyCount }
        case .alphabetical:  items.sort { $0.text.localizedCaseInsensitiveCompare($1.text) == .orderedAscending }
        }
        guard !searchText.isEmpty else { return items }
        return items.filter {
            switch Prefs.shared.searchMode {
            case .fuzzy:  return fuzzyMatch(searchText, in: $0.text)
            case .exact:  return $0.text.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    private func fuzzyMatch(_ query: String, in target: String) -> Bool {
        let q = query.lowercased()
        let t = target.lowercased()
        var qi = q.startIndex
        for ch in t {
            guard qi < q.endIndex else { break }
            if ch == q[qi] { qi = q.index(after: qi) }
        }
        return qi == q.endIndex
    }

    private var panelWidth: CGFloat = 420
    private var userPanelHeight: CGFloat? = nil  // nil = auto from item count
    private let defaultVisibleRows: Int = 8
    private let rowHeight: CGFloat = 34
    private let headerHeight: CGFloat = 52
    private let footerRowHeight: CGFloat = 60
    private let footerCount: Int = 1
    private let maxVisibleRows: Int = 12
    private var footerHeight: CGFloat { footerRowHeight + 1 }

    func applicationWillTerminate(_ notification: Notification) {
        if Prefs.shared.clearHistoryOnQuit {
            clipboardItems.removeAll()
            Store.shared.save(clipboardItems)
        }
        if Prefs.shared.clearClipboardOnQuit {
            NSPasteboard.general.clearContents()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        log("=== Copiha launched ===")
        clipboardItems = Store.shared.load()
        applyTTL()
        setupPanel()
        setupStatusItem()
        updateStatusIcon()
        startMonitoring()
        setupGlobalHotkey()
        showOnboardingIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.checkForUpdates() }
        // Note: Accessibility is only requested when the user enables auto-paste or via onboarding
    }

    private func applyTTL() {
        let days = Prefs.shared.historyTTLDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let before = clipboardItems.count
        clipboardItems.removeAll { $0.lastCopied < cutoff }
        if clipboardItems.count != before {
            Store.shared.save(clipboardItems)
            log("TTL removed \(before - clipboardItems.count) expired items")
        }
    }

    // MARK: - Update checker

    func checkForUpdates(userInitiated: Bool = false) {
        let apiURL = "https://api.github.com/repos/\(kGitHubOwner)/\(kGitHubRepo)/releases/latest"
        guard let url = URL(string: apiURL) else { return }
        var request = URLRequest(url: url)
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        request.setValue("Copiha/\(current)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            if let error { logError("Update check failed: \(error)") }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                if userInitiated {
                    DispatchQueue.main.async { self?.showAlert("Could not check for updates.", info: "Check your internet connection.") }
                }
                return
            }
            let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            // Find DMG asset URL
            let dmgURL: String? = (json["assets"] as? [[String: Any]])?.compactMap {
                ($0["browser_download_url"] as? String)
            }.first(where: { $0.hasSuffix(".dmg") })

            DispatchQueue.main.async {
                if latest.compare(current, options: .numeric) == .orderedDescending {
                    let alert = NSAlert()
                    alert.messageText = "Update Available — v\(latest)"
                    alert.informativeText = "You have v\(current). Copiha will download and install v\(latest) automatically."
                    alert.addButton(withTitle: "Update Now")
                    alert.addButton(withTitle: "Later")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    if let dmgURL, let downloadURL = URL(string: dmgURL) {
                        self?.downloadAndInstallUpdate(from: downloadURL, version: latest)
                    } else if let pageURL = json["html_url"] as? String, let url = URL(string: pageURL) {
                        NSWorkspace.shared.open(url)
                    }
                } else if userInitiated {
                    self?.showAlert("Copiha is up to date.", info: "You have the latest version (v\(current)).")
                }
            }
        }.resume()
    }

    private func downloadAndInstallUpdate(from url: URL, version: String) {
        // Show progress window
        let progressWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        progressWindow.title = "Updating Copiha"
        progressWindow.center()
        progressWindow.isReleasedWhenClosed = false

        let label = NSTextField(labelWithString: "Downloading v\(version)…")
        label.translatesAutoresizingMaskIntoConstraints = false
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.minValue = 0; bar.maxValue = 1; bar.doubleValue = 0
        bar.isIndeterminate = false
        bar.translatesAutoresizingMaskIntoConstraints = false

        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label); box.addSubview(bar)
        progressWindow.contentView = box
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 20),
            label.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
            bar.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -20),
            bar.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -20),
        ])
        progressWindow.makeKeyAndOrderFront(nil)

        let destURL = FileManager.default.temporaryDirectory.appendingPathComponent("Copiha-\(version).dmg")
        let task = URLSession.shared.downloadTask(with: url) { [weak progressWindow] tmpURL, _, error in
            DispatchQueue.main.async {
                progressWindow?.close()
                if let error {
                    logError("Update download failed: \(error)")
                    self.showAlert("Download failed.", info: error.localizedDescription)
                    return
                }
                guard let tmpURL else { return }
                do {
                    if FileManager.default.fileExists(atPath: destURL.path) {
                        try FileManager.default.removeItem(at: destURL)
                    }
                    try FileManager.default.moveItem(at: tmpURL, to: destURL)
                    self.installUpdate(dmgURL: destURL, version: version)
                } catch {
                    logError("Update move failed: \(error)")
                    self.showAlert("Update failed.", info: error.localizedDescription)
                }
            }
        }
        task.addObserver(self, forKeyPath: "countOfBytesReceived", options: .new, context: nil)
        task.addObserver(self, forKeyPath: "countOfBytesExpectedToReceive", options: .new, context: nil)
        self._updateProgressBar = bar
        self._updateTask = task
        task.resume()
    }

    private var _updateProgressBar: NSProgressIndicator?
    private var _updateTask: URLSessionDownloadTask?

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard let task = _updateTask,
              task.countOfBytesExpectedToReceive > 0 else { return }
        let progress = Double(task.countOfBytesReceived) / Double(task.countOfBytesExpectedToReceive)
        DispatchQueue.main.async { self._updateProgressBar?.doubleValue = progress }
    }

    private func installUpdate(dmgURL: URL, version: String) {
        let mountPoint = "/Volumes/Copiha-update-\(version)"
        let appDest = "/Applications/Copiha.app"
        let newAppPath = "\(mountPoint)/Copiha.app"
        let currentAppPath = Bundle.main.bundlePath

        // Mount DMG
        let mount = Process()
        mount.launchPath = "/usr/bin/hdiutil"
        mount.arguments = ["attach", dmgURL.path, "-mountpoint", mountPoint, "-nobrowse", "-quiet"]
        mount.launch(); mount.waitUntilExit()
        guard mount.terminationStatus == 0,
              FileManager.default.fileExists(atPath: newAppPath) else {
            showAlert("Install failed.", info: "Could not mount the update disk image.")
            return
        }

        // Write relaunch script — copies app, detaches DMG, relaunches
        let relaunchTarget = FileManager.default.fileExists(atPath: appDest) ? appDest : currentAppPath
        let script = """
        #!/bin/bash
        sleep 1
        rm -rf "\(relaunchTarget)"
        cp -R "\(newAppPath)" "\(relaunchTarget)"
        hdiutil detach "\(mountPoint)" -quiet
        open "\(relaunchTarget)"
        """
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("copiha_update.sh")
        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let launcher = Process()
        launcher.launchPath = "/bin/bash"
        launcher.arguments = [scriptURL.path]
        launcher.launch()

        NSApp.terminate(nil)
    }

    private func showAlert(_ message: String, info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Panel

    private func setupPanel() {
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 300),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.minSize = NSSize(width: 320, height: headerHeight + footerHeight + rowHeight + 2)

        let root = PanelRootView()                 // custom root to forward resize
        root.wantsLayer = true
        root.layer?.cornerRadius = 16
        root.layer?.masksToBounds = true

        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        bg.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bg)
        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: root.topAnchor),
            bg.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bg.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])

        panel.contentView = root
        buildHeader(in: root)
        buildScrollArea(in: root)
        buildFooter(in: root)
        buildResizeHandle(in: root)
        buildEdgeResizeHandles(in: root)
        reloadRows()
    }

    // MARK: - Header

    private func buildHeader(in parent: NSView) {
        let dragArea = DragHeaderView()
        dragArea.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(dragArea)
        NSLayoutConstraint.activate([
            dragArea.topAnchor.constraint(equalTo: parent.topAnchor),
            dragArea.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            dragArea.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            dragArea.heightAnchor.constraint(equalToConstant: headerHeight),
        ])

        // Pill container
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        pill.layer?.cornerRadius = 8
        pill.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(pill)

        searchIcon = NSImageView()
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.translatesAutoresizingMaskIntoConstraints = false

        searchField = NSTextField()
        searchField.placeholderString = "Search…"
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.font = NSFont.systemFont(ofSize: 13)
        searchField.focusRingType = .none
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self

        pill.addSubview(searchIcon)
        pill.addSubview(searchField)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(divider)

        // Pin button (top-right of header) + shortcut label
        let pinBtn = NSButton()
        pinBtn.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "Pin panel")
        pinBtn.bezelStyle = .regularSquare
        pinBtn.isBordered = false
        pinBtn.contentTintColor = .secondaryLabelColor
        pinBtn.target = self
        pinBtn.action = #selector(togglePin)
        pinBtn.toolTip = "Pin panel (⌘P)"
        pinBtn.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(pinBtn)
        pinButton = pinBtn

        let pinShortcutLabel = NSTextField(labelWithString: "⌘P")
        pinShortcutLabel.font = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
        pinShortcutLabel.textColor = .tertiaryLabelColor
        pinShortcutLabel.alignment = .center
        pinShortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(pinShortcutLabel)

        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 12),
            pill.trailingAnchor.constraint(equalTo: pinBtn.leadingAnchor, constant: -6),
            pill.centerYAnchor.constraint(equalTo: parent.topAnchor, constant: headerHeight / 2),
            pill.heightAnchor.constraint(equalToConstant: 28),

            searchIcon.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 8),
            searchIcon.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 13),
            searchIcon.heightAnchor.constraint(equalToConstant: 13),

            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 6),
            searchField.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
            searchField.centerYAnchor.constraint(equalTo: pill.centerYAnchor),

            divider.topAnchor.constraint(equalTo: parent.topAnchor, constant: headerHeight),
            divider.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            pinBtn.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -10),
            pinBtn.topAnchor.constraint(equalTo: parent.topAnchor, constant: 10),
            pinBtn.widthAnchor.constraint(equalToConstant: 20),
            pinBtn.heightAnchor.constraint(equalToConstant: 20),

            pinShortcutLabel.centerXAnchor.constraint(equalTo: pinBtn.centerXAnchor),
            pinShortcutLabel.topAnchor.constraint(equalTo: pinBtn.bottomAnchor, constant: 2),
        ])
    }

    // MARK: - Scroll area

    private func buildScrollArea(in parent: NSView) {
        itemsStack = NSStackView()
        itemsStack.orientation = .vertical
        itemsStack.spacing = 0
        itemsStack.translatesAutoresizingMaskIntoConstraints = false

        // FlippedView makes NSScrollView stack content from the top
        let container = FlippedView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(itemsStack)
        NSLayoutConstraint.activate([
            itemsStack.topAnchor.constraint(equalTo: container.topAnchor),
            itemsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            itemsStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            itemsStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = container
        container.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true

        parent.addSubview(scrollView)

        scrollTopConstraint = scrollView.topAnchor.constraint(equalTo: parent.topAnchor, constant: headerHeight + 1)
        scrollBottomConstraint = scrollView.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -(footerHeight + 1))
        NSLayoutConstraint.activate([
            scrollTopConstraint,
            scrollBottomConstraint,
            scrollView.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        ])

        emptyLabel = NSTextField(labelWithString: "Nothing copied yet")
        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
    }

    // MARK: - Footer

    private func buildFooter(in parent: NSView) {
        footerViews.removeAll()

        // subtle top divider
        let topDivider = NSView()
        topDivider.wantsLayer = true
        topDivider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(topDivider)
        footerViews.append(topDivider)
        NSLayoutConstraint.activate([
            topDivider.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -footerHeight),
            topDivider.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 1),
        ])

        // icon-only horizontal bar
        let bar = HoverView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.isFooter = false   // handled per-button via individual HoverViews below
        parent.addSubview(bar)
        footerViews.append(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: footerRowHeight),
        ])

        let footerItems: [(String, String, String, Selector)] = [
            ("trash",                  "Clear",        "⌥⇧⌘⌫", #selector(clearAll)),
            ("arrow.counterclockwise", "Reset",        "⌘0",    #selector(resetPanelSize)),
            ("gear",                   "Preferences",  "⌘,",    #selector(openPreferences)),
            ("info.circle",            "About",        "⌘I",    #selector(showAbout)),
            ("power",                  "Quit",         "⌘Q",    #selector(quitApp)),
        ]
        let totalFooterCount = footerItems.count + 1  // +1 for pause button

        var prevAnchor = bar.leadingAnchor
        for (symbol, title, shortcut, action) in footerItems {
            let btn = HoverView()
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.isFooter = true

            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            icon.contentTintColor = .secondaryLabelColor
            icon.translatesAutoresizingMaskIntoConstraints = false

            let titleLabel = LabelView.make(title)
            titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            titleLabel.textColor = .secondaryLabelColor
            titleLabel.alignment = .center

            let shortcutLabel = LabelView.make(shortcut)
            shortcutLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            shortcutLabel.textColor = .secondaryLabelColor
            shortcutLabel.alignment = .center

            btn.addSubview(icon)
            btn.addSubview(titleLabel)
            btn.addSubview(shortcutLabel)
            bar.addSubview(btn)

            NSLayoutConstraint.activate([
                btn.topAnchor.constraint(equalTo: bar.topAnchor),
                btn.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
                btn.leadingAnchor.constraint(equalTo: prevAnchor),
                btn.widthAnchor.constraint(equalTo: bar.widthAnchor, multiplier: 1.0 / CGFloat(totalFooterCount)),

                icon.centerXAnchor.constraint(equalTo: btn.centerXAnchor),
                icon.topAnchor.constraint(equalTo: btn.topAnchor, constant: 9),
                icon.widthAnchor.constraint(equalToConstant: 13),
                icon.heightAnchor.constraint(equalToConstant: 13),

                titleLabel.centerXAnchor.constraint(equalTo: btn.centerXAnchor),
                titleLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 3),
                titleLabel.leadingAnchor.constraint(equalTo: btn.leadingAnchor, constant: 2),
                titleLabel.trailingAnchor.constraint(equalTo: btn.trailingAnchor, constant: -2),

                shortcutLabel.centerXAnchor.constraint(equalTo: btn.centerXAnchor),
                shortcutLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
                shortcutLabel.leadingAnchor.constraint(equalTo: btn.leadingAnchor, constant: 2),
                shortcutLabel.trailingAnchor.constraint(equalTo: btn.trailingAnchor, constant: -2),
            ])

            let sel = action
            btn.debugLabel = "footer-\(title)"
            btn.onClicked = { [weak self] in self?.perform(sel) }
            allHoverViews.append(btn)
            footerViews.append(btn)

            prevAnchor = btn.trailingAnchor
        }

        // Pause / Resume button (dynamic — stored refs for live updates)
        let pauseBtn = HoverView()
        pauseBtn.translatesAutoresizingMaskIntoConstraints = false
        pauseBtn.isFooter = true

        let pauseIcon = NSImageView()
        pauseIcon.translatesAutoresizingMaskIntoConstraints = false

        let pauseLabel = LabelView.make("")
        pauseLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        pauseLabel.alignment = .center

        let pauseShortcut = LabelView.make("⌘⇧P")
        pauseShortcut.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        pauseShortcut.textColor = .secondaryLabelColor
        pauseShortcut.alignment = .center

        pauseBtn.addSubview(pauseIcon)
        pauseBtn.addSubview(pauseLabel)
        pauseBtn.addSubview(pauseShortcut)
        bar.addSubview(pauseBtn)

        NSLayoutConstraint.activate([
            pauseBtn.topAnchor.constraint(equalTo: bar.topAnchor),
            pauseBtn.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            pauseBtn.leadingAnchor.constraint(equalTo: prevAnchor),
            pauseBtn.trailingAnchor.constraint(equalTo: bar.trailingAnchor),

            pauseIcon.centerXAnchor.constraint(equalTo: pauseBtn.centerXAnchor),
            pauseIcon.topAnchor.constraint(equalTo: pauseBtn.topAnchor, constant: 9),
            pauseIcon.widthAnchor.constraint(equalToConstant: 13),
            pauseIcon.heightAnchor.constraint(equalToConstant: 13),

            pauseLabel.centerXAnchor.constraint(equalTo: pauseBtn.centerXAnchor),
            pauseLabel.topAnchor.constraint(equalTo: pauseIcon.bottomAnchor, constant: 3),
            pauseLabel.leadingAnchor.constraint(equalTo: pauseBtn.leadingAnchor, constant: 2),
            pauseLabel.trailingAnchor.constraint(equalTo: pauseBtn.trailingAnchor, constant: -2),

            pauseShortcut.centerXAnchor.constraint(equalTo: pauseBtn.centerXAnchor),
            pauseShortcut.topAnchor.constraint(equalTo: pauseLabel.bottomAnchor, constant: 1),
            pauseShortcut.leadingAnchor.constraint(equalTo: pauseBtn.leadingAnchor, constant: 2),
            pauseShortcut.trailingAnchor.constraint(equalTo: pauseBtn.trailingAnchor, constant: -2),
        ])

        pauseFooterIcon = pauseIcon
        pauseFooterLabel = pauseLabel
        allHoverViews.append(pauseBtn)
        pauseBtn.debugLabel = "footer-Pause"
        pauseBtn.onClicked = { [weak self] in self?.togglePauseMonitoring() }
        footerViews.append(pauseBtn)

        updatePauseButton()
    }

    // MARK: - Resize handle

    private func buildResizeHandle(in parent: NSView) {
        let handle = ResizeHandleView(panel: panel)
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.onResized = { [weak self] _, newHeight in
            self?.userPanelHeight = newHeight
            self?.panelWidth = self?.panel.frame.width ?? 420
        }
        parent.addSubview(handle)
        NSLayoutConstraint.activate([
            handle.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            handle.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            handle.widthAnchor.constraint(equalToConstant: 20),
            handle.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    private func buildEdgeResizeHandles(in parent: NSView) {
        // Right edge — drag to resize width
        let right = EdgeResizeView(edge: .right, panel: panel)
        right.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(right)
        NSLayoutConstraint.activate([
            right.topAnchor.constraint(equalTo: parent.topAnchor),
            right.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -20),
            right.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            right.widthAnchor.constraint(equalToConstant: 6),
        ])

        // Left edge — drag to resize width from the left
        let left = EdgeResizeView(edge: .left, panel: panel)
        left.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(left)
        NSLayoutConstraint.activate([
            left.topAnchor.constraint(equalTo: parent.topAnchor),
            left.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            left.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            left.widthAnchor.constraint(equalToConstant: 6),
        ])

        // Bottom edge — drag to resize height
        let bottom = EdgeResizeView(edge: .bottom, panel: panel)
        bottom.onResized = { [weak self] _, newHeight in self?.userPanelHeight = newHeight }
        bottom.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(bottom)
        NSLayoutConstraint.activate([
            bottom.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            bottom.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 6),
            bottom.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -20),
            bottom.heightAnchor.constraint(equalToConstant: 6),
        ])
    }

    // MARK: - Rows

    private func reloadRows() {
        selectedIndex = nil
        allHoverViews.removeAll { $0.debugLabel.hasPrefix("item-") }
        itemsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        emptyLabel.isHidden = !filteredItems.isEmpty
        emptyLabel.stringValue = clipboardItems.isEmpty ? "Nothing copied yet" : "No results for \"\(searchText)\""

        for (index, item) in filteredItems.enumerated() {
            let row = makeItemRow(item: item, index: index)
            itemsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: itemsStack.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true

            if index < filteredItems.count - 1 {
                let spacer = NSView()
                spacer.translatesAutoresizingMaskIntoConstraints = false
                itemsStack.addArrangedSubview(spacer)
                spacer.widthAnchor.constraint(equalTo: itemsStack.widthAnchor).isActive = true
                spacer.heightAnchor.constraint(equalToConstant: 1).isActive = true
            }
        }

        resizePanel()
    }

    private func makeItemRow(item: ClipItem, index: Int) -> NSView {
        let hover = HoverView()
        hover.translatesAutoresizingMaskIntoConstraints = false

        // Collapse multi-line text to single line, hard-cap at 300 chars for display
        let joined = item.text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let displayText = joined.count > 300 ? String(joined.prefix(300)) + "…" : joined

        let label = LabelView.make(displayText)
        label.font = NSFont.systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let shortcutText = index < 9 ? "⌘\(index + 1)" : ""
        let hint = LabelView.make(shortcutText)
        hint.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        hint.textColor = .secondaryLabelColor

        hover.addSubview(label)
        hover.addSubview(hint)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: hover.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: hint.leadingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: hover.centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: hover.trailingAnchor, constant: -16),
            hint.centerYAnchor.constraint(equalTo: hover.centerYAnchor),
            hint.widthAnchor.constraint(equalToConstant: 28),
        ])

        hover.debugLabel = "item-\(index)"
        hover.onClicked = { [weak self] in
            guard let self, self.filteredItems.indices.contains(index) else { return }
            log("Row clicked: index=\(index)")
            self.pasteItem(self.filteredItems[index].text)
        }
        allHoverViews.insert(hover, at: index)
        return hover
    }

    @objc private func clearAll() {
        log("Clear all")
        clipboardItems.removeAll()
        Store.shared.save(clipboardItems)
        reloadRows()
    }

    @objc private func resetPanelSize() {
        log("Reset panel size")
        userPanelHeight = nil
        panelWidth = 420
        resizePanel()
        var frame = panel.frame
        frame.size.width = panelWidth
        frame.origin.x = frame.maxX - panelWidth
        panel.setFrame(frame, display: true, animate: true)
    }

    @objc private func openPreferences() {
        log("openPreferences called")
        hidePanel()
        if preferencesWindow == nil {
            log("Creating PreferencesWindow")
            preferencesWindow = PreferencesWindow()
            preferencesWindow?.onClose = { [weak self] in
                log("Preferences window closed")
                NSApp.setActivationPolicy(.accessory)
                self?.preferencesWindow = nil
            }
        }
        // Switch to regular so the window can become key
        NSApp.setActivationPolicy(.regular)
        preferencesWindow?.showWindow(nil)
        preferencesWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        log("Preferences window shown")
    }

    @objc private func quitApp() {
        log("Quit")
        NSApp.terminate(nil)
    }

    @objc private func showAbout() {
        hidePanel()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.1"
        let year = Calendar.current.component(.year, from: Date())
        let alert = NSAlert()
        alert.messageText = "Copiha"
        alert.informativeText = "Version \(version)\n\nA lightweight clipboard manager for macOS.\nStores your clipboard history locally — no data ever leaves your Mac.\n\n© \(year) Ayoubahb"
        alert.icon = NSImage(named: NSImage.applicationIconName)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "View on GitHub")
        if alert.runModal() == .alertSecondButtonReturn,
           let url = URL(string: "https://github.com/\(kGitHubOwner)/\(kGitHubRepo)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showOnboardingIfNeeded() {
        // If the app data directory doesn't exist this is a fresh install — always show onboarding
        let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("Copiha", isDirectory: true)
        let dataFile = appSupportDir.appendingPathComponent("history.json")
        if !FileManager.default.fileExists(atPath: dataFile.path) {
            Prefs.shared.hasSeenOnboarding = false
        }
        guard !Prefs.shared.hasSeenOnboarding else { return }
        let controller = OnboardingWindowController()
        controller.onDismiss = { [weak self] in
            Prefs.shared.hasSeenOnboarding = true
            NSApp.setActivationPolicy(.accessory)
            self?.onboardingController = nil
        }
        onboardingController = controller
        NSApp.setActivationPolicy(.regular)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Pin

    @objc private func togglePin() {
        isPinned.toggle()
        updatePinButton()
    }

    private func updatePinButton() {
        let symbol = isPinned ? "pin.fill" : "pin"
        pinButton?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Pin panel")
        pinButton?.contentTintColor = isPinned ? .controlAccentColor : .secondaryLabelColor
    }

    @objc private func panelDidResignKey() {
        guard isPinned else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0.45
        }
    }

    @objc private func panelDidBecomeKey() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        }
    }

    // MARK: - Copied toast

    private func showCopiedToast() {
        guard let root = panel.contentView else { return }

        // Cancel any in-flight toast
        toastWorkItem?.cancel()
        toastView?.removeFromSuperview()

        // --- Build toast ---
        let toast = NSVisualEffectView()
        toast.material = .hudWindow
        toast.blendingMode = .withinWindow
        toast.state = .active
        toast.wantsLayer = true
        toast.layer?.cornerRadius = 18
        toast.layer?.masksToBounds = true
        toast.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        let cfg = NSImage.SymbolConfiguration(pointSize: 32, weight: .medium)
        iconView.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                                 accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "Copied")
        label.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [iconView, label])
        stack.orientation = .vertical
        stack.spacing = 7
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        toast.addSubview(stack)
        root.addSubview(toast)

        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toast.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            toast.widthAnchor.constraint(equalToConstant: 120),
            toast.heightAnchor.constraint(equalToConstant: 90),

            stack.centerXAnchor.constraint(equalTo: toast.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: toast.centerYAnchor),
        ])

        toastView = toast

        // --- Animate in: fade items out, toast in ---
        toast.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            toast.animator().alphaValue = 1
            scrollView.animator().alphaValue = 0.08
        }

        // --- Animate out after hold ---
        let workItem = DispatchWorkItem { [weak self, weak toast] in
            guard let self, let toast else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                toast.animator().alphaValue = 0
                self.scrollView.animator().alphaValue = 1
            }, completionHandler: {
                toast.removeFromSuperview()
            })
        }
        toastWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: workItem)
    }

    // MARK: - Resize panel height

    private func resizePanel() {
        let minH = headerHeight + 1 + rowHeight + 1 + footerHeight
        let totalH: CGFloat
        if let userH = userPanelHeight {
            totalH = max(userH, minH)
        } else {
            let count = min(filteredItems.count, defaultVisibleRows)
            let listH: CGFloat = filteredItems.isEmpty ? rowHeight : CGFloat(count) * rowHeight
            totalH = headerHeight + 1 + listH + 1 + footerHeight
        }
        var frame = panel.frame
        let delta = frame.height - totalH
        frame.size = NSSize(width: frame.width, height: totalH)
        frame.origin.y += delta
        panel.setFrame(frame, display: true, animate: false)
    }

    // MARK: - Accessibility

    private func requestAccessibilityIfNeeded() {
        if AXIsProcessTrusted() {
            log("Accessibility already granted")
            return
        }
        log("Requesting Accessibility permission")
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    // MARK: - Global hotkey

    private func setupGlobalHotkey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),
                            { _, event, userData -> OSStatus in
                                guard let userData else { return OSStatus(eventNotHandledErr) }
                                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                                delegate.toggle()
                                return noErr
                            },
                            1, &eventType,
                            Unmanaged.passUnretained(self).toOpaque(),
                            nil)
        registerHotkey()
    }

    private func registerHotkey() {
        if let ref = hotkeyRef { UnregisterEventHotKey(ref); hotkeyRef = nil }
        let hotkeyID = EventHotKeyID(signature: OSType(0x4353544B), id: 1)
        RegisterEventHotKey(Prefs.shared.hotkeyKeyCode, Prefs.shared.hotkeyModifiers,
                            hotkeyID, GetApplicationEventTarget(), 0, &hotkeyRef)
        log("Hotkey registered: \(HotkeyRecorderView.hotkeyString(keyCode: Prefs.shared.hotkeyKeyCode, modifiers: Prefs.shared.hotkeyModifiers))")
    }

    func reregisterHotkey() {
        registerHotkey()
    }

    @objc func toggle() {
        isVisible ? hidePanel(force: true) : showPanel(source: .hotkey)
    }

    @objc private func statusItemToggle() {
        isVisible ? hidePanel(force: true) : showPanel(source: .statusItem)
    }

    // MARK: - Local key monitor (⌘1–⌘9 while panel is open)

    private func startLocalMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseUp, .rightMouseUp, .mouseMoved]) { [weak self] event in
            guard let self else { return event }

            // Mouse moved — update hover highlight + preview popup
            if event.type == .mouseMoved {
                guard let contentView = self.panel.contentView else { return event }
                let point = contentView.convert(event.locationInWindow, from: nil)
                var newHoveredIndex: Int? = nil
                let scrollVisibleRect = self.scrollView.convert(self.scrollView.bounds, to: contentView)
                for view in self.allHoverViews {
                    let frame = view.convert(view.bounds, to: contentView)
                    // For item rows, clip to the scroll view's visible area so off-screen items
                    // below the footer don't register as hovered
                    let hitFrame = view.debugLabel.hasPrefix("item-")
                        ? frame.intersection(scrollVisibleRect)
                        : frame
                    let hovered = !hitFrame.isNull && hitFrame.contains(point)
                    if hovered != view.isHovered {
                        view.isHovered = hovered
                        view.setHighlight(hovered)
                    }
                    if hovered, view.debugLabel.hasPrefix("item-"),
                       let idx = Int(view.debugLabel.dropFirst(5)) {
                        newHoveredIndex = idx
                    }
                }
                if newHoveredIndex != self.hoveredItemIndex {
                    self.hoveredItemIndex = newHoveredIndex
                    if let idx = newHoveredIndex,
                       self.filteredItems.indices.contains(idx),
                       Prefs.shared.showPreviewOnHover {
                        let delay = Double(Prefs.shared.previewDelay) / 1000.0
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            guard self.hoveredItemIndex == idx else { return }
                            self.showPreviewPopup(for: self.filteredItems[idx], rowIndex: idx)
                        }
                    } else {
                        self.hidePreviewPopup()
                    }
                }
                return event
            }

            // Right-click — show context menu on item rows
            if event.type == .rightMouseUp {
                guard let contentView = self.panel.contentView else { return event }
                let point = contentView.convert(event.locationInWindow, from: nil)
                for view in self.allHoverViews {
                    guard view.debugLabel.hasPrefix("item-"),
                          let idx = Int(view.debugLabel.dropFirst(5)) else { continue }
                    let frame = view.convert(view.bounds, to: contentView)
                    if frame.contains(point) {
                        self.showItemContextMenu(for: idx, in: view)
                        return nil
                    }
                }
                return event
            }

            // Mouse click — find which HoverView was clicked
            if event.type == .leftMouseUp {
                guard let contentView = self.panel.contentView else { return event }
                let pointInContent = contentView.convert(event.locationInWindow, from: nil)
                var hitView = contentView.hitTest(pointInContent)
                while let v = hitView {
                    if let hover = v as? HoverView {
                        hover.onClicked?()
                        return nil
                    }
                    hitView = v.superview
                }
                return event
            }
            // Key events below
            // ↓ Arrow down — move selection down
            if event.keyCode == 125 {
                let count = self.filteredItems.count
                guard count > 0 else { return nil }
                let next = self.selectedIndex.map { min($0 + 1, count - 1) } ?? 0
                self.setKeyboardSelection(next)
                return nil
            }
            // ↑ Arrow up — move selection up
            if event.keyCode == 126 {
                let count = self.filteredItems.count
                guard count > 0 else { return nil }
                if let cur = self.selectedIndex, cur > 0 {
                    self.setKeyboardSelection(cur - 1)
                } else {
                    self.setKeyboardSelection(0)
                }
                return nil
            }
            // ↩ Return / Enter — paste selected item
            if event.keyCode == 36 || event.keyCode == 76 {
                if let idx = self.selectedIndex, self.filteredItems.indices.contains(idx) {
                    self.pasteItem(self.filteredItems[idx].text)
                }
                return nil
            }
            // ⌘1–⌘9
            if event.modifierFlags.contains(.command),
               let ch = event.charactersIgnoringModifiers,
               let digit = Int(ch), (1...9).contains(digit) {
                let index = digit - 1
                if self.filteredItems.indices.contains(index) {
                    log("⌘\(digit) pressed — pasting item \(index)")
                    self.pasteItem(self.filteredItems[index].text)
                }
                return nil  // consume event
            }
            // Escape closes panel (always, even when pinned)
            if event.keyCode == 53 {
                self.hidePanel(force: true)
                return nil
            }
            // ⌘Q — quit
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "q" {
                self.quitApp()
                return nil
            }
            // ⌘0 — reset size
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "0" {
                self.resetPanelSize()
                return nil
            }
            // ⌘, — preferences
            if event.modifierFlags.contains(.command),
               event.keyCode == 43 {
                self.openPreferences()
                return nil
            }
            // ⌘I — about
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "i" {
                self.showAbout()
                return nil
            }
            // ⌘P — toggle pin
            if event.modifierFlags.contains(.command),
               !event.modifierFlags.contains(.shift),
               event.charactersIgnoringModifiers?.lowercased() == "p" {
                self.togglePin()
                return nil
            }
            // ⌘⇧P — toggle pause monitoring
            if event.modifierFlags.contains([.command, .shift]),
               event.charactersIgnoringModifiers?.lowercased() == "p" {
                self.togglePauseMonitoring()
                return nil
            }
            // ⌥⌫ — delete selected (keyboard) or hovered (mouse) item
            if event.modifierFlags.contains(.option),
               !event.modifierFlags.contains(.command),
               !event.modifierFlags.contains(.shift),
               event.keyCode == 51 {
                let idx = self.selectedIndex ?? self.hoveredItemIndex
                if let idx {
                    self.deleteItem(at: idx)
                    // Keep selection in bounds after deletion
                    let remaining = self.filteredItems.count
                    if remaining > 0 {
                        self.setKeyboardSelection(min(idx, remaining - 1))
                    } else {
                        self.selectedIndex = nil
                    }
                }
                return nil
            }
            // ⌥⇧⌘⌫ — clear all
            if event.modifierFlags.contains([.command, .shift, .option]),
               event.keyCode == 51 {
                self.clearAll()
                return nil
            }
            return event
        }
    }

    private func stopLocalMonitor() {
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    private func pasteItem(_ text: String) {
        log("Paste: \"\(text.prefix(60))\"")

        // When pinned, capture current frontmost app (previousApp may be stale)
        if isPinned {
            previousApp = NSWorkspace.shared.runningApplications.first {
                $0.isActive && $0.bundleIdentifier != Bundle.main.bundleIdentifier
            }
        }

        // Write to clipboard
        NSPasteboard.general.clearContents()
        let fileURLs = text.components(separatedBy: "\n")
            .compactMap { URL(string: $0) }
            .filter { $0.scheme == "file" }
        if !fileURLs.isEmpty {
            NSPasteboard.general.writeObjects(fileURLs as [NSURL])
        } else {
            NSPasteboard.general.setString(text, forType: .string)
        }
        lastChangeCount = NSPasteboard.general.changeCount  // ignore our own write

        hidePanel()  // no-op when pinned (isPinned guard inside)
        if isPinned { showCopiedToast() }

        guard Prefs.shared.pasteAutomatically else {
            log("Paste automatically disabled — item copied to clipboard only")
            return
        }

        guard AXIsProcessTrusted() else {
            log("Accessibility not granted — clipboard written but not pasted")
            return
        }

        // Activate previous app then simulate ⌘V
        let appToActivate = previousApp
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            appToActivate?.activate(options: .activateIgnoringOtherApps)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                Self.simulateCmdV()
            }
        }
    }

    private static func simulateCmdV() {
        let src = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags   = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
        log("⌘V simulated")
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.action = #selector(statusItemToggle)
        button.target = self
        updateStatusIcon()
    }

    @objc func togglePauseMonitoring() {
        Prefs.shared.isPaused.toggle()
        updateStatusIcon()
        updatePauseButton()
    }

    func updatePauseButton() {
        let paused = Prefs.shared.isPaused
        let symbol = paused ? "play.circle" : "pause.circle"
        let title  = paused ? "Resume" : "Pause"
        let color: NSColor = paused ? .systemOrange : .secondaryLabelColor
        pauseFooterIcon?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        pauseFooterIcon?.contentTintColor = color
        pauseFooterLabel?.stringValue = title
        pauseFooterLabel?.textColor = color
    }

    func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        if let img = NSImage(named: "StatusIcon") {
            img.size = NSSize(width: 22, height: 22)
            img.isTemplate = false
            let paused = Prefs.shared.isPaused
            button.image = paused ? dimmedStatusIcon(img) : img
        } else {
            let name = Prefs.shared.isPaused ? "doc.on.clipboard" : "doc.on.clipboard.fill"
            button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Copiha")
            button.image?.isTemplate = true
        }
        button.toolTip = Prefs.shared.isPaused ? "Copiha — Paused" : "Copiha"
    }

    private func dimmedStatusIcon(_ img: NSImage) -> NSImage {
        let dimmed = img.copy() as! NSImage
        dimmed.lockFocus()
        NSColor.black.withAlphaComponent(0.4).setFill()
        NSRect(origin: .zero, size: dimmed.size).fill(using: .sourceAtop)
        dimmed.unlockFocus()
        return dimmed
    }

    // MARK: - Clipboard

    private func startMonitoring() {
        lastChangeCount = NSPasteboard.general.changeCount
        log("Monitoring started. changeCount=\(lastChangeCount)")
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    private func checkClipboard() {
        let pb = NSPasteboard.general
        let current = pb.changeCount
        guard current != lastChangeCount else { return }
        log("Clipboard changed \(lastChangeCount)→\(current)")
        lastChangeCount = current

        guard !Prefs.shared.isPaused else { return }

        // Check ignored apps
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let inList = Prefs.shared.ignoredBundleIDs.contains(frontmost)
        let shouldIgnore = Prefs.shared.ignoreAllExcept ? !inList : inList
        if shouldIgnore { log("Ignored app: \(frontmost)"); return }

        // File URLs (copies from Finder)
        if Prefs.shared.saveFiles,
           let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let text = urls.map { $0.absoluteString }.joined(separator: "\n")
            addToHistory(text)
            return
        }

        // Plain text
        guard Prefs.shared.saveText else { return }
        guard let text = pb.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            log("No plain text")
            return
        }
        addToHistory(text)
    }

    private func addToHistory(_ text: String) {
        let now = Date()
        if let idx = clipboardItems.firstIndex(where: { $0.text == text }) {
            var item = clipboardItems.remove(at: idx)
            item.lastCopied = now
            item.copyCount += 1
            clipboardItems.insert(item, at: 0)
            log("Updated existing: \"\(text.prefix(60))\"")
        } else {
            clipboardItems.insert(ClipItem(text: text, firstCopied: now, lastCopied: now, copyCount: 1), at: 0)
            log("Added: \"\(text.prefix(60))\" — total: \(clipboardItems.count)")
        }
        let limit = Prefs.shared.maxHistorySize
        if clipboardItems.count > limit { clipboardItems = Array(clipboardItems.prefix(limit)) }
        Store.shared.save(clipboardItems)
        reloadRows()
    }

    // MARK: - Show / Hide


    private func showPanel(source: TriggerSource = .hotkey) {
        previousApp = NSWorkspace.shared.runningApplications.first {
            $0.isActive && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        log("Show panel. Items: \(clipboardItems.count). Previous app: \(previousApp?.localizedName ?? "none")")
        positionPanel(source: source)
        applyAppearanceSettings()
        panel.alphaValue = 1.0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(Prefs.shared.showSearchField ? searchField : nil)
        isVisible = true
        startLocalMonitor()
        NotificationCenter.default.addObserver(self, selector: #selector(panelDidResignKey),
                                               name: NSWindow.didResignKeyNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(panelDidBecomeKey),
                                               name: NSWindow.didBecomeKeyNotification, object: panel)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return }
            let mouseLocation = NSEvent.mouseLocation
            let panelFrame = self.panel.frame
            let isInsidePanel = panelFrame.contains(mouseLocation)
            log("GlobalMonitor mouseDown — location=\(mouseLocation) panelFrame=\(panelFrame) insidePanel=\(isInsidePanel)")
            if !isInsidePanel {
                self.hidePanel()
            }
        }
    }

    private func applyAppearanceSettings() {
        let showSearch = Prefs.shared.showSearchField
        searchField.isHidden = !showSearch
        searchIcon.isHidden = !showSearch

        footerViews.forEach { $0.isHidden = false }
        allHoverViews.filter { $0.debugLabel.hasPrefix("footer-") }.forEach { $0.isHovered = false }

        scrollBottomConstraint.constant = -(footerHeight + 1)

        resizePanel()
    }

    private func hidePanel(force: Bool = false) {
        guard force || !isPinned else { return }
        log("Hide panel (force: \(force))")
        isPinned = false
        updatePinButton()
        panel.alphaValue = 1.0
        panel.orderOut(nil)
        isVisible = false
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        stopLocalMonitor()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: panel)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: panel)
        hidePreviewPopup()
        hoveredItemIndex = nil
        selectedIndex = nil
        // Clear search
        searchText = ""
        searchField.stringValue = ""
        reloadRows()
    }

    private func positionPanel(source: TriggerSource = .hotkey) {
        guard let screen = NSScreen.main else { return }
        switch source {
        case .hotkey:
            // Appear at the mouse cursor, centered
            let mouse = NSEvent.mouseLocation
            var x = mouse.x - panel.frame.width / 2
            var y = mouse.y - panel.frame.height / 2
            x = max(screen.visibleFrame.minX + 8, min(x, screen.visibleFrame.maxX - panel.frame.width - 8))
            y = max(screen.visibleFrame.minY + 8, min(y, screen.visibleFrame.maxY - panel.frame.height - 8))
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        case .statusItem:
            // Appear below and right-aligned to the menu bar icon
            if let btn = statusItem.button, let win = btn.window {
                let bf = win.convertToScreen(btn.frame)
                var x = bf.maxX - panel.frame.width
                let y = bf.minY - panel.frame.height - 4
                x = max(screen.visibleFrame.minX + 8, min(x, screen.visibleFrame.maxX - panel.frame.width - 8))
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            } else {
                panel.setFrameOrigin(NSPoint(
                    x: screen.visibleFrame.maxX - panel.frame.width - 8,
                    y: screen.visibleFrame.maxY - panel.frame.height - 8))
            }
        }
    }

    // MARK: - Keyboard selection

    private func setKeyboardSelection(_ index: Int?) {
        // Clear old highlight
        if let old = selectedIndex,
           old < allHoverViews.count,
           allHoverViews[old].debugLabel.hasPrefix("item-") {
            let view = allHoverViews[old]
            if !view.isHovered { view.setHighlight(false) }
        }
        selectedIndex = index
        guard let idx = index else { hidePreviewPopup(); return }
        guard idx < allHoverViews.count,
              allHoverViews[idx].debugLabel.hasPrefix("item-") else { return }
        allHoverViews[idx].setHighlight(true)
        scrollToRow(idx)
        if filteredItems.indices.contains(idx), Prefs.shared.showPreviewOnHover {
            showPreviewPopup(for: filteredItems[idx], rowIndex: idx)
        }
    }

    private func scrollToRow(_ index: Int) {
        guard index < allHoverViews.count,
              allHoverViews[index].debugLabel.hasPrefix("item-"),
              let clipView = scrollView.contentView as? NSClipView,
              let documentView = scrollView.documentView else { return }
        let view = allHoverViews[index]
        // Convert row frame into documentView coordinate space
        let rowFrame = view.convert(view.bounds, to: documentView)
        let visibleRect = clipView.documentVisibleRect
        var newOriginY = clipView.bounds.origin.y
        if rowFrame.maxY > visibleRect.maxY {
            newOriginY = rowFrame.maxY - visibleRect.height
        } else if rowFrame.minY < visibleRect.minY {
            newOriginY = rowFrame.minY
        }
        let maxY = max(0, documentView.frame.height - visibleRect.height)
        newOriginY = min(max(newOriginY, 0), maxY)
        clipView.scroll(to: NSPoint(x: 0, y: newOriginY))
        scrollView.reflectScrolledClipView(clipView)
    }

    // MARK: - Preview popup

    private func showPreviewPopup(for item: ClipItem, rowIndex: Int) {
        hidePreviewPopup()

        guard let hoverView = allHoverViews.first(where: { $0.debugLabel == "item-\(rowIndex)" }) else { return }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let popupWidth: CGFloat = 300
        let padding: CGFloat = 14
        let textContentWidth = popupWidth - padding * 2

        // Meta + hint section is a fixed ~105pt tall
        let metaSectionHeight: CGFloat = 105
        let maxTextHeight = screen.visibleFrame.height - metaSectionHeight - padding * 2 - 40

        // Compute actual text height for the full string
        let textFont = NSFont.systemFont(ofSize: 12)
        let textBounds = (item.text as NSString).boundingRect(
            with: NSSize(width: textContentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: textFont])
        let textHeight = min(ceil(textBounds.height) + 4, maxTextHeight)
        let needsScroll = ceil(textBounds.height) > maxTextHeight

        // Full-text view (scrollable when content exceeds screen cap)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: textContentWidth, height: textHeight))
        textView.string = item.text
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.font = textFont
        textView.textColor = .labelColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(width: textContentWidth, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false

        let textScroll = NSScrollView()
        textScroll.hasVerticalScroller = needsScroll
        textScroll.drawsBackground = false
        textScroll.borderType = .noBorder
        textScroll.documentView = textView
        textScroll.translatesAutoresizingMaskIntoConstraints = false

        let divider1 = NSBox(); divider1.boxType = .separator; divider1.translatesAutoresizingMaskIntoConstraints = false
        let divider2 = NSBox(); divider2.boxType = .separator; divider2.translatesAutoresizingMaskIntoConstraints = false

        func metaLabel(_ text: String) -> NSTextField {
            let f = NSTextField(labelWithString: text)
            f.font = NSFont.systemFont(ofSize: 11)
            f.textColor = .secondaryLabelColor
            f.translatesAutoresizingMaskIntoConstraints = false
            return f
        }

        let firstLabel = metaLabel("First copy time:  \(formatter.string(from: item.firstCopied))")
        let lastLabel  = metaLabel("Last copy time:   \(formatter.string(from: item.lastCopied))")
        let countLabel = metaLabel("Number of copies: \(item.copyCount)")

        let hintLabel = NSTextField(labelWithString: "Press ⌥⌫ to delete.")
        hintLabel.font = NSFont.systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true

        [textScroll, divider1, firstLabel, lastLabel, countLabel, divider2, hintLabel]
            .forEach { effect.addSubview($0) }

        NSLayoutConstraint.activate([
            textScroll.topAnchor.constraint(equalTo: effect.topAnchor, constant: padding),
            textScroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: padding),
            textScroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -padding),
            textScroll.heightAnchor.constraint(equalToConstant: textHeight),

            divider1.topAnchor.constraint(equalTo: textScroll.bottomAnchor, constant: 8),
            divider1.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            divider1.trailingAnchor.constraint(equalTo: effect.trailingAnchor),

            firstLabel.topAnchor.constraint(equalTo: divider1.bottomAnchor, constant: 5),
            firstLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: padding),

            lastLabel.topAnchor.constraint(equalTo: firstLabel.bottomAnchor, constant: 3),
            lastLabel.leadingAnchor.constraint(equalTo: firstLabel.leadingAnchor),

            countLabel.topAnchor.constraint(equalTo: lastLabel.bottomAnchor, constant: 3),
            countLabel.leadingAnchor.constraint(equalTo: firstLabel.leadingAnchor),

            divider2.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 5),
            divider2.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            divider2.trailingAnchor.constraint(equalTo: effect.trailingAnchor),

            hintLabel.topAnchor.constraint(equalTo: divider2.bottomAnchor, constant: 5),
            hintLabel.leadingAnchor.constraint(equalTo: firstLabel.leadingAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -padding),

            effect.widthAnchor.constraint(equalToConstant: popupWidth),
        ])

        let popup = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        popup.level = .popUpMenu
        popup.isOpaque = false
        popup.backgroundColor = .clear
        popup.hasShadow = true
        popup.collectionBehavior = [.canJoinAllSpaces, .transient]
        popup.contentView = effect
        popup.layoutIfNeeded()

        let fittingH = max(effect.fittingSize.height, 100)
        let popupSize = NSSize(width: popupWidth, height: fittingH)

        // Smart positioning: prefer left, fall back to right
        let spaceOnLeft = panel.frame.minX - screen.visibleFrame.minX
        let popupX: CGFloat = spaceOnLeft >= popupWidth + 12
            ? panel.frame.minX - popupWidth - 8
            : panel.frame.maxX + 8

        // Center on hovered row, clamp to screen
        let rowInWindow = hoverView.convert(hoverView.bounds, to: nil)
        let rowScreen = panel.convertToScreen(rowInWindow)
        var popupY = rowScreen.midY - popupSize.height / 2
        popupY = max(screen.visibleFrame.minY + 8,
                     min(popupY, screen.visibleFrame.maxY - popupSize.height - 8))

        popup.setFrame(NSRect(origin: NSPoint(x: popupX, y: popupY), size: popupSize), display: false)
        popup.orderFront(nil)
        previewPanel = popup
    }

    private func hidePreviewPopup() {
        previewPanel?.orderOut(nil)
        previewPanel = nil
    }

    // MARK: - Delete item

    private func deleteItem(at filteredIndex: Int) {
        guard filteredItems.indices.contains(filteredIndex) else { return }
        let text = filteredItems[filteredIndex].text
        clipboardItems.removeAll { $0.text == text }
        Store.shared.save(clipboardItems)
        hidePreviewPopup()
        hoveredItemIndex = nil
        reloadRows()
    }

    private func showItemContextMenu(for index: Int, in view: NSView) {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Delete", action: #selector(deleteFromMenu(_:)), keyEquivalent: "")
        item.tag = index
        menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent ?? NSEvent(), for: view)
    }

    @objc private func deleteFromMenu(_ sender: NSMenuItem) {
        deleteItem(at: sender.tag)
    }
}

// MARK: - HoverView (highlight on hover + click)

final class HoverView: NSView {
    var onClicked: (() -> Void)?
    var debugLabel: String = ""
    var isHovered: Bool = false
    var isFooter: Bool = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    private static let itemHighlight        = NSColor.labelColor.withAlphaComponent(0.08)
    private static let itemHighlightPressed = NSColor.labelColor.withAlphaComponent(0.14)
    private static let footerHighlight      = NSColor.labelColor.withAlphaComponent(0.08)
    private static let footerHighlightPressed = NSColor.labelColor.withAlphaComponent(0.14)

    func setHighlight(_ on: Bool) {
        layer?.backgroundColor = on ? Self.itemHighlight.cgColor : NSColor.clear.cgColor
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = isFooter
            ? Self.footerHighlightPressed.cgColor
            : Self.itemHighlightPressed.cgColor
    }
}

// MARK: - PanelRootView (round corners + clip)

final class PanelRootView: NSView {
    override func layout() {
        super.layout()
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
    }
}

// MARK: - ResizeHandleView (bottom-right drag to resize)

final class ResizeHandleView: NSView {
    private weak var panel: NSPanel?
    private var startLocation: NSPoint = .zero
    private var startFrame: NSRect = .zero
    var onResized: ((CGFloat, CGFloat) -> Void)?  // (width, height)

    init(panel: NSPanel) {
        self.panel = panel
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        startLocation = NSEvent.mouseLocation
        startFrame = panel?.frame ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let panel else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - startLocation.x
        let dy = current.y - startLocation.y
        let newWidth  = max(320, startFrame.width + dx)
        let newHeight = max(200, startFrame.height - dy)
        let newY = startFrame.maxY - newHeight
        panel.setFrame(NSRect(x: startFrame.origin.x, y: newY,
                              width: newWidth, height: newHeight), display: false)
        panel.displayIfNeeded()
        onResized?(newWidth, newHeight)
    }
}

// MARK: - EdgeResizeView (left/right edge drag to resize width)

final class EdgeResizeView: NSView {
    enum Edge { case left, right, bottom }
    private let edge: Edge
    private weak var targetPanel: NSPanel?
    private var startLocation: NSPoint = .zero
    private var startFrame: NSRect = .zero
    var onResized: ((CGFloat, CGFloat) -> Void)?

    init(edge: Edge, panel: NSPanel) {
        self.edge = edge
        self.targetPanel = panel
        super.init(frame: .zero)
        updateTrackingAreas()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .cursorUpdate, .mouseEnteredAndExited],
            owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        switch edge {
        case .left, .right: NSCursor.resizeLeftRight.set()
        case .bottom:       NSCursor.resizeUpDown.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        startLocation = NSEvent.mouseLocation
        startFrame = targetPanel?.frame ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let panel = targetPanel else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - startLocation.x
        let dy = mouse.y - startLocation.y
        switch edge {
        case .right:
            let newW = max(320, startFrame.width + dx)
            panel.setFrame(NSRect(x: startFrame.origin.x, y: panel.frame.origin.y,
                                  width: newW, height: panel.frame.height), display: true)
        case .left:
            let newW = max(320, startFrame.width - dx)
            let newX = startFrame.maxX - newW
            panel.setFrame(NSRect(x: newX, y: panel.frame.origin.y,
                                  width: newW, height: panel.frame.height), display: true)
        case .bottom:
            let newH = max(200, startFrame.height - dy)
            // Keep top edge fixed: top = startFrame.maxY, newY = top - newH
            let newY = startFrame.maxY - newH
            panel.setFrame(NSRect(x: panel.frame.origin.x, y: newY,
                                  width: panel.frame.width, height: newH), display: false)
            panel.displayIfNeeded()
            onResized?(panel.frame.width, newH)
        }
    }
}

// MARK: - NSTextFieldDelegate (search)

extension AppDelegate: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        searchText = field.stringValue
        log("Search: \"\(searchText)\" — \(filteredItems.count) results")
        reloadRows()
    }
}

// MARK: - DragHeaderView (drag the window by the header)

final class DragHeaderView: NSView {
    private var startMouseLocation: NSPoint = .zero
    private var startWindowOrigin: NSPoint = .zero

    override func mouseDown(with event: NSEvent) {
        startMouseLocation = NSEvent.mouseLocation
        startWindowOrigin = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - startMouseLocation.x
        let dy = current.y - startMouseLocation.y
        window.setFrameOrigin(NSPoint(x: startWindowOrigin.x + dx,
                                      y: startWindowOrigin.y + dy))
    }
}

// MARK: - LabelView (non-interactive NSTextField — passes all hits to superview)

final class LabelView: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    static func make(_ string: String) -> LabelView {
        let f = LabelView(labelWithString: string)
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }
}

// MARK: - FlippedView (top-aligned content in NSScrollView)

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Prefs (UserDefaults wrapper)

final class Prefs {
    static let shared = Prefs()
    private init() {}

    static let historySizeOptions = [25, 50, 100, 200, 500]
    var maxHistorySize: Int {
        get { let v = UserDefaults.standard.integer(forKey: "maxHistorySize"); return v > 0 ? v : 100 }
        set { UserDefaults.standard.set(newValue, forKey: "maxHistorySize") }
    }

    static let ttlOptions: [(label: String, days: Int)] = [
        ("Never", 0), ("1 day", 1), ("1 week", 7), ("1 month", 30)
    ]
    var historyTTLDays: Int {
        get { UserDefaults.standard.integer(forKey: "historyTTLDays") }
        set { UserDefaults.standard.set(newValue, forKey: "historyTTLDays") }
    }

    var showPreviewOnHover: Bool {
        get { UserDefaults.standard.object(forKey: "showPreviewOnHover") == nil ? true : UserDefaults.standard.bool(forKey: "showPreviewOnHover") }
        set { UserDefaults.standard.set(newValue, forKey: "showPreviewOnHover") }
    }

    var pasteAutomatically: Bool {
        get { UserDefaults.standard.object(forKey: "pasteAutomatically") == nil ? true : UserDefaults.standard.bool(forKey: "pasteAutomatically") }
        set { UserDefaults.standard.set(newValue, forKey: "pasteAutomatically") }
    }

    var pasteWithoutFormatting: Bool {
        get { UserDefaults.standard.bool(forKey: "pasteWithoutFormatting") }
        set { UserDefaults.standard.set(newValue, forKey: "pasteWithoutFormatting") }
    }

    enum SearchMode: String { case fuzzy, exact }
    var searchMode: SearchMode {
        get { SearchMode(rawValue: UserDefaults.standard.string(forKey: "searchMode") ?? "") ?? .fuzzy }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "searchMode") }
    }

    var saveText: Bool {
        get { UserDefaults.standard.object(forKey: "saveText") == nil ? true : UserDefaults.standard.bool(forKey: "saveText") }
        set { UserDefaults.standard.set(newValue, forKey: "saveText") }
    }
    var saveImages: Bool {
        get { UserDefaults.standard.bool(forKey: "saveImages") }
        set { UserDefaults.standard.set(newValue, forKey: "saveImages") }
    }
    var saveFiles: Bool {
        get { UserDefaults.standard.bool(forKey: "saveFiles") }
        set { UserDefaults.standard.set(newValue, forKey: "saveFiles") }
    }

    enum SortOrder: String { case lastCopy, copyCount, alphabetical }
    var sortOrder: SortOrder {
        get { SortOrder(rawValue: UserDefaults.standard.string(forKey: "sortOrder") ?? "") ?? .lastCopy }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "sortOrder") }
    }

    enum PopupPosition: String { case menuBar, cursor }
    var popupPosition: PopupPosition {
        get { PopupPosition(rawValue: UserDefaults.standard.string(forKey: "popupPosition") ?? "") ?? .menuBar }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "popupPosition") }
    }

    var previewDelay: Int {
        get { let v = UserDefaults.standard.integer(forKey: "previewDelay"); return v == 0 ? 300 : v }
        set { UserDefaults.standard.set(newValue, forKey: "previewDelay") }
    }

    var showSearchField: Bool {
        get { UserDefaults.standard.object(forKey: "showSearchField") == nil ? true : UserDefaults.standard.bool(forKey: "showSearchField") }
        set { UserDefaults.standard.set(newValue, forKey: "showSearchField") }
    }


    var ignoredBundleIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: "ignoredBundleIDs") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "ignoredBundleIDs") }
    }

    var ignoreAllExcept: Bool {
        get { UserDefaults.standard.bool(forKey: "ignoreAllExcept") }
        set { UserDefaults.standard.set(newValue, forKey: "ignoreAllExcept") }
    }

    var isPaused: Bool {
        get { UserDefaults.standard.bool(forKey: "isPaused") }
        set { UserDefaults.standard.set(newValue, forKey: "isPaused") }
    }

    var clearHistoryOnQuit: Bool {
        get { UserDefaults.standard.bool(forKey: "clearHistoryOnQuit") }
        set { UserDefaults.standard.set(newValue, forKey: "clearHistoryOnQuit") }
    }

    var clearClipboardOnQuit: Bool {
        get { UserDefaults.standard.bool(forKey: "clearClipboardOnQuit") }
        set { UserDefaults.standard.set(newValue, forKey: "clearClipboardOnQuit") }
    }

    var hotkeyKeyCode: UInt32 {
        get {
            guard let v = UserDefaults.standard.object(forKey: "hotkeyKeyCode") as? Int else { return 9 }
            return UInt32(v)
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: "hotkeyKeyCode") }
    }

    var hotkeyModifiers: UInt32 {
        get {
            guard let v = UserDefaults.standard.object(forKey: "hotkeyModifiers") as? Int else {
                return UInt32(cmdKey | shiftKey)
            }
            return UInt32(v)
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: "hotkeyModifiers") }
    }

    var hasSeenOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasSeenOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasSeenOnboarding") }
    }

    var launchAtLogin: Bool {
        get {
            if #available(macOS 13, *) { return SMAppService.mainApp.status == .enabled }
            return false
        }
        set {
            if #available(macOS 13, *) {
                do {
                    if newValue { try SMAppService.mainApp.register() }
                    else        { try SMAppService.mainApp.unregister() }
                } catch { log("Launch at login error: \(error)") }
            }
        }
    }
}

// MARK: - PreferencesWindow (toolbar-tab style)

final class PreferencesWindow: NSWindowController, NSWindowDelegate, NSTabViewDelegate {
    var onClose: (() -> Void)?
    private var keyMonitor: Any?

    convenience init() {
        log("PreferencesWindow init — step 1: creating tabVC")
        let tabVC = TitledTabVC()
        tabVC.tabStyle = .toolbar
        log("PreferencesWindow init — step 2: tabStyle set")

        let tabs: [(label: String, icon: String, vc: NSViewController)] = [
            ("General",    "gearshape",     GeneralPrefsVC()),
            ("Storage",    "internaldrive", StoragePrefsVC()),
            ("Appearance", "paintpalette",  AppearancePrefsVC()),
            ("Ignore",     "nosign",        IgnorePrefsVC()),
            ("Advanced",   "gearshape.2",   AdvancedPrefsVC()),
        ]
        for (label, icon, vc) in tabs {
            vc.title = label
            let item = NSTabViewItem(viewController: vc)
            item.label = label
            item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            tabVC.addTabViewItem(item)
        }
        log("PreferencesWindow init — step 3: tabs added")

        let win = NSWindow(contentViewController: tabVC)
        log("PreferencesWindow init — step 4: window created")
        win.title = "General"
        win.isReleasedWhenClosed = false
        win.center()
        self.init(window: win)
        win.delegate = self
        log("PreferencesWindow init — step 5: done")
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "w" {
                self?.window?.close()
                return nil
            }
            return event
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        onClose?()
    }
}

// NSTabViewController subclass that updates window title on tab switch
final class TitledTabVC: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        view.window?.title = tabViewItem?.label ?? ""
    }
}

// MARK: - Prefs helper

private func prefsLabel(_ text: String, alignment: NSTextAlignment = .right) -> NSTextField {
    let f = NSTextField(labelWithString: text)
    f.font = NSFont.systemFont(ofSize: 13)
    f.textColor = .labelColor
    f.alignment = alignment
    f.translatesAutoresizingMaskIntoConstraints = false
    return f
}

private func prefsSeparator() -> NSBox {
    let b = NSBox(); b.boxType = .separator; b.translatesAutoresizingMaskIntoConstraints = false; return b
}

// MARK: - General tab

final class GeneralPrefsVC: NSViewController {
    private var pasteAutoCheck: NSButton!

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let grid = NSGridView()
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
        ])

        // Launch at login
        let loginCheck = NSButton(checkboxWithTitle: "Launch at login", target: self, action: #selector(loginToggled(_:)))
        loginCheck.state = Prefs.shared.launchAtLogin ? .on : .off
        grid.addRow(with: [prefsLabel(""), loginCheck])

        // Separator
        let sep1 = prefsSeparator()
        let sepRow1 = grid.addRow(with: [NSGridCell.emptyContentView, sep1])
        sepRow1.topPadding = 4; sepRow1.bottomPadding = 4
        sep1.widthAnchor.constraint(equalToConstant: 280).isActive = true

        // Open hotkey (recorder)
        let recorder = HotkeyRecorderView(keyCode: Prefs.shared.hotkeyKeyCode,
                                          modifiers: Prefs.shared.hotkeyModifiers)
        recorder.onHotkeyChanged = { keyCode, mods in
            Prefs.shared.hotkeyKeyCode = keyCode
            Prefs.shared.hotkeyModifiers = mods
            (NSApp.delegate as? AppDelegate)?.reregisterHotkey()
        }
        grid.addRow(with: [prefsLabel("Open:"), recorder])

        // Separator
        let sep2 = prefsSeparator()
        let sepRow2 = grid.addRow(with: [NSGridCell.emptyContentView, sep2])
        sepRow2.topPadding = 4; sepRow2.bottomPadding = 4
        sep2.widthAnchor.constraint(equalToConstant: 280).isActive = true

        // Search mode
        let searchPopup = NSPopUpButton()
        searchPopup.addItem(withTitle: "Fuzzy")
        searchPopup.addItem(withTitle: "Exact")
        searchPopup.selectItem(withTitle: Prefs.shared.searchMode == .exact ? "Exact" : "Fuzzy")
        searchPopup.target = self
        searchPopup.action = #selector(searchModeChanged(_:))
        searchPopup.translatesAutoresizingMaskIntoConstraints = false
        grid.addRow(with: [prefsLabel("Search:"), searchPopup])

        // Separator
        let sep3 = prefsSeparator()
        let sepRow3 = grid.addRow(with: [NSGridCell.emptyContentView, sep3])
        sepRow3.topPadding = 4; sepRow3.bottomPadding = 4
        sep3.widthAnchor.constraint(equalToConstant: 280).isActive = true

        // Paste automatically
        pasteAutoCheck = NSButton(checkboxWithTitle: "Paste automatically  (requires Accessibility)", target: self, action: #selector(pasteAutoToggled(_:)))
        pasteAutoCheck.state = Prefs.shared.pasteAutomatically && AXIsProcessTrusted() ? .on : .off
        if pasteAutoCheck.state == .off { Prefs.shared.pasteAutomatically = false }
        grid.addRow(with: [prefsLabel("Behavior:"), pasteAutoCheck])

        // Paste without formatting
        let pasteFormatCheck = NSButton(checkboxWithTitle: "Paste without formatting", target: self, action: #selector(pasteFormatToggled(_:)))
        pasteFormatCheck.state = Prefs.shared.pasteWithoutFormatting ? .on : .off
        grid.addRow(with: [NSGridCell.emptyContentView, pasteFormatCheck])

        // Align right column of labels
        for i in 0..<grid.numberOfRows {
            grid.cell(atColumnIndex: 0, rowIndex: i).xPlacement = .trailing
        }
        grid.column(at: 0).width = 100
    }

    @objc private func loginToggled(_ s: NSButton)      { Prefs.shared.launchAtLogin = s.state == .on }
    @objc private func searchModeChanged(_ s: NSPopUpButton) {
        Prefs.shared.searchMode = s.titleOfSelectedItem == "Exact" ? .exact : .fuzzy
    }

    @objc private func pasteAutoToggled(_ s: NSButton) {
        guard s.state == .on else {
            Prefs.shared.pasteAutomatically = false
            return
        }
        if AXIsProcessTrusted() {
            Prefs.shared.pasteAutomatically = true
        } else {
            // Request permission and poll — uncheck until granted
            s.state = .off
            Prefs.shared.pasteAutomatically = false
            let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
            AXIsProcessTrustedWithOptions(opts as CFDictionary)
            pollAccessibility(attempts: 0)
        }
    }

    private func pollAccessibility(attempts: Int) {
        guard attempts < 20 else { return }  // give up after ~10 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if AXIsProcessTrusted() {
                self.pasteAutoCheck.state = .on
                Prefs.shared.pasteAutomatically = true
            } else {
                self.pollAccessibility(attempts: attempts + 1)
            }
        }
    }

    @objc private func pasteFormatToggled(_ s: NSButton){ Prefs.shared.pasteWithoutFormatting = s.state == .on }
}

// MARK: - Storage tab

final class StoragePrefsVC: NSViewController {
    private var sizeField: NSTextField!
    private var sizeStepper: NSStepper!

    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320)) }

    override func viewDidLoad() {
        super.viewDidLoad()

        let grid = NSGridView()
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
        ])

        // Save section — checkboxes
        let textCheck = NSButton(checkboxWithTitle: "Text", target: self, action: #selector(saveTextToggled(_:)))
        textCheck.state = Prefs.shared.saveText ? .on : .off

        let imagesCheck = NSButton(checkboxWithTitle: "Images", target: self, action: #selector(saveImagesToggled(_:)))
        imagesCheck.state = Prefs.shared.saveImages ? .on : .off

        let filesCheck = NSButton(checkboxWithTitle: "Files", target: self, action: #selector(saveFilesToggled(_:)))
        filesCheck.state = Prefs.shared.saveFiles ? .on : .off

        grid.addRow(with: [prefsLabel("Save:"), textCheck])
        grid.addRow(with: [NSGridCell.emptyContentView, imagesCheck])
        grid.addRow(with: [NSGridCell.emptyContentView, filesCheck])

        let note = NSTextField(labelWithString: "Change what types of copied content should be stored.")
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        grid.addRow(with: [NSGridCell.emptyContentView, note])

        // Separator
        let sep1 = prefsSeparator()
        let r1 = grid.addRow(with: [NSGridCell.emptyContentView, sep1])
        r1.topPadding = 4; r1.bottomPadding = 4
        sep1.widthAnchor.constraint(equalToConstant: 280).isActive = true

        // Size — stepper + field + disk size
        let sizeRow = NSView()
        sizeRow.translatesAutoresizingMaskIntoConstraints = false

        sizeField = NSTextField()
        sizeField.translatesAutoresizingMaskIntoConstraints = false
        sizeField.stringValue = "\(Prefs.shared.maxHistorySize)"
        sizeField.font = NSFont.systemFont(ofSize: 13)
        sizeField.bezelStyle = .roundedBezel
        sizeField.focusRingType = .none
        sizeField.alignment = .right
        NotificationCenter.default.addObserver(self, selector: #selector(sizeFieldChanged), name: NSTextField.textDidChangeNotification, object: sizeField)

        sizeStepper = NSStepper()
        sizeStepper.translatesAutoresizingMaskIntoConstraints = false
        sizeStepper.integerValue = Prefs.shared.maxHistorySize
        sizeStepper.minValue = 10
        sizeStepper.maxValue = 5000
        sizeStepper.increment = 25
        sizeStepper.valueWraps = false
        sizeStepper.target = self
        sizeStepper.action = #selector(stepperChanged(_:))


        // ⓘ info button for size field
        let sizeInfo = NSButton(title: "", target: nil, action: nil)
        sizeInfo.translatesAutoresizingMaskIntoConstraints = false
        sizeInfo.bezelStyle = .helpButton
        sizeInfo.setButtonType(.momentaryPushIn)
        sizeInfo.toolTip = "The number of clipboard items Copiha will remember.\nOlder items beyond this limit are automatically removed.\n\nCurrent history file size on disk: \(diskSizeString())"

        sizeRow.addSubview(sizeField)
        sizeRow.addSubview(sizeStepper)
        sizeRow.addSubview(sizeInfo)
        NSLayoutConstraint.activate([
            sizeField.leadingAnchor.constraint(equalTo: sizeRow.leadingAnchor),
            sizeField.centerYAnchor.constraint(equalTo: sizeRow.centerYAnchor),
            sizeField.widthAnchor.constraint(equalToConstant: 70),
            sizeStepper.leadingAnchor.constraint(equalTo: sizeField.trailingAnchor, constant: 4),
            sizeStepper.centerYAnchor.constraint(equalTo: sizeRow.centerYAnchor),
            sizeInfo.leadingAnchor.constraint(equalTo: sizeStepper.trailingAnchor, constant: 8),
            sizeInfo.centerYAnchor.constraint(equalTo: sizeRow.centerYAnchor),
            sizeRow.trailingAnchor.constraint(equalTo: sizeInfo.trailingAnchor),
            sizeRow.heightAnchor.constraint(equalToConstant: 28),
        ])
        grid.addRow(with: [prefsLabel("Size:"), sizeRow])

        // Sort by
        let sortPopup = NSPopUpButton()
        sortPopup.translatesAutoresizingMaskIntoConstraints = false
        sortPopup.addItem(withTitle: "Time of last copy")
        sortPopup.addItem(withTitle: "Number of copies")
        sortPopup.addItem(withTitle: "Alphabetical")
        switch Prefs.shared.sortOrder {
        case .lastCopy:     sortPopup.selectItem(at: 0)
        case .copyCount:    sortPopup.selectItem(at: 1)
        case .alphabetical: sortPopup.selectItem(at: 2)
        }
        sortPopup.target = self
        sortPopup.action = #selector(sortChanged(_:))
        grid.addRow(with: [prefsLabel("Sort by:"), sortPopup])

        // Separator
        let sep2 = prefsSeparator()
        let r2 = grid.addRow(with: [NSGridCell.emptyContentView, sep2])
        r2.topPadding = 4; r2.bottomPadding = 4
        sep2.widthAnchor.constraint(equalToConstant: 280).isActive = true

        // Auto-clear (TTL)
        let ttlPopup = NSPopUpButton()
        ttlPopup.translatesAutoresizingMaskIntoConstraints = false
        for opt in Prefs.ttlOptions {
            ttlPopup.addItem(withTitle: opt.label)
            ttlPopup.lastItem?.tag = opt.days
        }
        ttlPopup.selectItem(withTag: Prefs.shared.historyTTLDays)
        ttlPopup.target = self
        ttlPopup.action = #selector(ttlChanged(_:))
        grid.addRow(with: [prefsLabel("Auto-clear after:"), ttlPopup])

        for i in 0..<grid.numberOfRows {
            grid.cell(atColumnIndex: 0, rowIndex: i).xPlacement = .trailing
        }
        grid.column(at: 0).width = 120
    }

    private func diskSizeString() -> String {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Copiha/history.json")
        if let url, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            let mb = Double(size) / 1_048_576
            return mb < 0.1 ? "\(size) bytes" : String(format: "%.1f MB", mb)
        }
        return "0 bytes"
    }

    @objc private func saveTextToggled(_ s: NSButton)   { Prefs.shared.saveText   = s.state == .on }
    @objc private func saveImagesToggled(_ s: NSButton) { Prefs.shared.saveImages = s.state == .on }
    @objc private func saveFilesToggled(_ s: NSButton)  { Prefs.shared.saveFiles  = s.state == .on }

    @objc private func stepperChanged(_ s: NSStepper) {
        Prefs.shared.maxHistorySize = s.integerValue
        sizeField.stringValue = "\(s.integerValue)"
    }

    @objc private func sizeFieldChanged() {
        if var v = Int(sizeField.stringValue) {
            v = min(max(v, 10), 5000)
            Prefs.shared.maxHistorySize = v
            sizeStepper.integerValue = v
            sizeField.stringValue = "\(v)"
        }
    }

    @objc private func sortChanged(_ s: NSPopUpButton) {
        switch s.indexOfSelectedItem {
        case 1:  Prefs.shared.sortOrder = .copyCount
        case 2:  Prefs.shared.sortOrder = .alphabetical
        default: Prefs.shared.sortOrder = .lastCopy
        }
    }

    @objc private func ttlChanged(_ s: NSPopUpButton) {
        Prefs.shared.historyTTLDays = s.selectedTag()
    }
}

// MARK: - Appearance tab

final class AppearancePrefsVC: NSViewController {
    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 340)) }

    override func viewDidLoad() {
        super.viewDidLoad()
        let grid = NSGridView()
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
        ])

        // Popup position
        let posPopup = NSPopUpButton()
        posPopup.addItem(withTitle: "Menu bar icon")
        posPopup.addItem(withTitle: "Cursor position")
        posPopup.selectItem(at: Prefs.shared.popupPosition == .cursor ? 1 : 0)
        posPopup.target = self; posPopup.action = #selector(posChanged(_:))
        posPopup.translatesAutoresizingMaskIntoConstraints = false
        grid.addRow(with: [prefsLabel("Popup at:"), posPopup])

        let sep1 = prefsSeparator()
        let r1 = grid.addRow(with: [NSGridCell.emptyContentView, sep1])
        r1.topPadding = 4; r1.bottomPadding = 4
        sep1.widthAnchor.constraint(equalToConstant: 280).isActive = true

        // Preview on hover
        let previewCheck = NSButton(checkboxWithTitle: "Show info popup on hover", target: self, action: #selector(previewToggled(_:)))
        previewCheck.state = Prefs.shared.showPreviewOnHover ? .on : .off
        grid.addRow(with: [prefsLabel("Item preview:"), previewCheck])

        // Preview delay
        let delayRow = NSView()
        delayRow.translatesAutoresizingMaskIntoConstraints = false
        let delayStepper = NSStepper()
        delayStepper.translatesAutoresizingMaskIntoConstraints = false
        delayStepper.integerValue = Prefs.shared.previewDelay
        delayStepper.minValue = 0; delayStepper.maxValue = 2000; delayStepper.increment = 100
        delayStepper.target = self; delayStepper.action = #selector(delayChanged(_:))
        let delayLabel = NSTextField(labelWithString: "\(Prefs.shared.previewDelay) ms")
        delayLabel.translatesAutoresizingMaskIntoConstraints = false
        delayLabel.font = NSFont.systemFont(ofSize: 12)
        delayLabel.textColor = .secondaryLabelColor
        delayLabel.tag = 99
        delayStepper.tag = 98
        delayRow.addSubview(delayStepper)
        delayRow.addSubview(delayLabel)
        NSLayoutConstraint.activate([
            delayStepper.leadingAnchor.constraint(equalTo: delayRow.leadingAnchor),
            delayStepper.centerYAnchor.constraint(equalTo: delayRow.centerYAnchor),
            delayLabel.leadingAnchor.constraint(equalTo: delayStepper.trailingAnchor, constant: 8),
            delayLabel.centerYAnchor.constraint(equalTo: delayRow.centerYAnchor),
            delayRow.trailingAnchor.constraint(equalTo: delayLabel.trailingAnchor),
            delayRow.heightAnchor.constraint(equalToConstant: 24),
        ])
        grid.addRow(with: [prefsLabel("Preview delay:"), delayRow])

        let sep2 = prefsSeparator()
        let r2 = grid.addRow(with: [NSGridCell.emptyContentView, sep2])
        r2.topPadding = 4; r2.bottomPadding = 4
        sep2.widthAnchor.constraint(equalToConstant: 280).isActive = true

        // Show search field
        let searchCheck = NSButton(checkboxWithTitle: "Show search field", target: self, action: #selector(searchToggled(_:)))
        searchCheck.state = Prefs.shared.showSearchField ? .on : .off
        grid.addRow(with: [prefsLabel(""), searchCheck])

        let note = NSTextField(labelWithString: "Search field changes apply on next open.")
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        grid.addRow(with: [NSGridCell.emptyContentView, note])

        for i in 0..<grid.numberOfRows { grid.cell(atColumnIndex: 0, rowIndex: i).xPlacement = .trailing }
        grid.column(at: 0).width = 120
    }

    @objc private func posChanged(_ s: NSPopUpButton) {
        Prefs.shared.popupPosition = s.indexOfSelectedItem == 1 ? .cursor : .menuBar
    }
    @objc private func previewToggled(_ s: NSButton) { Prefs.shared.showPreviewOnHover = s.state == .on }
    @objc private func delayChanged(_ s: NSStepper) {
        Prefs.shared.previewDelay = s.integerValue
        if let label = s.superview?.viewWithTag(99) as? NSTextField {
            label.stringValue = "\(s.integerValue) ms"
        }
    }
    @objc private func searchToggled(_ s: NSButton) { Prefs.shared.showSearchField = s.state == .on }
}

// MARK: - Ignore tab

final class IgnorePrefsVC: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private var tableView: NSTableView!
    private var apps: [(name: String, bundleID: String, icon: NSImage?)] = []

    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 360)) }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadApps()

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 24

        let col1 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("icon"))
        col1.width = 24; col1.minWidth = 24; col1.maxWidth = 24
        let col2 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col2.title = "Application"; col2.width = 180
        let col3 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bundle"))
        col3.title = "Bundle ID"; col3.width = 220
        [col1, col2, col3].forEach { tableView.addTableColumn($0) }
        tableView.headerView = NSTableHeaderView()
        scrollView.documentView = tableView

        let addBtn = NSButton(title: "+", target: self, action: #selector(addApp))
        addBtn.bezelStyle = .smallSquare
        addBtn.translatesAutoresizingMaskIntoConstraints = false

        let removeBtn = NSButton(title: "−", target: self, action: #selector(removeApp))
        removeBtn.bezelStyle = .smallSquare
        removeBtn.translatesAutoresizingMaskIntoConstraints = false

        let invertCheck = NSButton(checkboxWithTitle: "Ignore all applications except listed", target: self, action: #selector(invertToggled(_:)))
        invertCheck.state = Prefs.shared.ignoreAllExcept ? .on : .off
        invertCheck.translatesAutoresizingMaskIntoConstraints = false

        let note = NSTextField(wrappingLabelWithString: "Copies from ignored apps will not be saved to history.")
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false

        [scrollView, addBtn, removeBtn, invertCheck, note].forEach { view.addSubview($0) }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scrollView.heightAnchor.constraint(equalToConstant: 200),
            addBtn.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            addBtn.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            addBtn.widthAnchor.constraint(equalToConstant: 26),
            removeBtn.topAnchor.constraint(equalTo: addBtn.topAnchor),
            removeBtn.leadingAnchor.constraint(equalTo: addBtn.trailingAnchor, constant: 4),
            removeBtn.widthAnchor.constraint(equalToConstant: 26),
            invertCheck.topAnchor.constraint(equalTo: addBtn.bottomAnchor, constant: 12),
            invertCheck.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            note.topAnchor.constraint(equalTo: invertCheck.bottomAnchor, constant: 6),
            note.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
        ])
    }

    private func loadApps() {
        apps = Prefs.shared.ignoredBundleIDs.map { bid in
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
            let name = url.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleName"] as? String } ?? bid
            let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            return (name, bid, icon)
        }
    }

    @objc private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.prompt = "Ignore"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url,
                  let bundle = Bundle(url: url),
                  let bid = bundle.bundleIdentifier else { return }
            var ids = Prefs.shared.ignoredBundleIDs
            guard !ids.contains(bid) else { return }
            ids.append(bid)
            Prefs.shared.ignoredBundleIDs = ids
            self?.loadApps()
            self?.tableView.reloadData()
        }
    }

    @objc private func removeApp() {
        let row = tableView.selectedRow
        guard row >= 0, row < apps.count else { return }
        var ids = Prefs.shared.ignoredBundleIDs
        ids.remove(at: row)
        Prefs.shared.ignoredBundleIDs = ids
        apps.remove(at: row)
        tableView.reloadData()
    }

    @objc private func invertToggled(_ s: NSButton) { Prefs.shared.ignoreAllExcept = s.state == .on }

    func numberOfRows(in tableView: NSTableView) -> Int { apps.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let app = apps[row]
        let cell = NSTextField(labelWithString: "")
        cell.translatesAutoresizingMaskIntoConstraints = false
        switch tableColumn?.identifier.rawValue {
        case "icon":
            let iv = NSImageView()
            iv.image = app.icon
            iv.imageScaling = .scaleProportionallyDown
            return iv
        case "name":  cell.stringValue = app.name
        case "bundle": cell.stringValue = app.bundleID
        default: break
        }
        return cell
    }
}

// MARK: - Advanced tab

final class AdvancedPrefsVC: NSViewController {
    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 520)) }

    override func viewDidLoad() {
        super.viewDidLoad()
        let grid = NSGridView()
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
        ])

        // Pause monitoring
        let pauseCheck = NSButton(checkboxWithTitle: "Pause monitoring", target: self, action: #selector(pauseToggled(_:)))
        pauseCheck.state = Prefs.shared.isPaused ? .on : .off
        grid.addRow(with: [prefsLabel(""), pauseCheck])

        let pauseNote = NSTextField(labelWithString: "Temporarily stop saving new clipboard copies.")
        pauseNote.font = NSFont.systemFont(ofSize: 11)
        pauseNote.textColor = .secondaryLabelColor
        pauseNote.translatesAutoresizingMaskIntoConstraints = false
        grid.addRow(with: [NSGridCell.emptyContentView, pauseNote])

        let sep1 = prefsSeparator()
        let r1 = grid.addRow(with: [NSGridCell.emptyContentView, sep1])
        r1.topPadding = 4; r1.bottomPadding = 4
        sep1.widthAnchor.constraint(equalToConstant: 280).isActive = true

        // Clear history on quit
        let historyCheck = NSButton(checkboxWithTitle: "Clear history on quit", target: self, action: #selector(clearHistoryToggled(_:)))
        historyCheck.state = Prefs.shared.clearHistoryOnQuit ? .on : .off
        grid.addRow(with: [prefsLabel(""), historyCheck])

        // Clear clipboard on quit
        let clipCheck = NSButton(checkboxWithTitle: "Clear system clipboard on quit", target: self, action: #selector(clearClipToggled(_:)))
        clipCheck.state = Prefs.shared.clearClipboardOnQuit ? .on : .off
        grid.addRow(with: [NSGridCell.emptyContentView, clipCheck])

        let sep2 = prefsSeparator()
        let r2 = grid.addRow(with: [NSGridCell.emptyContentView, sep2])
        r2.topPadding = 4; r2.bottomPadding = 4
        sep2.widthAnchor.constraint(equalToConstant: 280).isActive = true

        // Check for updates
        let updateBtn = NSButton(title: "Check for Updates…", target: self, action: #selector(checkForUpdates))
        updateBtn.bezelStyle = .rounded
        grid.addRow(with: [prefsLabel("Updates:"), updateBtn])

        let sep3 = prefsSeparator()
        let r3 = grid.addRow(with: [NSGridCell.emptyContentView, sep3])
        r3.topPadding = 4; r3.bottomPadding = 4
        sep3.widthAnchor.constraint(equalToConstant: 280).isActive = true

        // Log access
        let logBtn = NSButton(title: "Show Log in Finder", target: self, action: #selector(showLog))
        logBtn.bezelStyle = .rounded
        grid.addRow(with: [prefsLabel("Bug report:"), logBtn])

        let logNote = NSTextField(wrappingLabelWithString: "Attach the log file to your GitHub issue at github.com/\(kGitHubOwner)/\(kGitHubRepo)/issues")
        logNote.font = NSFont.systemFont(ofSize: 11)
        logNote.textColor = .secondaryLabelColor
        logNote.translatesAutoresizingMaskIntoConstraints = false
        grid.addRow(with: [NSGridCell.emptyContentView, logNote])

        let sep4 = prefsSeparator()
        let r4 = grid.addRow(with: [NSGridCell.emptyContentView, sep4])
        r4.topPadding = 4; r4.bottomPadding = 4
        sep4.widthAnchor.constraint(equalToConstant: 280).isActive = true

        // Privacy note
        let privacyNote = NSTextField(wrappingLabelWithString: "🔒  Copiha stores your clipboard history locally on this Mac only. No data is ever sent to any server. The only network request made is an optional update check to GitHub.")
        privacyNote.font = NSFont.systemFont(ofSize: 11)
        privacyNote.textColor = .secondaryLabelColor
        privacyNote.translatesAutoresizingMaskIntoConstraints = false
        grid.addRow(with: [NSGridCell.emptyContentView, privacyNote])
        privacyNote.widthAnchor.constraint(equalToConstant: 280).isActive = true

        for i in 0..<grid.numberOfRows { grid.cell(atColumnIndex: 0, rowIndex: i).xPlacement = .trailing }
        grid.column(at: 0).width = 20
    }

    @objc private func pauseToggled(_ s: NSButton) {
        Prefs.shared.isPaused = s.state == .on
        let d = NSApp.delegate as? AppDelegate
        d?.updateStatusIcon()
        d?.updatePauseButton()
    }
    @objc private func clearHistoryToggled(_ s: NSButton) { Prefs.shared.clearHistoryOnQuit = s.state == .on }
    @objc private func clearClipToggled(_ s: NSButton)    { Prefs.shared.clearClipboardOnQuit = s.state == .on }

    @objc private func checkForUpdates() {
        (NSApp.delegate as? AppDelegate)?.checkForUpdates(userInitiated: true)
    }

    @objc private func showLog() {
        NSWorkspace.shared.activateFileViewerSelecting([copihaLogFileURL()])
    }

    @objc private func copyLogPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copihaLogFileURL().path, forType: .string)
    }
}

// MARK: - HotkeyRecorderView

final class HotkeyRecorderView: NSView {
    var onHotkeyChanged: ((UInt32, UInt32) -> Void)?
    private var button: NSButton!
    private var isRecording = false
    private var monitor: Any?
    private(set) var keyCode: UInt32
    private(set) var modifiers: UInt32

    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        button = NSButton(title: Self.hotkeyString(keyCode: keyCode, modifiers: modifiers),
                          target: self, action: #selector(clicked))
        button.bezelStyle = .rounded
        button.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(equalToConstant: 110),
            heightAnchor.constraint(equalToConstant: 26),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() {
        isRecording ? cancelRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        button.title = "Press shortcut…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            if Self.modifierKeyCodes.contains(event.keyCode) { return event }
            if event.keyCode == 53 { self.cancelRecording(); return nil }  // Escape cancels
            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard !mods.isEmpty else { self.cancelRecording(); return event }
            self.keyCode = UInt32(event.keyCode)
            self.modifiers = Self.carbonMods(from: mods)
            self.stopRecording()
            self.onHotkeyChanged?(self.keyCode, self.modifiers)
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        button.title = Self.hotkeyString(keyCode: keyCode, modifiers: modifiers)
    }

    private func cancelRecording() {
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        button.title = Self.hotkeyString(keyCode: keyCode, modifiers: modifiers)
    }

    static func hotkeyString(keyCode: UInt32, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += keyName(for: keyCode)
        return s
    }

    private static func carbonMods(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    private static func keyName(for code: UInt32) -> String {
        let map: [UInt32: String] = [
            0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V",
            11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T",
            18:"1", 19:"2", 20:"3", 21:"4", 22:"6", 23:"5", 24:"=", 25:"9",
            26:"7", 27:"-", 28:"8", 29:"0", 30:"]", 31:"O", 32:"U", 33:"[",
            34:"I", 35:"P", 37:"L", 38:"J", 39:"'", 40:"K", 41:";", 42:"\\",
            43:",", 44:"/", 45:"N", 46:"M", 47:".", 50:"`",
            76:"↩", 96:"F5", 97:"F6", 98:"F7", 99:"F3", 100:"F8", 101:"F9",
            103:"F11", 109:"F10", 111:"F12", 118:"F4", 120:"F2", 122:"F1",
            123:"←", 124:"→", 125:"↓", 126:"↑",
        ]
        return map[code] ?? "?"
    }
}

// MARK: - OnboardingWindowController

final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    var onDismiss: (() -> Void)?

    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Welcome to Copiha"
        win.isReleasedWhenClosed = false
        win.center()
        self.init(window: win)
        win.delegate = self
        let vc = OnboardingVC()
        vc.onDismiss = { [weak self] in self?.closeAndDismiss() }
        win.contentViewController = vc
    }

    func windowWillClose(_ notification: Notification) {
        onDismiss?()
    }

    fileprivate func closeAndDismiss() {
        window?.close()
    }
}

final class OnboardingVC: NSViewController {
    var onDismiss: (() -> Void)?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 520))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let iconView = NSImageView()
        iconView.image = NSImage(named: NSImage.applicationIconName)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "Welcome to Copiha")
        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = NSTextField(wrappingLabelWithString:
            "Copiha lives in your menu bar and keeps a history of everything you copy.")
        subtitleLabel.font = NSFont.systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let hotkeyStr = HotkeyRecorderView.hotkeyString(
            keyCode: Prefs.shared.hotkeyKeyCode,
            modifiers: Prefs.shared.hotkeyModifiers)

        let step1 = makeStep(
            symbol: "keyboard",
            title: "Open with a hotkey",
            detail: "Press \(hotkeyStr) at any time to open Copiha and browse your clipboard history.")

        let step2 = makeStep(
            symbol: "lock.shield",
            title: "Optional: Auto-paste",
            detail: "When you pick an item, Copiha switches back to your previous app and simulates ⌘V — so it only works when a text field is focused. Requires Accessibility permission. You can enable it now or later in Preferences → General.")

        let grantBtn = NSButton(title: "Enable Auto-paste", target: self, action: #selector(openAccessibility))
        grantBtn.bezelStyle = .rounded
        grantBtn.translatesAutoresizingMaskIntoConstraints = false

        // Divider above buttons
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let startBtn = NSButton(title: "Get Started", target: self, action: #selector(getStarted))
        startBtn.bezelStyle = .rounded
        startBtn.keyEquivalent = "\r"
        startBtn.translatesAutoresizingMaskIntoConstraints = false

        [iconView, titleLabel, subtitleLabel, step1, step2, grantBtn, divider, startBtn].forEach { view.addSubview($0) }

        NSLayoutConstraint.activate([
            // Icon at top
            iconView.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            iconView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),

            // Title
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 12),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            // Subtitle
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            subtitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            subtitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),

            // Steps
            step1.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 20),
            step1.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            step1.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),

            step2.topAnchor.constraint(equalTo: step1.bottomAnchor, constant: 14),
            step2.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            step2.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),

            // Accessibility button below step2
            grantBtn.topAnchor.constraint(equalTo: step2.bottomAnchor, constant: 16),
            grantBtn.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            // Divider pinned to bottom area
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: startBtn.topAnchor, constant: -14),

            // Get Started always pinned to bottom
            startBtn.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            startBtn.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            startBtn.widthAnchor.constraint(equalToConstant: 140),
        ])
    }

    private func makeStep(symbol: String, title: String, detail: String) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = .systemBlue
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = NSFont.systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        [icon, titleLabel, detailLabel].forEach { container.addSubview($0) }

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            icon.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),

            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            detailLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            detailLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    @objc private func openAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    @objc private func getStarted() {
        onDismiss?()
    }
}
