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
    /// dimmed while a switch is running, orange when the CLI and FPM disagree.
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
        button.image = agrees ? Self.icon : Self.tinted(.systemOrange)
        button.toolTip = "CLI  \(state.linkedVersion.map { "PHP \($0)" } ?? "not linked")\n"
            + "FPM  \(state.fpmVersion.map { "PHP \($0)" } ?? "stopped")"
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
