import Foundation

/// Result of running an external command.
struct CommandResult {
    let command: String
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }

    /// stderr if there is any, otherwise stdout — whichever carries the message.
    var message: String {
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CommandRunner {
    /// Runs an executable directly (no shell) and captures its output.
    /// Times out after `timeout` seconds, terminating the process.
    static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 120
    ) -> CommandResult {
        let display = ([executable] + arguments).joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return CommandResult(
                command: display, exitCode: -1, stdout: "",
                stderr: "Failed to launch \(executable): \(error.localizedDescription)"
            )
        }

        // Drain both pipes on background queues so a full pipe buffer cannot deadlock us.
        var outData = Data()
        var errData = Data()
        let lock = NSLock()
        let group = DispatchGroup()
        for (handle, isStdout) in [(outPipe.fileHandleForReading, true), (errPipe.fileHandleForReading, false)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let data = handle.readDataToEndOfFile()
                lock.lock()
                if isStdout { outData = data } else { errData = data }
                lock.unlock()
                group.leave()
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                timedOut = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        _ = group.wait(timeout: .now() + 5)

        lock.lock()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        var stderr = String(data: errData, encoding: .utf8) ?? ""
        lock.unlock()

        if timedOut {
            stderr += "\nCommand timed out after \(Int(timeout))s."
        }

        return CommandResult(
            command: display,
            exitCode: timedOut ? -2 : process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }
}

/// Locates Homebrew and runs `brew` subcommands with a minimal, predictable environment.
enum Brew {
    /// Homebrew prefix, e.g. /opt/homebrew or /usr/local.
    static let prefix: String = {
        if let path = brewPath {
            // <prefix>/bin/brew -> <prefix>
            return URL(fileURLWithPath: path).deletingLastPathComponent()
                .deletingLastPathComponent().path
        }
        return "/opt/homebrew"
    }()

    /// Absolute path to the brew binary, or nil if Homebrew is not installed.
    static let brewPath: String? = {
        for candidate in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // Last resort: ask the login shell where brew lives.
        let which = CommandRunner.run(
            "/usr/bin/env", ["which", "brew"],
            environment: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"],
            timeout: 10
        )
        let path = which.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return which.succeeded && !path.isEmpty ? path : nil
    }()

    static var isInstalled: Bool { brewPath != nil }

    static var cellarURL: URL { URL(fileURLWithPath: prefix).appendingPathComponent("Cellar") }
    static var binURL: URL { URL(fileURLWithPath: prefix).appendingPathComponent("bin") }
    static var etcPHPURL: URL {
        URL(fileURLWithPath: prefix).appendingPathComponent("etc/php")
    }
    static var etcNginxURL: URL {
        URL(fileURLWithPath: prefix).appendingPathComponent("etc/nginx")
    }

    private static var environment: [String: String] {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return [
            "PATH": "\(prefix)/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home,
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
            "HOMEBREW_NO_INSTALL_CLEANUP": "1",
            "HOMEBREW_NO_COLOR": "1",
        ]
    }

    /// Runs `brew <arguments>`.
    static func run(_ arguments: [String], timeout: TimeInterval = 120) -> CommandResult {
        guard let brewPath else {
            return CommandResult(
                command: "brew " + arguments.joined(separator: " "),
                exitCode: -1, stdout: "",
                stderr: "Homebrew was not found at /opt/homebrew/bin/brew or /usr/local/bin/brew."
            )
        }
        return CommandRunner.run(brewPath, arguments, environment: environment, timeout: timeout)
    }
}
