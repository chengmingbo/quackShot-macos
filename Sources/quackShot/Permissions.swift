import AppKit
import CoreGraphics
import ScreenCaptureKit
import SwiftUI
import UserNotifications
import QuackShotCore

/// What quackShot needs from TCC, and the first-launch guide that asks for it.
///
/// Only Screen Recording is required. The global hot key goes through
/// Carbon's `RegisterEventHotKey`, which needs neither Accessibility nor
/// Input Monitoring, so the guide deliberately does not ask for those.
/// Notifications are optional and only used to confirm saves and copies.
enum Permissions {
    /// Cheap and synchronous, but macOS caches the answer per process: after
    /// the user grants access it stays `false` until quackShot relaunches.
    static var screenRecordingPreflight: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks ScreenCaptureKit directly. Unlike the preflight this can turn
    /// true without a relaunch on recent macOS versions, so the guide polls
    /// both and believes whichever says yes.
    static func screenRecordingWorks() async -> Bool {
        if screenRecordingPreflight { return true }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return !content.displays.isEmpty
        } catch {
            return false
        }
    }

    /// Shows the system prompt the first time and, either way, adds
    /// quackShot to the Screen Recording list so the user can tick it.
    @discardableResult
    static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    static func openScreenRecordingSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        ]
        for s in urls {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
    }

    static func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        let s = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)"
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    /// UNUserNotificationCenter traps when the process is not an app bundle
    /// (e.g. `swift run`), so every notification path checks this first.
    static var canUseNotifications: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static func notificationStatus() async -> UNAuthorizationStatus? {
        guard canUseNotifications else { return nil }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func requestNotifications() async -> Bool {
        guard canUseNotifications else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Start a fresh copy of the app and quit this one. Screen Recording
    /// access is only picked up by a new process.
    static func relaunch() {
        let path = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundlePath : CommandLine.arguments[0]
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open -n \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

// MARK: - Onboarding window

@MainActor
final class PermissionModel: ObservableObject {
    @Published var screen: Bool = Permissions.screenRecordingPreflight
    @Published var notifications: UNAuthorizationStatus?
    /// Set after the user went to System Settings, when a relaunch is the
    /// likely next step.
    @Published var visitedSettings = false
    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        Task {
            let s = await Permissions.screenRecordingWorks()
            let n = await Permissions.notificationStatus()
            self.screen = s
            self.notifications = n
        }
    }

    func grantScreen() {
        // The first call shows the system alert; later calls do nothing, so
        // always follow up by opening the right Settings pane.
        Permissions.requestScreenRecording()
        Permissions.openScreenRecordingSettings()
        visitedSettings = true
    }

    func grantNotifications() {
        Task {
            if notifications == .denied {
                Permissions.openNotificationSettings()
            } else {
                _ = await Permissions.requestNotifications()
            }
            refresh()
        }
    }
}

struct PermissionRow<Action: View>: View {
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool?
    let optional: Bool
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .frame(width: 30)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if optional {
                        Text("Optional").font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted == true {
                Label("Enabled", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
            } else {
                action()
            }
        }
        .padding(.vertical, 6)
    }
}

struct PermissionsView: View {
    @ObservedObject var model: PermissionModel
    let hotkey: String
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to quackShot").font(.title2.bold())
                    Text("A couple of macOS permissions and you're ready to capture with \(hotkey).")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            PermissionRow(
                symbol: "rectangle.dashed.badge.record",
                title: "Screen Recording",
                detail: "Required to take screenshots. macOS asks for this for any app that reads the screen; quackShot never records video or sends anything anywhere.",
                granted: model.screen,
                optional: false
            ) {
                Button("Grant…") { model.grantScreen() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            PermissionRow(
                symbol: "bell.badge",
                title: "Notifications",
                detail: "Confirms when a screenshot is copied or saved, and lets you click to reveal the file.",
                granted: model.notifications == .authorized || model.notifications == .provisional,
                optional: true
            ) {
                Button(model.notifications == .denied ? "Open Settings…" : "Allow") { model.grantNotifications() }
                    .disabled(model.notifications == nil)
            }

            if !model.screen && model.visitedSettings {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Switched quackShot on in System Settings?", systemImage: "arrow.clockwise.circle")
                        .font(.callout.bold())
                    Text("macOS applies Screen Recording only after the app restarts. If quackShot is already ticked but this still says it's off, the entry belongs to an older build: select it, click −, then press Grant again.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Relaunch quackShot") { Permissions.relaunch() }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }

            Text("No Accessibility or Input Monitoring access is needed — the hot key works without them.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(model.screen ? "Start Capturing" : "Later") { onDone() }
                    .keyboardShortcut(model.screen ? .defaultAction : .cancelAction)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

@MainActor
final class PermissionsWindowController: NSObject, NSWindowDelegate {
    static let shared = PermissionsWindowController()
    private var window: NSWindow?
    private let model = PermissionModel()
    private var onClose: (() -> Void)?

    var isGranted: Bool { model.screen }

    func show(hotkey: String, onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        model.start()
        if window == nil {
            let host = NSHostingController(rootView: PermissionsView(model: model, hotkey: hotkey) { [weak self] in
                self?.window?.close()
            })
            let w = NSWindow(contentViewController: host)
            w.title = "quackShot Permissions"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        var cfg = Config.load()
        if !cfg.onboardingDone {
            cfg.onboardingDone = true
            cfg.save()
        }
        onClose?()
        onClose = nil
    }
}
