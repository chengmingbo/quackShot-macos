import AppKit
import UserNotifications
import QuackShotCore

/// Menu bar mode: a status item, the global hot key, settings, and the
/// permission guide on first launch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            // Already running in the menu bar; a second copy would fight it
            // for the hot key.
            NSApp.terminate(nil)
            return
        }
        if Permissions.canUseNotifications {
            UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "quackShot")
        menu.delegate = self
        item.menu = menu
        statusItem = item

        let cfg = Config.load()
        HotKeyCenter.shared.install(cfg.hotkey) { [weak self] in self?.captureRegion() }
        SettingsWindowController.shared.model.onHotKeyChange = { key in
            HotKeyCenter.shared.register(key)
            SettingsWindowController.shared.model.hotKeyFailure = HotKeyCenter.shared.failure
        }

        // First launch, or permission lost (e.g. after an update re-signed
        // the app): explain before the first capture fails.
        if !cfg.onboardingDone || !Permissions.screenRecordingPreflight {
            showPermissions()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let region = menu.addItem(withTitle: "Capture Region", action: #selector(captureRegion), keyEquivalent: "")
        if let key = HotKeyCenter.shared.registered {
            region.title = "Capture Region    \(key.display)"
        }
        menu.addItem(withTitle: "Capture Region in 3 Seconds", action: #selector(captureDelayed), keyEquivalent: "")
        menu.addItem(withTitle: "Capture Full Screen", action: #selector(captureFull), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Screenshots Folder", action: #selector(openFolder), keyEquivalent: "")
        if !Permissions.screenRecordingPreflight {
            let warn = menu.addItem(withTitle: "⚠︎ Screen Recording Not Enabled…", action: #selector(showPermissions), keyEquivalent: "")
            warn.toolTip = "quackShot cannot capture until Screen Recording is allowed."
        }
        if let failure = HotKeyCenter.shared.failure {
            let warn = menu.addItem(withTitle: "⚠︎ Shortcut Unavailable…", action: #selector(showSettings), keyEquivalent: "")
            warn.toolTip = failure
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Permissions…", action: #selector(showPermissions), keyEquivalent: "")
        menu.addItem(withTitle: "About quackShot", action: #selector(about), keyEquivalent: "")
        menu.addItem(withTitle: "Quit quackShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
    }

    @objc func captureRegion() {
        startRegion(Options())
    }

    @objc func captureDelayed() {
        var o = Options()
        o.delayMs = 3000
        startRegion(o)
    }

    private func startRegion(_ o: Options) {
        CaptureSession.start(options: o, onPermissionMissing: { [weak self] in self?.showPermissions() }) { _ in }
    }

    @objc func captureFull() {
        Task { _ = await FullCapture.run(Options(), onPermissionMissing: { [weak self] in self?.showPermissions() }) }
    }

    @objc func openFolder() {
        let dir = Config.load().saveDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc func showSettings() {
        SettingsWindowController.shared.show { [weak self] in self?.showPermissions() }
    }

    @objc func showPermissions() {
        PermissionsWindowController.shared.show(hotkey: HotKeyCenter.shared.registered?.display ?? Config.load().hotkey.display)
    }

    @objc func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "quackShot",
            .credits: NSAttributedString(string: "A Flameshot-style screenshot tool. Quack — like the duck."),
        ])
    }
}

/// `quackShot gui` / `quackShot full`: do one capture, then exit.
@MainActor
final class OneShotDelegate: NSObject, NSApplicationDelegate {
    let command: Command

    init(command: Command) { self.command = command }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Permissions.canUseNotifications {
            UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        }
        let missing = {
            FileHandle.standardError.write(Data("quackShot: \(CaptureError.permission)\n".utf8))
            Permissions.requestScreenRecording()
        }
        switch command {
        case .gui(let o):
            CaptureSession.start(options: o, onPermissionMissing: missing) { code in Self.exitWhenPinsClose(code) }
        case .full(let o):
            Task {
                let code = await FullCapture.run(o, onPermissionMissing: missing)
                exit(code)
            }
        default:
            exit(2)
        }
    }

    static func exitWhenPinsClose(_ code: Int32) {
        if PinWindow.count == 0 { exit(code) }
        PinWindow.onAllClosed = { exit(code) }
    }
}

/// Whole-desktop capture without the editor (menu item and `full`).
@MainActor
enum FullCapture {
    static func run(_ o: Options, onPermissionMissing: () -> Void) async -> Int32 {
        let cfg = Config.load()
        if o.delayMs > 0 { try? await Task.sleep(nanoseconds: UInt64(o.delayMs) * 1_000_000) }
        let shots: [ScreenShot]
        do {
            shots = try await Capture.screens()
        } catch CaptureError.permission {
            onPermissionMissing()
            return 2
        } catch {
            Output.reportError("\(error)", config: cfg)
            return 2
        }
        guard let (stitched, scale) = Capture.stitch(shots) else {
            Output.reportError("could not combine screens", config: cfg)
            return 2
        }
        let full = CGRect(x: 0, y: 0, width: stitched.width, height: stitched.height)
        // --region is in points from the top-left of the desktop.
        let region = o.region.map { $0.scaled(scale).clamped(to: full) } ?? full
        guard !region.isTiny, let image = export(base: stitched, shapes: [], selection: region) else {
            Output.reportError("region is outside the screen", config: cfg)
            return 2
        }
        let points = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        do {
            var saved: URL?
            if let p = o.path {
                let url = resolveTarget(p, config: cfg)
                try writeImage(image, to: url)
                saved = url
            }
            if o.clipboard { Output.copy(image, pointSize: points) }
            if o.raw { try Output.writeStdout(image) }
            if !(o.path != nil || o.clipboard || o.raw) {
                let url = defaultTarget(cfg)
                try writeImage(image, to: url)
                saved = url
            }
            if let saved {
                (o.raw ? FileHandle.standardError : FileHandle.standardOutput).write(Data((saved.path + "\n").utf8))
                Output.notify(config: cfg, title: "Screenshot saved", body: saved.lastPathComponent, file: saved)
            }
            Output.playShutter(config: cfg)
            return 0
        } catch {
            Output.reportError("\(error)", config: cfg)
            return 2
        }
    }
}
