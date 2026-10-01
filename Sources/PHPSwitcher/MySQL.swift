import Foundation

/// A snapshot of what MySQL is installed and what is currently active.
struct MySQLState {
    var installs: [Keg] = []
    /// Formula the `mysql` CLI symlink currently resolves to, if any.
    var linkedFormula: String?
    var linkedVersion: String?
    /// Formula whose mysqld is currently running, if any.
    var serverFormula: String?
    var serverVersion: String?
    /// MySQL formulas with a running launchd service (stopped before switching).
    var loadedServiceFormulas: [String] = []
    /// Formula → version that last upgraded its data dir, from `mysql_upgrade_history`.
    /// Missing for a dir that has not been initialised yet.
    var dataVersions: [String: String] = [:]

    var isInstalled: Bool { !installs.isEmpty }

    /// Nothing installed, or the CLI and the running server agree.
    var isHealthy: Bool {
        !isInstalled || (linkedFormula != nil && linkedFormula == serverFormula)
    }

    func install(named formula: String) -> Keg? {
        installs.first { $0.formula == formula }
    }

    /// Whether `target` can open its data dir as it stands.
    func compatibility(of target: Keg) -> DataCompat {
        guard let dataVersion = dataVersions[target.formula] else { return .unknown }
        let data = Keg(formula: "", version: dataVersion).sortKey
        let wanted = target.sortKey
        if (wanted.0, wanted.1) == (data.0, data.1) { return .same }
        return (wanted.0, wanted.1) > (data.0, data.1) ? .upgrade : .downgrade
    }
}

/// How a MySQL version relates to the data dir: MySQL upgrades data one way and never downgrades it.
enum DataCompat {
    case same, upgrade, downgrade, unknown
}

enum MySQLDetector {

    /// Matches "mysql" and "mysql@9.7" but nothing else under Cellar.
    static let formulaPattern = try! NSRegularExpression(
        pattern: #"^mysql(@\d+\.\d+)?$"#
    )

    /// Full snapshot. `loaded` is the output of `PHPDetector.loadedBrewServices()`.
    static func detect(loaded: [String]) -> MySQLState {
        var state = MySQLState()
        state.installs = PHPDetector.kegs(matching: formulaPattern)
        guard state.isInstalled else { return state }

        if let linked = linkedCLI() {
            state.linkedFormula = linked.formula
            state.linkedVersion = linked.version
        }
        state.loadedServiceFormulas = loaded.filter { matches($0) }
        if let server = runningServer() {
            state.serverFormula = server.formula
            state.serverVersion = state.install(named: server.formula)?.version ?? server.version
        }
        for install in state.installs {
            state.dataVersions[install.formula] = dataVersion(in: dataDir(for: install.formula))
        }
        return state
    }

    /// Formulas that get their own data dir, `var/<formula>`, instead of the shared `var/mysql`.
    /// Homebrew's own service for these hard-codes the shared dir, so `MySQLService` runs them
    /// from a LaunchAgent of ours.
    static let separateDataDirs: Set<String> = ["mysql@8.4"]

    static func hasSeparateDataDir(_ formula: String) -> Bool {
        separateDataDirs.contains(formula)
    }

    static func dataDir(for formula: String) -> URL {
        hasSeparateDataDir(formula)
            ? URL(fileURLWithPath: Brew.prefix).appendingPathComponent("var/\(formula)")
            : Brew.varMySQLURL
    }

    /// A separate data dir that does not exist yet, or is empty.
    static func needsInit(_ formula: String) -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dataDir(for: formula).path)) ?? []
        return entries.filter { !$0.hasPrefix(".") }.isEmpty
    }

    /// `<prefix>/opt/<formula>/bin/<tool>`.
    static func tool(_ name: String, of formula: String) -> String {
        URL(fileURLWithPath: Brew.prefix).appendingPathComponent("opt/\(formula)/bin/\(name)").path
    }

    static func matches(_ name: String) -> Bool {
        let range = NSRange(name.startIndex..., in: name)
        return formulaPattern.firstMatch(in: name, range: range) != nil
    }

    /// Resolves <prefix>/bin/mysql back to the keg it is linked from.
    static func linkedCLI() -> (formula: String, version: String)? {
        let link = Brew.binURL.appendingPathComponent("mysql")
        guard FileManager.default.fileExists(atPath: link.path) else { return nil }
        return PHPDetector.kegComponents(fromPath: link.resolvingSymlinksInPath().path)
    }

    /// The keg and PID of the live mysqld process, from its executable path in `ps`.
    /// Matches `.../opt/mysql@9.7/bin/mysqld` and the Cellar path, but not `mysqld_safe`.
    static func runningServer() -> (formula: String, version: String, pid: Int)? {
        let result = CommandRunner.run("/bin/ps", ["-axo", "pid=,command="], timeout: 15)
        guard result.succeeded else { return nil }
        for line in result.stdout.split(separator: "\n") {
            let columns = line.split(separator: " ", maxSplits: 2)
            guard columns.count >= 2, let pid = Int(columns[0]),
                  columns[1].hasSuffix("/bin/mysqld") else { continue }
            // The temporary servers MySQLCopy starts are not the live server.
            if columns.count > 2, columns[2].contains(MySQLCopy.socketPrefix) { continue }
            let resolved = URL(fileURLWithPath: String(columns[1])).resolvingSymlinksInPath().path
            if let keg = PHPDetector.kegComponents(fromPath: resolved), matches(keg.formula) {
                return (keg.formula, keg.version, pid)
            }
        }
        return nil
    }

    /// Whether a server answers on `socket` (the default socket when nil). `mysqladmin ping`
    /// exits 0 as soon as mysqld responds, even when it denies the (credential-less) login.
    static func serverAnswers(_ keg: Keg, socket: String? = nil) -> Bool {
        let arguments = (socket.map { ["--socket=\($0)"] } ?? []) + ["ping", "--connect-timeout=2"]
        return CommandRunner.run(tool("mysqladmin", of: keg.formula), arguments, timeout: 5).succeeded
    }

    /// The last entry of `<dir>/mysql_upgrade_history`, e.g. "9.6.0".
    static func dataVersion(in dir: URL) -> String? {
        let url = dir.appendingPathComponent("mysql_upgrade_history")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let history = json["upgrade_history"] as? [[String: Any]] else { return nil }
        return history.last?["version"] as? String
    }

    /// The last `lines` lines of the newest *.err log in `dir` — where mysqld says why it died.
    static func errorLogTail(in dir: URL, lines: Int = 15) -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        let newest = entries
            .filter { $0.pathExtension == "err" }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
        guard let newest, let text = try? String(contentsOf: newest, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }
}

