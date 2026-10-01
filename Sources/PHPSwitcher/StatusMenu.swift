import AppKit
import ServiceManagement

/// Owns the menu bar item: the always-visible "CLI ▸ FPM" title and the version menu.
final class StatusMenuController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var state = PHPState()
    private var busy = false
    private var busyMessage = ""
    private var refreshTimer: Timer?

    private let detectQueue = DispatchQueue(label: "com.classcreative.phpswitcher.detect")
    private let workQueue = DispatchQueue(label: "com.classcreative.phpswitcher.work")

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly

        renderTitle()
        refresh()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit { refreshTimer?.invalidate() }

    // MARK: - Detection

    /// Re-detects state on a background queue, then redraws.
    private func refresh(completion: (() -> Void)? = nil) {
        detectQueue.async { [weak self] in
            let fresh = PHPDetector.detect()
            DispatchQueue.main.async {
                guard let self else { return }
                self.state = fresh
                self.renderTitle()
                self.rebuildMenu()
                completion?()
            }
        }
    }

    // MARK: - Title

    /// The elephant, from Resources/elephant.svg in the app bundle.
    /// Falls back to an SF Symbol when running the bare binary outside a bundle.
    private static let icon: NSImage = {
        let height: CGFloat = 17
        if let url = Bundle.main.url(forResource: "elephant", withExtension: "svg"),
           let image = NSImage(contentsOf: url) {
            let ratio = image.size.height > 0 ? image.size.width / image.size.height : 1
            image.size = NSSize(width: (height * ratio).rounded(), height: height)
            image.isTemplate = true
            image.accessibilityDescription = "PHP version"
            return image
        }
        let fallback = NSImage(
            systemSymbolName: "chevron.left.forwardslash.chevron.right",
            accessibilityDescription: "PHP version"
        ) ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }()

    /// Same silhouette filled with `color`, for the mismatched state.
    private static func tinted(_ color: NSColor) -> NSImage {
        let source = icon
        let image = NSImage(size: source.size)
        image.lockFocus()
        source.draw(in: NSRect(origin: .zero, size: source.size))
        color.set()
        NSRect(origin: .zero, size: source.size).fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        image.accessibilityDescription = source.accessibilityDescription
        return image
    }

    /// The menu bar shows the elephant only. State is carried by its appearance:
    /// dimmed while a switch is running, orange when the CLI and FPM disagree,
    /// or when MySQL is installed and its CLI and server disagree.
    private func renderTitle() {
        guard let button = statusItem.button else { return }
        button.attributedTitle = NSAttributedString(string: "")

        if busy {
            button.image = Self.icon
            button.alphaValue = 0.4
            button.toolTip = busyMessage
            return
        }

        button.alphaValue = 1

        if state.brewMissing {
            button.image = Self.tinted(.systemOrange)
            button.toolTip = "Homebrew was not found."
            return
        }

        let agrees = state.linkedFormula != nil && state.linkedFormula == state.fpmFormula
        button.image = agrees && state.mysql.isHealthy ? Self.icon : Self.tinted(.systemOrange)
        var tip = "CLI  \(state.linkedVersion.map { "PHP \($0)" } ?? "not linked")\n"
            + "FPM  \(state.fpmVersion.map { "PHP \($0)" } ?? "stopped")"
        if state.mysql.isInstalled {
            tip += "\nMySQL CLI     \(state.mysql.linkedVersion ?? "not linked")\n"
                + "MySQL server  \(state.mysql.serverVersion ?? "stopped")"
        }
        button.toolTip = tip
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        if state.brewMissing {
            menu.addItem(disabledItem("Homebrew not found"))
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q").targeting(self))
            return
        }

        let cliText = state.linkedVersion.map { "CLI \($0)" } ?? "CLI not linked"
        let fpmText = state.fpmVersion.map { "FPM \($0)" } ?? "FPM stopped"
        menu.addItem(disabledItem(busy ? busyMessage : "\(cliText)     \(fpmText)"))
        menu.addItem(.separator())

        if state.installs.isEmpty {
            menu.addItem(disabledItem("No PHP formulas installed"))
        }

        for install in state.installs {
            let item = NSMenuItem(
                title: "\(install.shortVersion)   (\(install.formula))",
                action: #selector(selectVersion(_:)),
                keyEquivalent: ""
            ).targeting(self)
            item.representedObject = install.formula
            let isLinked = state.linkedFormula == install.formula
            let isServing = state.fpmFormula == install.formula
            item.state = isLinked && isServing ? .on : (isLinked || isServing ? .mixed : .off)
            item.toolTip = "PHP \(install.version)"
                + (isLinked ? "\nCLI linked" : "")
                + (isServing ? "\nFPM running" : "")
            item.isEnabled = !busy
            menu.addItem(item)
        }

        if state.mysql.isInstalled {
            addMySQLSection()
        }

        menu.addItem(.separator())

        let restart = NSMenuItem(title: "Restart FPM", action: #selector(restartFPM), keyEquivalent: "")
            .targeting(self)
        restart.isEnabled = !busy && (state.fpmFormula ?? state.linkedFormula) != nil
        menu.addItem(restart)

        if state.nginxInstalled {
            let nginx = NSMenuItem(title: "Restart nginx", action: #selector(restartNginx), keyEquivalent: "")
                .targeting(self)
            nginx.isEnabled = !busy
            nginx.toolTip = state.nginxRunning ? "nginx is running" : "nginx is stopped — this will start it"
            menu.addItem(nginx)
        }

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
            .targeting(self)
        refreshItem.isEnabled = !busy
        menu.addItem(refreshItem)

        let configItem = NSMenuItem(
            title: "Open PHP Config Folder", action: #selector(openConfigFolder), keyEquivalent: ""
        ).targeting(self)
        configItem.isEnabled = !busy
        menu.addItem(configItem)

        if let sites = state.sitesFolder {
            let sitesItem = NSMenuItem(
                title: "Open Sites Folder", action: #selector(openSitesFolder), keyEquivalent: ""
            ).targeting(self)
            sitesItem.isEnabled = !busy
            sitesItem.toolTip = sites.path
            menu.addItem(sitesItem)
        }

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            .targeting(self)
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem(title: "Quit PHPSwitcher", action: #selector(quit), keyEquivalent: "q").targeting(self))
    }

    /// Header with the live versions, one item per mysql keg, then Restart MySQL.
    private func addMySQLSection() {
        let mysql = state.mysql
        menu.addItem(.separator())
        let cliText = mysql.linkedVersion.map { "CLI \($0)" } ?? "CLI not linked"
        let serverText = mysql.serverVersion.map { "Server \($0)" } ?? "Server stopped"
        menu.addItem(disabledItem("MySQL  \(cliText)     \(serverText)"))

        for install in mysql.installs {
            let item = NSMenuItem(
                title: "\(install.shortVersion)   (\(install.formula))",
                action: #selector(selectMySQLVersion(_:)),
                keyEquivalent: ""
            ).targeting(self)
            item.representedObject = install.formula
            let isLinked = mysql.linkedFormula == install.formula
            let isServing = mysql.serverFormula == install.formula
            item.state = isLinked && isServing ? .on : (isLinked || isServing ? .mixed : .off)
            item.toolTip = "MySQL \(install.version)"
                + (isLinked ? "\nCLI linked" : "")
                + (isServing ? "\nServer running" : "")
                + "\nData: \(MySQLDetector.dataDir(for: install.formula).path) "
                + "(\(mysql.dataVersions[install.formula] ?? "not created yet"))"
            item.isEnabled = !busy
            menu.addItem(item)
        }

        if let target = MySQLCopy.targetFormula.flatMap(mysql.install(named:)) {
            menu.addItem(copyDatabaseItem(into: target))
        }

        let restart = NSMenuItem(title: "Restart MySQL", action: #selector(restartMySQL), keyEquivalent: "")
            .targeting(self)
        restart.isEnabled = !busy && (mysql.serverFormula ?? mysql.linkedFormula) != nil
        menu.addItem(restart)
    }

    /// "Copy Database to 8.4 ▸" — one item per database in the shared data dir, checked when
    /// the separate dir already has it.
    private func copyDatabaseItem(into target: Keg) -> NSMenuItem {
        let item = NSMenuItem(title: "Copy Database to \(target.shortVersion)", action: nil, keyEquivalent: "")
        item.isEnabled = !busy
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let existing = Set(MySQLCopy.databases(in: MySQLDetector.dataDir(for: target.formula)))
        let names = MySQLCopy.databases(in: Brew.varMySQLURL)
        if names.isEmpty {
            submenu.addItem(disabledItem("No databases in \(Brew.varMySQLURL.path)"))
        }
        for name in names {
            let entry = NSMenuItem(title: name, action: #selector(copyDatabase(_:)), keyEquivalent: "")
                .targeting(self)
            entry.representedObject = name
            entry.state = existing.contains(name) ? .on : .off
            entry.toolTip = existing.contains(name) ? "Already in \(target.shortVersion) — copying replaces it" : nil
            entry.isEnabled = !busy
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func selectVersion(_ sender: NSMenuItem) {
        guard !busy,
              let formula = sender.representedObject as? String,
              let install = state.install(named: formula) else { return }

        let snapshot = state
        setBusy(true, message: "Switching to PHP \(install.shortVersion)…")

        workQueue.async { [weak self] in
            let outcome = Switcher.switchTo(install, state: snapshot) { message in
                DispatchQueue.main.async { self?.setBusy(true, message: message) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.setBusy(false, message: "")
                self.refresh {
                    if case .failed(let result) = outcome {
                        self.showFailure(result, while: "switching to PHP \(install.shortVersion)")
                    }
                }
            }
        }
    }

    @objc private func selectMySQLVersion(_ sender: NSMenuItem) {
        guard !busy,
              let formula = sender.representedObject as? String,
              let install = state.mysql.install(named: formula),
              confirmDataDir(for: install) else { return }

        let snapshot = state.mysql
        setBusy(true, message: "Switching to MySQL \(install.shortVersion)…")

        workQueue.async { [weak self] in
            let outcome = Switcher.switchMySQL(install, state: snapshot) { message in
                DispatchQueue.main.async { self?.setBusy(true, message: message) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.setBusy(false, message: "")
                self.refresh {
                    if case .failed(let result) = outcome {
                        self.showFailure(result, while: "switching to MySQL \(install.shortVersion)")
                    }
                }
            }
        }
    }

    /// MySQL upgrades a data dir one way and never downgrades it, and a separate data dir starts
    /// empty. Asks before any of those; returns whether to go ahead.
    private func confirmDataDir(for install: Keg) -> Bool {
        let dir = MySQLDetector.dataDir(for: install.formula)
        if MySQLDetector.hasSeparateDataDir(install.formula), MySQLDetector.needsInit(install.formula) {
            return confirm(
                title: "Create a MySQL \(install.shortVersion) data folder?",
                message: "MySQL \(install.shortVersion) keeps its own data in \(dir.path). It starts empty "
                    + "(root, no password); use Copy Database to \(install.shortVersion) to bring databases over.",
                confirmTitle: "Create",
                style: .informational
            )
        }
        let data = state.mysql.dataVersions[install.formula] ?? ""
        switch state.mysql.compatibility(of: install) {
        case .same, .unknown:
            return true
        case .upgrade:
            return confirm(
                title: "Upgrade MySQL data to \(install.shortVersion)?",
                message: "The data in \(dir.path) was last used by MySQL \(data). "
                    + "Starting \(install.shortVersion) upgrades it in place, and older versions "
                    + "cannot open it afterwards. Consider a mysqldump first.",
                confirmTitle: "Upgrade",
                style: .warning
            )
        case .downgrade:
            return confirm(
                title: "MySQL \(install.shortVersion) can't open data from \(data)",
                message: "MySQL does not downgrade a data directory, so the server will refuse to start. "
                    + "Switch anyway only if you just want the \(install.shortVersion) client.",
                confirmTitle: "Switch Anyway",
                style: .critical,
                confirmIsDefault: false
            )
        }
    }

    @objc private func copyDatabase(_ sender: NSMenuItem) {
        guard !busy, let name = sender.representedObject as? String,
              let target = MySQLCopy.targetFormula.flatMap(state.mysql.install(named:)) else { return }
        if sender.state == .on, !confirm(
            title: "Replace \(name) in MySQL \(target.shortVersion)?",
            message: "\(name) already exists in \(MySQLDetector.dataDir(for: target.formula).path). "
                + "Copying drops it there and loads a fresh copy from the shared data.",
            confirmTitle: "Replace",
            style: .warning
        ) { return }

        let snapshot = state.mysql
        setBusy(true, message: "Copying \(name) to \(target.shortVersion)…")
        workQueue.async { [weak self] in
            let outcome = MySQLCopy.copy(database: name, state: snapshot) { message in
                DispatchQueue.main.async { self?.setBusy(true, message: message) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.setBusy(false, message: "")
                self.refresh {
                    if case .failed(let result) = outcome {
                        self.showFailure(result, while: "copying \(name) to MySQL \(target.shortVersion)")
                    }
                }
            }
        }
    }

    @objc private func restartMySQL() {
        guard !busy, let formula = state.mysql.serverFormula ?? state.mysql.linkedFormula else { return }
        setBusy(true, message: "Restarting \(formula)…")
        workQueue.async { [weak self] in
            let outcome = Switcher.restartMySQL(formula)
            DispatchQueue.main.async {
                guard let self else { return }
                self.setBusy(false, message: "")
                self.refresh {
                    if case .failed(let result) = outcome {
                        self.showFailure(result, while: "restarting \(formula)")
                    }
                }
            }
        }
    }

    @objc private func restartFPM() {
        guard !busy, let formula = state.fpmFormula ?? state.linkedFormula else { return }
        setBusy(true, message: "Restarting \(formula)…")
        workQueue.async { [weak self] in
            let outcome = Switcher.restartFPM(formula)
            DispatchQueue.main.async {
                guard let self else { return }
                self.setBusy(false, message: "")
                self.refresh {
                    if case .failed(let result) = outcome {
                        self.showFailure(result, while: "restarting \(formula)")
                    }
                }
            }
        }
    }

    @objc private func restartNginx() {
        guard !busy else { return }
        setBusy(true, message: "Restarting nginx…")
        workQueue.async { [weak self] in
            let outcome = Switcher.restartService("nginx")
            DispatchQueue.main.async {
                guard let self else { return }
                self.setBusy(false, message: "")
                self.refresh {
                    if case .failed(let result) = outcome {
                        self.showFailure(result, while: "restarting nginx")
                    }
                }
            }
        }
    }

    @objc private func refreshNow() {
        refresh()
    }

    @objc private func openConfigFolder() {
        let base = Brew.etcPHPURL
        let target = state.linkedShortVersion.map { base.appendingPathComponent($0) } ?? base
        let url = FileManager.default.fileExists(atPath: target.path) ? target : base
        NSWorkspace.shared.open(url)
    }

    @objc private func openSitesFolder() {
        guard let sites = state.sitesFolder else { return }
        NSWorkspace.shared.open(sites)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            showAlert(
                title: "Could not change the login item",
                message: error.localizedDescription,
                style: .warning
            )
        }
        rebuildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Feedback

    private func setBusy(_ value: Bool, message: String) {
        busy = value
        busyMessage = message
        renderTitle()
        rebuildMenu()
    }

    private func showFailure(_ result: CommandResult, while action: String) {
        showAlert(
            title: "Failed \(action)",
            message: "\(result.command)\nexit \(result.exitCode)\n\n\(result.message)",
            style: .warning
        )
    }

    /// Two-button alert. With `confirmIsDefault` false, Cancel is the button Return presses.
    private func confirm(
        title: String, message: String, confirmTitle: String,
        style: NSAlert.Style, confirmIsDefault: Bool = true
    ) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        if confirmIsDefault {
            alert.addButton(withTitle: confirmTitle)
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: confirmTitle)
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private extension NSMenuItem {
    /// Sets the action target and returns self, so items can be built in one expression.
    func targeting(_ target: AnyObject) -> NSMenuItem {
        self.target = target
        return self
    }
}
