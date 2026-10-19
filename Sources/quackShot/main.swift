import AppKit
import QuackShotCore

let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("quackShot: \(message)\n\n\(usage)\n".utf8))
    exit(2)
}

let command: Command
switch parseCommand(Array(CommandLine.arguments.dropFirst())) {
case .success(let c): command = c
case .failure(let e): fail(e.description)
}

switch command {
case .help:
    print(usage)
case .version:
    print("quackShot \(version)")
case .config:
    if !FileManager.default.fileExists(atPath: Config.path.path) { Config().save() }
    print(Config.path.path)
case .selfTest(let dir):
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    exit(MainActor.assumeIsolated { SelfTest.run(outputDirectory: dir) })
case .agent:
    let app = NSApplication.shared
    let delegate = MainActor.assumeIsolated { AppDelegate() }
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
case .gui, .full:
    let app = NSApplication.shared
    let delegate = MainActor.assumeIsolated { OneShotDelegate(command: command) }
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
