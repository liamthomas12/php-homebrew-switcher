import Foundation

/// One installed Homebrew PHP keg.
struct PHPInstall: Equatable {
    /// Formula name as brew knows it: "php", "php@8.4", ...
    let formula: String
    /// Full version from the Cellar directory: "8.4.25", "7.4.33_13".
    let version: String

    /// "8.4" — the major.minor pair used in menu titles and config paths.
    var shortVersion: String {
        let parts = version.split(separator: ".")
        guard parts.count >= 2 else { return version }
        return "\(parts[0]).\(parts[1])"
    }

    /// Numeric sort key, newest first.
    var sortKey: (Int, Int, Int) {
        let numbers = version.split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
        return (numbers.first ?? 0, numbers.count > 1 ? numbers[1] : 0, numbers.count > 2 ? numbers[2] : 0)
    }
}

/// A snapshot of what PHP is installed and what is currently active.
struct PHPState {
    var installs: [PHPInstall] = []
    /// Formula the `php` CLI symlink currently resolves to, if any.
    var linkedFormula: String?
    var linkedVersion: String?
    /// Formula whose php-fpm service is currently running, if any.
    var fpmFormula: String?
    var fpmVersion: String?
    /// Formulas with a loaded launchd service (used to stop everything before switching).
    var loadedServiceFormulas: [String] = []
    /// Whether nginx is installed via Homebrew, and whether its service is running.
    var nginxInstalled: Bool = false
    var nginxRunning: Bool = false
    /// Where the vhost files live, if that folder exists.
    var sitesFolder: URL?
    /// Set when Homebrew itself could not be found.
    var brewMissing: Bool = false

    var linkedShortVersion: String? {
        linkedVersion.map { PHPInstall(formula: "", version: $0).shortVersion }
    }
    var fpmShortVersion: String? {
        fpmVersion.map { PHPInstall(formula: "", version: $0).shortVersion }
    }

    func install(named formula: String) -> PHPInstall? {
        installs.first { $0.formula == formula }
    }
}

enum PHPDetector {

    /// Matches "php" and "php@8.4" but nothing else under Cellar.
    private static let formulaPattern = try! NSRegularExpression(
        pattern: #"^php(@\d+\.\d+)?$"#
    )

    /// Full snapshot. Cheap: filesystem reads plus `launchctl list` and `ps`.
    static func detect() -> PHPState {
        var state = PHPState()
        guard Brew.isInstalled else {
            state.brewMissing = true
            return state
        }
        state.installs = installedVersions()

        if let linked = linkedCLI() {
            state.linkedFormula = linked.formula
            state.linkedVersion = linked.version
        }

        let loaded = loadedBrewServices()
        state.loadedServiceFormulas = loaded.filter { matchesPHPFormula($0) }
        state.nginxInstalled = FileManager.default.fileExists(
            atPath: Brew.cellarURL.appendingPathComponent("nginx").path
        )
        state.nginxRunning = loaded.contains("nginx")
        state.sitesFolder = sitesFolder()
        if let fpm = runningFPM(installs: state.installs, loaded: state.loadedServiceFormulas) {
            state.fpmFormula = fpm
            state.fpmVersion = state.install(named: fpm)?.version
        }
        return state
    }

    /// Every php keg under <prefix>/Cellar, newest version first.
    static func installedVersions() -> [PHPInstall] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: Brew.cellarURL.path) else {
            return []
        }
        var installs: [PHPInstall] = []
        for entry in entries {
            let range = NSRange(entry.startIndex..., in: entry)
            guard formulaPattern.firstMatch(in: entry, range: range) != nil else { continue }
            let kegDir = Brew.cellarURL.appendingPathComponent(entry)
            guard let versions = try? fm.contentsOfDirectory(atPath: kegDir.path) else { continue }
            let candidates = versions
                .filter { !$0.hasPrefix(".") }
                .map { PHPInstall(formula: entry, version: $0) }
                .sorted { $0.sortKey > $1.sortKey }
            if let newest = candidates.first { installs.append(newest) }
        }
        return installs.sorted { $0.sortKey > $1.sortKey }
    }

    /// The nginx vhost folder: "sites-available" if this setup uses the Debian layout,
    /// otherwise Homebrew's own "servers". nil when neither exists.
    static func sitesFolder() -> URL? {
        for name in ["sites-available", "servers"] {
            let url = Brew.etcNginxURL.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return url
            }
        }
        return nil
    }

    /// Resolves <prefix>/bin/php back to the keg it is linked from.
    static func linkedCLI() -> (formula: String, version: String)? {
        let phpLink = Brew.binURL.appendingPathComponent("php")
        guard FileManager.default.fileExists(atPath: phpLink.path) else { return nil }
        let resolved = phpLink.resolvingSymlinksInPath().path
        return kegComponents(fromPath: resolved)
    }

    /// Pulls (formula, version) out of ".../Cellar/php@8.4/8.4.25/bin/php".
    static func kegComponents(fromPath path: String) -> (formula: String, version: String)? {
        let cellarPrefix = Brew.cellarURL.path + "/"
        guard path.hasPrefix(cellarPrefix) else { return nil }
        let parts = path.dropFirst(cellarPrefix.count).split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    static func matchesPHPFormula(_ name: String) -> Bool {
        let range = NSRange(name.startIndex..., in: name)
        return formulaPattern.firstMatch(in: name, range: range) != nil
    }

    /// Every Homebrew formula with a launchd job loaded and actually running (non-zero PID).
    static func loadedBrewServices() -> [String] {
        let result = CommandRunner.run("/bin/launchctl", ["list"], timeout: 15)
        guard result.succeeded else { return [] }
        var formulas: [String] = []
        for line in result.stdout.split(separator: "\n") {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 3 else { continue }
            let pid = columns[0].trimmingCharacters(in: .whitespaces)
            let label = columns[2].trimmingCharacters(in: .whitespaces)
            guard Int(pid) != nil else { continue }  // "-" means loaded but not running
            for domain in ["sh.brew.", "homebrew.mxcl."] where label.hasPrefix(domain) {
                let formula = String(label.dropFirst(domain.count))
                if !formula.isEmpty, !formulas.contains(formula) {
                    formulas.append(formula)
                }
            }
        }
        return formulas
    }

    /// The formula serving php-fpm right now.
    ///
    /// Prefers the launchd label, but cross-checks against the master process's config path
    /// so a loaded-but-dead job does not read as running.
    static func runningFPM(installs: [PHPInstall], loaded: [String]) -> String? {
        guard let confShortVersion = runningFPMConfigVersion() else { return nil }
        // Match the launchd label whose keg matches the live master process.
        for formula in loaded {
            if let install = installs.first(where: { $0.formula == formula }),
               install.shortVersion == confShortVersion {
                return formula
            }
        }
        // FPM is running but was not started through brew services — report the keg anyway.
        return installs.first { $0.shortVersion == confShortVersion }?.formula
    }

    /// Reads "<prefix>/etc/php/8.5/php-fpm.conf" out of the running master process's command line.
    static func runningFPMConfigVersion() -> String? {
        let result = CommandRunner.run("/bin/ps", ["-axo", "command"], timeout: 15)
        guard result.succeeded else { return nil }
        let needle = Brew.etcPHPURL.path + "/"
        for line in result.stdout.split(separator: "\n") {
            guard line.contains("php-fpm"), line.contains("master process"),
                  let range = line.range(of: needle) else { continue }
            let tail = line[range.upperBound...]
            if let slash = tail.firstIndex(of: "/") {
                return String(tail[..<slash])
            }
        }
        return nil
    }
}
