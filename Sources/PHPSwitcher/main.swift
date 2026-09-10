import AppKit

// `PHPSwitcher --probe` prints what the app detects and exits — handy for debugging
// detection without the menu bar in the way.
if CommandLine.arguments.contains("--probe") {
    let state = PHPDetector.detect()
    print("brew prefix:      \(Brew.prefix)")
    print("brew binary:      \(Brew.brewPath ?? "not found")")
    print("linked CLI:       \(state.linkedFormula ?? "none") \(state.linkedVersion ?? "")")
    print("running FPM:      \(state.fpmFormula ?? "none") \(state.fpmVersion ?? "")")
    print("loaded services:  \(state.loadedServiceFormulas.joined(separator: ", "))")
    print("sites folder:     \(state.sitesFolder?.path ?? "none")")
    print("nginx:            \(state.nginxInstalled ? (state.nginxRunning ? "running" : "installed, stopped") : "not installed")")
    print("installed:")
    for install in state.installs {
        let flags = [
            state.linkedFormula == install.formula ? "cli" : nil,
            state.fpmFormula == install.formula ? "fpm" : nil,
        ].compactMap { $0 }.joined(separator: "+")
        print("  \(install.shortVersion)\t\(install.version)\t\(install.formula)\t\(flags)")
    }
    exit(0)
}

// `PHPSwitcher --switch php@8.4` runs the same switch sequence the menu uses, from a terminal.
if let index = CommandLine.arguments.firstIndex(of: "--switch") {
    guard index + 1 < CommandLine.arguments.count else {
        print("usage: PHPSwitcher --switch <formula>")
        exit(2)
    }
    let formula = CommandLine.arguments[index + 1]
    let state = PHPDetector.detect()
    guard let install = state.install(named: formula) else {
        print("No installed formula named \(formula)")
        exit(1)
    }
    switch Switcher.switchTo(install, state: state, progress: { print($0) }) {
    case .success:
        let after = PHPDetector.detect()
        print("now: CLI \(after.linkedVersion ?? "none")  FPM \(after.fpmVersion ?? "stopped")")
        exit(0)
    case .failed(let result):
        print("FAILED: \(result.command)\nexit \(result.exitCode)\n\(result.message)")
        exit(1)
    }
}

// `PHPSwitcher --restart nginx` runs the same service restart the menu items use.
if let index = CommandLine.arguments.firstIndex(of: "--restart") {
    guard index + 1 < CommandLine.arguments.count else {
        print("usage: PHPSwitcher --restart <formula>")
        exit(2)
    }
    let formula = CommandLine.arguments[index + 1]
    switch Switcher.restartService(formula) {
    case .success:
        print("restarted \(formula)")
        exit(0)
    case .failed(let result):
        print("FAILED: \(result.command)\nexit \(result.exitCode)\n\(result.message)")
        exit(1)
    }
}

// `PHPSwitcher --icon` reports whether the menu bar artwork resolved out of the bundle.
if CommandLine.arguments.contains("--icon") {
    if let url = Bundle.main.url(forResource: "elephant", withExtension: "svg") {
        let image = NSImage(contentsOf: url)
        print("elephant.svg: \(url.path)")
        print("loaded: \(image != nil)  size: \(image?.size ?? .zero)")
    } else {
        print("elephant.svg not found in bundle — the SF Symbol fallback will be used")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
