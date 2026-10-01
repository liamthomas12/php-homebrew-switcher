import Foundation

/// Outcome of a switch attempt: either everything ran, or the first failing command.
enum SwitchOutcome {
    case success
    case failed(CommandResult)
}

enum Switcher {

    /// Switches both the CLI link and the running FPM service to `target`.
    ///
    /// Runs synchronously — call it off the main thread. `progress` is invoked with a short
    /// description before each command, on an arbitrary queue.
    static func switchTo(_ target: Keg, state: PHPState, progress: @escaping (String) -> Void) -> SwitchOutcome {
        let outcome = switchKeg(
            target, linked: state.linkedFormula, loadedServices: state.loadedServiceFormulas,
            progress: progress, rollbackWait: { waitForFPM($0) }
        )
        if case .success = outcome { waitForFPM(target) }
        return outcome
    }

    /// Switches both the `mysql` CLI link and the running mysqld to `target`.
    ///
    /// `brew services start` returns before mysqld is up, and mysqld can still refuse the data
    /// dir after that — so a server that never comes up is reported with the tail of its error log.
    static func switchMySQL(_ target: Keg, state: MySQLState, progress: @escaping (String) -> Void) -> SwitchOutcome {
        let previousPID = MySQLDetector.runningServer()?.pid
        let outcome = switchKeg(
            target, linked: state.linkedFormula, loadedServices: state.loadedServiceFormulas,
            progress: progress, rollbackWait: { waitForMySQL($0, replacing: previousPID) },
            start: MySQLService.start, stop: MySQLService.stop
        )
        guard case .success = outcome else { return outcome }
        progress("Waiting for mysqld \(target.shortVersion)…")
        return waitForMySQL(target, replacing: previousPID) ? .success : .failed(mysqldDidNotStart(target))
    }

    /// The shared sequence:
    ///
    /// 1. stop every running service of this kind
    /// 2. unlink the currently linked formula
    /// 3. link --force --overwrite the target (--force is what links a keg-only formula)
    /// 4. start the target's service
    ///
    /// `start`/`stop` default to `brew services`; MySQL passes its own for separate data dirs.
    private static func switchKeg(
        _ target: Keg,
        linked previous: String?,
        loadedServices: [String],
        progress: @escaping (String) -> Void,
        rollbackWait: @escaping (Keg) -> Void,
        start: @escaping (String) -> CommandResult = { Brew.run(["services", "start", $0]) },
        stop: (String) -> CommandResult = { Brew.run(["services", "stop", $0]) }
    ) -> SwitchOutcome {
        for formula in loadedServices {
            progress("Stopping \(formula)…")
            let result = stop(formula)
            // A service that is already stopped is not a failure worth aborting on.
            if !result.succeeded, !result.message.lowercased().contains("not started") {
                return .failed(result)
            }
        }

        if let linked = previous, linked != target.formula {
            progress("Unlinking \(linked)…")
            let result = Brew.run(["unlink", linked])
            if !result.succeeded { return .failed(result) }
        }

        progress("Linking \(target.formula)…")
        let link = Brew.run(["link", "--force", "--overwrite", target.formula])
        if !link.succeeded {
            // Never leave the machine without the CLI on PATH: put the old version back.
            rollback(to: previous, progress: progress, wait: rollbackWait, start: start)
            return .failed(link)
        }

        progress("Starting \(target.formula)…")
        let started = start(target.formula)
        if !started.succeeded { return .failed(started) }
        return .success
    }

    /// Re-links the formula that was active before a failed switch, and restarts its service.
    /// Best effort — any error here is swallowed so the original failure is what gets reported.
    private static func rollback(
        to formula: String?, progress: @escaping (String) -> Void,
        wait: (Keg) -> Void, start: (String) -> CommandResult
    ) {
        guard let formula else { return }
        progress("Restoring \(formula)…")
        _ = Brew.run(["link", "--force", "--overwrite", formula])
        _ = start(formula)
        if let keg = installedKeg(formula) { wait(keg) }
    }

    private static func installedKeg(_ formula: String) -> Keg? {
        (PHPDetector.installedVersions() + PHPDetector.kegs(matching: MySQLDetector.formulaPattern))
            .first { $0.formula == formula }
    }

    /// Restarts the php-fpm service for `formula`.
    static func restartFPM(_ formula: String) -> SwitchOutcome {
        let result = Brew.run(["services", "restart", formula])
        guard result.succeeded else { return .failed(result) }
        if let install = PHPDetector.installedVersions().first(where: { $0.formula == formula }) {
            waitForFPM(install)
        }
        return .success
    }

    /// Restarts mysqld for `formula`, reporting the error log if it does not come back.
    static func restartMySQL(_ formula: String) -> SwitchOutcome {
        let previousPID = MySQLDetector.runningServer()?.pid
        let result = MySQLService.restart(formula)
        guard result.succeeded else { return .failed(result) }
        guard let keg = installedKeg(formula) else { return .success }
        return waitForMySQL(keg, replacing: previousPID) ? .success : .failed(mysqldDidNotStart(keg))
    }

    /// Restarts an arbitrary Homebrew service (nginx).
    static func restartService(_ formula: String) -> SwitchOutcome {
        let result = Brew.run(["services", "restart", formula])
        return result.succeeded ? .success : .failed(result)
    }

    /// launchd takes a moment to spawn the fpm master; give it up to `timeout` seconds so the
    /// menu bar does not flash "off" straight after a successful start.
    private static func waitForFPM(_ target: Keg, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if PHPDetector.runningFPMConfigVersion() == target.shortVersion { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// Waits until a *new* mysqld from `target` (not the one with `previousPID`, which may still
    /// be shutting down) answers a ping. mysqld can take a while on first start after an upgrade,
    /// so this waits longer than FPM.
    @discardableResult
    private static func waitForMySQL(_ target: Keg, replacing previousPID: Int?, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let server = MySQLDetector.runningServer(),
               server.formula == target.formula, server.pid != previousPID,
               MySQLDetector.serverAnswers(target) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    private static func mysqldDidNotStart(_ target: Keg) -> CommandResult {
        let dir = MySQLDetector.dataDir(for: target.formula)
        return CommandResult(
            command: "start \(target.formula)",
            exitCode: -3,
            stdout: "",
            stderr: "mysqld \(target.shortVersion) did not start. Last lines of the error log:\n\n"
                + (MySQLDetector.errorLogTail(in: dir) ?? "(no error log found in \(dir.path))")
        )
    }
}
