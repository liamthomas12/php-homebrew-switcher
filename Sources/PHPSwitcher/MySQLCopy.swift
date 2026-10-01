import Foundation

/// Lets a failing command travel in a `Result`.
extension CommandResult: Error {}

/// Copies one database from the shared data dir into a separate one (`var/mysql@8.4`).
///
/// Only one server can own port 3306, so whichever side is not the live server is started
/// temporarily on a private socket with networking off, then shut down again.
enum MySQLCopy {

    /// Temporary servers listen on `/tmp/phpswitcher-<formula>.sock`; detection skips them.
    static let socketPrefix = "/tmp/phpswitcher-"

    private static let systemDatabases: Set<String> = ["mysql", "sys", "performance_schema", "information_schema"]

    /// The formula that has its own data dir to copy into.
    static var targetFormula: String? { MySQLDetector.separateDataDirs.sorted().first }

    /// Database names in `dir`, from its folder names — no server needed.
    static func databases(in dir: URL) -> [String] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return entries.compactMap { entry -> String? in
            var isDirectory: ObjCBool = false
            guard !entry.hasPrefix("#"), !entry.hasPrefix("."),
                  fm.fileExists(atPath: dir.appendingPathComponent(entry).path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            let name = decodeFilename(entry)
            return systemDatabases.contains(name) ? nil : name
        }
        .sorted()
    }

    /// MySQL stores "my-db" as the folder "my@002ddb".
    private static func decodeFilename(_ name: String) -> String {
        guard name.contains("@") else { return name }
        var result = ""
        var rest = Substring(name)
        while let at = rest.firstIndex(of: "@") {
            result += rest[..<at]
            let hex = rest[rest.index(after: at)...].prefix(4)
            if hex.count == 4, let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                result.unicodeScalars.append(scalar)
                rest = rest[rest.index(at, offsetBy: 5)...]
            } else {
                result += "@"
                rest = rest[rest.index(after: at)...]
            }
        }
        return result + rest
    }

    /// The keg that serves the shared data dir: the live one if it is running, otherwise the
    /// installed keg matching the data version, otherwise the newest shared-dir keg.
    static func sourceKeg(_ state: MySQLState) -> Keg? {
        let shared = state.installs.filter { !MySQLDetector.hasSeparateDataDir($0.formula) }
        if let live = state.serverFormula, let keg = shared.first(where: { $0.formula == live }) {
            return keg
        }
        if let version = shared.lazy.compactMap({ state.dataVersions[$0.formula] }).first {
            let wanted = Keg(formula: "", version: version).shortVersion
            if let keg = shared.first(where: { $0.shortVersion == wanted }) { return keg }
        }
        return shared.first
    }

    /// Runs synchronously — call it off the main thread.
    static func copy(database: String, state: MySQLState, progress: @escaping (String) -> Void) -> SwitchOutcome {
        guard let targetFormula, let target = state.install(named: targetFormula) else {
            return .failed(failure("copy \(database)", "No MySQL with a separate data dir is installed."))
        }
        guard let source = sourceKeg(state) else {
            return .failed(failure("copy \(database)", "No MySQL on the shared data dir is installed."))
        }

        if MySQLDetector.needsInit(target.formula) {
            progress("Creating the \(target.shortVersion) data folder…")
            let initialise = MySQLService.initialiseDataDir(target.formula)
            if !initialise.succeeded { return .failed(initialise) }
        }

        var temporary: [TemporaryServer] = []
        defer {
            for server in temporary {
                progress("Stopping temporary \(server.keg.formula)…")
                server.shutDown()
            }
        }

        // nil socket = the live server on the default socket.
        func socket(for keg: Keg) -> Result<String?, CommandResult> {
            if state.serverFormula == keg.formula { return .success(nil) }
            progress("Starting temporary \(keg.formula)…")
            switch TemporaryServer.start(keg) {
            case .success(let server):
                temporary.append(server)
                return .success(server.socket)
            case .failure(let result):
                return .failure(result)
            }
        }

        let sourceSocket: String?
        let targetSocket: String?
        switch socket(for: source) {
        case .success(let path): sourceSocket = path
        case .failure(let result): return .failed(result)
        }
        switch socket(for: target) {
        case .success(let path): targetSocket = path
        case .failure(let result): return .failed(result)
        }

        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.classcreative.phpswitcher")
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let dump = cache.appendingPathComponent("\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: dump) }

        progress("Dumping \(database) from \(source.shortVersion)…")
        let dumped = CommandRunner.run(
            MySQLDetector.tool("mysqldump", of: source.formula),
            ["-uroot"] + (sourceSocket.map { ["--socket=\($0)"] } ?? []) + [
                "--single-transaction", "--routines", "--triggers", "--events",
                "--add-drop-database", "--databases", database, "--result-file=\(dump.path)",
            ],
            timeout: 1800
        )
        if !dumped.succeeded { return .failed(dumped) }

        progress("Importing \(database) into \(target.shortVersion)…")
        let imported = CommandRunner.run(
            MySQLDetector.tool("mysql", of: target.formula),
            ["-uroot"] + (targetSocket.map { ["--socket=\($0)"] } ?? []) + ["-e", "source \(dump.path)"],
            timeout: 3600
        )
        return imported.succeeded ? .success : .failed(imported)
    }

    private static func failure(_ command: String, _ message: String) -> CommandResult {
        CommandResult(command: command, exitCode: -1, stdout: "", stderr: message)
    }
}

/// A mysqld started for the length of a copy: its own data dir, a private socket, no TCP.
private struct TemporaryServer {
    let keg: Keg
    let socket: String
    let process: Process

    static func start(_ keg: Keg) -> Result<TemporaryServer, CommandResult> {
        let dir = MySQLDetector.dataDir(for: keg.formula)
        let socket = "\(MySQLCopy.socketPrefix)\(keg.formula).sock"
        let log = dir.appendingPathComponent("phpswitcher-temporary.err")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: MySQLDetector.tool("mysqld", of: keg.formula))
        process.arguments = [
            "--no-defaults",
            "--basedir=\(Brew.prefix)/opt/\(keg.formula)",
            "--datadir=\(dir.path)",
            "--socket=\(socket)",
            "--skip-networking",
            "--mysqlx=OFF",
            "--pid-file=\(dir.appendingPathComponent("phpswitcher-temporary.pid").path)",
            "--log-error=\(log.path)",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let command = ([process.executableURL!.path] + process.arguments!).joined(separator: " ")
        do {
            try process.run()
        } catch {
            return .failure(CommandResult(command: command, exitCode: -1, stdout: "", stderr: error.localizedDescription))
        }

        let server = TemporaryServer(keg: keg, socket: socket, process: process)
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, process.isRunning {
            if MySQLDetector.serverAnswers(keg, socket: socket) { return .success(server) }
            Thread.sleep(forTimeInterval: 0.5)
        }
        server.shutDown()
        let tail = (try? String(contentsOf: log, encoding: .utf8))
            .map { $0.split(separator: "\n").suffix(15).joined(separator: "\n") } ?? ""
        return .failure(CommandResult(
            command: command, exitCode: process.isRunning ? -2 : process.terminationStatus, stdout: "",
            stderr: "Temporary \(keg.formula) server did not start.\n\n\(tail)"
        ))
    }

    func shutDown() {
        if process.isRunning {
            _ = CommandRunner.run(
                MySQLDetector.tool("mysqladmin", of: keg.formula),
                ["-uroot", "--socket=\(socket)", "shutdown"], timeout: 30
            )
        }
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }
}
