import Foundation

/// Outcome of a switch attempt: either everything ran, or the first failing command.
enum SwitchOutcome {
    case success
    case failed(CommandResult)
}

enum Switcher {

    /// Switches both the CLI link and the running FPM service to `target`.
    ///
    /// 1. stop every running php service
    /// 2. unlink the currently linked php formula
    /// 3. link --force --overwrite the target
    /// 4. start the target's service
    ///
    /// Runs synchronously — call it off the main thread. `progress` is invoked with a short
    /// description before each command, on an arbitrary queue.
    static func switchTo(_ target: PHPInstall, state: PHPState, progress: @escaping (String) -> Void) -> SwitchOutcome {
        for formula in state.loadedServiceFormulas {
            progress("Stopping \(formula)…")
            let result = Brew.run(["services", "stop", formula])
            // A service that is already stopped is not a failure worth aborting on.
            if !result.succeeded, !result.message.lowercased().contains("not started") {
                return .failed(result)
            }
        }

        let previous = state.linkedFormula
        if let linked = previous, linked != target.formula {
            progress("Unlinking \(linked)…")
            let result = Brew.run(["unlink", linked])
            if !result.succeeded { return .failed(result) }
        }

        progress("Linking \(target.formula)…")
        let link = Brew.run(["link", "--force", "--overwrite", target.formula])
        if !link.succeeded {
            // Never leave the machine with no php on PATH: put the old version back.
            rollback(to: previous, progress: progress)
            return .failed(link)
        }

        progress("Starting \(target.formula)…")
        let start = Brew.run(["services", "start", target.formula])
        if !start.succeeded { return .failed(start) }

        waitForFPM(target)
        return .success
    }

    /// Re-links the formula that was active before a failed switch, and restarts its service.
    /// Best effort — any error here is swallowed so the original failure is what gets reported.
    private static func rollback(to formula: String?, progress: @escaping (String) -> Void) {
        guard let formula else { return }
        progress("Restoring \(formula)…")
        _ = Brew.run(["link", "--force", "--overwrite", formula])
        _ = Brew.run(["services", "start", formula])
        if let install = PHPDetector.installedVersions().first(where: { $0.formula == formula }) {
            waitForFPM(install)
        }
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

    /// Restarts an arbitrary Homebrew service (nginx).
    static func restartService(_ formula: String) -> SwitchOutcome {
        let result = Brew.run(["services", "restart", formula])
        return result.succeeded ? .success : .failed(result)
    }

    /// launchd takes a moment to spawn the fpm master; give it up to `timeout` seconds so the
    /// menu bar does not flash "off" straight after a successful start.
    private static func waitForFPM(_ target: PHPInstall, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if PHPDetector.runningFPMConfigVersion() == target.shortVersion { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }
}
