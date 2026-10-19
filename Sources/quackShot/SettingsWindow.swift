import AppKit
import ServiceManagement
import SwiftUI
import QuackShotCore

@MainActor
final class SettingsModel: ObservableObject {
    @Published var config = Config.load() {
        didSet {
            guard config != oldValue else { return }
            config.save()
            if config.hotkey != oldValue.hotkey { onHotKeyChange?(config.hotkey) }
        }
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?
    @Published var hotKeyFailure: String?
    var onHotKeyChange: ((HotKey) -> Void)?

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Could not change login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = config.saveDirectory
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            config.saveDir = url.path
        }
    }
}

/// Click, then press the new chord. Esc cancels.
struct HotKeyRecorder: View {
    @Binding var hotkey: HotKey
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Type shortcut…" : hotkey.display) {
            recording ? stop() : start()
        }
        .frame(minWidth: 110)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stop()
                return nil
            }
            let f = event.modifierFlags
            let key = HotKey(keyCode: UInt32(event.keyCode), command: f.contains(.command), shift: f.contains(.shift),
                             option: f.contains(.option), control: f.contains(.control))
            if key.hasModifier {
                hotkey = key
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let showPermissions: () -> Void

    var body: some View {
        Form {
            Section("Capture") {
                LabeledContent("Shortcut") {
                    HStack {
                        HotKeyRecorder(hotkey: $model.config.hotkey)
                        if let f = model.hotKeyFailure {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(f)
                        }
                    }
                }
                Toggle("Show magnifier", isOn: $model.config.showMagnifier)
                Toggle("Show keyboard help", isOn: $model.config.showHelp)
                Toggle("Play shutter sound", isOn: $model.config.playSound)
            }
            Section("Saving") {
                LabeledContent("Folder") {
                    HStack {
                        Text(model.config.saveDirectory.path(percentEncoded: false))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { model.chooseFolder() }
                    }
                }
                TextField("File name", text: $model.config.filenamePattern)
                Toggle("⌘S saves without asking", isOn: $model.config.saveWithoutDialog)
                Toggle("Also copy when saving", isOn: $model.config.copyOnSave)
                Toggle("Notifications", isOn: $model.config.notifications)
            }
            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                if let e = model.loginError { Text(e).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("Permissions…") { showPermissions() }
                    Button("Open Config File") {
                        model.config.save()
                        NSWorkspace.shared.activateFileViewerSelecting([Config.path])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    let model = SettingsModel()
    private var window: NSWindow?

    func show(showPermissions: @escaping () -> Void) {
        model.config = Config.load()
        model.hotKeyFailure = HotKeyCenter.shared.failure
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model, showPermissions: showPermissions)))
            w.title = "quackShot Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
