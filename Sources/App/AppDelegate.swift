import AppKit

/// Menu bar app. Shows the daemon state and sends commands to it.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?

    private var state: DaemonState?
    private var daemonError: String?
    /// Failed polls in a row. The app shows "no daemon" only after `failureLimit` failures.
    private var failures = 0
    private let failureLimit = 3

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: Daemon

    private func refresh() {
        DispatchQueue.global().async { [weak self] in
            let result = Result { try SocketClient.send(.status) }
            DispatchQueue.main.async {
                self?.take(result)
            }
        }
    }

    private func send(_ command: FenceCommand) {
        DispatchQueue.global().async { [weak self] in
            let result = Result { try SocketClient.send(command) }
            DispatchQueue.main.async {
                self?.take(result)
            }
        }
    }

    private func take(_ result: Result<DaemonState, Error>) {
        switch result {
        case .success(let s):
            state = s
            daemonError = nil
            failures = 0
        case .failure(let e):
            failures += 1
            daemonError = "\(e)"
            // One lost poll is normal while the daemon restarts or runs pfctl. Keep the last state.
            if failures >= failureLimit { state = nil }
        }
        updateIcon()
    }

    // MARK: Icon

    private func updateIcon() {
        let symbol: String
        let text: String
        if let s = state, s.blockError != nil {
            let image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: L.text(.iconBlockError))
            image?.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.toolTip = L.text(.iconBlockError)
            return
        }
        switch state?.status {
        case .open:
            symbol = "circle"
            text = L.text(.iconOpen)
        case .blocked, .manual:
            symbol = "xmark"
            text = L.text(.iconBlocked)
        case .checking:
            symbol = "circle.dotted"
            text = L.text(.iconChecking)
        case nil:
            symbol = "exclamationmark.triangle"
            text = L.text(.iconNoDaemon)
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = text
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        addInfo(statusTitle())

        if let s = state {
            if let last = s.lastCheck {
                let source = s.geoSource.map { " · \($0)" } ?? ""
                addInfo(L.text(.checkedAt, timeFormatter.string(from: last)) + source)
            }
            if let error = s.blockError {
                addInfo(L.text(.error, shorten(error)))
            }
            if let error = s.lastError {
                addInfo(L.text(.error, shorten(error)))
            }
        } else {
            addInfo(L.text(.installHint))
        }

        menu.addItem(.separator())

        let manual = addAction(L.text(.manualBlock), #selector(toggleManual))
        manual.state = state?.manualBlock == true ? .on : .off
        manual.isEnabled = state != nil

        let recheck = addAction(L.text(.recheck), #selector(recheckNow))
        recheck.isEnabled = state != nil

        addServicesMenu()

        menu.addItem(.separator())

        addAction(L.text(.openLog), #selector(openLog))
        let login = addAction(L.text(.launchAtLogin), #selector(toggleLoginItem))
        login.state = loginItemEnabled ? .on : .off

        menu.addItem(.separator())
        addLanguageMenu()

        menu.addItem(.separator())
        let quit = addAction(L.text(.quit), #selector(quit))
        quit.keyEquivalent = "q"
    }

    private func statusTitle() -> String {
        guard let s = state else { return L.text(.statusNoDaemon) }
        let country = s.country ?? "?"
        let ip = s.ip ?? "?"
        switch s.status {
        case .open:
            return L.text(.statusOpen, country, ip)
        case .blocked:
            return L.text(.statusBlocked, country, ip)
        case .manual:
            return L.text(.statusManual, country, ip)
        case .checking:
            return L.text(.statusChecking)
        }
    }

    @discardableResult
    private func addInfo(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        return item
    }

    @discardableResult
    private func addAction(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        menu.addItem(item)
        return item
    }

    private func addServicesMenu() {
        let item = NSMenuItem(title: L.text(.services), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for service in state?.services ?? [] {
            let entry = NSMenuItem(title: service.name, action: #selector(toggleService(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = service.id
            entry.state = service.enabled ? .on : .off
            submenu.addItem(entry)
        }
        item.submenu = submenu
        item.isEnabled = state != nil
        menu.addItem(item)
    }

    @objc private func toggleService(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let service = state?.services.first(where: { $0.id == id }) else { return }
        send(service.enabled ? .serviceOff(id) : .serviceOn(id))
    }

    private func addLanguageMenu() {
        let item = NSMenuItem(title: L.text(.language), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for language in Language.allCases {
            let entry = NSMenuItem(title: language.nativeName, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = language.rawValue
            entry.state = language == Language.current ? .on : .off
            submenu.addItem(entry)
        }
        item.submenu = submenu
        menu.addItem(item)
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let language = Language(rawValue: raw) else { return }
        Language.current = language
        updateIcon()
    }

    private func shorten(_ text: String) -> String {
        text.count > 70 ? String(text.prefix(70)) + "…" : text
    }

    // MARK: Actions

    @objc private func toggleManual() {
        guard let s = state else { return }
        send(s.manualBlock ? .manualOff : .manualOn)
    }

    @objc private func recheckNow() {
        send(.recheck)
    }

    @objc private func openLog() {
        let url = URL(fileURLWithPath: FencePaths.logFile)
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: FencePaths.logDir)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Login item

    private var loginAgentPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(FenceConfig.appLabel).plist"
    }

    private var loginItemEnabled: Bool {
        FileManager.default.fileExists(atPath: loginAgentPath)
    }

    @objc private func toggleLoginItem() {
        if loginItemEnabled {
            try? FileManager.default.removeItem(atPath: loginAgentPath)
            return
        }
        guard let executable = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": FenceConfig.appLabel,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        let dir = (loginAgentPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: loginAgentPath))
    }
}