/// Starts and stops mysqld: `brew services` for formulas on the shared data dir, a LaunchAgent
/// of ours for formulas with a separate one (a copy of brew's, pointed at the other dir).
enum MySQLService {

    static let labelPrefix = "com.classcreative.phpswitcher."

    static func label(for formula: String) -> String { labelPrefix + formula }

    static func plistURL(for formula: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label(for: formula)).plist")
    }

    private static var domain: String { "gui/\(getuid())" }

    static func start(_ formula: String) -> CommandResult {
        guard MySQLDetector.hasSeparateDataDir(formula) else {
            return Brew.run(["services", "start", formula])
        }
        if MySQLDetector.needsInit(formula) {
            let initialise = initialiseDataDir(formula)
            if !initialise.succeeded { return initialise }
        }
        let dir = MySQLDetector.dataDir(for: formula)
        let plist: [String: Any] = [
            "Label": label(for: formula),
            "ProgramArguments": [MySQLDetector.tool("mysqld_safe", of: formula), "--datadir=\(dir.path)"],
            "WorkingDirectory": dir.path,
            "RunAtLoad": true,
            "KeepAlive": true,
        ]
        let url = plistURL(for: formula)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: url)
        } catch {
            return CommandResult(
                command: "write \(url.path)", exitCode: -1, stdout: "",
                stderr: error.localizedDescription
            )
        }
        // A job left loaded by an earlier run would make bootstrap fail; clear it first.
        _ = CommandRunner.run("/bin/launchctl", ["bootout", "\(domain)/\(label(for: formula))"], timeout: 15)
        return CommandRunner.run("/bin/launchctl", ["bootstrap", domain, url.path], timeout: 15)
    }

    /// Stops the service and removes our plist, so it does not come back at login.
    static func stop(_ formula: String) -> CommandResult {
        guard MySQLDetector.hasSeparateDataDir(formula) else {
            return Brew.run(["services", "stop", formula])
        }
        let target = "\(domain)/\(label(for: formula))"
        let result = CommandRunner.run("/bin/launchctl", ["bootout", target], timeout: 30)
        try? FileManager.default.removeItem(at: plistURL(for: formula))
        // Not loaded is the state we wanted anyway.
        let notLoaded = result.message.contains("No such process") || result.message.contains("Could not find")
        return notLoaded
            ? CommandResult(command: result.command, exitCode: 0, stdout: "", stderr: "")
            : result
    }

    static func restart(_ formula: String) -> CommandResult {
        guard MySQLDetector.hasSeparateDataDir(formula) else {
            return Brew.run(["services", "restart", formula])
        }
        let kick = CommandRunner.run(
            "/bin/launchctl", ["kickstart", "-k", "\(domain)/\(label(for: formula))"], timeout: 30
        )
        return kick.succeeded ? kick : start(formula)
    }

    /// Creates an empty data dir the way Homebrew's post_install does: root, no password.
    static func initialiseDataDir(_ formula: String) -> CommandResult {
        let dir = MySQLDetector.dataDir(for: formula)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let result = CommandRunner.run(
            MySQLDetector.tool("mysqld", of: formula),
            [
                "--no-defaults", "--initialize-insecure", "--user=\(NSUserName())",
                "--basedir=\(Brew.prefix)/opt/\(formula)", "--datadir=\(dir.path)", "--tmpdir=/tmp",
            ],
            timeout: 120
        )
        // Only ever called on an empty dir, so a failed run leaves nothing worth keeping —
        // and a half-initialised dir would no longer look like it needs init.
        if !result.succeeded { try? FileManager.default.removeItem(at: dir) }
        return result
    }
}
